#if DEBUG || STRUIS_INTERNAL
import Foundation

/// ChatGPT に送る時の、Messages API の形の履歴 → Responses API の要求。会話の履歴は Messages API の形のまま
/// (`ClaudeConversationStore`)持ち、送る直前にこの形にする。届いたイベントは `ResponsesEventTranslator` が
/// Messages API のイベントに戻し、今の読み手(`ClaudeMessageReader`・`ClaudeStreamStatus`)がそのまま読む。
nonisolated enum ResponsesRequest {
    /// namespace の無い道具(`view_image`)をまとめる namespace。Responses の経路は道具を namespace にまとめて渡す。
    static let coreNamespace = "struis_core"

    static func body(model: String, effort: String?, system: [[String: Any]], messages: [[String: Any]], tools: ClaudeToolNames,
                     includeReasoning: Bool = true) -> [String: Any] {
        var body: [String: Any] = [
            "model": model, "instructions": instructions(system), "input": input(messages, tools: tools),
            "store": false, "stream": true,
        ]
        let definitions = self.tools(tools)
        if !definitions.isEmpty {
            body["tools"] = definitions
            body["tool_choice"] = "auto"
        }
        if includeReasoning {
            var reasoning: [String: Any] = ["summary": "auto"]
            if let effort = reasoningEffort(effort) { reasoning["effort"] = effort }
            body["reasoning"] = reasoning
        }
        return body
    }

    /// system のブロック(キャッシュの印は Claude だけのもの)を 1 つの指示文にする。
    static func instructions(_ system: [[String: Any]]) -> String {
        system.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Claude の effort → Responses の `reasoning.effort`。Claude の `max` は Responses に無いので `xhigh`。
    static func reasoningEffort(_ value: String?) -> String? {
        switch ClaudeRequestFormat.effort(value) {
        case "low": "low"
        case "medium": "medium"
        case "high": "high"
        case "xhigh", "max": "xhigh"
        default: nil
        }
    }

    /// 道具の定義を namespace ごとにまとめる。Claude 用に変えた定義(freeform の道具は `input` の文字列 1 つ)をそのまま使う。
    static func tools(_ names: ClaudeToolNames) -> [[String: Any]] {
        var groups: [String: [[String: Any]]] = [:]
        var order: [String] = []
        for claudeName in names.order {
            guard let entry = names.entry(claudeName: claudeName) else { continue }
            let tool = entry.tool.mapValues(\.value)
            var function: [String: Any] = [
                "type": "function", "name": entry.name, "strict": false,
                "parameters": tool["input_schema"] ?? ["type": "object", "properties": [String: Any]()],
            ]
            if let description = tool["description"] as? String { function["description"] = description }
            let namespace = entry.namespace ?? coreNamespace
            if groups[namespace] == nil { order.append(namespace) }
            groups[namespace, default: []].append(function)
        }
        return order.map { namespace in
            ["type": "namespace", "name": namespace, "description": namespace == coreNamespace ? "Struis app tools." : "Struis tools.",
             "tools": groups[namespace] ?? []]
        }
    }

    /// Messages の履歴 → Responses の `input`。thinking は送らない(Anthropic の署名付きで、OpenAI には渡せない)。
    static func input(_ messages: [[String: Any]], tools: ClaudeToolNames) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for message in messages {
            let role = message["role"] as? String ?? "user"
            let content: [[String: Any]]
            if let text = message["content"] as? String {
                content = [["type": "text", "text": text]]
            } else {
                content = message["content"] as? [[String: Any]] ?? []
            }
            if role == "assistant" {
                items += assistantItems(content, tools: tools)
            } else {
                items += userItems(content)
            }
        }
        return items
    }

    private static func assistantItems(_ content: [[String: Any]], tools: ClaudeToolNames) -> [[String: Any]] {
        var items: [[String: Any]] = []
        var texts: [[String: Any]] = []
        func flushText() {
            guard !texts.isEmpty else { return }
            items.append(["type": "message", "role": "assistant", "content": texts])
            texts = []
        }
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { texts.append(["type": "output_text", "text": text]) }
            case "tool_use":
                flushText()
                let claudeName = block["name"] as? String ?? ""
                let entry = tools.entry(claudeName: claudeName)
                let input = block["input"] ?? [String: Any]()
                let arguments = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                var call: [String: Any] = ["type": "function_call", "call_id": block["id"] as? String ?? "", "name": entry?.name ?? claudeName,
                                           "arguments": arguments]
                call["namespace"] = entry?.namespace ?? (entry == nil ? nil : coreNamespace)
                items.append(call)
            default:
                // thinking・redacted_thinking は送らない。
                break
            }
        }
        flushText()
        return items
    }

    private static func userItems(_ content: [[String: Any]]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        var parts: [[String: Any]] = []
        /// 道具の結果の画像(Responses の道具の結果は文字で返し、画像は続く user の発話で渡す)。
        var resultImages: [[String: Any]] = []
        for block in content {
            switch block["type"] as? String {
            case "tool_result":
                let (text, images) = flatten(block["content"])
                var output = text
                if block["is_error"] as? Bool == true, !output.hasPrefix("Error") { output = "Error: " + output }
                if !images.isEmpty { output += (output.isEmpty ? "" : "\n") + "(\(images.count) image(s) attached in the next message.)" }
                items.append(["type": "function_call_output", "call_id": block["tool_use_id"] as? String ?? "",
                              "output": output.isEmpty ? "(no output)" : output])
                resultImages += images
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { parts.append(["type": "input_text", "text": text]) }
            case "image":
                if let image = inputImage(block) { parts.append(image) }
            default:
                break
            }
        }
        let message = resultImages + parts
        if !message.isEmpty { items.append(["type": "message", "role": "user", "content": message]) }
        return items
    }

    /// 道具の結果(文字か、文字と画像のブロックの並び)→ 文字と画像。
    private static func flatten(_ content: Any?) -> (String, [[String: Any]]) {
        if let text = content as? String { return (text, []) }
        var texts: [String] = []
        var images: [[String: Any]] = []
        for block in content as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text": if let text = block["text"] as? String { texts.append(text) }
            case "image": if let image = inputImage(block) { images.append(image) }
            default: break
            }
        }
        return (texts.joined(separator: "\n"), images)
    }

    /// Claude の image ブロック → `input_image`(data URL か URL)。
    static func inputImage(_ block: [String: Any]) -> [String: Any]? {
        guard let source = block["source"] as? [String: Any] else { return nil }
        switch source["type"] as? String {
        case "base64":
            guard let mediaType = source["media_type"] as? String, let data = source["data"] as? String else { return nil }
            return ["type": "input_image", "image_url": "data:\(mediaType);base64,\(data)"]
        case "url":
            guard let url = source["url"] as? String else { return nil }
            return ["type": "input_image", "image_url": url]
        default:
            return nil
        }
    }
}

