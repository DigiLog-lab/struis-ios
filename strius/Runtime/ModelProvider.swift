import Foundation

/// AI の実行先。どちらも端末内の Codex App Server が動かし、Claude は端末内の
/// `ClaudeResponsesProxy`(Responses API → Messages API の変換)を provider として使う。
nonisolated enum ModelProvider: String, Codable, CaseIterable, Sendable {
    /// ChatGPT / Codex 認証で OpenAI のモデルを使う(従来の経路)。
    case openai
    /// App Attest で端末を確かめ、Anthropic の API を端末から直接使う。
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
        case .anthropic: "anthropic_app_attest"
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
            // 前に選んだ実行先は DEBUG の検証用の入口(`-show-codex-settings`)からだけ選べる。
            return UserDefaults.standard.string(forKey: defaultsKey).flatMap(ModelProvider.init(rawValue:)) ?? .anthropic
            #else
            // ChatGPT(Codex)の経路は選択肢から外した(#40、2026-10-31)。前に GPT を選んでいた端末も Claude で始める。
            return .anthropic
            #endif
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// 設定で選んだタイムライン(出題・採点・見直し)の Claude のモデル。検証のための設定なので、配信 manifest の
/// `claude:timeline` より優先する(2026-10-28 の指示)。知識グラフ(`timeline_graph`)は対象外。
nonisolated enum TimelineModelPreference {
    static let defaultsKey = "settings.timelineClaudeModel"
    static let choices = ["claude-sonnet-5-5", "claude-haiku-5-5"]
    static let defaultModel = "claude-sonnet-5-5"

    static var current: String {
        get {
            #if DEBUG
            if let forced = ProcessInfo.processInfo.environment["STRUIS_TIMELINE_CLAUDE_MODEL"], choices.contains(forced) { return forced }
            #endif
            return UserDefaults.standard.string(forKey: defaultsKey).flatMap { choices.contains($0) ? $0 : nil } ?? defaultModel
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
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

/// Codex に渡す Claude のモデル情報。Codex は Claude のモデルを知らないので、未知のモデルの既定値
/// (想定の上限 272,000・利用できる枠 95% の 258,400・自動要約 90% の 244,800)で動いていた。値は明示して変えない:
/// Claude の上限(100 万)まで履歴を伸ばすと、要求ごとのキャッシュ読み込みが伸びた分だけ毎回かかる。要約は
/// 署名付きの thinking を含む古い履歴を Codex の要約に置き換える(要約の後は記憶を渡し直す。`forgetMemory`)。
/// 入力は文字と画像(Codex の既定。Struis は長辺 2048px までに縮小して送る)。
nonisolated enum ClaudeModelInfo {
    static let contextWindow = 272_000
    static let autoCompactTokenLimit = 244_800
}

nonisolated enum ModelProviderError: Error, LocalizedError {
    case claudeUnavailable

    var errorDescription: String? {
        switch self {
        case .claudeUnavailable: ClaudeAppAttestConfig.clientID == nil
            ? "このビルドには Claude の接続設定(client ID)がありません。"
            : "この端末では App Attest(端末の確認)を使えないため、採点と説明を使えません。iPhone か iPad で開いてください。"
        }
    }
}

/// Claude を使えるか。実機は App Attest で Anthropic から token を受け取り、端末から直接使う(API キーも中継サーバーも無い)。
nonisolated enum ClaudeAccess {
    static var isAvailable: Bool {
        AnthropicCredentials.debugAPIKey != nil || (AppAttestClient.isSupported && ClaudeAppAttestConfig.clientID != nil)
    }
}

/// 検証用の Anthropic の API キー。DEBUG の Simulator だけ(App Attest が使えないため)。端末向けのビルドには入らない。
nonisolated enum AnthropicCredentials {
    static var debugAPIKey: String? {
        #if DEBUG && targetEnvironment(simulator)
        // `STRUIS_DEBUG_ANTHROPIC_KEY_FILE=<host path>`(0600 の作業コピー)。
        if let path = ProcessInfo.processInfo.environment["STRUIS_DEBUG_ANTHROPIC_KEY_FILE"], !path.isEmpty,
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }
        #endif
        return nil
    }
}
