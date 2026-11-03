import Foundation

/// ターンとコマンド worker の失敗。学習者に見せる文(`errorDescription`)と、記録に残す診断の文(`detail`)を分ける。
nonisolated enum TurnRuntimeError: Error, LocalizedError, Sendable {
    case notRunning
    case rpc(code: Int?, message: String)
    case timeout(String)
    /// A request the command worker never answered within its limit.
    case unanswered(String)
    case closed(String)
    case malformed(String)
    case interrupted
    case turnFailed(String)

    /// Learner-facing text: one fixed Japanese sentence per case (design: 学習者に見せるエラーは
    /// 日本語の一言だけ). Method names, RPC messages and guest details never reach the screen;
    /// they are logged through `detail`.
    var errorDescription: String? {
        switch self {
        case .notRunning: "AI を起動できませんでした。もう一度送ってください。"
        case .rpc: "AI がこの依頼を受け付けませんでした。もう一度送ってください。"
        case .timeout, .unanswered: "AI の返事が止まりました。もう一度送ってください。"
        case .closed: "AI が途中で止まりました。もう一度送ってください。"
        case .malformed: "AI の返事を読み取れませんでした。もう一度送ってください。"
        case .interrupted: "停止しました。"
        case .turnFailed(let detail) where detail.contains(UsageLimitResponse.code):
            "今週の利用枠を使い切りました。設定の「利用枠」で、戻る日時とプランを確かめてください。"
        case .turnFailed:
            "AI が返事を作れませんでした。もう一度送ってください。"
        }
    }

    /// Diagnostic text for os_log and the execution audit. Never shown to the learner.
    var detail: String {
        switch self {
        case .notRunning: "not running"
        case .rpc(let code, let message): "rpc \(code.map(String.init) ?? "-"): \(message)"
        case .timeout(let method): "timeout \(method)"
        case .unanswered(let method): "no answer to \(method)"
        case .closed(let detail): "closed \(detail)"
        case .malformed(let detail): "malformed \(detail)"
        case .interrupted: "interrupted"
        case .turnFailed(let detail): "turn failed: \(detail)"
        }
    }
}

extension TurnRuntimeError: Equatable {
    nonisolated static func == (lhs: TurnRuntimeError, rhs: TurnRuntimeError) -> Bool {
        lhs.detail == rhs.detail
    }
}

/// 道具の呼び出し・実行監査などで受け渡す JSON のオブジェクト(JSON の境界の型)。
typealias JSONObject = [String: Any]
