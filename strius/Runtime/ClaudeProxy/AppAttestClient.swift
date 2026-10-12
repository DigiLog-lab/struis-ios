import CryptoKit
import DeviceCheck
import Foundation
import OSLog

nonisolated private let attestLog = Logger(subsystem: "com.digiloglab.strius", category: "app-attest")

/// Claude の要求を中継する Struis の relay(`cloudflare/claude-relay`)。Anthropic の API キーは relay にだけある。
nonisolated enum ClaudeRelayConfig {
    static var baseURL: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["STRUIS_CLAUDE_RELAY_URL"].flatMap(URL.init(string:)) { return override }
        #endif
        return URL(string: "https://claude-struis.digiloglab.com")!
    }

    /// `wrangler dev` の relay に App Attest なしで送る(DEBUG の Simulator だけ。本番の relay は受け付けない)。
    static var devToken: String? {
        #if DEBUG && targetEnvironment(simulator)
        if let token = ProcessInfo.processInfo.environment["STRUIS_CLAUDE_RELAY_DEV_TOKEN"], !token.isEmpty { return token }
        #endif
        return nil
    }
}

/// App Attest: この iPhone の Secure Enclave の鍵で、要求が正規の Struis アプリから来たことを relay に示す。
///
/// 1. 初回に鍵を作り、relay のチャレンジに対する attestation(Apple の証明書つき)を送って登録する。
/// 2. 要求ごとに、本文の SHA-256 に対する assertion を付ける。relay は署名と counter を確かめてから中継する。
/// 鍵の ID は Keychain に置く。鍵そのものは端末の外に出ない。
actor AppAttestClient {
    static let shared = AppAttestClient()

    enum Failure: Error, LocalizedError {
        case unsupported
        case registration(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: "この端末では App Attest を使えないため、Claude を使えません。"
            case .registration(let detail): "Claude を使う準備(端末の確認)に失敗しました: \(detail)"
            }
        }
    }

    nonisolated static var isSupported: Bool { DCAppAttestService.shared.isSupported }

    private let keychain = KeychainStore(service: "com.digiloglab.strius.app-attest")
    private let account = "key-id"
    private let session: URLSession
    private var registration: Task<String, Error>?

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    /// relay への要求に付けるヘッダー(鍵の ID と、本文に対する assertion)。
    func headers(for body: Data, relay: URL) async throws -> [String: String] {
        let hash = Data(SHA256.hash(data: body))
        for attempt in 0..<2 {
            let keyID = try await registeredKeyID(relay: relay)
            do {
                let assertion = try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: hash)
                return ["X-Struis-App-Attest-Key-Id": keyID, "X-Struis-App-Attest-Assertion": assertion.base64EncodedString()]
            } catch let error as DCError where error.code == .invalidKey && attempt == 0 {
                // 端末の復元などで鍵が使えなくなった。作り直して登録し直す。
                attestLog.error("app attest key became invalid, registering a new key")
                reset()
            }
        }
        throw Failure.registration("invalid key")
    }

    /// relay が鍵を知らない・counter が合わないと答えた時に、次の要求で登録し直す。
    func reset() {
        keychain.delete(account)
        registration = nil
    }

    private func registeredKeyID(relay: URL) async throws -> String {
        if let keyID = keychain.get(account) { return keyID }
        if let registration { return try await registration.value }
        let task = Task { try await register(relay: relay) }
        registration = task
        defer { registration = nil }
        let keyID = try await task.value
        keychain.set(keyID, for: account)
        return keyID
    }

    private func register(relay: URL) async throws -> String {
        guard Self.isSupported else { throw Failure.unsupported }
        let service = DCAppAttestService.shared
        let keyID = try await service.generateKey()
        let challenge = try await post(relay.appendingPathComponent("v1/app-attest/challenge"), body: [:])
        guard let challengeText = challenge["challenge"] as? String, let challengeData = Data(base64Encoded: challengeText) else {
            throw Failure.registration("no challenge")
        }
        let attestation = try await service.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: challengeData)))
        _ = try await post(relay.appendingPathComponent("v1/app-attest/register"), body: [
            "key_id": keyID, "attestation": attestation.base64EncodedString(), "challenge": challengeText,
        ])
        attestLog.info("app attest key registered")
        return keyID
    }

    private func post(_ url: URL, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw Failure.registration(message)
        }
        return object
    }
}
