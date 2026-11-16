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
    /// 前の版の定着の基準(別々の日に3回)。今の定着は不意打ちで決める(Issue #154)。新しい点の行に入れる値としてだけ残す。
    static let masteryThreshold = 3
    /// 先へ進んでよい: そのスキルの数える答案の直近5問で ○ が4問以上(Issue #154、2026-11-16 に持ち主が決めた)。
    static let clearWindow = 5
    static let clearNeeded = 4
    /// 不意打ちの1回目: 先へ進んでよいになってから、ほかのスキルの数える答案がこの数たまった後(同じ日のうち)。
    static let surpriseFirstGap = 10
    /// 2回目以降の不意打ち: その日の数える答案がこの数たまってから(3枚目以降)。
    static let surpriseAfterAnswersToday = 2
    /// 定着後に不意打ちで ○ だった回数ごとの、次に出すまでの日数(Cepeda et al. 2008 の最適な間隔の範囲)。
    /// 5枚に必ず入れさせる「答案の足りない前提」の数(多すぎると5枚に収まらない)。
    static let requiredEvidenceCards = 2
    /// 1 回の5枚に入れさせる不意打ちの数(残りは次の5枚へ。依頼のたびに計算し直すので持ち越される)。
    static let requiredSurpriseCards = 2
    static let reviewIntervals = [3, 7, 21]
    /// 段の上限を決めるスキルごとの窓と、上限を掛け始める答案の数。
    static let skillLevelWindow = 5
    static let skillLevelMinimum = 3
    /// 2択カード: いつもの2倍、次の8枚は出さない、最初の10問は判定しない、「いつも」は同じ段の直近20問。
    /// 他のアプリから戻った時は、2択カードではなく戻った時の計算練習(`TimelineWarmup`、#155)。
    static let slowFactor = 2.0
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
        if isFirstOfDay || card.origin == "easier" || card.origin == "rapid" || card.origin == "review" || card.origin == TimelineWarmup.origin || card.status == "broken" { return false }
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
    /// 全スキルをまとめた正答率なので、5枚の依頼には使わない(`skillLevelCap` を使う。Issue #154)。
    static func levelCap(accuracy: Double?, currentLevel: Int) -> Int? {
        guard let accuracy, accuracy < forceLowerBelow else { return nil }
        return max(1, currentLevel - 1)
    }

    /// スキルごとの段の上限: そのスキルの数える答案の直近5問(3問以上ある時)の正答率が60%を切ったら、最後に解いた段より1つ下。
    /// 他のスキルの × では下げない(全体の正答率で下げると、指数の × のせいで別のスキルも段1から出られなくなった)。
    static func skillLevelCap(_ marks: [(correct: Bool, level: Int)]) -> Int? {
        let window = marks.suffix(skillLevelWindow)
        guard window.count >= skillLevelMinimum, let last = window.last else { return nil }
        let accuracy = Double(window.filter(\.correct).count) / Double(window.count)
        guard accuracy < forceLowerBelow else { return nil }
        return max(1, last.level - 1)
    }

    // MARK: 先へ進む判定(Issue #154)

    /// 直近5問で ○ が4問以上(5問に足りなければ、まだ判定しない)。
    static func isCleared(_ marks: [Bool]) -> Bool {
        let window = marks.suffix(clearWindow)
        return window.count == clearWindow && window.filter { $0 }.count >= clearNeeded
    }

    /// 初めて先へ進んでよいになった答案の位置(無ければ nil)。
    static func firstClearedIndex(_ marks: [Bool]) -> Int? {
        guard marks.count >= clearWindow else { return nil }
        for end in (clearWindow - 1)..<marks.count where isCleared(Array(marks[...end])) { return end }
        return nil
    }

    /// 小単元のゴールを出せるか。直接の前提のうち ○× が1つ以上あるものが全部「先へ進んでよい」なら出せる。
    /// 答案が1〜4問の前提は判定できないので、`needsEvidence` に返す(依頼で優先して出させる)。○× が無い前提は、ゴールの問題の中で確かめる。
    static func goalReadiness(prerequisites: [String], marks: [String: [Bool]]) -> (ready: Bool, needsEvidence: [String]) {
        var ready = true
        var needs: [String] = []
        for id in prerequisites {
            let list = marks[id] ?? []
            if list.isEmpty { continue }
            if list.count < clearWindow { needs.append(id); ready = false; continue }
            if !isCleared(list) { ready = false }
        }
        return (ready, needs)
    }

    /// 手元のカードを捨てる時にも残すカード: 小単元のゴールと不意打ち。
    static func isProtected(_ card: TimelineCardRecord) -> Bool {
        card.payload["surprise"]?.stringValue != nil || card.skills.contains { $0.hasPrefix("goal.") }
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
        wrongBefore: Bool, base: TimelineCardRecord? = nil
    ) -> Next {
        let rest = queue.filter { $0.id != card.id }
        switch outcome {
        case .correct:
            var next = Next(cardID: rest.first?.id)
            next.reveal = isLastOfChain(card)
            if rest.isEmpty { next.cardID = rapid.first?.id; next.requestBatch = true }
            return next
        case .wrong:
            // 数値だけ変えた問題も ×: 元のカードのやさしくした問題へ(無ければ、やさしい版も × と同じ扱い)。
            if card.origin == "variant", let base, base.id == card.easierOf, base.payload["easier"]?.objectValue != nil {
                return Next(cardID: nil, makeEasierOf: base.id)
            }
            if card.origin == "easier" || card.origin == "variant" || wrongBefore {
                // やさしい版も ×: その前提の段1(手元の速攻用)。続きは保留、残りは捨てて頼み直す。
                var next = Next(cardID: rapid.first?.id ?? rest.first?.id)
                // ゴールと不意打ちのカードは捨てない(やさしい版の後に、そのまま並んで残る。Issue #154)。
                next.discardIDs = rest.filter { $0.id != next.cardID && !isProtected($0) }.map(\.id)
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
            next.discardIDs = rest.filter { !isProtected($0) }.map(\.id)
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
        /// 他のアプリから戻った(#155 より前の記録だけ。今は戻った時の計算練習を出す)。
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

    // MARK: 「できること」の状態

    /// 1 回の結果を「できること」に反映する。回数・最後の ○・○ の日(ヒントなし・目安時間内。記録として残す)だけを付ける。
    /// 定着は普通の答案では動かさない。定着は不意打ちの答案(`recordSurprise`)だけで決める(Issue #154。前の版は別々の日の
    /// ○ の数で定着にし、定着後の 1 回の × で日数を消して基準を 4 回に上げていたので、同じ所を回り続けた)。
    static func record(_ skill: TimelineSkillRecord, correct: Bool, assisted: Bool, withinTime: Bool, at now: String, calendar: Calendar = .current) -> TimelineSkillRecord {
        var row = skill
        row.attempts += 1
        row.updatedAt = now
        if row.status == "assumed" { row.status = "practicing" }
        guard let today = day(now, calendar: calendar) else { return row }
        if correct {
            row.lastCorrectAt = now
            if !assisted, withinTime, !row.correctDates.contains(today) { row.correctDates.append(today) }
        }
        return row
    }

    /// 不意打ちの答案を反映する。`clearedDay` はそのスキルが初めて先へ進んでよいになった日。
    /// - まだ定着していない: 先へ進んでよいになった日より後の日の ○ で定着(1 日以上空けた不意打ち。Pyc et al. 2014)。
    /// - 定着済み: ○ なら次の間隔(3・7・21日、以降 21 日ごと)へ、× なら間隔を 3 日に戻す。定着は外さない。
    static func recordSurprise(_ skill: TimelineSkillRecord, correct: Bool, at now: String, clearedDay: String?, calendar: Calendar = .current) -> TimelineSkillRecord {
        var row = skill
        guard let today = day(now, calendar: calendar) else { return row }
        row.updatedAt = now
        if row.status == "mastered" {
            row.reviewCount = correct ? row.reviewCount + 1 : 0
            row.nextReviewAt = nextReview(reviewCount: row.reviewCount, from: today)
        } else if correct, let clearedDay, today > clearedDay {
            row.status = "mastered"
            row.reviewCount = 0
            row.nextReviewAt = nextReview(reviewCount: 0, from: today)
        }
        return row
    }

    /// 不意打ちを今出すか。
    /// - `clearedAt`: 初めて先へ進んでよいになった答案の日(定着していない時に要る)。`othersSinceCleared` はその後のほかのスキルの数える答案の数。
    /// - `cleared`: 今も先へ進んでよいか。`hadSurprise`: このスキルの不意打ちの答案が前にあるか。
    /// - `answeredToday`: 今日の数える答案の数。`shownToday`: 今日すでにこのスキルの不意打ちを出したか。
    static func surpriseDue(status: String, nextReviewAt: String?, clearedDay: String?, cleared: Bool, othersSinceCleared: Int, hadSurprise: Bool,
                            answeredToday: Int, shownToday: Bool, today: String) -> Bool {
        guard !shownToday else { return false }
        if status == "mastered" {
            guard let next = nextReviewAt, next <= today else { return false }
            return answeredToday >= surpriseAfterAnswersToday
        }
        guard cleared, let clearedDay else { return false }
        if clearedDay == today { return !hadSurprise && othersSinceCleared >= surpriseFirstGap }
        return today > clearedDay && answeredToday >= surpriseAfterAnswersToday
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

    /// 詰まっている「できること」(同じ点で1日に3回 ×。途中に誤りは数えない)。前の版はその日は出さない決まりだったが、
    /// いちばん練習の要る点の練習が止まり、部品として使う大きな問題で × が続いて翌日も止まるので、止めずに細かく分けさせる(Issue #154)。
    static func stuckToday(results: [(skill: String, correct: Bool, day: String, partial: Bool)], today: String) -> Set<String> {
        let wrongs = results.filter { $0.day == today && !$0.correct && !$0.partial }
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

    /// タイムラインの結果を単元ホームの合格に数えるか: 段3以上(小単元のゴールのカードは段を問わない。Issue #154)、その問題の初回、
    /// ヒントなし、小単元がある。
    static func countsForUnitHome(card: TimelineCardRecord, firstTry: Bool, assisted: Bool) -> Bool {
        let isGoal = card.skills.contains { $0.hasPrefix("goal.") }
        return card.kind == "solve" && (card.level >= 3 || isGoal) && firstTry && !assisted && card.subunitId != nil && card.origin == "batch"
    }
}
