import Foundation

/// Claude の Messages API のストリーム(SSE の data)から、応答の ID・モデル・止まり方・使用量・ストリームの失敗を読む。
/// 応答の中身(thinking・text・tool_use)は `ClaudeMessageReader` が組み立てる。
nonisolated final class ClaudeStreamStatus {
    private var finished: Bool = false
    private(set) var stopReason: String?
    private(set) var model: String?
    /// Anthropic の応答 ID(`msg_...`)。
    private(set) var messageID: String?
    /// Anthropic の `usage`(message_start に message_delta の値を重ねたもの)。要求ごとの記録にそのまま残す。
    private(set) var rawUsage: [String: Any] = [:]
    /// cache diagnostics の結果(`message_start` の `message.diagnostics`)。
    private(set) var diagnostics: Any?
    /// ストリームの `error` イベントの種類。
    private(set) var errorType: String?

    var isFinished: Bool { finished }

    /// Claude の 1 イベント(`data:` の JSON)を読む。
    func consume(_ event: [String: Any]) {
        guard !finished else { return }
        switch event["type"] as? String {
        case "message_start":
            let message: [String: Any] = event["message"] as? [String: Any] ?? [:]
            model = message["model"] as? String
            messageID = message["id"] as? String
            diagnostics = message["diagnostics"]
            readUsage(message["usage"] as? [String: Any])
        case "message_delta":
            if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
            readUsage(event["usage"] as? [String: Any])
        case "message_stop":
            finished = true
        case "error":
            let error: [String: Any] = event["error"] as? [String: Any] ?? [:]
            errorType = error["type"] as? String ?? "api_error"
            finished = true
        default:
            break // content_block_*(`ClaudeMessageReader` が読む)・ping など
        }
    }

    private func readUsage(_ usage: [String: Any]?) {
        guard let usage else { return }
        for (key, value) in usage where !(value is NSNull) { rawUsage[key] = value }
    }
}
