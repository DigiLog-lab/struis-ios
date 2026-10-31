import Foundation
import Observation
import OSLog

nonisolated private let activityLog = Logger(subsystem: "com.digiloglab.strius", category: "turn-activity")

/// 待ちの間に本当に起きていることを画面へ渡す(待ち時間の体験 W11、信頼性計画 P2)。
///
/// `CodexTurnRunner.observeTurn` が出す `TurnProgressEvent` を、ターンの対象(会話の返事・答案・一枚・全体像・先回りの例題)
/// ごとに 1 本の流れにまとめる。画面はこの板を読み、実際に起きた出来事の言葉・書かれた本文・届いた部分の結果だけを出す。
/// 出来事が 10 秒以上来ない時は、その事実(「いつもより時間がかかっています」など)を出す。値と段は偽らない。
nonisolated enum TurnActivityKey {
    /// 会話の返事(台帳の assistant メッセージ)。
    static func reply(_ messageID: String) -> String { "reply:" + messageID.lowercased() }
    static func reply(_ messageID: UUID) -> String { reply(messageID.uuidString) }
    /// 構造化ターンの対象(答案・一枚・全体像の id)。
    static func target(_ targetID: String) -> String { "target:" + targetID.lowercased() }
    /// 答案に赤ペンを入れるターン(同じ答案の見直しと並んで走るので、対象とは別の key)。
    static func marks(_ attemptID: String) -> String { "marks:" + attemptID.lowercased() }
    /// 先回りで作っている例題(小単元)。
    static func examplePrefetch(subunitID: String) -> String { "prefetch-example:" + subunitID.lowercased() }
    /// 返事の中の提案から先に組み始めた全体像(A12)。返事の assistant メッセージで引く。
    static func unitPrefetch(messageID: String) -> String { "prefetch-unit:" + messageID.lowercased() }
    static func unitPrefetch(messageID: UUID) -> String { unitPrefetch(messageID: messageID.uuidString) }
}

/// 1 つのターンの、今わかっていること。
nonisolated struct TurnActivity: Sendable, Equatable {
    var startedAt: Date
    /// 最後に実際の出来事(モデル・ツール・圧縮・委任・部分の結果)が届いた時刻。無ければまだ 1 つも来ていない。
    var lastEventAt: Date?
    /// 最後の出来事の言葉(学習者に見せる短い文)。
    var headline: String? { didSet { if headline != oldValue { lastVisibleChangeAt = Date() } } }
    /// 書かれている返事の本文(タグ・閉じていない数式を除いた、見せてよい部分)。
    var visibleReply = "" { didSet { if visibleReply != oldValue { lastVisibleChangeAt = Date() } } }
    /// 部分の結果(届いた問題・判定・小単元の数)。
    var partialDone: Int? { didSet { if partialDone != oldValue { lastVisibleChangeAt = Date() } } }
    /// 書き終わった要素の、見せてよい文(一枚の問題文)。届いた順。
    var partialItems: [String] = []
    /// 画面に出る言葉・本文が最後に変わった時刻(出来事は届いていても、見えるものが変わらない間を測る)。
    var lastVisibleChangeAt: Date?
    var compacting = false
    var delegations = 0
    /// 動いているコマンド・dynamic tool(終わりが届くまで)。
    var runningTools: Set<String> = []
    var toolsRunning: Int { runningTools.count }
    /// 届いた推論の要約の段(item と要約の番号)。
    var reasoningParts: Set<String> = []
    var finished = false
    /// 見える返事を書き終え、その後ろの非公開のブロック(進み具合・記憶などの記録)だけを書いている。
    /// この間は学習者の送信を妨げない(送った質問は、記録が終わってから答える)。
    var writingPrivateTail = false
    /// 同じ会話の前の返事が記録を書き終えるのを待っている(この返事はまだ始まっていない)。
    var queuedBehindReply = false
    /// 構造化の枠が空くのを待っている(まだ AI に頼んでいない)。値は何の後に始まるかの言葉。
    var waitingForSlot: String?
    /// 学習者が「このまま待つ」を選んだ時刻。
    var keepWaitingAt: Date?

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// 出来事が来ていない秒数(最初の出来事の前はターンの始まりから)。
    func silence(now: Date) -> TimeInterval {
        now.timeIntervalSince(lastEventAt ?? startedAt)
    }
}

