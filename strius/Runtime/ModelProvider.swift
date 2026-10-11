import Foundation

/// AI の実行先。どちらも端末内の Codex App Server が動かし、Claude は端末内の
/// `ClaudeResponsesProxy`(Responses API → Messages API の変換)を provider として使う。
nonisolated enum ModelProvider: String, Codable, CaseIterable, Sendable {
    /// ChatGPT / Codex 認証で OpenAI のモデルを使う(従来の経路)。
    case openai
    /// Anthropic の API キーで Claude を使う。
    case anthropic

    /// Codex の `model_providers` に登録する ID(組み込みの `openai` 等と重ならない名前)。
    var codexProviderID: String? {
        switch self {
        case .openai: nil
        case .anthropic: "struis-claude"
        }
    }

    var displayName: String {
        switch self {
        case .openai: "GPT"
        case .anthropic: "Claude"
        }
    }

    /// 実行監査の `billing_source`。
    var billingSource: String {
        switch self {
        case .openai: "byo_chatgpt"
        case .anthropic: "byo_anthropic_api_key"
        }
    }

    /// 配信 manifest がこの provider のモデルを渡すときのキー(`models["claude:astra"]` など)。
    func manifestKey(role: String) -> String {
        switch self {
        case .openai: role
        case .anthropic: "claude:" + role
        }
    }
}

/// 学習者が設定画面で選んだ実行先。新しく始めるスレッドだけが従う(続きの会話は始めた時の実行先のまま)。
nonisolated enum ModelProviderPreference {
    static let defaultsKey = "settings.modelProvider"

    static var current: ModelProvider {
        get {
            #if DEBUG
            // 検証用の起動引数・環境(Simulator の実AIテストなど)。設定より優先する。
            if let forced = ProcessInfo.processInfo.environment["STRUIS_MODEL_PROVIDER"].flatMap(ModelProvider.init(rawValue:)) {
                return forced
            }
            #endif
            return UserDefaults.standard.string(forKey: defaultsKey).flatMap(ModelProvider.init(rawValue:)) ?? .openai
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// Claude の既定のモデル。配信 manifest に `claude:astra` / `claude:luna` があればそちらを使う。
nonisolated enum ClaudeModels {
    static let astraModel = "claude-opus-5-5"
    static let astraEffort = "medium"
    static let lunaModel = "claude-haiku-5-5"
    static let lunaEffort = "low"

    /// 学習者に見せる名前(委任の指示文にも使う)。
    static func displayName(_ model: String) -> String {
        switch model {
        case "claude-opus-5-5": "Claude Opus 5.5"
        case "claude-sonnet-5-5": "Claude Sonnet 5.5"
        case "claude-haiku-5-5": "Claude Haiku 5.5"
        case "claude-fable-5-1": "Claude Fable 5.1"
        default: model
        }
    }
}

/// Anthropic の API キー。Keychain(この端末だけ)に置き、台帳・書き出し・バックアップには入れない。
nonisolated enum AnthropicCredentials {
    private static let keychain = KeychainStore(service: "com.digiloglab.strius.anthropic")
    private static let account = "api-key"

    static var apiKey: String? {
        #if DEBUG && targetEnvironment(simulator)
        // Simulator の検証用: `STRUIS_DEBUG_ANTHROPIC_KEY_FILE=<host path>`(0600 の作業コピー)。端末向けには入らない。
        if let path = ProcessInfo.processInfo.environment["STRUIS_DEBUG_ANTHROPIC_KEY_FILE"], !path.isEmpty,
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }
        #endif
        return keychain.get(account)
    }

    static var isConfigured: Bool { apiKey != nil }

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { keychain.delete(account) } else { keychain.set(trimmed, for: account) }
    }

    static func delete() { keychain.delete(account) }

    /// 画面に出す末尾 4 文字だけの表示。
    static var maskedKey: String? {
        guard let key = apiKey, key.count > 8 else { return nil }
        return "…" + key.suffix(4)
    }
}
