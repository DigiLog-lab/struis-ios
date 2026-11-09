import Foundation

/// Claude への要求を組み立てる部品。
nonisolated enum ClaudeRequestFormat {
    /// 1 回の応答の出力の上限。
    static let maxTokens: Int = 64_000
    /// 画像 1 枚の上限(base64 を戻した大きさ)。超える画像は送らない(送る前に `WorkspaceStager` が縮めてある)。
    static let maxImageBytes: Int = 5 * 1024 * 1024

    /// 計画の reasoning effort → Claude の effort。`none` / `minimal` は Claude にないので `low`。
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

    /// `data:image/png;base64,...` → Claude の image ブロック。http(s) は URL のまま渡す。
    static func imageBlock(_ url: String, maxBytes: Int = maxImageBytes) -> [String: Any]? {
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            return ["type": "image", "source": ["type": "url", "url": url]]
        }
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header: Substring = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let mediaType: String = String(header.dropLast(";base64".count))
        guard ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mediaType) else { return nil }
        let data: String = String(url[url.index(after: comma)...])
        // base64 は 4 文字で 3 バイト。
        guard data.utf8.count / 4 * 3 <= maxBytes else { return nil }
        return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data]]
    }
}

/// 1 回の要求の送り方(実行監査の `requests[]` に残す)。
nonisolated struct ClaudeRequestOptions: Sendable {
    /// 署名の合わない thinking を外して送った。
    var stripThinking: Bool = false
    /// 出力の形を指示文で渡した(`output_config.format` を使わない)。
    var schemaInInstructions: Bool = false
    /// cache diagnostics で比べた直前の応答 ID。`includeDiagnostics` の時だけ送る。
    var previousResponseID: String?
    var includeDiagnostics: Bool = true
}

