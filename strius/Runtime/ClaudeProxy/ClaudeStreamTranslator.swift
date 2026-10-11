import Foundation

/// Claude の Messages API のストリーム(SSE の data)を、Codex が読む Responses API のイベントに変換する。
///
/// - text ブロック → assistant の message 項目。同じ応答の中で後に tool_use が続いた text は途中経過
///   (`phase: commentary`)、最後の text は答え(`final_answer`)として閉じる。
/// - thinking ブロック → reasoning 項目。要約は reasoning summary として流し、ブロック自体(署名付き)は
///   `encrypted_content` に入れて Codex に持ち回ってもらう。
/// - tool_use ブロック → function_call / custom_tool_call 項目(namespace は `ClaudeToolNames` で戻す)。
nonisolated final class ClaudeStreamTranslator {
    private let tools: ClaudeToolNames
    private let responseID: String
    private var created = false
    private var finished = false

    private enum Block {
        case text(itemID: String, text: String)
        case thinking(itemID: String, text: String, signature: String, redactedData: String?, summaryStarted: Bool)
        case toolUse(itemID: String, callID: String, name: String, json: String)
        case ignored
    }

    private var blocks: [Int: Block] = [:]
    /// 閉じたが phase を決めていない text 項目(次のブロックか応答の終わりで決める)。
    private var pendingText: (itemID: String, text: String)?
    private var counter = 0
    private var inputTokens = 0
    private var cachedTokens = 0
    private var cacheWriteTokens = 0
    private var outputTokens = 0
    private var stopReason: String?
    private(set) var model: String?

    init(tools: ClaudeToolNames, responseID: String = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) {
        self.tools = tools
        self.responseID = responseID
    }

    var isFinished: Bool { finished }

    /// Claude の 1 イベント(`data:` の JSON)を受け、Responses のイベントを返す。
    func consume(_ event: [String: Any]) -> [[String: Any]] {
        guard !finished else { return [] }
        var out: [[String: Any]] = []
        switch event["type"] as? String {
        case "message_start":
            let message = event["message"] as? [String: Any] ?? [:]
            model = message["model"] as? String
            readUsage(message["usage"] as? [String: Any])
            out += createdEvent()
        case "content_block_start":
            out += createdEvent()
            guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { break }
            out += start(index: index, block: block)
        case "content_block_delta":
            guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any] else { break }
            out += self.delta(index: index, delta: delta)
        case "content_block_stop":
            guard let index = event["index"] as? Int else { break }
            out += stop(index: index)
        case "message_delta":
            if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
            readUsage(event["usage"] as? [String: Any])
        case "message_stop":
            out += finish()
        case "error":
            let error = event["error"] as? [String: Any] ?? [:]
            out += failed(type: error["type"] as? String ?? "api_error", message: error["message"] as? String ?? "Claude stream error")
        default:
            break // ping など
        }
        return out
    }

    /// 上流のストリームが message_stop なしで終わった。
    func streamEnded() -> [[String: Any]] {
        guard !finished else { return [] }
        return failed(type: "api_error", message: "Claude stream ended before the message was complete")
    }

    // MARK: - Blocks

    private func start(index: Int, block: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        switch block["type"] as? String {
        case "text":
            out += settlePendingText(phase: "commentary")
            let itemID = nextID("msg")
            blocks[index] = .text(itemID: itemID, text: block["text"] as? String ?? "")
            out.append(["type": "response.output_item.added", "output_index": index, "item": [
                "type": "message", "id": itemID, "role": "assistant", "content": [Any](), "phase": "final_answer",
            ]])
            if let text = block["text"] as? String, !text.isEmpty {
                out.append(["type": "response.output_text.delta", "item_id": itemID, "output_index": index, "content_index": 0, "delta": text])
            }
        case "thinking", "redacted_thinking":
            out += settlePendingText(phase: "commentary")
            let itemID = nextID("rs")
            blocks[index] = .thinking(itemID: itemID, text: block["thinking"] as? String ?? "", signature: block["signature"] as? String ?? "",
                                      redactedData: block["type"] as? String == "redacted_thinking" ? block["data"] as? String ?? "" : nil,
                                      summaryStarted: false)
            out.append(["type": "response.output_item.added", "output_index": index, "item": [
                "type": "reasoning", "id": itemID, "summary": [Any](),
            ]])
        case "tool_use":
            out += settlePendingText(phase: "commentary")
            let itemID = nextID("fc")
            let callID = block["id"] as? String ?? itemID
            let name = block["name"] as? String ?? ""
            var json = ""
            if let input = block["input"] as? [String: Any], !input.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: input) {
                json = String(decoding: data, as: UTF8.self)
            }
            blocks[index] = .toolUse(itemID: itemID, callID: callID, name: name, json: json)
            out.append(["type": "response.output_item.added", "output_index": index, "item": toolItem(itemID: itemID, callID: callID, claudeName: name, json: "")])
        default:
            // server tool の結果など、Codex に渡すものがないブロック。
            blocks[index] = .ignored
        }
        return out
    }

    private func delta(index: Int, delta: [String: Any]) -> [[String: Any]] {
        guard let block = blocks[index] else { return [] }
        switch (block, delta["type"] as? String) {
        case (.text(let itemID, let text), "text_delta"):
            let piece = delta["text"] as? String ?? ""
            blocks[index] = .text(itemID: itemID, text: text + piece)
            guard !piece.isEmpty else { return [] }
            return [["type": "response.output_text.delta", "item_id": itemID, "output_index": index, "content_index": 0, "delta": piece]]
        case (.thinking(let itemID, let text, let signature, let redacted, let started), "thinking_delta"):
            let piece = delta["thinking"] as? String ?? ""
            blocks[index] = .thinking(itemID: itemID, text: text + piece, signature: signature, redactedData: redacted, summaryStarted: started || !piece.isEmpty)
            guard !piece.isEmpty else { return [] }
            var out: [[String: Any]] = []
            if !started {
                out.append(["type": "response.reasoning_summary_part.added", "item_id": itemID, "output_index": index, "summary_index": 0,
                            "part": ["type": "summary_text", "text": ""]])
            }
            out.append(["type": "response.reasoning_summary_text.delta", "item_id": itemID, "output_index": index, "summary_index": 0, "delta": piece])
            return out
        case (.thinking(let itemID, let text, let signature, let redacted, let started), "signature_delta"):
            blocks[index] = .thinking(itemID: itemID, text: text, signature: signature + (delta["signature"] as? String ?? ""), redactedData: redacted, summaryStarted: started)
            return []
        case (.toolUse(let itemID, let callID, let name, let json), "input_json_delta"):
            let piece = delta["partial_json"] as? String ?? ""
            blocks[index] = .toolUse(itemID: itemID, callID: callID, name: name, json: json + piece)
            return []
        default:
            return []
        }
    }

    private func stop(index: Int) -> [[String: Any]] {
        guard let block = blocks.removeValue(forKey: index) else { return [] }
        switch block {
        case .text(let itemID, let text):
            // phase は次のブロック(tool_use なら途中経過)か応答の終わりで決める。
            pendingText = (itemID, text)
            return []
        case .thinking(let itemID, let text, let signature, let redacted, let started):
            var original: [String: Any]
            if let redacted {
                original = ["type": "redacted_thinking", "data": redacted]
            } else {
                original = ["type": "thinking", "thinking": text, "signature": signature]
            }
            let summary: [[String: Any]] = text.isEmpty ? [] : [["type": "summary_text", "text": text]]
            var item: [String: Any] = ["type": "reasoning", "id": itemID, "summary": summary]
            if let encoded = ClaudeReasoningCodec.encode(original) { item["encrypted_content"] = encoded }
            var out: [[String: Any]] = []
            if started {
                out.append(["type": "response.reasoning_summary_text.done", "item_id": itemID, "output_index": index, "summary_index": 0, "text": text])
            }
            out.append(["type": "response.output_item.done", "output_index": index, "item": item])
            return out
        case .toolUse(let itemID, let callID, let name, let json):
            return [["type": "response.output_item.done", "output_index": index, "item": toolItem(itemID: itemID, callID: callID, claudeName: name, json: json)]]
        case .ignored:
            return []
        }
    }

    private func toolItem(itemID: String, callID: String, claudeName: String, json: String) -> [String: Any] {
        let arguments = json.isEmpty ? "{}" : json
        let entry = tools.entry(claudeName: claudeName)
        if entry?.custom == true {
            let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
            var item: [String: Any] = ["type": "custom_tool_call", "id": itemID, "call_id": callID, "name": entry?.name ?? claudeName,
                                       "input": object?["input"] as? String ?? "", "status": "completed"]
            if let namespace = entry?.namespace { item["namespace"] = namespace }
            return item
        }
        var item: [String: Any] = ["type": "function_call", "id": itemID, "call_id": callID, "name": entry?.name ?? claudeName,
                                   "arguments": arguments, "status": "completed"]
        if let namespace = entry?.namespace { item["namespace"] = namespace }
        return item
    }

    private func settlePendingText(phase: String) -> [[String: Any]] {
        guard let pending = pendingText else { return [] }
        pendingText = nil
        return [["type": "response.output_item.done", "item": [
            "type": "message", "id": pending.itemID, "role": "assistant", "phase": phase,
            "content": [["type": "output_text", "text": pending.text, "annotations": [Any]()]],
        ]]]
    }

    // MARK: - Response lifecycle

    private func createdEvent() -> [[String: Any]] {
        guard !created else { return [] }
        created = true
        return [["type": "response.created", "response": ["id": responseID, "object": "response", "status": "in_progress"]]]
    }

    private func finish() -> [[String: Any]] {
        var out = createdEvent()
        // 最後に閉じた text は、tool_use で終わった応答なら途中経過、それ以外は答え。
        out += settlePendingText(phase: stopReason == "tool_use" ? "commentary" : "final_answer")
        finished = true
        switch stopReason {
        case "refusal":
            out += failedEvents(code: "invalid_prompt", message: "Claude declined to answer this request.")
        case "max_tokens":
            out.append(["type": "response.incomplete", "response": ["id": responseID, "status": "incomplete",
                                                                     "incomplete_details": ["reason": "max_output_tokens"]]])
        case "model_context_window_exceeded":
            out += failedEvents(code: "context_length_exceeded", message: "The conversation is longer than the model's context window.")
        default:
            out.append(["type": "response.completed", "response": [
                "id": responseID, "object": "response", "status": "completed",
                "usage": [
                    "input_tokens": inputTokens + cachedTokens + cacheWriteTokens,
                    "input_tokens_details": ["cached_tokens": cachedTokens, "cache_write_tokens": cacheWriteTokens],
                    "output_tokens": outputTokens,
                    "output_tokens_details": ["reasoning_tokens": 0],
                    "total_tokens": inputTokens + cachedTokens + cacheWriteTokens + outputTokens,
                ],
            ]])
        }
        return out
    }

    private func failed(type: String, message: String) -> [[String: Any]] {
        var out = createdEvent()
        finished = true
        out += failedEvents(code: Self.responsesErrorCode(anthropicType: type), message: message)
        return out
    }

    private func failedEvents(code: String, message: String) -> [[String: Any]] {
        [["type": "response.failed", "response": ["id": responseID, "status": "failed", "error": ["code": code, "message": message]]]]
    }

    /// Codex が再試行や表示を決めるのに使うエラーコードへ。
    static func responsesErrorCode(anthropicType: String) -> String {
        switch anthropicType {
        case "overloaded_error": "server_is_overloaded"
        case "rate_limit_error": "rate_limit_exceeded"
        case "billing_error": "insufficient_quota"
        case "invalid_request_error": "invalid_request_error"
        default: "server_error"
        }
    }

    private func readUsage(_ usage: [String: Any]?) {
        guard let usage else { return }
        if let value = usage["input_tokens"] as? Int { inputTokens = value }
        if let value = usage["cache_read_input_tokens"] as? Int { cachedTokens = value }
        if let value = usage["cache_creation_input_tokens"] as? Int { cacheWriteTokens = value }
        if let value = usage["output_tokens"] as? Int { outputTokens = value }
    }

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)_\(responseID.dropFirst(5).prefix(16))_\(counter)"
    }
}
