import Foundation

/// 離れて戻った時の計算練習(Issue #155)。学習者の計算のつまずき(ボトルネック)になっている点の易しい問題を 2〜3 問
/// 出してから、元の問題に戻る。出す問題は、いつものカードと同じ見た目で出す(戻ったことを特別な画面にしない)。
/// 中身は点ごとの「問題の型」(`DrillTemplate`)から端末が作る(AI を待たない)。型の無い時は、手元の速攻の問題を使う。
/// 正答率・先へ進む判定・定着・詰まりの判定には数えない(カードの origin が `warmup`)。
nonisolated enum TimelineWarmup {
    static let origin: String = "warmup"
    /// これ以上離れていたら出す(5分)。
    static let awaySeconds: TimeInterval = 300
    /// 解いている途中で離れた時: これ未満なら、その問題の答えを送った後に出す。これ以上なら先に出す(30分)。
    static let midCardSeconds: TimeInterval = 1800
    /// 2 問とも ○ なら 2 問で戻る。それ以外は 3 問まで。
    static let minimumCount: Int = 2
    static let maximumCount: Int = 3
    /// 直近この日数の × が `recentWrongs` 回以上の点を、計算のつまずきとみなす(今日を含めて 3 日)。
    static let recentDays: Int = 3
    static let recentWrongs: Int = 2
    /// 不意打ちで × だった点は、この日数のうちは候補に入れる。
    static let surpriseMissDays: Int = 7
    /// 次の依頼に一言を添えるのは、× がこの数以上の時。
    static let noteWrongs: Int = 2

    nonisolated enum Timing: Equatable, Sendable {
        /// 出さない。
        case none
        /// 今すぐ出す(戻ったら元の問題に戻る)。
        case now
        /// 解いている問題の答えを送った後に出す。
        case afterAnswer
    }

    /// 離れていた秒数と、解いている途中だったかから、いつ出すか。
    static func timing(awaySeconds seconds: TimeInterval, midCard: Bool) -> Timing {
        guard seconds >= awaySeconds else { return .none }
        if midCard, seconds < midCardSeconds { return .afterAnswer }
        return .now
    }

    /// これまでの結果(出した順の ○×)から、もう 1 問出すか。
    static func wantsAnother(results: [Bool]) -> Bool {
        if results.count < minimumCount { return true }
        if results.count >= maximumCount { return false }
        return !results.allSatisfy { $0 }
    }

    /// 次の 5 枚の依頼に添える一言(× が 2 問以上の時だけ)。
    static func note(skillName: String, results: [Bool]) -> String? {
        let wrong: Int = results.filter { !$0 }.count
        guard wrong >= noteWrongs else { return nil }
        return "戻った時の計算練習(\(skillName))で \(results.count) 問中 \(wrong) 問 ×。この点の計算がまだ崩れやすい(正答率には数えていない)。"
    }

    // MARK: - 答えの式

    /// 型の答え(文の中の式は `$…$`)から、アプリが読み取った答えと突き合わせる式。数だけの答え(`16`・`\frac{1}{8}`・
    /// `2\sqrt{3}` など)だけを式にする。文字や単位や等号を含む答えは空にして、いつもの採点に回す。
    static func answerExpr(fromAnswer answer: String) -> String {
        var text: String = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("$"), text.hasSuffix("$"), text.count >= 2 else { return "" }
        text = String(text.dropFirst().dropLast())
        guard !text.contains("$") else { return "" }
        guard let converted: String = plainExpression(fromLaTeX: text) else { return "" }
        // 数だけの式(sqrt と pi のほかに文字が無い)。
        let letters: String = converted.replacingOccurrences(of: "sqrt", with: "").replacingOccurrences(of: "pi", with: "")
        guard !letters.contains(where: { $0.isLetter }) else { return "" }
        guard let parsed: TimelineExpression = try? TimelineExpression.parse(converted),
              let value: Double = parsed.evaluate([:]), value.isFinite else { return "" }
        return converted
    }

    /// 簡単な LaTeX(分数・平方根・べき・×÷)を、`TimelineExpression` が読める式にする。読めない命令があれば nil。
    static func plainExpression(fromLaTeX source: String) -> String? {
        var text: String = source
        for (from, to) in [("\\left", ""), ("\\right", ""), ("\\,", ""), ("\\;", ""), ("\\!", ""), ("\\ ", ""), ("\\times", "*"), ("\\cdot", "*"),
                           ("\\div", "/"), ("\\pi", "pi"), ("\\dfrac", "\\frac"), ("\\tfrac", "\\frac"), ("−", "-")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        var characters: [Character] = Array(text)
        var index: Int = 0
        guard let out: String = convert(&characters, &index, until: nil), index == characters.count else { return nil }
        let allowed: Set<Character> = Set("0123456789.+-*/^() abcdefghijklmnopqrstuvwxyz")
        guard !out.isEmpty, out.allSatisfy({ allowed.contains($0) }) else { return nil }
        return out.replacingOccurrences(of: " ", with: "")
    }

    /// `until` の文字(閉じ波かっこ)まで読んで式にする。
    private static func convert(_ chars: inout [Character], _ index: inout Int, until close: Character?) -> String? {
        var out: String = ""
        while index < chars.count {
            let c: Character = chars[index]
            if let close, c == close { index += 1; return out }
            if c == "\\" {
                var name: String = ""
                index += 1
                while index < chars.count, chars[index].isLetter { name.append(chars[index]); index += 1 }
                switch name {
                case "frac":
                    guard let a: String = group(&chars, &index), let b: String = group(&chars, &index) else { return nil }
                    out += "((\(a))/(\(b)))"
                case "sqrt":
                    var root: String? = nil
                    if index < chars.count, chars[index] == "[" {
                        index += 1
                        guard let r: String = convert(&chars, &index, until: "]") else { return nil }
                        root = r
                    }
                    guard let body: String = group(&chars, &index) else { return nil }
                    out += root.map { "((\(body))^(1/(\($0))))" } ?? "sqrt(\(body))"
                default:
                    return nil
                }
                continue
            }
            if c == "{" {
                index += 1
                guard let inner: String = convert(&chars, &index, until: "}") else { return nil }
                out += "(\(inner))"
                continue
            }
            if c == "}" || c == "]" { return nil }
            out.append(c)
            index += 1
        }
        return close == nil ? out : nil
    }

    /// `{…}` 1 つ(波かっこが無ければ次の 1 文字)。
    private static func group(_ chars: inout [Character], _ index: inout Int) -> String? {
        while index < chars.count, chars[index] == " " { index += 1 }
        guard index < chars.count else { return nil }
        if chars[index] == "{" {
            index += 1
            return convert(&chars, &index, until: "}")
        }
        let c: Character = chars[index]
        guard c.isNumber || c.isLetter else { return nil }
        index += 1
        return String(c)
    }
}

// MARK: - 台帳から決めること

extension TimelineMachine {
    /// 計算のつまずきとして練習させる点の候補(先頭ほど優先)。型にできる種類の点(手順・組み合わせ)だけ。
    /// 1. 今日、同じ点で × が 3 回(詰まり)。 2. 直近 3 日の数える答案で × が 2 回以上(途中の誤りは除く)。
    /// 3. 直近 7 日の不意打ちで × だった点。
    var warmupCandidates: [String] {
        var out: [String] = []
        func add(_ id: String) {
            guard !out.contains(id), let skill = skills[id], DrillAuthoring.isCandidate(kind: skill.kind) else { return }
            out.append(id)
        }
        for stuck in stuckSkills { add(stuck.skill) }
        let today: String = today
        var wrongs: [String: (count: Int, last: String)] = [:]
        for attempt in orderedAttempts where attempt.countsForAccuracy && attempt.grade != "partial" {
            guard let day = TimelineRules.day(attempt.createdAt, calendar: calendar),
                  let gap = TimelineRules.daysBetween(day, today), gap < TimelineWarmup.recentDays else { continue }
            for mark in skillMarks(attempt) where !mark.correct {
                wrongs[mark.skill] = ((wrongs[mark.skill]?.count ?? 0) + 1, attempt.createdAt)
            }
        }
        let recent = wrongs.filter { $0.value.count >= TimelineWarmup.recentWrongs }
            .sorted { ($0.value.count, $0.value.last, $0.key) > ($1.value.count, $1.value.last, $1.key) }
        for (id, _) in recent { add(id) }
        for attempt in orderedAttempts.reversed() where attempt.verdict == "wrong" && attempt.grade != "partial" {
            guard let card = cards[attempt.cardId], let skillID = surpriseSkill(of: card),
                  let day = TimelineRules.day(attempt.createdAt, calendar: calendar),
                  let gap = TimelineRules.daysBetween(day, today), gap < TimelineWarmup.surpriseMissDays else { continue }
            add(skillID)
        }
        return out
    }

    /// ウォームアップのカードなら、その回の ID。
    func warmupSession(of card: TimelineCardRecord) -> String? {
        guard card.origin == TimelineWarmup.origin else { return nil }
        return card.payload["warmup_session"]?.stringValue
    }

    /// その回で出したカード(出した順)。
    func warmupCards(session: String) -> [TimelineCardRecord] {
        cards.values.filter { warmupSession(of: $0) == session }.sorted { ($0.createdAt, $0.position) < ($1.createdAt, $1.position) }
    }

    /// その回の結果(出した順の ○×。結果の出ていないカード・飛ばしたカードは入れない)。
    func warmupResults(session: String) -> [Bool] {
        warmupCards(session: session).compactMap { card -> Bool? in
            guard let attempt = attempts(cardID: card.id).last(where: { $0.verdict == "correct" || $0.verdict == "wrong" }) else { return nil }
            return attempt.verdict == "correct"
        }
    }

    /// 型から作った問題を、次に出す位置へ差し込む。
    @discardableResult
    mutating func insertWarmup(skillID: String, problem: DrillProblem, title: String, session: String) -> String {
        let first: Int = queue.first?.position ?? nextPosition
        let card = TimelineCardRecord(
            id: newID(), batchId: nil, position: first - 1, kind: "solve", level: 1, skills: [],
            typeName: title, prompt: problem.prompt, math: problem.math, question: "", answerKey: problem.answer,
            answerExpr: TimelineWarmup.answerExpr(fromAnswer: problem.answer), checkpoints: [], commonMistakes: [], estimatedSeconds: 20,
            chain: nil, easierOf: nil, subunitId: nil, unitId: skills[skillID]?.unitId,
            payload: .object(["warmup": .string(skillID), "warmup_session": .string(session)]),
            origin: TimelineWarmup.origin, status: "unused", createdAt: now(), updatedAt: now()
        )
        put("timeline.card_warmup", card)
        return card.id
    }

    /// 型が無い時: 手元の速攻の問題を 1 問、ウォームアップとして出す(速攻の手元からは外れる)。
    @discardableResult
    mutating func adoptRapidAsWarmup(cardID: String, session: String) -> String? {
        guard var card = cards[cardID], card.origin == "rapid", card.status == "unused" else { return nil }
        var payload: [String: LedgerJSON] = card.payload.objectValue ?? [:]
        payload["warmup_session"] = .string(session)
        payload["warmup_from"] = .string("rapid")
        card.payload = .object(payload)
        card.origin = TimelineWarmup.origin
        card.position = (queue.first?.position ?? nextPosition) - 1
        card.updatedAt = now()
        put("timeline.card_warmup", card)
        return card.id
    }

    /// その回が終わった: × が多ければ、次の依頼に読ませる一言を今日の記録に残す。
    mutating func finishWarmup(session: String) {
        let cards = warmupCards(session: session)
        guard !cards.isEmpty else { return }
        let skillID: String? = cards.first?.payload["warmup"]?.stringValue
        let name: String = skillID.flatMap { skills[$0]?.name } ?? cards.first?.typeName ?? "計算"
        guard let text = TimelineWarmup.note(skillName: name, results: warmupResults(session: session)) else { return }
        _ = appendLog(kind: "warmup", skillIDs: skillID.map { [$0] } ?? [], text: text)
    }

    /// 最後に手を動かした時刻(答案・カードの表示)。アプリを開き直した時に、離れていた時間を測る。
    var lastActivityAt: String? {
        let answered: String? = attempts.values.map(\.createdAt).max()
        let shown: String? = cards.values.filter { $0.status == "shown" || $0.status == "answered" }.map(\.updatedAt).max()
        return [answered, shown].compactMap { $0 }.max()
    }
}