/// 端末の tool 定義(Responses の形の `function`・`namespace`)と Claude の tool 名の対応。namespace の tool
/// (`struis.exec_command`)は Claude の名前の規則(英数字・`_`・`-`)に合わせて `struis__exec_command` にする。
nonisolated struct ClaudeToolNames: Sendable {
    nonisolated struct Entry: Sendable {
        let name: String
        let namespace: String?
        let custom: Bool
        let tool: [String: AnySendable]
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var order: [String] = []

    /// `sorted`: Claude の名前の順に並べる(版 2 以降。定義の並べ方が変わっても tools の先頭を変えない)。
    init(responsesTools: [[String: Any]], sorted: Bool = false) {
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
                // ほかの種類(web_search など)は Claude の側に対応する tool がない。
                break
            }
        }
        if sorted { order.sort() }
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

/// Claude への要求の変換方式の版。スレッドごとに始めた時の版を `ThreadContextStore` に記録し、続きのターンもその版で送る。
/// - 1: 最初の版。自動の prompt caching(5 分)だけ。キーの順は決めない。
/// - 2: キーの順・tools の順を固定し、固定の指示に 1 時間の breakpoint、会話の末尾は処理群ごとの TTL。cache diagnostics。
/// - 3: 2 に加えて、system を指示と developer 指示の別々のブロックにし、それぞれの後ろに末尾と同じ TTL の breakpoint を置く。
///   タイムラインの採点・出題・見直し(`tutorKinds`)だけが使う(2026-10-25)。
/// - 4: 3 に代わるタイムラインの版(2026-10-27)。developer 指示(今日の記録)を `blockSeparator` で分けて 1 件 1 ブロックにし、
///   基本指示の最後と今日の記録の最後に 1 時間の breakpoint を置く。出力の形は最初から指示文で渡す。
nonisolated enum ClaudeTranslation {
    static let current = 2
    static let tutor = 4
    /// 今日の記録の 1 件ごとの区切り(版 4 で system のブロックに分ける)。
    static let blockSeparator = "\n\n<!-- struis:block -->\n\n"
    /// 今日の記録の終わり(この後ろに足す注記は記録のブロックに混ぜない)。
    static let logEnd = "\n\n<!-- struis:log-end -->"
    static let tutorKinds: Set<String> = ["timeline_batch", "timeline_grading", "timeline_review"]

    /// スレッドを始める時の版。
    static func version(kind: String) -> Int { tutorKinds.contains(kind) ? tutor : current }

    /// 末尾の自動の印を付けるか。版 4 は最後の発話に tool_result がある(1 回の依頼の中の続きの要求)時だけ。
    static func marksTail(translation: Int, messages: [[String: Any]]) -> Bool {
        guard translation >= 4 else { return true }
        guard let last = messages.last, last["role"] as? String == "user",
              let content = last["content"] as? [[String: Any]] else { return false }
        return content.contains { $0["type"] as? String == "tool_result" }
    }

    /// 出力の形を指示文で渡す時の文。
    static func schemaInstruction(_ schema: Any) -> String {
        let text = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "Answer with exactly one JSON object and nothing else. It must validate against this JSON Schema:\n" + text
    }

    /// 版 4 の system。1 つ目(基本指示)と、その後の developer 指示(今日の記録)を `blockSeparator` で分けて 1 件 1 ブロックにする。
    /// 1 時間の印は基本指示の最後と、今日の記録の最後のブロックに置く(後ろに足すだけの記録は、前の印から 20 ブロック
    /// 以内なら前回の分を読める)。記録の終わり(`logEnd`)より後ろ(足した注記など)は別のブロックにし、
    /// 印は置かない。出力の形はその後ろ。末尾の自動の印(5 分)は続きの要求だけで、さらに後ろに来る。
    static func tutorSystem(parts: [String], schema: String?) -> [[String: Any]] {
        guard let first = parts.first else { return [] }
        var blocks: [[String: Any]] = [["type": "text", "text": first, "cache_control": cacheControl(ttl: "1h")]]
        var logMark: Int?
        for part in parts.dropFirst() {
            let end = part.range(of: logEnd)
            let log = end.map { String(part[..<$0.lowerBound]) } ?? part
            for piece in log.components(separatedBy: blockSeparator) where !piece.isEmpty {
                blocks.append(["type": "text", "text": piece])
                logMark = blocks.count - 1
            }
            if let end {
                let rest = part[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { blocks.append(["type": "text", "text": rest]) }
            }
        }
        if let logMark { blocks[logMark]["cache_control"] = cacheControl(ttl: "1h") }
        if let schema { blocks.append(["type": "text", "text": schema]) }
        return blocks
    }

    static func cacheControl(ttl: String?) -> [String: Any] {
        guard let ttl, ttl != "5m" else { return ["type": "ephemeral"] }
        return ["type": "ephemeral", "ttl": ttl]
    }

    /// 末尾の TTL。解答を考えて撮影する継続会話は 1 時間、一度で終わる処理(単元の構成・出題・採点・下調べ)は 5 分
    /// (固有の入力まで 1 時間の倍の書き込み料金を払わない)。タイムラインの採点・出題・見直しの末尾は 1 回の依頼の中で
    /// 道具を使った時の続きの要求のための 5 分で、依頼をまたいで残す先頭は system の 1 時間の印(版 4)が受け持つ。
    static func tailCacheTTL(kind: String?) -> String {
        switch kind {
        case "chat", "thread_fork": "1h"
        default: "5m"
        }
    }

    /// system の breakpoint の TTL(実行監査の記録用)。版 4 は 1 時間、版 3 は末尾と同じ、版 2 は 1 時間。
    static func systemCacheTTL(translation: Int, tail: String) -> String? {
        switch translation {
        case 4...: "1h"
        case 3: tail
        case 2: "1h"
        default: nil
        }
    }

    /// cache diagnostics で比べる直前の応答の控えのキー。タイムラインの採点・出題・見直しは毎回新しいスレッドなので、
    /// 種類をまたいで直前のタイムラインの依頼と比べる。キャッシュはモデルごとなので、設定でモデルを切り替えた後は
    /// 同じモデルの直前の依頼と比べる(別のモデルの応答と比べて外れたと記録しない)。
    static func diagnosticsKey(threadID: String, kind: String?, model: String = "") -> String {
        guard kind.map(tutorKinds.contains) == true else { return threadID }
        return model.isEmpty ? "timeline-tutor" : "timeline-tutor:" + model
    }
}

/// `[String: Any]` を Sendable な値として持ち運ぶための箱(JSON の値だけを入れる)。
nonisolated struct AnySendable: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
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
