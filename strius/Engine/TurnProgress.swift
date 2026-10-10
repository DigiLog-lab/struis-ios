import Foundation

// Port of the progress-label and agent-text helpers of
// backend/src/struis/services/codex_app_server.py.  Inputs are the JSON-RPC
// notification payloads (`item`, `params`) as `EngineJSON`.

nonisolated enum TurnProgress {
    typealias JSONObject = [String: Any]

    static let commandActivityLabels: [String: String] = [
        "cat": "内容を読んでいます…", "sed": "内容を読んでいます…", "head": "内容を読んでいます…", "tail": "内容を読んでいます…",
        "less": "内容を読んでいます…", "nl": "内容を読んでいます…",
        "rg": "必要な情報を探しています…", "grep": "必要な情報を探しています…", "find": "必要な情報を探しています…",
        "fd": "必要な情報を探しています…", "ls": "必要な情報を探しています…",
        "wc": "分量を確認しています…",
        "tesseract": "画像を読んでいます…", "pdftoppm": "画像を読んでいます…", "magick": "画像を読んでいます…", "convert": "画像を読んでいます…",
        "apply_patch": "内容を整えています…", "patch": "内容を整えています…",
        "python": "スクリプトで確認しています…", "python3": "スクリプトで確認しています…", "node": "スクリプトで確認しています…",
        "pytest": "動きを確認しています…", "ruff": "動きを確認しています…", "eslint": "動きを確認しています…", "tsc": "動きを確認しています…",
        "npm": "動きを確認しています…", "pnpm": "動きを確認しています…", "yarn": "動きを確認しています…",
        "git": "変更内容を確認しています…",
        "curl": "接続を確認しています…", "wget": "接続を確認しています…",
    ]

    struct ActivityMetadata: Equatable {
        var source = "app_server_command"
        var tone = "activity"
        var allowDuplicate = "true"
        var progressID: String?

        var json: EngineJSON {
            var object = EngineObject([("source", .string(source)), ("tone", .string(tone)), ("allow_duplicate", .string(allowDuplicate))])
            if let progressID { object["progress_id"] = .string(progressID) }
            return .object(object)
        }
    }

    /// Python `str(value)` for the scalar JSON values that reach these helpers.
    static func pyStr(_ value: EngineJSON?) -> String {
        guard let value else { return "None" }
        switch value {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .integer(let i): return String(i)
        case .number(let d): return EngineJSON.pythonFloatRepr(d)
        case .string(let s): return s
        case .array, .object: return value.serialized()
        }
    }

    /// `str(item.get(key) or "")`
    static func stringOrEmpty(_ value: EngineJSON?) -> String {
        guard let value, value.isTruthy else { return "" }
        return pyStr(value)
    }

    // MARK: plan

    static func progressLabelsFromPlan(_ params: EngineJSON) -> [String] {
        guard let plan = params["plan"]?.arrayValue else { return [] }
        let steps = plan.compactMap(\.objectValue)
        let active = steps.filter { $0["status"] == .string("inProgress") }.map { stringOrEmpty($0["step"]) }
        var labels = active.map(activityLabelFromText).filter { !$0.isEmpty }
        if !labels.isEmpty { return uniqueLabels(labels) }
        let pending = steps.filter { $0["status"] == .string("pending") }.map { stringOrEmpty($0["step"]) }
        labels = pending.prefix(1).map(activityLabelFromText)
        return uniqueLabels(labels.filter { !$0.isEmpty })
    }

    static func uniqueLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.filter { seen.insert($0).inserted }
    }

    // MARK: items

    static func progressLabelFromItem(_ item: EngineJSON) -> String {
        progressActivityFromItem(item).label
    }

    static func progressActivityFromItem(_ item: EngineJSON) -> (label: String, metadata: ActivityMetadata?) {
        guard let object = item.objectValue else { return ("", nil) }
        guard let command = commandFromItem(object) else { return ("", nil) }
        let label = activityLabelFromCommand(command)
        if label.isEmpty { return ("", nil) }
        var metadata = ActivityMetadata()
        let progressID = activityProgressID(object)
        if !progressID.isEmpty { metadata.progressID = progressID }
        return (label, metadata)
    }

    static func commandFromItem(_ item: EngineObject) -> EngineJSON? {
        for key in ["command", "cmd", "commandLine"] {
            if let value = item[key], value.isTruthy { return value }
        }
        if let arguments = item["arguments"]?.stringValue {
            if !EnginePyText.strip(arguments).isEmpty, let parsed = try? EngineJSON.parse(arguments), let object = parsed.objectValue {
                for key in ["command", "cmd", "commandLine"] {
                    if let value = object[key], value.isTruthy { return value }
                }
            }
        } else if let arguments = item["arguments"]?.objectValue {
            for key in ["command", "cmd", "commandLine"] {
                if let value = arguments[key], value.isTruthy { return value }
            }
        }
        return nil
    }

    static func activityProgressID(_ item: EngineObject) -> String {
        for key in ["id", "call_id", "callId", "itemId"] {
            if let value = item[key], value.isTruthy { return "cmd-\(pyStr(value))" }
        }
        return ""
    }

    /// `pathlib.Path(value).name`
    static func pathName(_ value: String) -> String {
        var text = value
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        if text == "/" { return "" }
        let name = text.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        return name == "." ? "" : name
    }

    static func activityLabelFromCommand(_ command: EngineJSON) -> String {
        let rawParts = commandParts(command)
        let text = rawParts.joined(separator: " ").lowercased()
        if text.isEmpty { return "" }
        func mentions(_ words: Set<String>) -> Bool {
            let tokens = Set(rawParts.map { pathName($0).lowercased() })
            let padded = " \(text) "
            return !tokens.isDisjoint(with: words) || words.contains { EnginePyText.contains(padded, " \($0) ") }
        }
        let first = rawParts.first.map { pathName($0).lowercased() } ?? ""
        if mentions(["tesseract", "pdftoppm", "magick"]) || ["ocr", "image", "画像", ".png", ".jpg", ".jpeg", ".webp", ".pdf"].contains(where: { EnginePyText.contains(text, $0) }) {
            return "画像を読んでいます…"
        }
        if mentions(["pytest", "ruff", "eslint", "tsc"]) || (mentions(["npm", "pnpm", "yarn", "docker"])
            && ["test", "build", "check", "lint", "pytest", "ruff"].contains(where: { EnginePyText.contains(text, $0) })) {
            return "動きを確認しています…"
        }
        if mentions(["python", "python3", "node"]) && ["test", "check", "lint", "pytest", "ruff"].contains(where: { EnginePyText.contains(text, $0) }) {
            return "動きを確認しています…"
        }
        return commandActivityLabels[first] ?? ""
    }

    static func commandParts(_ command: EngineJSON) -> [String] {
        var rawParts: [String]
        if let list = command.arrayValue {
            rawParts = list.map { pyStr($0) }
        } else {
            let raw = command.isTruthy ? pyStr(command) : ""
            rawParts = (try? shlexSplit(raw)) ?? EnginePyText.split(raw)
        }
        if rawParts.count >= 3, ["bash", "sh"].contains(pathName(rawParts[0])), ["-c", "-lc"].contains(rawParts[1]) {
            return (try? shlexSplit(rawParts[2])) ?? EnginePyText.split(rawParts[2])
        }
        return rawParts
    }

    /// Python `shlex.split` (POSIX mode, whitespace_split, no comments).
    static func shlexSplit(_ text: String) throws -> [String] {
        enum State { case normal, single, double }
        var tokens: [String] = []
        var current: String.UnicodeScalarView? = nil
        var state = State.normal
        let scalars = Array(text.unicodeScalars)
        var i = 0
        let whitespace: Set<Unicode.Scalar> = [" ", "\t", "\r", "\n"]
        while i < scalars.count {
            let c = scalars[i]
            switch state {
            case .normal:
                if whitespace.contains(c) {
                    if let token = current { tokens.append(String(token)); current = nil }
                } else if c == "\\" {
                    i += 1
                    guard i < scalars.count else { throw EngineError("No escaped character") }
                    if current == nil { current = .init() }
                    current!.append(scalars[i])
                } else if c == "'" {
                    state = .single
                    if current == nil { current = .init() }
                } else if c == "\"" {
                    state = .double
                    if current == nil { current = .init() }
                } else {
                    if current == nil { current = .init() }
                    current!.append(c)
                }
            case .single:
                if c == "'" { state = .normal } else { current!.append(c) }
            case .double:
                if c == "\"" {
                    state = .normal
                } else if c == "\\" {
                    i += 1
                    guard i < scalars.count else { throw EngineError("No escaped character") }
                    let next = scalars[i]
                    if next != "\"" && next != "\\" { current!.append("\\") }
                    current!.append(next)
                } else {
                    current!.append(c)
                }
            }
            i += 1
        }
        if state != .normal { throw EngineError("No closing quotation") }
        if let token = current { tokens.append(String(token)) }
        return tokens
    }

    // MARK: text labels

    static func activityLabelFromText(_ value: String) -> String {
        let text = value.lowercased()
        if text.isEmpty { return "" }
        func any(_ markers: [String]) -> Bool { markers.contains { EnginePyText.contains(text, $0) } }
        if any(["画像", "添付", "写真", "image", "ocr"]) { return "画像を読んでいます…" }
        if any(["教材", "問題文", "資料"]) { return "内容を読んでいます…" }
        if any(["前回", "前の", "過去", "履歴", "会話", "文脈", "context", "history"]) { return "前のやりとりを見ています…" }
        if any(["検索", "探", "照合", "比べ", "search", "find"]) { return "必要な情報を探しています…" }
        if any(["読", "確認", "見る", "見て", "check", "read"]) { return "内容を読んでいます…" }
        if any(["検証", "テスト", "動作", "build", "lint", "test"]) { return "動きを確認しています…" }
        if any(["修正", "編集", "書", "保存", "更新", "patch", "edit"]) { return "内容を整えています…" }
        if any(["整理", "準備", "組み立て", "考え", "答", "説明", "選"]) { return "答え方を整えています…" }
        return ""
    }

    static func normalizedLabelText(_ value: String) -> String {
        EnginePyText.strip(EnginePyText.normalizeSpaces(EnginePyText.replace(value, "\n", " ")), chars: " -・。.")
    }

    static func containsDigit(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.numericType == .decimal || $0.properties.numericType == .digit }
    }

    static func progressLabelFromAgentDelta(_ value: String) -> String {
        let text = normalizedLabelText(value)
        if text.isEmpty { return "" }
        if EnginePyText.length(text) > 80 { return "" }
        let blocked = ["$", "\\", "{", "}", "=", "→", "←", "```", "http", "/", ":"]
        if blocked.contains(where: { EnginePyText.contains(text, $0) }) || EnginePyText.contains(text, "：") { return "" }
        if containsDigit(text) { return "" }
        let markers = ["確認", "見て", "読み取", "整理", "絞", "探", "照合", "検証", "比べ", "準備", "組み立て", "考え"]
        if !markers.contains(where: { EnginePyText.contains(text, $0) }) { return "" }
        if !["ます", "ました", "ています", "してます", "します", "みます", "中"].contains(where: { text.hasSuffix($0) }) { return "" }
        return text
    }

    static func progressMessageFromAgentText(_ value: String) -> String {
        let text = normalizedLabelText(value)
        if text.isEmpty { return "" }
        if EnginePyText.length(text) > 240 { return "" }
        let blocked = ["$", "\\", "{", "}", "```", "http://", "https://", "Traceback"]
        if blocked.contains(where: { EnginePyText.contains(text, $0) }) { return "" }
        let markers = ["確認", "見て", "読み取", "読み込", "整理", "分け", "絞", "探", "照合", "検証", "比べ", "準備", "組み立て", "考え", "選び", "進め"]
        if !markers.contains(where: { EnginePyText.contains(text, $0) }) { return "" }
        if !["ます", "ました", "ています", "してます", "します", "みます", "です"].contains(where: { text.hasSuffix($0) }) { return "" }
        return text
    }

    static func progressLabel(_ value: String) -> String {
        let text = normalizedLabelText(value)
        if text.isEmpty { return "" }
        if text.hasSuffix("…") || text.hasSuffix("...") { return text }
        if ["ます", "ました", "です", "ください", "します"].contains(where: { text.hasSuffix($0) }) { return text }
        let scalars = text.unicodeScalars.count
        if text.hasSuffix("中") { return EnginePyText.prefix(text, scalars - 1) + "します" }
        if text.hasSuffix("する") { return EnginePyText.prefix(text, scalars - 2) + "します" }
        if text.hasSuffix("る") && containsJapanese(text) { return EnginePyText.prefix(text, scalars - 1) + "ます" }
        if containsJapanese(text) { return text + "します" }
        return text
    }

    static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }
}

