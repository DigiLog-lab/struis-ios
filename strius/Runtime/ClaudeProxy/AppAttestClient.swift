// The token flow (endpoints, client-data bindings, recovery) follows
// anthropics/ClaudeForFoundationModels `AppAttestSession` (Copyright 2026 Anthropic PBC, Apache-2.0).
// That package's credential API is internal to its Foundation Models provider, so the flow is
// reimplemented here for Struis's own Messages API requests.
import CryptoKit
import DeviceCheck
import Foundation
import OSLog
import Security

nonisolated private let attestLog = Logger(subsystem: "com.digiloglab.strius", category: "app-attest")

/// Claude Console の App integration の client ID(`clid_...`)。秘密値ではない(ビルド設定 `STRUIS_CLAUDE_CLIENT_ID`)。
nonisolated enum ClaudeAppAttestConfig {
    static var clientID: String? {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["STRUIS_CLAUDE_CLIENT_ID"], !value.isEmpty { return value }
        #endif
        guard let value = Bundle.main.object(forInfoDictionaryKey: "StruisClaudeClientID") as? String,
              value.hasPrefix("clid_") else { return nil }
        return value
    }
}

/// Anthropic の App Attest: この端末の正規の Struis だと Apple の App Attest で示し、1 時間有効の access token を
/// Anthropic から直接受け取る。API キーも中継サーバーも使わない。
///
/// 1. 初回: Secure Enclave に鍵を作る → チャレンジ → attestation → 登録(最初の token が返る)。
/// 2. 以後: チャレンジに対する assertion を token と交換する。token は `Authorization: Bearer` で Messages API に使う。
/// 鍵の ID と token は、この端末だけの Keychain に置く(バックアップ・同期しない)。
actor AppAttestClient {
    static let shared = AppAttestClient()

    enum Failure: Error, LocalizedError, Equatable {
        case unsupported
        case notConfigured
        case keyInvalidated
        /// 端末側で鍵が使えない(アプリの入れ直し・端末の移行・復元の後は Keychain の ID だけが残る。Apple の指針では鍵を作り直す)。
        case keyUnusable
        case rateLimited
        case requestFailed(endpoint: String, status: Int)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .unsupported: "この端末では App Attest を使えないため、Claude を使えません。"
            case .notConfigured: "Claude の接続設定(client ID)がこのアプリにありません。"
            case .keyInvalidated: "この端末の確認(App Attest)が通りませんでした。少し時間をおいてもう一度試してください。"
            case .keyUnusable: "この端末の確認(App Attest)の鍵を作り直せませんでした。アプリを開き直してもう一度試してください。"
            case .rateLimited: "Claude の利用が一時的に混み合っています。少し時間をおいてもう一度試してください。"
            case .requestFailed(let endpoint, let status): "Claude を使う準備に失敗しました(\(endpoint) HTTP \(status))。"
            case .malformedResponse: "Claude の認証サーバーから想定外の応答が返りました。"
            }
        }
    }

    /// DCAppAttestService の差し替え口(テスト用)。
    protocol Attestation: Sendable {
        var isSupported: Bool { get }
        func generateKey() async throws -> String
        func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
        func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
    }

    struct DeviceAttestation: Attestation {
        var isSupported: Bool { DCAppAttestService.shared.isSupported }
        func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }
        func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
            try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
        }
        func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
            do {
                return try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
            } catch let error as DCError where error.code != .serverUnavailable {
                // アプリの入れ直し・端末の移行・復元では Keychain の ID だけが残り、Secure Enclave の鍵は無い
                // (invalidKey。実機では invalidInput(2) で返ることもある。2026-10-16 の台帳)。Apple の指針どおり鍵を作り直す。
                attestLog.error("app attest assertion failed on device: DCError \(error.code.rawValue)")
                throw Failure.keyUnusable
            }
        }
    }

    nonisolated static var isSupported: Bool { DCAppAttestService.shared.isSupported }

    nonisolated struct StoredToken: Codable, Sendable, Equatable {
        let value: String
        let expiresAt: Date
    }

    private let baseURL: URL
    private let attestation: any Attestation
    private let session: URLSession
    private let keychainService: String
    private var keyID: String?
    private var token: StoredToken?
    private var pendingChallenge: (challenge: Data, expiresAt: Date)?
    private var refreshInFlight: Task<String, Error>?
    private var registrationInFlight: Task<String, Error>?
    private var mintCooldownUntil: Date?
    private var lastKeyReplacement: Date?

    init(baseURL: URL = URL(string: "https://api.anthropic.com")!, attestation: any Attestation = DeviceAttestation(),
         session: URLSession = URLSession(configuration: .ephemeral), keychainService: String = "com.digiloglab.strius.claude-app-attest") {
        self.baseURL = baseURL
        self.attestation = attestation
        self.session = session
        self.keychainService = keychainService
    }

    // MARK: - Token

    /// Messages API に使う bearer token。期限の 60 秒前に取り直す。同時の呼び出しは 1 回の取得にまとめる。
    func currentToken(clientID: String) async throws -> String {
        if token == nil { token = loadToken(clientID) }
        if let token, token.expiresAt > Date().addingTimeInterval(60) { return token.value }
        if let refreshInFlight { return try await refreshInFlight.value }
        let task = Task { try await refresh(clientID: clientID) }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        return try await task.value
    }

    /// Messages API が 401 を返した token を捨てる(次の呼び出しで取り直す)。
    func invalidate(token used: String, clientID: String) {
        guard token?.value == nil || token?.value == used else { return }
        token = nil
        keychainDelete("\(clientID)#token")
    }

    private func refresh(clientID: String) async throws -> String {
        let keyID = try await ensureKey(clientID: clientID, replacing: nil)
        // 初回の登録は token も返す。
        if let token, token.expiresAt > Date().addingTimeInterval(60) { return token.value }
        let minted: StoredToken
        do {
            minted = try await mint(clientID: clientID, keyID: keyID)
        } catch Failure.keyUnusable {
            // 端末側で鍵が使えない。サーバーの 401 と違って待っても変わらないので、すぐ作り直す(1 回だけ。作り直した鍵でも
            // 使えなければ keyUnusable のまま返す)。
            attestLog.error("app attest key unusable on this device, registering a new key")
            let newKey = try await ensureKey(clientID: clientID, replacing: keyID)
            if let token, token.expiresAt > Date() { return token.value }
            minted = try await mint(clientID: clientID, keyID: newKey)
        } catch Failure.keyInvalidated {
            // 期限切れ・競合したチャレンジも同じ 401 になる。もう一度だけ試し、続けて拒まれたら鍵を作り直す(10 分に 1 回まで)。
            do {
                minted = try await mint(clientID: clientID, keyID: keyID)
            } catch Failure.keyInvalidated {
                if let last = lastKeyReplacement, Date().timeIntervalSince(last) < 600 { throw Failure.keyInvalidated }
                lastKeyReplacement = Date()
                attestLog.error("app attest key rejected twice, registering a new key")
                let newKey = try await ensureKey(clientID: clientID, replacing: keyID)
                if let token, token.expiresAt > Date() { return token.value }
                minted = try await mint(clientID: clientID, keyID: newKey)
            }
        }
        store(minted, clientID: clientID)
        return minted.value
    }

    private func store(_ token: StoredToken, clientID: String) {
        self.token = token
        if let data = try? JSONEncoder().encode(token) { keychainSet(data, "\(clientID)#token") }
    }

    private func loadToken(_ clientID: String) -> StoredToken? {
        keychainGet("\(clientID)#token").flatMap { try? JSONDecoder().decode(StoredToken.self, from: $0) }
    }

    // MARK: - Key

    private func ensureKey(clientID: String, replacing rejected: String?) async throws -> String {
        if rejected != nil {
            // 使えない ID を残さない(登録に失敗しても、次は新しい鍵から始める)。
            keyID = nil
            token = nil
            keychainDelete("\(clientID)#key-id")
            keychainDelete("\(clientID)#token")
        }
        if rejected == nil {
            if let keyID { return keyID }
            if let stored = keychainGet("\(clientID)#key-id").map({ String(decoding: $0, as: UTF8.self) }) {
                keyID = stored
                return stored
            }
        }
        if let registrationInFlight { return try await registrationInFlight.value }
        let task = Task { try await register(clientID: clientID) }
        registrationInFlight = task
        defer { registrationInFlight = nil }
        return try await task.value
    }

    private func register(clientID: String) async throws -> String {
        guard attestation.isSupported else { throw Failure.unsupported }
        let newKey = try await attestation.generateKey()
        let challenge = try await fetchChallenge(clientID: clientID, keyID: newKey)
        let object = try await attestation.attestKey(newKey, clientDataHash: Data(SHA256.hash(data: challenge)))
        let (data, status) = try await post("v1/oauth/app-attest/register", contentType: "application/json", body: try JSONSerialization.data(withJSONObject: [
            "client_id": clientID, "key_id": newKey, "attestation_object": object.base64EncodedString(),
        ]))
        try Self.requireSuccess(status, endpoint: "register")
        let first = try ingest(data)
        // 登録が通ってから保存する(登録されていない鍵を次の起動で使わない)。
        keyID = newKey
        keychainSet(Data(newKey.utf8), "\(clientID)#key-id")
        store(first, clientID: clientID)
        attestLog.info("app attest key registered")
        return newKey
    }

    private func mint(clientID: String, keyID: String) async throws -> StoredToken {
        guard let keyBytes = Self.decodeBase64Loose(keyID), keyBytes.count == 32 else { throw Failure.keyInvalidated }
        if let until = mintCooldownUntil, until > Date() { throw Failure.rateLimited }
        let challenge = try await fetchChallenge(clientID: clientID, keyID: keyID)
        let assertion = try await attestation.generateAssertion(keyID, clientDataHash: Self.assertionClientDataHash(challenge: challenge, clientID: clientID, keyID: keyBytes))
        let (data, status, retryAfter) = try await postWithRetryAfter("v1/oauth/token", contentType: "application/x-www-form-urlencoded", body: Data(Self.formEncode([
            "grant_type": "urn:anthropic:params:oauth:grant-type:app-attest",
            "client_id": clientID, "key_id": keyID, "assertion": assertion.base64EncodedString(),
        ]).utf8))
        switch status {
        case 401: throw Failure.keyInvalidated
        case 429:
            mintCooldownUntil = Date().addingTimeInterval(retryAfter ?? 60)
            throw Failure.rateLimited
        default:
            try Self.requireSuccess(status, endpoint: "token")
            return try ingest(data)
        }
    }

    /// 前の応答が渡したチャレンジ(1 回だけ使える)を先に使う。残りが 15 秒未満なら取り直す。
    private func fetchChallenge(clientID: String, keyID: String) async throws -> Data {
        if let pending = pendingChallenge {
            pendingChallenge = nil
            if pending.expiresAt.timeIntervalSinceNow >= 15 { return pending.challenge }
        }
        for attempt in 0..<2 {
            let (data, status) = try await post("v1/oauth/app-attest/challenge", contentType: "application/json",
                                                body: try JSONSerialization.data(withJSONObject: ["client_id": clientID, "key_id": keyID]))
            try Self.requireSuccess(status, endpoint: "challenge")
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = object["challenge"] as? String, let challenge = Self.decodeBase64Loose(text), !challenge.isEmpty
            else { throw Failure.malformedResponse }
            let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue ?? 0
            if expiresIn >= 15 { return challenge }
            // 再発行された古いチャレンジは期限まで待って、次のものを取る。
            if attempt == 0 { try await Task.sleep(for: .seconds(max(expiresIn, 0) + 1)) }
        }
        throw Failure.malformedResponse
    }

    private func ingest(_ data: Data) throws -> StoredToken {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["access_token"] as? String, !value.isEmpty,
              let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0
        else { throw Failure.malformedResponse }
        if let next = object["next_challenge"] as? String, let challenge = Self.decodeBase64Loose(next), !challenge.isEmpty,
           let ttl = (object["next_challenge_expires_in"] as? NSNumber)?.doubleValue, ttl > 0, ttl <= 86_400 {
            pendingChallenge = (challenge, Date().addingTimeInterval(ttl))
        }
        return StoredToken(value: value, expiresAt: Date().addingTimeInterval(min(expiresIn, 86_400)))
    }

    // MARK: - Bindings

    /// token 交換の assertion が署名する内容(サーバーが同じバイト列を組み立てて確かめる)。
    nonisolated static func assertionClientDataHash(challenge: Data, clientID: String, keyID: Data) -> Data {
        var hash = SHA256()
        hash.update(data: Data("anthropic-app-attest-token-v1".utf8))
        hash.update(data: challenge)
        hash.update(data: Data(clientID.utf8))
        hash.update(data: keyID)
        return Data(hash.finalize())
    }

    nonisolated static func formEncode(_ fields: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    nonisolated static func decodeBase64Loose(_ string: String) -> Data? {
        var normalized = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if normalized.count % 4 != 0 { normalized += String(repeating: "=", count: 4 - normalized.count % 4) }
        return Data(base64Encoded: normalized)
    }

    private static func requireSuccess(_ status: Int, endpoint: String) throws {
        guard (200..<300).contains(status) else { throw Failure.requestFailed(endpoint: endpoint, status: status) }
    }

    // MARK: - HTTP

    private func post(_ path: String, contentType: String, body: Data) async throws -> (Data, Int) {
        let (data, status, _) = try await postWithRetryAfter(path, contentType: contentType, body: body)
        return (data, status)
    }

    private func postWithRetryAfter(_ path: String, contentType: String, body: Data) async throws -> (Data, Int, TimeInterval?) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "content-type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init).flatMap { $0 >= 0 && $0 <= 86_400 ? $0 : nil }
        return (data, http?.statusCode ?? 0, retryAfter)
    }

    // MARK: - Keychain(この端末だけ・同期しない)

    private func keychainQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: account]
    }

    private func keychainGet(_ account: String) -> Data? {
        var query = keychainQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
    }

    private func keychainSet(_ data: Data, _ account: String) {
        SecItemDelete(keychainQuery(account) as CFDictionary)
        var attributes = keychainQuery(account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func keychainDelete(_ account: String) {
        SecItemDelete(keychainQuery(account) as CFDictionary)
    }
}