/// 出来事が来ない時に出す事実の言葉(W11・B7)。10 秒ごとに 1 段ずつ進む。どれも、その時点で本当のことだけ。
nonisolated enum TurnSilence {
    struct Statement: Equatable {
        var text: String
        /// 「止める」「このまま待つ」を出す(60 秒を超えた時)。
        var offersChoice: Bool
    }

    static let choiceAfter: TimeInterval = 60
    /// 前の返事の記録を待っている間の言葉。
    static let queuedText = "前の返事の記録が終わりしだい、答えます"

    static func statement(for activity: TurnActivity, now: Date) -> Statement? {
        guard !activity.finished else { return nil }
        if activity.queuedBehindReply {
            // まだ始まっていないので、沈黙は数えない(前の返事の記録は、その返事の行で見える)。
            return Statement(text: queuedText, offersChoice: false)
        }
        let silence = activity.silence(now: now)
        if let slot = activity.waitingForSlot {
            // まだ AI に頼んでいない(枠が空くのを待っている)。AI の応答を待っているとは言わない。
            // 1 分を超えて待っていれば、止めるか待つかを選べる(「このまま待つ」を選んだ後は聞き直さない)。
            return Statement(text: slot, offersChoice: activity.keepWaitingAt == nil && silence >= choiceAfter)
        }
        if let keep = activity.keepWaitingAt, (activity.lastEventAt ?? .distantPast) < keep {
            return Statement(text: "このまま待っています。応答が届いたらすぐに出します", offersChoice: false)
        }
        let started = activity.lastEventAt != nil
        if silence < 10 {
            // 出来事は届いているが、見えるものが 10 秒以上変わらない(長い記録を書いている等)。
            let unchanged = now.timeIntervalSince(activity.lastVisibleChangeAt ?? activity.startedAt)
            if started, unchanged >= 20 { return Statement(text: "長い作業を続けています。終わりしだい次へ進みます", offersChoice: false) }
            if started, unchanged >= 10 { return Statement(text: "同じ作業を続けています", offersChoice: false) }
            return nil
        }
        // 何が止まっているかで言い分ける(どれも、その時点で本当のこと)。
        let ladder: [String]
        if activity.compacting {
            ladder = ["会話の整理を続けています", "会話が長くなったので、整理に時間がかかっています", "整理が終わると、続きを考え始めます",
                      "整理が終わりしだい、ここに出します", "会話の整理が 1 分近く続いています",
                      "会話の整理が 1 分以上続いています。止めるか、このまま待つかを選べます"]
        } else if activity.toolsRunning > 0 || activity.delegations > 0 {
            ladder = ["この作業を続けています", "この作業に時間がかかっています", "作業が終わると、AI が続きを考えます",
                      "作業が終わりしだい、ここに出します", "この作業が 1 分近く続いています",
                      "この作業が 1 分以上続いています。止めるか、このまま待つかを選べます"]
        } else if started {
            ladder = ["AI が続きを考えています", "いつもより時間がかかっています", "AI の応答を待っています（混み合っている可能性があります）",
                      "応答が届いたら、すぐにここに出します", "AI からの応答がないまま、1 分近くたちました",
                      "1 分以上、AI から応答がありません。止めるか、このまま待つかを選べます"]
        } else {
            ladder = ["AI の最初の応答を待っています", "AI の応答を待っています（混み合っている可能性があります）", "いつもより時間がかかっています",
                      "応答が届いたら、すぐにここに出します", "AI からの応答がないまま、1 分近くたちました",
                      "1 分以上、AI から応答がありません。止めるか、このまま待つかを選べます"]
        }
        let step = min(ladder.count - 1, Int(silence / 10) - 1)
        return Statement(text: ladder[step], offersChoice: silence >= choiceAfter)
    }
}

