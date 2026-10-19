import Foundation

/// 待ちの間に出す言葉を、実際に起きた出来事(コマンド・委任・構造化ターンの書き出し)から作る(信頼性計画 P2 の 3)。
/// 起きていないことは言わない。
nonisolated enum TurnActivityLabels {
    // MARK: コマンド

    /// コマンドを始めた時と終えた時の言葉。読んだもの(送った PDF・写真・学習の記録)が分かればそれを言う。
    static func command(_ cmd: String, skills: SkillWaiting = SkillWaiting()) -> (started: String, finished: String) {
        // Skill の本文を読むコマンドは、その Skill が決めた言葉にする(資料を読む出来事と取り違えない)。
        if let skill = SkillWaiting.skillName(inCommand: cmd) {
            let pair = skills.pair(forSkill: skill) ?? SkillWaiting.unknownSkill
            return (pair.started, pair.finished)
        }
        let text = cmd.lowercased()
        let pageNumber = Self.pageNumber(in: text)
        if text.contains("tutor_desk/inbox") || text.contains("document-") || text.contains("source-") || text.contains(".pdf") {
            if text.contains(".pdf") || text.contains("document-") {
                if let page = pageNumber { return ("送られた PDF の \(page) ページ目を読んでいます", "送られた PDF の \(page) ページ目を読みました") }
                return ("送られた PDF を読んでいます", "送られた PDF を読みました")
            }
            if text.contains(".jpg") || text.contains(".png") || text.contains(".heic") || text.contains("source-") {
                return ("送られた写真を見ています", "送られた写真を見ました")
            }
            return ("送られた資料を読んでいます", "送られた資料を読みました")
        }
        if text.contains("struis_context") || text.contains("tutor_memory") || text.contains("tutor_desk/queue/memory") {
            return ("これまでの学習の記録を確かめています", "これまでの学習の記録を確かめました")
        }
        if text.contains("struis_reply_lint") {
            return ("返事の書き方を確かめています", "返事の書き方を確かめました")
        }
        if text.contains("sympy") {
            return ("計算を確かめています", "計算を確かめました")
        }
        let label = TurnProgress.activityLabelFromCommand(.string(cmd))
        switch label {
        case "内容を読んでいます…": return ("資料を読んでいます", "資料を読みました")
        case "必要な情報を探しています…": return ("必要な情報を探しています", "必要な情報を探しました")
        case "分量を確認しています…": return ("分量を確かめています", "分量を確かめました")
        case "画像を読んでいます…": return ("画像を読んでいます", "画像を読みました")
        case "スクリプトで確認しています…": return ("計算して確かめています", "計算して確かめました")
        case "動きを確認しています…": return ("動きを確かめています", "動きを確かめました")
        default: return ("手元で確かめています", "手元での確認が終わりました")
        }
    }

    static func pageNumber(in text: String) -> Int? {
        for pattern in [#"page[ _-]?(\d{1,4})"#, #"pages\[(\d{1,4})\]"#, #"(\d{1,4})\s*ページ"#, #"-(\d{1,4})-[^/\s]*\.(?:jpg|png)"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text), let value = Int(text[range])
            else { continue }
            // `pages[149]` は 0 から数えるので 1 足す。
            return pattern.hasPrefix("pages") ? value + 1 : value
        }
        return nil
    }

    /// dynamic tool の item(`exec_command`)からコマンドの文字列を取り出す。
    static func commandText(_ item: [String: Any]) -> String? {
        for key in ["command", "cmd", "commandLine"] {
            if let value = item[key] as? String, !value.isEmpty { return value }
            if let value = item[key] as? [String], !value.isEmpty { return value.joined(separator: " ") }
        }
        if let arguments = item["arguments"] as? [String: Any], let cmd = arguments["cmd"] as? String { return cmd }
        if let arguments = item["arguments"] as? String, let data = arguments.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let cmd = object["cmd"] as? String {
            return cmd
        }
        return nil
    }

    // MARK: 推論の要約

    /// 推論の要約の見出し(`**…**`)。日本語を含む時だけ、その文をそのまま出す。
    static func reasoningHeadline(_ text: String) -> String? {
        var candidate = text
        if let regex = try? NSRegularExpression(pattern: #"\*\*([^*]{2,80})\*\*"#),
           let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
           let range = Range(match.range(at: 1), in: text) {
            candidate = String(text[range])
        } else {
            candidate = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= 2, TurnProgress.containsJapanese(candidate) else { return nil }
        return String(candidate.prefix(60))
    }

    // MARK: 構造化ターンの部分の結果

    /// 書き出している途中の JSON から、届いた分を数える(判定の問題・一枚の問題・全体像の小単元)。
    /// 出力の契約は変えず、モデルが実際に書いた分だけを数える。
    /// `items` は学習者に見せてよい文だけ(一枚の問題文。答え・採点の観点は含めない)。
    static func structuredPartial(taskType: String, text: String) -> (done: Int, label: String, items: [String])? {
        switch TurnPlan.Kind(rawValue: taskType) {
        case .workbookGrading:
            let scan = PartialJSONScanner.scan(text)
            let items = scan.arrays["items"] ?? []
            guard !items.isEmpty else { return nil }
            let label = (items.last.flatMap { $0["label"] as? String } ?? "").trimmingCharacters(in: .whitespaces)
            return (items.count, label.isEmpty ? "\(items.count) 問目まで見ました" : "「\(label)」まで見ました", [])
        case .workbookSet:
            let problems = PartialJSONScanner.scan(text).arrays["problems"] ?? []
            guard !problems.isEmpty else { return nil }
            let prompts = problems.map { $0["prompt"] as? String ?? "" }
            // 3.2: 書き終わった問題に欠け(空の問題文・空の答え・重複)があれば、このターンの問題は一枚に入らず組み直しになる。
            // 入らない問題を見せると、学習者がそれを撮って解いても判定が見つけられないので、一つも見せない。
            let defects = WorkbookMachine.problemDefects(
                prompts: prompts, answerKeys: problems.map { $0["answer_key"] as? String ?? "" }, existingPrompts: [])
            return (problems.count, "\(problems.count) 問できました", defects.isEmpty ? prompts : [])
        case .workbookUnit:
            let scan = PartialJSONScanner.scan(text)
            let subunits = scan.arrays["subunits"] ?? []
            if let last = subunits.last, let title = last["title"] as? String {
                return (subunits.count, "小単元を \(subunits.count) つ並べました（\(title)）", [])
            }
            if let title = scan.strings["unit_title"] { return (0, "単元名を「\(title)」にしました", []) }
            return nil
        default:
            return nil
        }
    }
}

/// Skill ごとの待ちの言葉(`配信Skillの説明`)。
/// 各 Skill の `SKILL.md` の frontmatter `metadata.struis-waiting` に、添付の種類ごとの言葉を書く:
/// `pdf`(そのターンに PDF が添えてある)、`image`(画像だけ)、`default`(それ以外)。それぞれ `started` と `finished`。
nonisolated struct SkillWaiting: Sendable, Hashable {
    struct Pair: Sendable, Hashable {
        var started: String
        var finished: String
    }

    enum Attachments: String, Sendable, Hashable {
        case pdf, image, none
    }

    /// Skill のフォルダ名 → 添付の種類(`pdf`・`image`・`default`)→ 言葉。
    var labels: [String: [String: Pair]] = [:]
    var attachments: Attachments = .none

    /// 配信した Skill はすべて言葉を持つ(単体テストで確かめる)。ここに来るのは、配信に無い Skill を読んだ時だけ。
    static let unknownSkill = Pair(started: "やり方を確かめています", finished: "やり方を確かめました")

    /// 作業フォルダに置く Skill のパス(`.agents/skills/<名前>/SKILL.md`)。
    static func skillName(fromWorkspacePath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == ".agents", parts[1] == "skills", parts[3] == "SKILL.md" else { return nil }
        return parts[2]
    }

    /// コマンドが読んでいる Skill の名前(`…/.agents/skills/<名前>/SKILL.md`)。
    static func skillName(inCommand cmd: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\.agents/skills/([A-Za-z0-9._-]+)/SKILL\.md"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
              let range = Range(match.range(at: 1), in: cmd)
        else { return nil }
        return String(cmd[range])
    }

    /// `SKILL.md` の frontmatter から言葉を読む。`default` が無いものは言葉が無いものとして扱う。
    static func parse(skillMarkdown text: String) -> [String: Pair]? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              let front = try? EngineYAML.load(lines[1..<end].joined(separator: "\n")),
              let waiting = front.objectValue?["metadata"]?.objectValue?["struis-waiting"]?.objectValue
        else { return nil }
        var result: [String: Pair] = [:]
        for key in ["pdf", "image", "default"] {
            guard let entry = waiting[key]?.objectValue,
                  let started = entry["started"]?.stringValue?.trimmingCharacters(in: .whitespaces), !started.isEmpty,
                  let finished = entry["finished"]?.stringValue?.trimmingCharacters(in: .whitespaces), !finished.isEmpty
            else { continue }
            result[key] = Pair(started: started, finished: finished)
        }
        return result["default"] == nil ? nil : result
    }

    func pair(forSkill name: String) -> Pair? {
        guard let variants = labels[name] else { return nil }
        switch attachments {
        case .pdf: return variants["pdf"] ?? variants["default"]
        case .image: return variants["image"] ?? variants["default"]
        case .none: return variants["default"]
        }
    }
}

/// 書きかけの JSON を読む。最上位のオブジェクトの、書き終わった文字列の値と、配列の中の書き終わったオブジェクトを返す。
nonisolated enum PartialJSONScanner {
    struct Result {
        var strings: [String: String] = [:]
        var arrays: [String: [[String: Any]]] = [:]
    }

    static func scan(_ text: String) -> Result {
        var result = Result()
        let chars = Array(text.utf8)
        var depth = 0
        var inString = false
        var escaped = false
        var stringStart = 0
        var lastTopKey: String?
        var expectingValueFor: String?
        var topArrayKey: String?
        var objectStart: Int?
        var index = 0
        func slice(_ from: Int, _ to: Int) -> String { String(decoding: chars[from..<to], as: UTF8.self) }
        while index < chars.count {
            let c = chars[index]
            if inString {
                if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true } else if c == UInt8(ascii: "\"") {
                    inString = false
                    if depth == 1 {
                        let raw = slice(stringStart, index + 1)
                        let value = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String
                        if let key = expectingValueFor {
                            if let value { result.strings[key] = value }
                            expectingValueFor = nil
                        } else {
                            lastTopKey = value
                        }
                    }
                }
                index += 1
                continue
            }
            switch c {
            case UInt8(ascii: "\""):
                inString = true
                stringStart = index
            case UInt8(ascii: ":"):
                if depth == 1 { expectingValueFor = lastTopKey }
            case UInt8(ascii: ","):
                if depth == 1 { expectingValueFor = nil; lastTopKey = nil }
            case UInt8(ascii: "{"):
                depth += 1
                if depth == 3, topArrayKey != nil { objectStart = index }
            case UInt8(ascii: "}"):
                if depth == 3, let start = objectStart, let key = topArrayKey {
                    let raw = slice(start, index + 1)
                    if let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
                        result.arrays[key, default: []].append(object)
                    }
                    objectStart = nil
                }
                depth -= 1
            case UInt8(ascii: "["):
                depth += 1
                if depth == 2 { topArrayKey = expectingValueFor; expectingValueFor = nil }
            case UInt8(ascii: "]"):
                if depth == 2 { topArrayKey = nil }
                depth -= 1
            default:
                break
            }
            index += 1
        }
        return result
    }
}
