#if DEBUG || STRUIS_INTERNAL
import Foundation

/// 「ChatGPT でサインイン」(Sign in with ChatGPT の open-source 向けの経路)の決まった値。内部の配布(TestFlight・
/// プロトタイプ)と Debug だけに入る。App Store に出すビルドには、このファイルごと入らない(`Config/Build.xcconfig`)。
///
/// 確かめたこと(2026-11-25、こちらの環境から認可の URL を直接呼んだ): `client_id=dynamic_agent_client` は審査なしで
/// ログインの画面へ進む。`ext_agent_host_id` は `urn:uuid:` の形でないと 400。戻り先は `http://127.0.0.1:<任意のポート>`
/// だけが通り、独自の URL スキームは 400。
nonisolated enum ChatGPTConfig {
    static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let apiBaseURL = URL(string: "https://api.openai.com/v1")!
    /// 認可の `resource`(ChatGPT のプランで推論する先)。
    static let resource = "https://api.openai.com/v1"
    /// 初めての登録だけに使う client ID。登録すると、OpenAI がアカウントごとの client ID(`oaiapp_...`)を返す。
    static let registrationClientID = "dynamic_agent_client"
    /// 登録の時に OpenAI の画面に出す名前(利用者が承認の前に変えられる)。
    static let agentName = "Struis"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    /// ChatGPT のプランで推論してよい印。ID トークンだけでは足りず、この権限が付いている必要がある。
    static let planScope = "chatgpt.tokens.use.direct"
    static let callbackPath = "/auth/callback"
    /// 戻り先のポート。ふさがっていれば次を試す(2 回目以降のサインインで変わってよいのはポートだけ)。
    static let ports: [UInt16] = Array(1455...1464)
    /// アクセストークンの残りがこれより短ければ、送る前に更新する。
    static let refreshMargin: TimeInterval = 120
}

/// 保存する認証の記録。Keychain の「この端末だけ」に置き、iCloud にもバックアップの移し先にも渡さない。
nonisolated struct ChatGPTCredentials: Codable, Sendable, Equatable {
    var clientID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var scopes: [String]
    var idToken: String?
    var email: String?
    var name: String?

    var canUsePlan: Bool { scopes.contains(ChatGPTConfig.planScope) }
}

/// 開発者向けの設定で選ぶ、送り先とモデル。App Store のビルドにはこの型が無く、常に Claude で動く。
nonisolated enum ChatGPTPreferences {
    static let providerKey = "settings.aiProvider"
    static let modelKey = "settings.chatGPTModel"

    /// 送り先に ChatGPT を選んでいる(サインインしていなければ Claude で動く)。
    static var prefersChatGPT: Bool {
        get { UserDefaults.standard.string(forKey: providerKey) == "chatgpt" }
        set { UserDefaults.standard.set(newValue ? "chatgpt" : "claude", forKey: providerKey) }
    }

    static var model: String? {
        get { UserDefaults.standard.string(forKey: modelKey) }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }
}