/// 返事の本文のうち、書いている途中でも見せてよい部分。
nonisolated enum TurnReplyStream {
    /// 非公開のブロック(`<struis_…>`)の手前までを返す。書きかけのタグ(`<str` など)も落とす。
    static func visible(_ raw: String) -> String {
        var text = raw
        if let range = text.range(of: "<struis_", options: .caseInsensitive) {
            text = String(text[..<range.lowerBound])
        }
        if let open = text.lastIndex(of: "<") {
            let tail = text[open...].lowercased()
            if !tail.contains(">"), "<struis_".hasPrefix(tail) || tail.hasPrefix("<struis_") || tail.hasPrefix("</") {
                text = String(text[..<open])
            }
        }
        return closedMath(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 書いている途中の段落を読める文字にする(数式は近い記号に、箇条書きの「- 」は「• 」に)。
    static func readable(_ paragraph: String) -> String {
        approximateMath(paragraph)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.drop { $0 == " " }
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return "• " + trimmed.dropFirst(2) }
                if trimmed.hasPrefix("#") { return String(trimmed.drop { $0 == "#" || $0 == " " }) }
                return String(line)
            }
            .joined(separator: "\n")
    }

    /// `readable` と同じく読める文字に直し、強調(`**…**`)と見出し(`# …`)は太字で残す(書いている途中の段落)。
    static func readableMarkdown(_ paragraph: String) -> AttributedString {
        var result = AttributedString()
        for (index, line) in paragraph.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result += AttributedString("\n") }
            let trimmed = line.drop { $0 == " " }
            let heading = trimmed.hasPrefix("#")
            var body = String(line)
            if heading {
                body = String(trimmed.drop { $0 == "#" || $0 == " " })
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                body = "• " + trimmed.dropFirst(2)
            }
            // 閉じていない強調は `visible` が切っているので、`**` は開き・閉じの組で来る。
            for (offset, part) in body.components(separatedBy: "**").enumerated() where !part.isEmpty {
                var piece = AttributedString(approximateMath(part))
                if heading || offset % 2 == 1 { piece.inlinePresentationIntent = .stronglyEmphasized }
                result += piece
            }
        }
        return result
    }

    /// 返事の後ろに書いている非公開のブロック(学習者には見せない)を、何を書いているかの言葉にする。
    /// 本文が増えなくても、実際に書いているものが分かる(進み具合・記憶・全体像・例題)。
    static func privateBlockLabel(_ raw: String) -> String? {
        // 名前を書き終えた開きタグだけを見る(`<struis_m` のような書きかけは数えない)。
        guard let regex = try? NSRegularExpression(pattern: #"<struis_([a-z_]+)(?=[\s/>])"#, options: .caseInsensitive) else { return nil }
        let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        guard let last = matches.last, let range = Range(last.range(at: 1), in: raw) else { return nil }
        switch raw[range].lowercased() {
        case "progress_update":
            // 記録の中で書き終わった目標や次の行動の言葉を添える(モデルが実際に書いた値。数字や演出ではない)。
            let block = Range(last.range, in: raw).map { String(raw[$0.lowerBound...]) } ?? raw
            if let item = lastRecordedText(block) { return "学習の進み具合を記録しています（\(item)）" }
            return "学習の進み具合を記録しています"
        case "memory_update": return "覚えておくことを書き留めています"
        case "workbook_proposal": return "全体像の提案を書いています"
        case "workbook_hint": return "次の手がかりを書いています"
        case "workbook_example": return "例題を書いています"
        case "workbook_example_ready": return "例題の準備ができました"
        default: return "返事の仕上げをしています"
        }
    }

    /// 進み具合の記録(JSON)の中で、いちばん最後に書き終わった目標の題(日本語)。
    /// 題だけを出す: 次の行動・評価・メモは教える側の内部の記録で、答えや方針を含みうるので見せない。
    static func lastRecordedText(_ block: String, limit: Int = 24) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""title"\s*:\s*"((?:[^"\\]|\\.)*)""#) else { return nil }
        for match in regex.matches(in: block, range: NSRange(block.startIndex..., in: block)).reversed() {
            guard let range = Range(match.range(at: 1), in: block) else { continue }
            let value = String(block[range]).replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\\"", with: "\"")
            guard TurnProgress.containsJapanese(value) else { continue }
            let readable = approximateMath(value)
            return readable.count > limit ? String(readable.prefix(limit)) + "…" : readable
        }
        return nil
    }

    /// 本文の最後の一文(待ちの画面で、書かれている返事を 1 行で見せる)。
    static func lastSentence(_ visible: String, limit: Int = 48) -> String? {
        let trimmed = approximateMath(visible).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let line = trimmed.split(whereSeparator: \.isNewline).last.map(String.init) ?? trimmed
        let sentences = line.split(separator: "。", omittingEmptySubsequences: true)
        var sentence = (sentences.last.map(String.init) ?? line).trimmingCharacters(in: .whitespaces)
        if sentence.count > limit { sentence = "…" + sentence.suffix(limit) }
        return sentence
    }

    /// 閉じていない数式(`$…`、`$$…`、`\(…`、`\[…`)と強調(`**…`)の手前で切る(数式は閉じた式から順に描く)。
    static func closedMath(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var open: (start: Int, close: String)?
        var boldStart: Int?
        func matches(_ token: String, at position: Int) -> Bool {
            let tokenScalars = Array(token.unicodeScalars)
            guard position + tokenScalars.count <= scalars.count else { return false }
            for (offset, scalar) in tokenScalars.enumerated() where scalars[position + offset] != scalar { return false }
            return true
        }
        while index < scalars.count {
            if let current = open {
                if matches(current.close, at: index) {
                    index += current.close.unicodeScalars.count
                    open = nil
                    continue
                }
                index += 1
                continue
            }
            if scalars[index] == "\\", index + 1 < scalars.count, scalars[index + 1] == "$" {
                index += 2
                continue
            }
            if matches("$$", at: index) {
                open = (index, "$$"); index += 2; continue
            }
            if matches("$", at: index) {
                open = (index, "$"); index += 1; continue
            }
            if matches("\\(", at: index) {
                open = (index, "\\)"); index += 2; continue
            }
            if matches("\\[", at: index) {
                open = (index, "\\]"); index += 2; continue
            }
            if matches("**", at: index) {
                boldStart = boldStart == nil ? index : nil
                index += 2
                continue
            }
            index += 1
        }
        var cut = scalars.count
        if let open { cut = min(cut, open.start) }
        if let boldStart { cut = min(cut, boldStart) }
        // 最後に残った `\` (`\(` の書きかけ) も落とす。
        if cut == scalars.count, scalars.last == "\\" { cut -= 1 }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[0..<cut])
        return String(view)
    }

    /// 書いている途中の段落の数式を、読める文字に直す(閉じた式だけ。KaTeX は段落が書き終わってから描く)。
    static func approximateMath(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            ("\\left", ""), ("\\right", ""), ("\\times", "×"), ("\\cdot", "·"), ("\\div", "÷"), ("\\pm", "±"),
            ("\\leq", "≤"), ("\\geq", "≥"), ("\\le", "≤"), ("\\ge", "≥"), ("\\neq", "≠"), ("\\ne", "≠"),
            ("\\Rightarrow", "⇒"), ("\\rightarrow", "→"), ("\\to", "→"), ("\\quad", " "), ("\\,", " "), ("\\;", " "),
            ("\\alpha", "α"), ("\\beta", "β"), ("\\theta", "θ"), ("\\pi", "π"), ("\\infty", "∞"),
            ("^2", "²"), ("^3", "³"), ("^{2}", "²"), ("^{3}", "³"),
        ]
        result = result.replacingOccurrences(of: #"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#, with: "($1)/($2)", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\\sqrt\{([^{}]*)\}"#, with: "√($1)", options: .regularExpression)
        for (from, to) in replacements { result = result.replacingOccurrences(of: from, with: to) }
        for token in ["$$", "$", "\\(", "\\)", "\\[", "\\]"] { result = result.replacingOccurrences(of: token, with: "") }
        result = result.replacingOccurrences(of: #"\\text\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return result.replacingOccurrences(of: "**", with: "")
    }
}

/// 各ターンの今の様子。画面はこれを読む(`@Observable`)。
@Observable
@MainActor
final class TurnActivityBoard {
    static let shared = TurnActivityBoard()

    private(set) var activities: [String: TurnActivity] = [:]
    /// 返事の本文の生の文字(アイテムごと)。見せる文字は `TurnActivity.visibleReply`。
    @ObservationIgnored private var replyText: [String: (itemID: String, text: String)] = [:]
    @ObservationIgnored private var publishPending: Set<String> = []
    @ObservationIgnored private var lastPublish: [String: Date] = [:]
    /// 終わった印(同じ key で次のターンが始まったら外す)。
    @ObservationIgnored private var generation: [String: Int] = [:]

    func activity(_ key: String?) -> TurnActivity? {
        guard let key else { return nil }
        return activities[key]
    }

    /// いちばん新しく始まった、まだ終わっていない活動。
    func firstLive(_ keys: [String]) -> TurnActivity? {
        keys.compactMap { activities[$0] }.filter { !$0.finished }.max { $0.startedAt < $1.startedAt }
    }

    func begin(_ key: String, at date: Date = Date(), queuedBehindReply: Bool = false) -> Int {
        let next = (generation[key] ?? 0) + 1
        generation[key] = next
        var activity = TurnActivity(startedAt: date)
        activity.queuedBehindReply = queuedBehindReply
        activities[key] = activity
        replyText[key] = nil
        return next
    }

    func finish(_ key: String, generation expected: Int) {
        guard generation[key] == expected else { return }
        publishReply(key)
        activities[key]?.finished = true
    }

    /// 前の返事の記録が終わり、この返事が始まった(待っていた間は沈黙に数えない)。
    func startQueued(_ key: String, generation expected: Int, at date: Date = Date()) {
        guard generation[key] == expected, activities[key]?.queuedBehindReply == true else { return }
        activities[key]?.queuedBehindReply = false
        activities[key]?.startedAt = date
    }

    /// 学習者が「このまま待つ」を選んだ。
    func keepWaiting(_ key: String) {
        activities[key]?.keepWaitingAt = Date()
    }

    /// 枠が空くのを待ち始めた(`text`)・枠を取れた(nil)。取れた時から、AI の応答の沈黙を数え直す。
    func slotWait(_ key: String, text: String?, generation expected: Int, at date: Date = Date()) {
        guard generation[key] == expected, var activity = activities[key] else { return }
        let wasWaiting = activity.waitingForSlot != nil
        activity.waitingForSlot = text
        if text == nil, wasWaiting { activity.startedAt = date }
        activities[key] = activity
        activityLog.info("activity \(key, privacy: .public) slot \(text ?? "acquired", privacy: .public)")
    }

    func apply(_ key: String, _ event: TurnProgressEvent, generation expected: Int) {
        guard generation[key] == expected, var activity = activities[key] else { return }
        let now = Date()
        if case .replyDelta = event.kind {} else {
            // 画面に出した段と rollout の出来事を照らし合わせるための記録(検証用。本文は残さない)。
            activityLog.info("activity \(key, privacy: .public) \(String(describing: event.kind).prefix(60), privacy: .public) \(event.label, privacy: .public)")
        }
        switch event.kind {
        case .waitingForModel:
            // ランナーが沈黙を測った印。出来事ではないので、最後の出来事の時刻は動かさない。
            return
        case .replyDelta(let itemID, let text):
            var current = replyText[key] ?? (itemID, "")
            if current.itemID != itemID { current = (itemID, "") }
            current.text += text
            replyText[key] = current
            activity.lastEventAt = now
            // 本文の後ろの非公開のブロックを書いている間は、何を書いているかを言う(本文は増えないので)。
            let block = TurnReplyStream.privateBlockLabel(current.text)
            activity.writingPrivateTail = block != nil
            if let block {
                if activity.headline != block { activityLog.info("activity \(key, privacy: .public) privateBlock \(block, privacy: .public)") }
                activity.headline = block
            } else if !event.label.isEmpty, current.text.range(of: "<struis_", options: .caseInsensitive) == nil {
                // 書きかけのタグの間は、前の言葉のまま(「返事を書いています」に戻してちらつかせない)。
                activity.headline = event.label
            }
            activities[key] = activity
            schedulePublish(key)
            return
        case .commentary:
            // 途中経過の文として書かれていたものは、返事の本文から外す。
            if let itemID = event.progressID, replyText[key]?.itemID == itemID {
                replyText[key] = nil
                activity.visibleReply = ""
                activity.writingPrivateTail = false
            }
        case .compaction(let started):
            activity.compacting = started
        case .delegation(let started):
            activity.delegations = max(0, activity.delegations + (started ? 1 : -1))
        case .partialResult(let done, _):
            activity.partialDone = done
            activity.partialItems = event.items
        case .reasoningSummary:
            // 推論の要約の見出しが日本語でなければ、届いた段の数だけを言う(本当に届いた要約の数。偽らない)。
            if let part = event.progressID { activity.reasoningParts.insert(part) }
            if event.label.isEmpty {
                activity.headline = "AI が考えを進めています（\(max(1, activity.reasoningParts.count)) 段目）"
                activity.lastEventAt = now
                activities[key] = activity
                return
            }
        case .activity:
            // コマンド・dynamic tool の始まり(「〜ています」)と終わり(「〜ました」)で、動いている作業を数える。
            if let id = event.progressID, id.hasPrefix("cmd-") {
                if event.label.hasSuffix("ています") { activity.runningTools.insert(id) } else { activity.runningTools.remove(id) }
            }
        }
        activity.lastEventAt = now
        if !event.label.isEmpty { activity.headline = event.label }
        activities[key] = activity
    }

    /// 本文の表示は 0.25 秒に 1 回まで(書かれるたびに描き直さない)。
    private func schedulePublish(_ key: String) {
        let last = lastPublish[key] ?? .distantPast
        if Date().timeIntervalSince(last) >= 0.25 {
            publishReply(key)
            return
        }
        guard publishPending.insert(key).inserted else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.publishPending.remove(key)
            self?.publishReply(key)
        }
    }

    private func publishReply(_ key: String) {
        lastPublish[key] = Date()
        guard let raw = replyText[key]?.text else { return }
        let visible = TurnReplyStream.visible(raw)
        if activities[key]?.visibleReply != visible { activities[key]?.visibleReply = visible }
    }

    /// ランナーへ渡す受け口。呼ばれた順に板へ届ける(返事の本文の順序を崩さない)。
    /// `queuedBehindReply`: 同じ会話の前の返事の記録を待ってから始まる返事(始まったら `TurnActivitySink.started()`)。
    nonisolated static func sink(_ key: String, queuedBehindReply: Bool = false) -> TurnActivitySink {
        let (stream, continuation) = AsyncStream.makeStream(of: TurnActivitySink.Message.self)
        let started = Date()
        Task { @MainActor in
            let board = TurnActivityBoard.shared
            let generation = board.begin(key, at: started, queuedBehindReply: queuedBehindReply)
            for await message in stream {
                switch message {
                case .event(let event): board.apply(key, event, generation: generation)
                case .started(let date): board.startQueued(key, generation: generation, at: date)
                case .slotWait(let text, let date): board.slotWait(key, text: text, generation: generation, at: date)
                }
            }
            board.finish(key, generation: generation)
        }
        return TurnActivitySink(continuation: continuation)
    }
}

/// 1 つのターンの進捗の受け口。`finish()` で流れを閉じる。
nonisolated struct TurnActivitySink: Sendable {
    enum Message: Sendable {
        case event(TurnProgressEvent)
        /// 前の返事を待っていたターンが始まった。
        case started(Date)
        /// 構造化の枠を待ち始めた(言葉)・枠を取れた(nil)。
        case slotWait(String?, Date)
    }

    let continuation: AsyncStream<Message>.Continuation

    func send(_ event: TurnProgressEvent) { continuation.yield(.event(event)) }
    func started() { continuation.yield(.started(Date())) }
    func waitForSlot(_ text: String?) { continuation.yield(.slotWait(text, Date())) }
    func finish() { continuation.finish() }
}