/// Responses API のストリームのイベント → Messages API のイベント(`ClaudeMessageReader`・`ClaudeStreamStatus` が読む形)。
nonisolated final class ResponsesEventTranslator: ResponsesEventSource {
    /// 利用上限で止まった時のエラーコード(上限は再試行しない)。
    static let limitCodes: Set<String> = ["subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable"]

    private let tools: ClaudeToolNames
    private var started = false
    private var nextIndex = 0
    private var textBlocks: [String: Int] = [:]
    private var thinkingBlocks: [String: Int] = [:]
    private var sawToolCall = false
    private var finished = false
    /// 失敗の理由(`response.failed`・`error`)。
    private(set) var errorCode: String?
    private(set) var errorMessage: String?

    init(tools: ClaudeToolNames) {
        self.tools = tools
    }

    func translate(_ event: [String: Any]) -> [[String: Any]] {
        guard !finished else { return [] }
        let type = event["type"] as? String ?? ""
        var out: [[String: Any]] = []
        if let response = event["response"] as? [String: Any], !started {
            out.append(start(response))
        }
        switch type {
        case "response.output_text.delta":
            let key = "\(event["output_index"] ?? 0):\(event["content_index"] ?? 0)"
            let index = blockIndex(key, in: &textBlocks, start: ["type": "text", "text": ""], into: &out)
            out.append(["type": "content_block_delta", "index": index, "delta": ["type": "text_delta", "text": event["delta"] as? String ?? ""]])
        case "response.reasoning_summary_text.delta":
            let key = "\(event["output_index"] ?? 0):\(event["summary_index"] ?? 0)"
            let index = blockIndex(key, in: &thinkingBlocks, start: ["type": "thinking", "thinking": "", "signature": ""], into: &out)
            out.append(["type": "content_block_delta", "index": index, "delta": ["type": "thinking_delta", "thinking": event["delta"] as? String ?? ""]])
        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any], item["type"] as? String == "function_call" else { break }
            sawToolCall = true
            let name = item["name"] as? String ?? ""
            var namespace = item["namespace"] as? String
            if namespace == ResponsesRequest.coreNamespace { namespace = nil }
            let claudeName = toolName(name: name, namespace: namespace)
            let arguments = (item["arguments"] as? String).flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } ?? [:]
            let index = nextIndex
            nextIndex += 1
            out.append(["type": "content_block_start", "index": index,
                        "content_block": ["type": "tool_use", "id": item["call_id"] as? String ?? "", "name": claudeName, "input": arguments]])
        case "response.completed", "response.incomplete":
            let response = event["response"] as? [String: Any] ?? [:]
            var stop = sawToolCall ? "tool_use" : "end_turn"
            if type == "response.incomplete" {
                let reason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String
                stop = reason == "max_output_tokens" ? "max_tokens" : (reason == "content_filter" ? "refusal" : stop)
            }
            out.append(["type": "message_delta", "delta": ["stop_reason": stop], "usage": Self.usage(response["usage"] as? [String: Any])])
            out.append(["type": "message_stop"])
            finished = true
        case "response.failed":
            let error = (event["response"] as? [String: Any])?["error"] as? [String: Any] ?? [:]
            out.append(fail(code: error["code"] as? String ?? error["type"] as? String, message: error["message"] as? String))
        case "error":
            let nested = event["error"] as? [String: Any]
            out.append(fail(code: (event["code"] ?? nested?["code"] ?? nested?["type"]) as? String,
                            message: (event["message"] ?? nested?["message"]) as? String))
        default:
            break
        }
        return out
    }

    var isLimit: Bool { errorCode.map(Self.limitCodes.contains) ?? false }

    private func start(_ response: [String: Any]) -> [String: Any] {
        started = true
        return ["type": "message_start", "message": ["id": response["id"] ?? NSNull(), "model": response["model"] ?? NSNull(), "usage": [String: Any]()]]
    }

    private func fail(code: String?, message: String?) -> [String: Any] {
        errorCode = code ?? "api_error"
        errorMessage = message
        finished = true
        return ["type": "error", "error": ["type": errorCode!, "message": message ?? ""]]
    }

    private func blockIndex(_ key: String, in blocks: inout [String: Int], start: [String: Any], into out: inout [[String: Any]]) -> Int {
        if let index = blocks[key] { return index }
        let index = nextIndex
        nextIndex += 1
        blocks[key] = index
        out.append(["type": "content_block_start", "index": index, "content_block": start])
        return index
    }

    /// Responses の道具の名前 → Claude の名前(履歴と道具の呼び出しは Claude の名前で扱う)。
    private func toolName(name: String, namespace: String?) -> String {
        let claudeName = ClaudeToolNames.claudeName(name: name, namespace: namespace)
        if tools.entry(claudeName: claudeName) != nil { return claudeName }
        // namespace が付かずに返った時は、名前で探す。
        return tools.order.first { tools.entry(claudeName: $0)?.name == name } ?? claudeName
    }

    /// Responses の usage → Messages の usage(キャッシュから読んだ分は `cache_read_input_tokens` に分ける)。
    static func usage(_ usage: [String: Any]?) -> [String: Any] {
        guard let usage else { return [:] }
        let input = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
        let cached = ((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? NSNumber)?.intValue ?? 0
        var result: [String: Any] = [
            "input_tokens": max(0, input - cached), "cache_read_input_tokens": cached,
            "output_tokens": (usage["output_tokens"] as? NSNumber)?.intValue ?? 0,
        ]
        if let reasoning = ((usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? NSNumber)?.intValue {
            result["output_tokens_details"] = ["thinking_tokens": reasoning]
        }
        return result
    }
}
/// 道具を使わない 1 回きりの要求(問題の型の作成など。Messages API の形の本文を受けて、同じ形の応答を返す)。
/// ChatGPT の経路は `stream: true` しか受けないので、ストリームを最後まで読んで 1 つの応答にまとめる。
nonisolated enum ChatGPTOneShot {
    static func send(_ claudeBody: [String: Any], model: String, session: URLSession = .shared) async throws -> [String: Any] {
        var instructions: String = (claudeBody["system"] as? String) ?? ResponsesRequest.instructions(claudeBody["system"] as? [[String: Any]] ?? [])
        if let schema = ((claudeBody["output_config"] as? [String: Any])?["format"] as? [String: Any])?["schema"] {
            instructions += "\n\n" + ClaudeTranslation.schemaInstruction(schema)
        }
        let effort: String? = (claudeBody["output_config"] as? [String: Any])?["effort"] as? String
        let tools = ClaudeToolNames(responsesTools: [])
        let body = ResponsesRequest.body(model: model, effort: effort, system: [["type": "text", "text": instructions]],
                                         messages: claudeBody["messages"] as? [[String: Any]] ?? [], tools: tools)
        var request = URLRequest(url: ChatGPTConfig.apiBaseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + (try await ChatGPTAccount.shared.accessToken()), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var collected = Data()
            for try await byte in bytes {
                collected.append(byte)
                if collected.count > 64 * 1024 { break }
            }
            let message = String(decoding: collected.prefix(2000), as: UTF8.self)
            ChatGPTFailureLog.record(summary: "受け付けられませんでした(HTTP \(status))", detail: "task: drill_template\nmodel: \(model)\n\(message)")
            throw ChatGPTAccount.Failure.token(status: status, message: message)
        }
        let events = ResponsesEventTranslator(tools: tools)
        let status_ = ClaudeStreamStatus()
        let reader = ClaudeMessageReader(keepsThinking: false)
        for try await line in bytes.lines {
            guard line.hasPrefix("data:"),
                  let event = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8))) as? [String: Any]
            else { continue }
            for translated in events.translate(event) {
                status_.consume(translated)
                _ = reader.consume(translated)
            }
            if status_.isFinished { break }
        }
        if let code = events.errorCode {
            ChatGPTFailureLog.record(summary: events.isLimit ? "上限に達しました" : "途中で止まりました",
                                     detail: "task: drill_template\ncode: \(code)\n\(events.errorMessage ?? "")")
            if events.isLimit { DispatchQueue.main.async { NotificationCenter.default.post(name: .chatGPTLimitReached, object: "drill_template") } }
            throw ChatGPTAccount.Failure.malformed(code)
        }
        // 終わりの印(response.completed など)の前に切れた返事は、途中の JSON を点検に回さず通信の失敗にする
        // (点検に落ちると、その点の問題の型を作らない記録が残るため)。
        guard status_.isFinished else {
            ChatGPTFailureLog.record(summary: "返事が途中で切れました", detail: "task: drill_template\nstream ended before response.completed")
            throw ChatGPTAccount.Failure.malformed("stream ended before response.completed")
        }
        if status_.stopReason == "max_tokens" || status_.stopReason == "refusal" {
            throw ChatGPTAccount.Failure.malformed("incomplete: \(status_.stopReason ?? "")")
        }
        return ["content": reader.content, "model": status_.model ?? model, "stop_reason": status_.stopReason ?? NSNull()]
    }
}
#endif