/// サインイン・トークンの更新・モデルの一覧。
actor ChatGPTAccount {
    static let shared = ChatGPTAccount()

    nonisolated struct Model: Sendable, Hashable, Identifiable {
        var slug: String
        var displayName: String
        var id: String { slug }
    }

    nonisolated enum Failure: Error, LocalizedError, Sendable {
        case signedOut
        case missingPlanScope
        case token(status: Int, message: String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .signedOut: "ChatGPT にサインインしていません。"
            case .missingPlanScope: "ChatGPT のプランを使う許可がありませんでした。"
            case .token(let status, let message): "ChatGPT の認証に失敗しました(HTTP \(status)): \(message)"
            case .malformed(let detail): "ChatGPT の応答を読めませんでした: \(detail)"
            }
        }
    }

    private static let keychain = KeychainStore(service: "com.digiloglab.struis.chatgpt")
    private static let credentialsAccount = "credentials"
    private static let hostAccount = "host-id"

    /// 画面とターンの送り先の判定が同期で読む写し。
    nonisolated private static let cache = CredentialsCache()

    private var refreshing: Task<ChatGPTCredentials, Error>?

    /// 今の記録(無ければ nil)。
    nonisolated static var current: ChatGPTCredentials? { cache.value }

    /// ターンを ChatGPT に送るか。選んでいて、プランを使う許可のある記録がある時だけ。
    nonisolated static var isActive: Bool {
        ChatGPTPreferences.prefersChatGPT && current?.canUsePlan == true
    }

    /// 送るモデル。選んだものが無ければ nil(ターンは失敗にする)。
    nonisolated static var activeModel: String? {
        guard isActive else { return nil }
        return ChatGPTPreferences.model
    }

    /// この端末の ID(`urn:uuid:...`)。端末ごとに 1 つ、同じ端末では使い回す(`ext_agent_host_id`)。
    nonisolated static func hostID() -> String {
        if let saved = keychain.get(hostAccount) { return saved }
        let made = "urn:uuid:" + UUID().uuidString.lowercased()
        keychain.set(made, for: hostAccount, thisDeviceOnly: true)
        return made
    }

    func save(_ credentials: ChatGPTCredentials) {
        Self.store(credentials)
    }

    func signOut() {
        refreshing?.cancel()
        refreshing = nil
        Self.keychain.delete(Self.credentialsAccount)
        Self.cache.value = nil
        ChatGPTPreferences.prefersChatGPT = false
    }

    /// 送る前のアクセストークン。期限が近ければ更新してから返す。
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let credentials = Self.current else { throw Failure.signedOut }
        if !forceRefresh, credentials.expiresAt.timeIntervalSinceNow > ChatGPTConfig.refreshMargin { return credentials.accessToken }
        return try await refresh(credentials).accessToken
    }

    private func refresh(_ credentials: ChatGPTCredentials) async throws -> ChatGPTCredentials {
        if let refreshing { return try await refreshing.value }
        let task = Task { () throws -> ChatGPTCredentials in
            let response = try await Self.postToken([
                "grant_type": "refresh_token", "client_id": credentials.clientID, "refresh_token": credentials.refreshToken,
            ])
            // リフレッシュトークンは使うたびに変わる。アクセストークン・期限・権限と一緒に入れ替える。
            let updated = try Self.credentials(from: response, clientID: credentials.clientID, previous: credentials)
            Self.store(updated)
            return updated
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    /// このアカウントで使えるモデル(`visibility` が `list` のもの)。
    func models() async throws -> [Model] {
        let token = try await accessToken()
        var request = URLRequest(url: ChatGPTConfig.apiBaseURL.appendingPathComponent("models"))
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.token(status: status, message: String(decoding: data.prefix(500), as: UTF8.self)) }
        return Self.models(from: data)
    }

    nonisolated static func models(from data: Data) -> [Model] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let entries = (object?["models"] ?? object?["data"]) as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let slug = (entry["slug"] ?? entry["id"]) as? String else { return nil }
            if let visibility = entry["visibility"] as? String, visibility != "list" { return nil }
            return Model(slug: slug, displayName: entry["display_name"] as? String ?? slug)
        }
    }

    // MARK: - トークンの要求

    /// トークンの窓口へ form で送る。
    nonisolated static func postToken(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: ChatGPTConfig.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formBody(fields).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let object else {
            let error = object?["error"]
            let message = (error as? [String: Any])?["message"] as? String ?? (error as? String) ?? String(decoding: data.prefix(500), as: UTF8.self)
            throw Failure.token(status: status, message: message)
        }
        return object
    }

    nonisolated static func formBody(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }

    /// トークンの応答から記録を作る。`previous` は更新の時の前の記録(応答に無い値を引き継ぐ)。
    nonisolated static func credentials(from response: [String: Any], clientID: String, previous: ChatGPTCredentials? = nil,
                                        now: Date = Date()) throws -> ChatGPTCredentials {
        guard let access = response["access_token"] as? String else { throw Failure.malformed("access_token がありません") }
        let refresh = response["refresh_token"] as? String ?? previous?.refreshToken
        guard let refresh else { throw Failure.malformed("refresh_token がありません") }
        let lifetime = (response["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let scopes = (response["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? []
        let idToken = response["id_token"] as? String ?? previous?.idToken
        let claims = idToken.flatMap(Self.claims(of:)) ?? [:]
        let result = ChatGPTCredentials(
            clientID: clientID, accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(lifetime), scopes: scopes,
            idToken: idToken, email: claims["email"] as? String ?? previous?.email, name: claims["name"] as? String ?? previous?.name
        )
        guard result.canUsePlan else { throw Failure.missingPlanScope }
        return result
    }

    /// JWT の中身(署名は確かめない。トークンの窓口から TLS で直接受け取った値だけに使う)。
    nonisolated static func claims(of jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated private static func store(_ credentials: ChatGPTCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        keychain.set(String(decoding: data, as: UTF8.self), for: credentialsAccount, thisDeviceOnly: true)
        cache.value = credentials
    }

    nonisolated fileprivate static func load() -> ChatGPTCredentials? {
        guard let text = keychain.get(credentialsAccount) else { return nil }
        return try? JSONDecoder().decode(ChatGPTCredentials.self, from: Data(text.utf8))
    }
}

/// Keychain の記録の写し(読むたびに Keychain を引かない)。
nonisolated private final class CredentialsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    private var stored: ChatGPTCredentials?

    var value: ChatGPTCredentials? {
        get {
            lock.withLock {
                if !loaded {
                    stored = ChatGPTAccount.load()
                    loaded = true
                }
                return stored
            }
        }
        set { lock.withLock { stored = newValue; loaded = true } }
    }
}

/// 直近の失敗(開発者向けの「ChatGPT」の画面に出し、詳細をコピーできるようにする)。
nonisolated enum ChatGPTFailureLog {
    nonisolated struct Entry: Codable, Sendable, Equatable {
        var at: Date
        /// 画面に出す短い一言。
        var summary: String
        /// コピーする詳細(エラーコード・メッセージ・どの処理か)。
        var detail: String
    }

    static let key = "settings.chatGPTLastFailure"

    static var last: Entry? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    static func record(summary: String, detail: String) {
        let entry = Entry(at: Date(), summary: summary, detail: String(detail.prefix(4000)))
        if let data = try? JSONEncoder().encode(entry) { UserDefaults.standard.set(data, forKey: key) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .chatGPTFailureRecorded, object: nil) }
    }
}

extension Notification.Name {
    /// ChatGPT の利用上限で要求が止まった。開発者向けの案内のシートを出す。
    nonisolated static let chatGPTLimitReached = Notification.Name("struis.chatGPTLimitReached")
    /// 直近の失敗を書き換えた。
    nonisolated static let chatGPTFailureRecorded = Notification.Name("struis.chatGPTFailureRecorded")
}
#endif
