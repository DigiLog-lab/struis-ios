import Foundation

/// Codex が送る Responses API の要求を、Claude の Messages API の要求に変換する。
///
/// Codex は provider を HTTP で使うとき `store: false` で履歴の全体を毎回送る。そのためこの変換は
/// 要求ごとに完結し、状態を持たない。Claude の thinking ブロック(署名付き)は、Codex の reasoning 項目の
/// `encrypted_content` に入れて持ち回ってもらう(`ClaudeReasoningCodec`)。
nonisolated enum ClaudeRequestTranslator {
    nonisolated struct Options: Sendable {
        var maxTokens = 64_000
        /// 送る直前に画像の data URL を縮小しない(Codex 側でもう縮小済み)。上限を超える画像だけ落とす。
        var maxImageBytes = 5 * 1024 * 1024
        /// 署名の合わない thinking を外してもう一度送る時に使う。
        var stripThinking = false
        /// schema が大きすぎて structured outputs に拒まれた時は、schema を指示文で渡す(結果は Engine が検証する)。
        var schemaInInstructions = false
    }

    nonisolated struct Translation {
        var body: [String: Any]
        var tools: ClaudeToolNames
        /// `text.format` があった(構造化ターン)。
        var structured: Bool
    }

    enum TranslationError: Error, LocalizedError {
        case malformed(String)
        var errorDescription: String? {
            switch self {
            case .malformed(let detail): "Responses request could not be translated: \(detail)"
            }
        }
    }

    static func translate(_ request: [String: Any], options: Options = Options()) throws -> Translation {
        guard let model = request["model"] as? String, !model.isEmpty else { throw TranslationError.malformed("model") }
        let tools = ClaudeToolNames(responsesTools: request["tools"] as? [[String: Any]] ?? [])
        var builder = MessageBuilder(tools: tools, options: options)
        var systemParts: [String] = []
        if let instructions = request["instructions"] as? String, !instructions.isEmpty { systemParts.append(instructions) }
        for item in request["input"] as? [[String: Any]] ?? [] {
            // 会話の前に来る developer / system 指示は Claude の system に入れる。
            if builder.isEmpty, let role = item["role"] as? String, role == "developer" || role == "system",
               (item["type"] as? String ?? "message") == "message" {
                let text = Self.plainText(item["content"])
                if !text.isEmpty { systemParts.append(text) }
                continue
            }
            builder.add(item)
        }
        var messages = builder.finish()
        if messages.isEmpty { messages = [["role": "user", "content": [["type": "text", "text": "Continue."]]]] }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": options.maxTokens,
            "stream": true,
            "messages": messages,
            // 変わらない先頭(tools・system・それまでの履歴)を毎回読み直さないよう、自動の prompt caching を使う。
            "cache_control": ["type": "ephemeral"],
        ]
        let claudeTools = tools.claudeTools
        if !claudeTools.isEmpty {
            body["tools"] = claudeTools
            var choice: [String: Any] = ["type": "auto"]
            if request["parallel_tool_calls"] as? Bool == false { choice["disable_parallel_tool_use"] = true }
            // Codex の `tool_choice: "none"` は tool を使わせない。
            if request["tool_choice"] as? String == "none" { choice = ["type": "none"] }
            body["tool_choice"] = choice
        }

        var outputConfig: [String: Any] = [:]
        let reasoning = request["reasoning"] as? [String: Any]
        if let effort = Self.effort(reasoning?["effort"] as? String) { outputConfig["effort"] = effort }
        var structured = false
        if let format = (request["text"] as? [String: Any])?["format"] as? [String: Any],
           format["type"] as? String == "json_schema", let schema = format["schema"] {
            if options.schemaInInstructions {
                let text = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                systemParts.append("Answer with exactly one JSON object and nothing else. It must validate against this JSON Schema:\n" + text)
            } else {
                outputConfig["format"] = ["type": "json_schema", "schema": ClaudeSchema.sanitize(schema)]
            }
            structured = true
        }
        if !outputConfig.isEmpty { body["output_config"] = outputConfig }
        if !systemParts.isEmpty { body["system"] = systemParts.joined(separator: "\n\n") }
        // 現行の Claude は adaptive thinking。要約を見せる設定(Struis は待ち時間の見出しに使う)。
        let summary = reasoning?["summary"] as? String
        var thinking: [String: Any] = ["type": "adaptive"]
        if summary != nil, summary != "none" { thinking["display"] = "summarized" }
        body["thinking"] = thinking
        return Translation(body: body, tools: tools, structured: structured)
    }

    /// Codex の reasoning effort → Claude の effort。`none` / `minimal` は Claude にないので `low`。
    static func effort(_ value: String?) -> String? {
        switch value {
        case "none", "minimal", "low": "low"
        case "medium": "medium"
        case "high": "high"
        case "xhigh": "xhigh"
        case "max": "max"
        default: nil
        }
    }

    static func plainText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? []).compactMap { part in
            switch part["type"] as? String {
            case "input_text", "output_text", "text": part["text"] as? String
            default: nil
            }
        }.joined(separator: "\n")
    }

    /// `data:image/png;base64,...` → Claude の image ブロック。http(s) は URL のまま渡す。
    static func imageBlock(_ url: String, maxBytes: Int) -> [String: Any]? {
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            return ["type": "image", "source": ["type": "url", "url": url]]
        }
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let mediaType = String(header.dropLast(";base64".count))
        guard ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mediaType) else { return nil }
        let data = String(url[url.index(after: comma)...])
        // base64 は 4 文字で 3 バイト。
        guard data.utf8.count / 4 * 3 <= maxBytes else { return nil }
        return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data]]
    }

    /// Claude の tool_use id は `^[a-zA-Z0-9_-]+$`。Codex の call_id が他の文字を含む時は置き換える。
    static func toolUseID(_ callID: String) -> String {
        let allowed = callID.unicodeScalars.map { scalar -> Character in
            let ok = (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) || scalar == "_" || scalar == "-"
            return ok ? Character(scalar) : "_"
        }
        let id = String(allowed)
        return id.isEmpty ? "toolu_missing" : id
    }

    /// 入力項目を Claude の messages(user / assistant が交互)にまとめる。
    private struct MessageBuilder {
        let tools: ClaudeToolNames
        let options: Options
        private(set) var messages: [[String: Any]] = []
        /// 次の user 発話の頭に付ける、会話の途中で来た developer 指示。
        private var pendingDeveloper: [String] = []
        /// 応答していない tool_use(id → 名前)。結果がないまま次の発話になったら補う。
        private var openToolUses: [String] = []

        init(tools: ClaudeToolNames, options: Options) {
            self.tools = tools
            self.options = options
        }

        var isEmpty: Bool { messages.isEmpty && pendingDeveloper.isEmpty }

        mutating func add(_ item: [String: Any]) {
            let type = item["type"] as? String ?? "message"
            switch type {
            case "message":
                let role = item["role"] as? String ?? "user"
                switch role {
                case "assistant":
                    let text = ClaudeRequestTranslator.plainText(item["content"])
                    if !text.isEmpty { append(role: "assistant", blocks: [["type": "text", "text": text]]) }
                case "developer", "system":
                    // 会話の途中の指示(Struis の注記・更新された developer 指示)。学習者の発話と区別して渡す。
                    let text = ClaudeRequestTranslator.plainText(item["content"])
                    if !text.isEmpty { pendingDeveloper.append(text) }
                default:
                    var blocks: [[String: Any]] = []
                    for part in item["content"] as? [[String: Any]] ?? [] {
                        switch part["type"] as? String {
                        case "input_text", "text", "output_text":
                            if let text = part["text"] as? String, !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                        case "input_image":
                            if let url = part["image_url"] as? String,
                               let image = ClaudeRequestTranslator.imageBlock(url, maxBytes: options.maxImageBytes) {
                                blocks.append(image)
                            } else {
                                blocks.append(["type": "text", "text": "[An attached image could not be sent to the model.]"])
                            }
                        default:
                            break
                        }
                    }
                    if !blocks.isEmpty { appendUser(blocks) }
                }
            case "reasoning":
                guard !options.stripThinking,
                      let encoded = item["encrypted_content"] as? String,
                      let blocks = ClaudeReasoningCodec.decode(encoded) else { return }
                append(role: "assistant", blocks: blocks)
            case "function_call":
                let callID = item["call_id"] as? String ?? ""
                let name = tools.claudeName(name: item["name"] as? String ?? "", namespace: item["namespace"] as? String)
                let arguments = item["arguments"] as? String ?? "{}"
                let input = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
                let id = ClaudeRequestTranslator.toolUseID(callID)
                append(role: "assistant", blocks: [["type": "tool_use", "id": id, "name": name, "input": input]])
                openToolUses.append(id)
            case "custom_tool_call":
                let callID = item["call_id"] as? String ?? ""
                let name = tools.claudeName(name: item["name"] as? String ?? "", namespace: item["namespace"] as? String)
                let id = ClaudeRequestTranslator.toolUseID(callID)
                append(role: "assistant", blocks: [["type": "tool_use", "id": id, "name": name, "input": ["input": item["input"] as? String ?? ""]]])
                openToolUses.append(id)
            case "function_call_output", "custom_tool_call_output":
                let id = ClaudeRequestTranslator.toolUseID(item["call_id"] as? String ?? "")
                // 対応する tool_use がない結果(別の provider で始めた履歴など)は Claude に拒まれるので文字で渡す。
                guard openToolUses.contains(id) else {
                    let text = ClaudeRequestTranslator.outputText(item["output"])
                    if !text.isEmpty { appendUser([["type": "text", "text": "[Tool output]\n" + text]]) }
                    return
                }
                openToolUses.removeAll { $0 == id }
                var result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": toolResultContent(item["output"])]
                if (item["output"] as? [String: Any])?["success"] as? Bool == false { result["is_error"] = true }
                appendUser([result], toolResult: true)
            default:
                // web_search_call・local_shell_call・tool_search 等、この経路で出ない項目は渡さない。
                break
            }
        }

        private func toolResultContent(_ output: Any?) -> Any {
            if let text = output as? String { return text.isEmpty ? "(no output)" : text }
            let items = output as? [[String: Any]] ?? ((output as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            if items.isEmpty, let text = (output as? [String: Any])?["content"] as? String { return text }
            var blocks: [[String: Any]] = []
            for part in items {
                switch part["type"] as? String {
                case "input_text", "text", "output_text":
                    if let text = part["text"] as? String { blocks.append(["type": "text", "text": text]) }
                case "input_image":
                    if let url = part["image_url"] as? String, let image = ClaudeRequestTranslator.imageBlock(url, maxBytes: options.maxImageBytes) {
                        blocks.append(image)
                    }
                default:
                    break
                }
            }
            return blocks.isEmpty ? "(no output)" : blocks
        }

        private mutating func appendUser(_ blocks: [[String: Any]], toolResult: Bool = false) {
            var blocks = blocks
            if !pendingDeveloper.isEmpty {
                let note: [String: Any] = ["type": "text", "text": "<developer_instructions>\n" + pendingDeveloper.joined(separator: "\n\n") + "\n</developer_instructions>"]
                pendingDeveloper = []
                // tool_result は user 発話の先頭に置く必要がある。
                if toolResult { blocks.append(note) } else { blocks.insert(note, at: 0) }
            }
            if !toolResult { closeOpenToolUses() }
            append(role: "user", blocks: blocks)
        }

        /// 結果のない tool_use が残ったまま次の発話になると Claude に拒まれる。中断として結果を補う。
        private mutating func closeOpenToolUses() {
            guard !openToolUses.isEmpty else { return }
            let results: [[String: Any]] = openToolUses.map {
                ["type": "tool_result", "tool_use_id": $0, "content": "The tool call was interrupted before it returned.", "is_error": true]
            }
            openToolUses = []
            append(role: "user", blocks: results)
        }

        private mutating func append(role: String, blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if role == "assistant", messages.isEmpty {
                // 会話は user から始める。
                messages.append(["role": "user", "content": [["type": "text", "text": "(The conversation continues.)"]]])
            }
            if var last = messages.last, last["role"] as? String == role {
                var content = last["content"] as? [[String: Any]] ?? []
                if role == "user" {
                    // tool_result は user 発話の先頭にまとめる。
                    let results = blocks.filter { $0["type"] as? String == "tool_result" }
                    let others = blocks.filter { $0["type"] as? String != "tool_result" }
                    let insertAt = content.firstIndex { $0["type"] as? String != "tool_result" } ?? content.count
                    content.insert(contentsOf: results, at: insertAt)
                    content.append(contentsOf: others)
                } else {
                    content.append(contentsOf: blocks)
                }
                last["content"] = content
                messages[messages.count - 1] = last
            } else {
                messages.append(["role": role, "content": blocks])
            }
        }

        mutating func finish() -> [[String: Any]] {
            closeOpenToolUses()
            if !pendingDeveloper.isEmpty || messages.last?["role"] as? String == "assistant" {
                // 最後が assistant だと prefill になり、現行の Claude では拒まれる。
                appendUser([["type": "text", "text": "Continue."]])
            }
            return messages
        }
    }

    static func outputText(_ output: Any?) -> String {
        if let text = output as? String { return text }
        if let object = output as? [String: Any] {
            if let text = object["content"] as? String { return text }
            return plainText(object["content"])
        }
        return plainText(output)
    }
}

/// Codex の tool 定義と Claude の tool 名の対応。namespace の tool(`struis.exec_command`)は
/// Claude の名前の規則(英数字・`_`・`-`)に合わせて `struis__exec_command` にする。
nonisolated struct ClaudeToolNames: Sendable {
    nonisolated struct Entry: Sendable {
        let name: String
        let namespace: String?
        let custom: Bool
        let tool: [String: AnySendable]
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var order: [String] = []

    init(responsesTools: [[String: Any]]) {
        for tool in responsesTools {
            switch tool["type"] as? String {
            case "function":
                add(tool, namespace: nil)
            case "custom":
                add(tool, namespace: nil)
            case "namespace":
                let namespace = tool["name"] as? String
                for inner in tool["tools"] as? [[String: Any]] ?? [] { add(inner, namespace: namespace) }
            default:
                // web_search・tool_search・local_shell・image_generation は Claude の側に対応する tool がない。
                break
            }
        }
    }

    private mutating func add(_ tool: [String: Any], namespace: String?) {
        guard let name = tool["name"] as? String, !name.isEmpty else { return }
        let custom = tool["type"] as? String == "custom"
        var description = tool["description"] as? String ?? ""
        let schema: Any
        if custom {
            // freeform(文法つき)の tool は、入力の文字列 1 つを受ける JSON の tool として渡す。
            if let format = tool["format"] as? [String: Any], let definition = format["definition"] as? String {
                description += "\n\nPut the whole tool input in the `input` string. Its format (\(format["syntax"] as? String ?? "grammar")):\n" + definition
            }
            schema = ["type": "object", "properties": ["input": ["type": "string"]], "required": ["input"]]
        } else {
            schema = tool["parameters"] ?? tool["inputSchema"] ?? ["type": "object", "properties": [String: Any]()]
        }
        let claudeName = Self.claudeName(name: name, namespace: namespace)
        guard entries[claudeName] == nil else { return }
        var definition: [String: Any] = ["name": claudeName, "input_schema": schema]
        if !description.isEmpty { definition["description"] = description }
        entries[claudeName] = Entry(name: name, namespace: namespace, custom: custom, tool: definition.mapValues(AnySendable.init))
        order.append(claudeName)
    }

    var claudeTools: [[String: Any]] { order.compactMap { entries[$0]?.tool.mapValues(\.value) } }

    func claudeName(name: String, namespace: String?) -> String { Self.claudeName(name: name, namespace: namespace) }

    static func claudeName(name: String, namespace: String?) -> String {
        let joined = (namespace.map { $0 + "__" } ?? "") + name
        let sanitized = String(joined.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "_" || $0 == "-" ? $0 : "_" })
        return String(sanitized.prefix(128))
    }

    func entry(claudeName: String) -> Entry? { entries[claudeName] }
}

/// `[String: Any]` を Sendable な値として持ち運ぶための箱(JSON の値だけを入れる)。
nonisolated struct AnySendable: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// Claude の thinking / redacted_thinking ブロックを Codex の reasoning 項目の `encrypted_content` に入れる。
/// Codex はこの値を解釈せず、そのまま次の要求で返してくる。
nonisolated enum ClaudeReasoningCodec {
    static let prefix = "struis-claude:v1:"

    static func encode(_ block: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [block], options: [.sortedKeys]) else { return nil }
        return prefix + data.base64EncodedString()
    }

    /// Struis が作った値だけを戻す。別の provider の reasoning は渡さない(Claude には読めない)。
    static func decode(_ value: String) -> [[String: Any]]? {
        guard value.hasPrefix(prefix), let data = Data(base64Encoded: String(value.dropFirst(prefix.count))),
              let blocks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let allowed = blocks.filter { ["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
        return allowed.isEmpty ? nil : allowed
    }
}

/// Claude の structured outputs が受け付けない JSON Schema の制約を外す(結果は Struis の Engine が検証する)。
nonisolated enum ClaudeSchema {
    static let unsupportedKeys: Set<String> = [
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "minLength", "maxLength", "minItems", "maxItems", "uniqueItems", "contains", "minContains", "maxContains",
        "minProperties", "maxProperties", "patternProperties", "propertyNames", "$schema", "$id",
    ]

    static func sanitize(_ schema: Any) -> Any {
        if let array = schema as? [Any] { return array.map(sanitize) }
        guard var object = schema as? [String: Any] else { return schema }
        for key in unsupportedKeys { object.removeValue(forKey: key) }
        for (key, value) in object {
            switch key {
            case "properties", "$defs", "definitions":
                if let map = value as? [String: Any] { object[key] = map.mapValues(sanitize) }
            case "enum", "const", "required", "default", "examples":
                break
            default:
                if value is [String: Any] || value is [Any] { object[key] = sanitize(value) }
            }
        }
        let isObject = (object["type"] as? String) == "object" || ((object["type"] as? [Any])?.contains { $0 as? String == "object" } ?? false)
            || object["properties"] != nil
        if isObject {
            // Claude はすべての object に `additionalProperties: false` を求める。
            object["additionalProperties"] = false
        }
        return object
    }
}
