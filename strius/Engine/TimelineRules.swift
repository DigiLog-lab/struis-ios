import Foundation

/// 学習タイムラインの規則(Issue #46「内部ロジック」)。次に出す 1 枚の切り替え・正答率・段の歯止め・
/// 2択カードを出す条件・「できること」の状態と復習の間隔。どれも AI を待たずに端末で決める純粋な関数で、
/// 数字は仮置き(記録を見て調整する)。
nonisolated enum TimelineRules {
    // MARK: 仮置きの数字

    /// 正答率を測る窓(直近10問)。
    static let accuracyWindow = 10
    static let targetAccuracy = 0.8
    /// これを超えたら段を上げる。
    static let raiseAbove = 0.85
    /// これを切ったら段を下げるか前提へ下りる。
    static let lowerBelow = 0.7
    /// これを切ったら、AI の判断に関係なく次の5枚は段を1つ下げさせる。
    static let forceLowerBelow = 0.6
    /// 1 回に頼む枚数と、裏で次を頼む位置(5枚のうち4枚目を出した時点)。
    static let batchSize = 5
    static let requestAtPosition = 4
    /// 定着の基準(別々の日に3回、外れた人は4回)。
    static let masteryThreshold = 3
    static let raisedMasteryThreshold = 4
    /// 定着後に ○ だった回数ごとの、次に出すまでの日数。
    static let reviewIntervals = [3, 7, 21]
    /// 2択カード: いつもの2倍、他のアプリから30秒、次の8枚は出さない、最初の10問は判定しない、「いつも」は同じ段の直近20問。
    static let slowFactor = 2.0
    static let awaySeconds: TimeInterval = 30
    static let dipCooldownCards = 8
    static let dipWarmupAttempts = 10
    static let usualWindow = 20
    /// 同じ「できること」で1日に3回 × で原因も見つからなければ、その日は出さない。
    static let dailyWrongLimit = 3
    /// 上位モデルの見直し: アプリの修正が3つ溜まった。
    static let reviewAfterChanges = 3
    static let rapidCount = 3

    // MARK: 日付

    static func day(_ iso: String?, calendar: Calendar = .current) -> String? {
        guard let iso, let date = LedgerClock.parse(iso) else { return nil }
        return day(date, calendar: calendar)
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 2 つの日(yyyy-MM-dd)の間の日数。
    static func daysBetween(_ from: String, _ to: String) -> Int? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let a = formatter.date(from: from), let b = formatter.date(from: to) else { return nil }
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }

    // MARK: 正答率

    /// 直近10問の正答率に数えるか。数えないもの: その日の最初の30秒の1問、間違えた後に出したやさしい版、速攻の問題、飛ばした問題。
    /// 撮らないカード(並べ替えなど)と、答えが間違っていた問題も数えない。
    static func countsForAccuracy(card: TimelineCardRecord, isFirstOfDay: Bool, verdict: String) -> Bool {
        guard verdict == "correct" || verdict == "wrong" else { return false }
        if isFirstOfDay || card.origin == "easier" || card.origin == "rapid" || card.status == "broken" { return false }
        return card.kind == "solve"
    }

    /// 数に入る解答(古い順)から、直近10問の正答率。1 問も無ければ nil。
    static func accuracy(_ attempts: [TimelineAttemptRecord]) -> Double? {
        let window = attempts.filter { $0.countsForAccuracy && ($0.verdict == "correct" || $0.verdict == "wrong") }.suffix(accuracyWindow)
        guard !window.isEmpty else { return nil }
        return Double(window.filter { $0.verdict == "correct" }.count) / Double(window.count)
    }

    /// 次の5枚の段の目安(AI への指示に書く基準)。
    static func levelDirection(accuracy: Double?) -> String {
        guard let accuracy else { return "same" }
        if accuracy > raiseAbove { return "raise" }
        if accuracy < lowerBelow { return "lower" }
        return "same"
    }

    /// 歯止め: 直近10問の正答率が60%を切ったら、次の5枚は今の段から1つ下げさせる(返ってきた level が上限を超えたら作り直し)。
    static func levelCap(accuracy: Double?, currentLevel: Int) -> Int? {
        guard let accuracy, accuracy < forceLowerBelow else { return nil }
        return max(1, currentLevel - 1)
    }

    /// × が2回続いた(数に入る解答の直近2つ、または同じ流れの直近2つ)。次は定着済みの前提の段1を挟む。
    static func twoWrongInARow(_ attempts: [TimelineAttemptRecord]) -> Bool {
        let graded = attempts.filter { $0.verdict == "correct" || $0.verdict == "wrong" }.suffix(2)
        return graded.count == 2 && graded.allSatisfy { $0.verdict == "wrong" }
    }

    // MARK: 次の 1 枚

    nonisolated enum Outcome: Equatable, Sendable {
        case correct
        case wrong
        case skipped
    }

    nonisolated struct Next: Equatable, Sendable {
        /// 次に出すカード(nil なら手元に無い: 頼んだ5枚を待つ)。
        var cardID: String?
        /// その場で作るやさしい版(元のカード)。
        var makeEasierOf: String?
        /// 残りの5枚を捨てる。
        var discardIDs: [String] = []
        /// 新しく5枚を頼む。
        var requestBatch = false
        /// 結果の画面で「入試の形」を明かす(さっきの続きの最後を ○)。
        var reveal = false
        /// 「さっきの続き」を保留にした(やさしい版も ×)。
        var pausedChain: String?
    }

    /// 正解・間違い・飛ばすの直後の 1 枚(本文の「カードの切り替え」の表)。`queue` は手元の未使用のカード(出す順)。
    static func next(
        after card: TimelineCardRecord, outcome: Outcome, queue: [TimelineCardRecord], rapid: [TimelineCardRecord],
        wrongBefore: Bool
    ) -> Next {
        let rest = queue.filter { $0.id != card.id }
        switch outcome {
        case .correct:
            var next = Next(cardID: rest.first?.id)
            next.reveal = isLastOfChain(card)
            if rest.isEmpty { next.cardID = rapid.first?.id; next.requestBatch = true }
            return next
        case .wrong:
            if card.origin == "easier" || wrongBefore {
                // やさしい版も ×: その前提の段1(手元の速攻用)。続きは保留、残りは捨てて頼み直す。
                var next = Next(cardID: rapid.first?.id ?? rest.first?.id)
                next.discardIDs = rest.filter { $0.id != next.cardID }.map(\.id)
                next.requestBatch = true
                next.pausedChain = chainID(card)
                return next
            }
            if card.payload["easier"]?.objectValue != nil {
                return Next(cardID: nil, makeEasierOf: card.id)
            }
            var next = Next(cardID: rest.first?.id ?? rapid.first?.id)
            if rest.isEmpty { next.requestBatch = true }
            return next
        case .skipped:
            // 飛ばした問題と同じ「さっきの続き」に属さない次のカード。無ければ速攻用を出して、残りを捨てて頼み直す。
            let chain = chainID(card)
            if let other = rest.first(where: { chain == nil || chainID($0) != chain }) {
                return Next(cardID: other.id)
            }
            var next = Next(cardID: rapid.first?.id)
            next.discardIDs = rest.map(\.id)
            next.requestBatch = true
            return next
        }
    }

    static func chainID(_ card: TimelineCardRecord) -> String? {
        card.chain?["chain_id"]?.stringValue
    }

    static func chainPosition(_ card: TimelineCardRecord) -> (position: Int, total: Int)? {
        guard let position = card.chain?["position"]?.intValue, let total = card.chain?["total"]?.intValue, total > 1 else { return nil }
        return (position, total)
    }

    static func isLastOfChain(_ card: TimelineCardRecord) -> Bool {
        guard let chain = chainPosition(card) else { return card.level >= 4 && card.origin == "batch" }
        return chain.position >= chain.total
    }

    /// 裏で次の5枚を頼むか: 5枚のうち4枚目を出した時点(手元の未使用が1枚以下)で、頼んでいる最中でない。
    static func shouldRequestBatch(unusedCount: Int, pending: Bool) -> Bool {
        !pending && unusedCount <= batchSize - requestAtPosition
    }

    // MARK: その日の1枚目

    nonisolated enum FirstCard: Equatable, Sendable {
        /// 前の日の「さっきの続き」の残り(「↺ 昨日」、解けている分は ○)。
        case resume(cardID: String)
        /// 手元の速攻用の問題(定着済みの前提の段1)。「時計 30秒」「答えだけでOK」。
        case rapid(cardID: String)
        /// 前に解けた形(保存済みの過去の問題)。
        case history(cardID: String)
        /// 使い始め: 「単元を作る」へ案内する1枚(オンボーディングの最初の1問の流れ #40 ができるまで)。
        case guide
    }

    /// その日の1枚目(AI を待たせない)。`cards` は手元の全カード、`today` は今日(yyyy-MM-dd)。
    static func firstCard(cards: [TimelineCardRecord], attempts: [TimelineAttemptRecord], history: [TimelineCardRecord], today: String) -> FirstCard {
        if let resume = resumeCard(cards: cards, attempts: attempts, today: today) { return .resume(cardID: resume.id) }
        if let rapid = cards.first(where: { $0.origin == "rapid" && $0.status == "unused" }) { return .rapid(cardID: rapid.id) }
        if let past = history.first { return .history(cardID: past.id) }
        return .guide
    }

    /// 前の日に途中で止まった「さっきの続き」の、次に解く 1 枚。
    static func resumeCard(cards: [TimelineCardRecord], attempts: [TimelineAttemptRecord], today: String) -> TimelineCardRecord? {
        let answered = Dictionary(grouping: attempts, by: \.cardId)
        var chains: [String: [TimelineCardRecord]] = [:]
        for card in cards { if let id = chainID(card) { chains[id, default: []].append(card) } }
        var best: (TimelineCardRecord, String)?
        for (_, members) in chains {
            let ordered = members.sorted { (chainPosition($0)?.position ?? 0) < (chainPosition($1)?.position ?? 0) }
            let solved = ordered.filter { answered[$0.id]?.contains { $0.verdict == "correct" } == true }
            guard let lastSolved = solved.last, let solvedDay = TimelineRules.day(answered[lastSolved.id]?.last?.createdAt), solvedDay < today else { continue }
            guard let next = ordered.first(where: { card in
                (chainPosition(card)?.position ?? 0) > (chainPosition(lastSolved)?.position ?? 0)
                    && answered[card.id]?.contains { $0.verdict == "correct" } != true
                    && card.status != "broken"
            }) else { continue }
            if best == nil || solvedDay > best!.1 { best = (next, solvedDay) }
        }
        return best?.0
    }

    // MARK: 2択カード

    nonisolated enum DipTrigger: String, Equatable, Sendable {
        case slow
        case skips
        case away
    }

    /// 「いつも」= 同じ段の直近20問にかかった時間の真ん中の値。使い始めの10問は判定しない(目安の秒数が無ければ nil)。
    static func usualSeconds(level: Int, history: [(level: Int, seconds: Double)], estimatedSeconds: Int?) -> Double? {
        if history.count < dipWarmupAttempts {
            return estimatedSeconds.map(Double.init)
        }
        let same = history.filter { $0.level == level }.suffix(usualWindow).map(\.seconds).sorted()
        guard !same.isEmpty else { return estimatedSeconds.map(Double.init) }
        let middle = same.count / 2
        return same.count % 2 == 0 ? (same[middle - 1] + same[middle]) / 2 : same[middle]
    }

    /// 撮るか飛ばすかした直後に、2択カードを出すか。`sinceLastDip` は前の2択カードの後に出したカードの数(無ければ nil)。
    static func dipAfterAnswer(seconds: Double, usual: Double?, outcome: Outcome, previousWasSkip: Bool, sinceLastDip: Int?) -> DipTrigger? {
        if let sinceLastDip, sinceLastDip < dipCooldownCards { return nil }
        if outcome == .skipped, previousWasSkip { return .skips }
        if let usual, usual > 0, seconds > usual * slowFactor { return .slow }
        return nil
    }

    /// 解いている途中で他のアプリに移り、30秒以上たって戻ってきた。
    static func dipOnReturn(awaySeconds seconds: TimeInterval, isSolving: Bool, sinceLastDip: Int?) -> DipTrigger? {
        if let sinceLastDip, sinceLastDip < dipCooldownCards { return nil }
        return isSolving && seconds >= awaySeconds ? .away : nil
    }

    // MARK: 「できること」の状態

    /// 1 回の結果を「できること」に反映する。定着: 別々の日に基準の回数、ヒントなしで ○、しかも目安時間内。
    /// 定着したはずのものが × → 練習中に戻し、この点だけ基準を 4 回に上げる。
    static func record(_ skill: TimelineSkillRecord, correct: Bool, assisted: Bool, withinTime: Bool, at now: String, calendar: Calendar = .current) -> TimelineSkillRecord {
        var row = skill
        row.attempts += 1
        row.updatedAt = now
        guard let today = day(now, calendar: calendar) else { return row }
        if correct {
            row.lastCorrectAt = now
            if !assisted, withinTime, !row.correctDates.contains(today) { row.correctDates.append(today) }
            if row.status == "mastered" {
                row.reviewCount += 1
                row.nextReviewAt = nextReview(reviewCount: row.reviewCount, from: today)
            } else if row.correctDays >= row.masteryThreshold {
                row.status = "mastered"
                row.reviewCount = 0
                row.nextReviewAt = nextReview(reviewCount: 0, from: today)
            } else if row.status == "assumed" {
                row.status = "practicing"
            }
        } else {
            if row.status == "mastered" {
                row.masteryThreshold = raisedMasteryThreshold
                row.correctDates = []
                row.nextReviewAt = nil
            }
            row.status = "practicing"
        }
        return row
    }

    /// 上の問題が一発で ○ になった時、未定着の前提を「できると推定」にする。
    static func assume(_ skill: TimelineSkillRecord, at now: String) -> TimelineSkillRecord? {
        guard skill.status == "practicing", skill.attempts == 0 else { return nil }
        var row = skill
        row.status = "assumed"
        row.updatedAt = now
        return row
    }

    /// 次に出す日(yyyy-MM-dd)。0回(定着したばかり)3日、1回7日、2回以上21日。
    static func nextReview(reviewCount: Int, from today: String) -> String {
        let interval = reviewIntervals[min(max(0, reviewCount), reviewIntervals.count - 1)]
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: today), let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: interval, to: date) else { return today }
        return formatter.string(from: next)
    }

    /// 復習の時期が来た前提。
    static func reviewDue(_ skills: [TimelineSkillRecord], today: String) -> [TimelineSkillRecord] {
        skills.filter { $0.isActive && $0.status == "mastered" && ($0.nextReviewAt.map { $0 <= today } ?? false) }
    }

    /// 同じ「できること」の中で、問題の形によって ○ と × が分かれる(片方で ○ が3回以上、もう片方で × が2回以上)。
    static func splitCandidate(results: [(typeName: String, correct: Bool)]) -> (good: String, bad: String)? {
        let byType = Dictionary(grouping: results, by: \.typeName)
        let good = byType.filter { !$0.key.isEmpty && $0.value.filter(\.correct).count >= 3 && $0.value.allSatisfy(\.correct) }.keys.sorted()
        let bad = byType.filter { !$0.key.isEmpty && $0.value.filter { !$0.correct }.count >= 2 && !$0.value.contains(where: \.correct) }.keys.sorted()
        guard let g = good.first, let b = bad.first, g != b else { return nil }
        return (g, b)
    }

    /// その日はもう出さない「できること」(同じ点で1日に3回 ×)。
    static func suppressedToday(results: [(skill: String, correct: Bool, day: String)], today: String) -> Set<String> {
        let wrongs = results.filter { $0.day == today && !$0.correct }
        return Set(Dictionary(grouping: wrongs, by: \.skill).filter { $0.value.count >= dailyWrongLimit }.keys)
    }

    /// 2日続けて同じ所で止まった(別々の2日に、その点で × が続いた)。質問(チューター)へ誘導する・見直しのきっかけ。
    static func stuckTwoDays(results: [(skill: String, correct: Bool, day: String)], today: String) -> Set<String> {
        var stuck: Set<String> = []
        for (skill, rows) in Dictionary(grouping: results, by: \.skill) {
            let days = Dictionary(grouping: rows, by: \.day)
            let failedDays = days.filter { $0.value.count >= 2 && !$0.value.contains(where: \.correct) }.keys.sorted()
            guard let last = failedDays.last, last == today || daysBetween(last, today) == 0 || daysBetween(last, today) == 1 else { continue }
            if failedDays.count >= 2, let previous = failedDays.dropLast().last, daysBetween(previous, last) == 1 { stuck.insert(skill) }
        }
        return stuck
    }

    // MARK: 単元ホームとの数え合い

    /// タイムラインの結果を単元ホームの合格に数えるか: 段3以上、その問題の初回、ヒントなし、小単元がある。
    static func countsForUnitHome(card: TimelineCardRecord, firstTry: Bool, assisted: Bool) -> Bool {
        card.kind == "solve" && card.level >= 3 && firstTry && !assisted && card.subunitId != nil && card.origin == "batch"
    }
}