nonisolated enum AgentText {
    static func extractAgentText(params: EngineJSON) -> String {
        guard let item = params["item"], item.objectValue != nil else { return "" }
        return extractAgentTextFromItem(item)
    }

    static func agentMessagePhase(_ item: EngineJSON) -> String {
        guard let object = item.objectValue, let phase = object["phase"], !phase.isNull else { return "" }
        return phase.isTruthy ? TurnProgress.pyStr(phase) : ""
    }

    static func extractAgentTextFromItem(_ item: EngineJSON) -> String {
        guard let object = item.objectValue else { return "" }
        let itemType = TurnProgress.stringOrEmpty(object["type"])
        let role = TurnProgress.stringOrEmpty(object["role"])
        if !role.isEmpty && role != "assistant" { return "" }
        if role != "assistant" && !["agentMessage", "assistantMessage", "assistant_message", "message", "response_item"].contains(itemType) { return "" }
        var text: EngineJSON = .null
        for key in ["text", "outputText", "output_text", "finalText", "final_text", "content"] {
            if let value = object[key], value.isTruthy { text = value; break }
            if key == "content" { text = object[key] ?? .null }
        }
        switch text {
        case .string(let s): return s
        case .array(let parts): return parts.map(extractTextPart).joined()
        case .object: return extractTextPart(text)
        default: return ""
        }
    }

    static func extractTextPart(_ value: EngineJSON?) -> String {
        guard let value else { return "" }
        if let s = value.stringValue { return s }
        if let items = value.arrayValue { return items.map(extractTextPart).joined() }
        guard let object = value.objectValue else { return "" }
        let partType = TurnProgress.stringOrEmpty(object["type"])
        if !partType.isEmpty && !["text", "output_text", "assistant_text", "content", "message"].contains(partType) { return "" }
        for key in ["text", "outputText", "output_text", "content"] {
            let extracted = extractTextPart(object[key])
            if !extracted.isEmpty { return extracted }
        }
        return ""
    }

    // MARK: natural language recovery

    struct ObjectSpan: Equatable {
        var start: Int
        var end: Int
        var object: EngineObject
    }

    /// `_json_object_spans`: offsets are code points, like Python string indices.
    static func jsonObjectSpans(_ text: String) -> [ObjectSpan] {
        let scalars = Array(text.unicodeScalars)
        var spans: [ObjectSpan] = []
        var index = 0
        while index < scalars.count {
            let start = EnginePyText.find(scalars, ["{"], from: index)
            if start < 0 { break }
            guard let (parsed, end) = try? EngineJSON.rawDecode(scalars, from: start) else {
                index = start + 1
                continue
            }
            if let object = parsed.objectValue { spans.append(ObjectSpan(start: start, end: end, object: object)) }
            index = end
        }
        return spans
    }

    static func naturalLanguageFromAgentText(_ text: String) -> String {
        let raw = EnginePyText.strip(text)
        if raw.isEmpty { return "" }
        if EnginePyText.contains(raw, "<struis_progress_update>") { return raw }
        let spans = jsonObjectSpans(raw)
        for span in spans {
            var message = span.object["message"]?.stringValue
            if message == nil { message = span.object[""]?.stringValue }
            if let message, !EnginePyText.strip(message).isEmpty { return cleanAgentText(message) }
        }
        let tolerant = tolerantStructuredMessage(raw)
        if !tolerant.isEmpty { return cleanAgentText(tolerant) }
        let scalars = Array(raw.unicodeScalars)
        var cleanedParts: [String] = []
        var cursor = 0
        for span in spans {
            if !span.object.contains("blocks") && !span.object.contains("message") && !span.object.contains("") { continue }
            cleanedParts.append(String(String.UnicodeScalarView(scalars[cursor..<span.start])))
            cursor = span.end
        }
        cleanedParts.append(String(String.UnicodeScalarView(scalars[cursor...])))
        return cleanAgentText(stripJsonishContract(cleanedParts.joined()))
    }

    static func tolerantStructuredMessage(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        for key in ["\"message\"", "\"\""] {
            let keyScalars = Array(key.unicodeScalars)
            var searchFrom = 0
            while true {
                let keyIndex = EnginePyText.find(scalars, keyScalars, from: searchFrom)
                if keyIndex < 0 { break }
                let colonIndex = EnginePyText.find(scalars, [":"], from: keyIndex + keyScalars.count)
                if colonIndex < 0 { break }
                var quoteIndex = colonIndex + 1
                while quoteIndex < scalars.count, EnginePyText.isSpace(scalars[quoteIndex]) { quoteIndex += 1 }
                if quoteIndex < scalars.count, scalars[quoteIndex] == "\"" {
                    let value = readJsonishString(scalars, quoteIndex: quoteIndex)
                    if !value.isEmpty, !EnginePyText.strip(value).isEmpty { return value }
                }
                searchFrom = keyIndex + keyScalars.count
            }
        }
        return ""
    }

    static func readJsonishString(_ text: String, quoteIndex: Int) -> String {
        readJsonishString(Array(text.unicodeScalars), quoteIndex: quoteIndex)
    }

    static func readJsonishString(_ scalars: [Unicode.Scalar], quoteIndex: Int) -> String {
        var chars = String.UnicodeScalarView()
        var index = quoteIndex + 1
        while index < scalars.count {
            let char = scalars[index]
            if char == "\"" { return String(chars) }
            if char == "\\", index + 1 < scalars.count {
                let next = scalars[index + 1]
                if next == "\"" || next == "\\" || next == "/" {
                    chars.append(next)
                    index += 2
                    continue
                }
                if next == "u", index + 5 < scalars.count {
                    let hex = String(String.UnicodeScalarView(scalars[(index + 2)..<(index + 6)]))
                    if let code = UInt32(hex, radix: 16), hex.unicodeScalars.allSatisfy(\.isASCII), let scalar = Unicode.Scalar(code) {
                        chars.append(scalar)
                        index += 6
                        continue
                    }
                }
                chars.append("\\")
                chars.append(next)
                index += 2
                continue
            }
            chars.append(char)
            index += 1
        }
        return ""
    }

    static func stripJsonishContract(_ text: String) -> String {
        let raw = EnginePyText.strip(text)
        if raw.isEmpty { return "" }
        let scalars = Array(raw.unicodeScalars)
        var start = EnginePyText.find(scalars, ["{"])
        while start >= 0 {
            let suffix = String(String.UnicodeScalarView(scalars[start...]))
            if EnginePyText.contains(suffix, "\"blocks\"") || EnginePyText.contains(suffix, "\"message\"") || EnginePyText.contains(suffix, "\"wait_for_user\"") {
                return EnginePyText.rstrip(String(String.UnicodeScalarView(scalars[0..<start])))
            }
            start = EnginePyText.find(scalars, ["{"], from: start + 1)
        }
        return raw
    }

    static func cleanAgentText(_ text: String) -> String {
        var cleaned = EnginePyText.strip(EnginePyText.replace(EnginePyText.replace(text, "```json", ""), "```", ""))
        if EnginePyText.count(cleaned, "$") % 2 == 1 { cleaned = EnginePyText.replace(cleaned, "$", "") }
        return EnginePyText.strip(cleaned)
    }
}

nonisolated extension EngineJSON {
    /// `json.JSONDecoder().raw_decode(text[start:])`: parses one value at `start` and returns the end offset.
    static func rawDecode(_ scalars: [Unicode.Scalar], from start: Int) throws -> (EngineJSON, Int) {
        var parser = Parser(scalars: scalars)
        parser.index = start
        let value = try parser.parseValue()
        return (value, parser.index)
    }
}
