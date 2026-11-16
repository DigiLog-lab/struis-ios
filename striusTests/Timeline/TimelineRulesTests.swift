import XCTest
@testable import strius

/// Issue #46「カードの切り替え」「正答率の測り方」「段の上げ下げ」「2択カード」「できること」の規則。
final class TimelineRulesTests: XCTestCase {
    typealias F = TimelineFixture

    // MARK: 正答率

    func testAccuracyCountsOnlyCountedAnswersInTheLastTen() {
        var attempts: [TimelineAttemptRecord] = []
        for i in 0..<12 { attempts.append(F.attempt("a\(i)", card: "c", verdict: i < 4 ? "wrong" : "correct")) }
        // 数えないもの(その日の最初の1問・やさしい版・速攻・飛ばした問題)は窓に入らない。
        attempts.append(F.attempt("skip", card: "c", verdict: "skipped", counts: false))
        attempts.append(F.attempt("easy", card: "c", verdict: "wrong", counts: false))
        XCTAssertEqual(TimelineRules.accuracy(attempts)!, 0.8, accuracy: 1e-9)
        XCTAssertNil(TimelineRules.accuracy([]))
    }

    func testWhatDoesNotCount() {
        let card = F.card("c")
        XCTAssertTrue(TimelineRules.countsForAccuracy(card: card, isFirstOfDay: false, verdict: "correct"))
        XCTAssertFalse(TimelineRules.countsForAccuracy(card: card, isFirstOfDay: true, verdict: "correct"))
        XCTAssertFalse(TimelineRules.countsForAccuracy(card: F.card("e", origin: "easier"), isFirstOfDay: false, verdict: "wrong"))
        XCTAssertFalse(TimelineRules.countsForAccuracy(card: F.card("r", origin: "rapid"), isFirstOfDay: false, verdict: "correct"))
        XCTAssertFalse(TimelineRules.countsForAccuracy(card: card, isFirstOfDay: false, verdict: "skipped"))
        XCTAssertFalse(TimelineRules.countsForAccuracy(card: F.card("o", kind: "order"), isFirstOfDay: false, verdict: "correct"))
    }

    func testLevelDirectionAndCap() {
        XCTAssertEqual(TimelineRules.levelDirection(accuracy: 0.9), "raise")
        XCTAssertEqual(TimelineRules.levelDirection(accuracy: 0.8), "same")
        XCTAssertEqual(TimelineRules.levelDirection(accuracy: 0.6), "lower")
        // 60% を切ったら、AI の判断に関係なく段を1つ下げさせる。
        XCTAssertEqual(TimelineRules.levelCap(accuracy: 0.5, currentLevel: 3), 2)
        XCTAssertEqual(TimelineRules.levelCap(accuracy: 0.5, currentLevel: 1), 1)
        XCTAssertNil(TimelineRules.levelCap(accuracy: 0.6, currentLevel: 3))
        XCTAssertTrue(TimelineRules.twoWrongInARow([F.attempt("1", card: "c", verdict: "correct"), F.attempt("2", card: "c", verdict: "wrong"), F.attempt("3", card: "c", verdict: "wrong")]))
        XCTAssertFalse(TimelineRules.twoWrongInARow([F.attempt("2", card: "c", verdict: "wrong"), F.attempt("3", card: "c", verdict: "correct")]))
    }

    // MARK: 次の 1 枚

    func testCorrectGoesToTheNextCardAndRevealsAtTheEndOfAChain() {
        let last = F.card("c3", chain: ("ch", 3, 3))
        let queue = [F.card("c4", position: 4), F.card("c5", position: 5)]
        let next = TimelineRules.next(after: last, outcome: .correct, queue: queue, rapid: [], wrongBefore: false)
        XCTAssertEqual(next.cardID, "c4")
        XCTAssertTrue(next.reveal)
        let middle = TimelineRules.next(after: F.card("c2", chain: ("ch", 2, 3)), outcome: .correct, queue: queue, rapid: [], wrongBefore: false)
        XCTAssertFalse(middle.reveal)
    }

    func testWrongMakesTheEasierVersionThenFallsBackToLevelOne() {
        let card = F.card("c1", chain: ("ch", 2, 3))
        let queue = [F.card("c2", position: 2, chain: ("ch", 3, 3)), F.card("c3", position: 3)]
        let rapid = [F.card("r1", level: 1, origin: "rapid")]
        let first = TimelineRules.next(after: card, outcome: .wrong, queue: queue, rapid: rapid, wrongBefore: false)
        XCTAssertEqual(first.makeEasierOf, "c1")
        XCTAssertNil(first.cardID)
        // やさしい版も ×: 手元の速攻用(段1)。続きは保留し、残りは捨てて頼み直す。
        var easier = F.card("e1", origin: "easier", chain: ("ch", 2, 3))
        easier.easierOf = "c1"
        let second = TimelineRules.next(after: easier, outcome: .wrong, queue: queue, rapid: rapid, wrongBefore: true)
        XCTAssertEqual(second.cardID, "r1")
        XCTAssertEqual(Set(second.discardIDs), ["c2", "c3"])
        XCTAssertTrue(second.requestBatch)
        XCTAssertEqual(second.pausedChain, "ch")
    }

    func testSkipAvoidsTheSameChain() {
        let card = F.card("c1", chain: ("ch", 1, 3))
        let queue = [F.card("c2", position: 2, chain: ("ch", 2, 3)), F.card("c3", position: 3)]
        XCTAssertEqual(TimelineRules.next(after: card, outcome: .skipped, queue: queue, rapid: [], wrongBefore: false).cardID, "c3")
        let onlyChain = TimelineRules.next(after: card, outcome: .skipped, queue: [queue[0]], rapid: [F.card("r", origin: "rapid")], wrongBefore: false)
        XCTAssertEqual(onlyChain.cardID, "r")
        XCTAssertEqual(onlyChain.discardIDs, ["c2"])
        XCTAssertTrue(onlyChain.requestBatch)
    }

    func testRequestsTheNextBatchAtTheFourthCard() {
        XCTAssertFalse(TimelineRules.shouldRequestBatch(unusedCount: 2, pending: false))
        XCTAssertTrue(TimelineRules.shouldRequestBatch(unusedCount: 1, pending: false))
        XCTAssertFalse(TimelineRules.shouldRequestBatch(unusedCount: 0, pending: true))
    }

    // MARK: その日の1枚目

    func testFirstCardPrefersYesterdaysChainThenRapidThenHistoryThenGuide() {
        let yesterday = "2026-10-22T06:00:00.000000Z"
        let cards = [F.card("c1", status: "answered", chain: ("ch", 1, 3), createdAt: yesterday), F.card("c2", status: "discarded", chain: ("ch", 2, 3), createdAt: yesterday),
                     F.card("r1", level: 1, origin: "rapid")]
        let attempts = [F.attempt("a1", card: "c1", verdict: "correct", createdAt: yesterday)]
        XCTAssertEqual(TimelineRules.firstCard(cards: cards, attempts: attempts, history: [], today: "2026-10-23"), .resume(cardID: "c2"))
        // 今日解いた続きは「昨日の続き」ではない。
        let today = [F.attempt("a1", card: "c1", verdict: "correct")]
        XCTAssertEqual(TimelineRules.firstCard(cards: cards, attempts: today, history: [], today: "2026-10-23"), .rapid(cardID: "r1"))
        XCTAssertEqual(TimelineRules.firstCard(cards: [], attempts: [], history: [F.card("h", origin: "history")], today: "2026-10-23"), .history(cardID: "h"))
        XCTAssertEqual(TimelineRules.firstCard(cards: [], attempts: [], history: [], today: "2026-10-23"), .guide)
    }

    // MARK: 2択カード

    func testUsualSecondsIsTheMedianOfTheSameLevel() {
        let history = (0..<12).map { (level: $0 % 2 == 0 ? 3 : 2, seconds: Double($0 * 10)) }
        // 段3: 0,20,40,60,80,100 → 真ん中は 50
        XCTAssertEqual(TimelineRules.usualSeconds(level: 3, history: history, estimatedSeconds: 30)!, 50, accuracy: 1e-9)
        // 使い始めの10問は、AI の目安の秒数を使う。
        XCTAssertEqual(TimelineRules.usualSeconds(level: 3, history: Array(history.prefix(5)), estimatedSeconds: 30), 30)
    }

    func testDipTriggersAndCooldown() {
        XCTAssertEqual(TimelineRules.dipAfterAnswer(seconds: 130, usual: 60, outcome: .correct, previousWasSkip: false, sinceLastDip: nil), .slow)
        XCTAssertNil(TimelineRules.dipAfterAnswer(seconds: 110, usual: 60, outcome: .correct, previousWasSkip: false, sinceLastDip: nil))
        XCTAssertEqual(TimelineRules.dipAfterAnswer(seconds: 5, usual: 60, outcome: .skipped, previousWasSkip: true, sinceLastDip: 9), .skips)
        // 一度出したら次の8枚は出さない。
        XCTAssertNil(TimelineRules.dipAfterAnswer(seconds: 500, usual: 60, outcome: .correct, previousWasSkip: false, sinceLastDip: 3))
        XCTAssertEqual(TimelineRules.dipOnReturn(awaySeconds: 31, isSolving: true, sinceLastDip: nil), .away)
        XCTAssertNil(TimelineRules.dipOnReturn(awaySeconds: 29, isSolving: true, sinceLastDip: nil))
        XCTAssertNil(TimelineRules.dipOnReturn(awaySeconds: 60, isSolving: false, sinceLastDip: nil))
    }

    // MARK: できること

    func testRecordKeepsDaysAsARecordButNeverMastersOrResets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var skill = F.skill("s")
        skill = TimelineRules.record(skill, correct: true, assisted: false, withinTime: true, at: "2026-10-20T01:00:00.000000Z", calendar: calendar)
        skill = TimelineRules.record(skill, correct: true, assisted: true, withinTime: true, at: "2026-10-21T01:00:00.000000Z", calendar: calendar)
        skill = TimelineRules.record(skill, correct: true, assisted: false, withinTime: false, at: "2026-10-22T01:00:00.000000Z", calendar: calendar)
        skill = TimelineRules.record(skill, correct: true, assisted: false, withinTime: true, at: "2026-10-23T02:00:00.000000Z", calendar: calendar)
        skill = TimelineRules.record(skill, correct: true, assisted: false, withinTime: true, at: "2026-10-24T02:00:00.000000Z", calendar: calendar)
        // ○ の日は記録として残すが、日数では定着にしない(Issue #154: 定着は不意打ちで決める)。
        XCTAssertEqual(skill.correctDays, 3)
        XCTAssertEqual(skill.status, "practicing")
        // 前の版で定着した点も、普通の答案の × では日数を消さず、基準も上げず、定着のまま。
        var mastered = F.skill("m", status: "mastered", dates: ["2026-10-20", "2026-10-21", "2026-10-22"])
        mastered = TimelineRules.record(mastered, correct: false, assisted: false, withinTime: true, at: "2026-11-05T02:00:00.000000Z", calendar: calendar)
        XCTAssertEqual(mastered.status, "mastered")
        XCTAssertEqual(mastered.correctDays, 3)
        XCTAssertEqual(mastered.masteryThreshold, 3)
        // できると推定の点は、答えると練習中になる。
        let assumed = TimelineRules.record(F.skill("a", status: "assumed"), correct: false, assisted: false, withinTime: true, at: "2026-11-05T02:00:00.000000Z", calendar: calendar)
        XCTAssertEqual(assumed.status, "practicing")
    }

    func testSurpriseMastersOnlyOnALaterDayAndBacksOffOnMiss() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var skill = F.skill("s")
        // 先へ進んでよいになった日と同じ日の不意打ちは、○ でも定着にしない。
        skill = TimelineRules.recordSurprise(skill, correct: true, at: "2026-11-15T12:30:00.000000Z", clearedDay: "2026-11-15", calendar: calendar)
        XCTAssertEqual(skill.status, "practicing")
        // 翌日以降の ○ で定着。次は 3 日後。
        skill = TimelineRules.recordSurprise(skill, correct: true, at: "2026-11-16T05:00:00.000000Z", clearedDay: "2026-11-15", calendar: calendar)
        XCTAssertEqual(skill.status, "mastered")
        XCTAssertEqual(skill.nextReviewAt, "2026-11-19")
        skill = TimelineRules.recordSurprise(skill, correct: true, at: "2026-11-19T05:00:00.000000Z", clearedDay: "2026-11-15", calendar: calendar)
        XCTAssertEqual(skill.nextReviewAt, "2026-11-26")
        skill = TimelineRules.recordSurprise(skill, correct: true, at: "2026-11-26T05:00:00.000000Z", clearedDay: "2026-11-15", calendar: calendar)
        XCTAssertEqual(skill.nextReviewAt, "2026-12-17")
        // × なら間隔を 3 日に戻す。定着は外さない。
        skill = TimelineRules.recordSurprise(skill, correct: false, at: "2026-12-17T05:00:00.000000Z", clearedDay: "2026-11-15", calendar: calendar)
        XCTAssertEqual(skill.status, "mastered")
        XCTAssertEqual(skill.nextReviewAt, "2026-12-20")
    }

    func testSurpriseTiming() {
        func due(status: String = "practicing", next: String? = nil, cleared: String? = "2026-11-15", isCleared: Bool = true, others: Int = 0,
                 had: Bool = false, answered: Int = 0, shown: Bool = false, today: String) -> Bool {
            TimelineRules.surpriseDue(status: status, nextReviewAt: next, clearedDay: cleared, cleared: isCleared, othersSinceCleared: others,
                                      hadSurprise: had, answeredToday: answered, shownToday: shown, today: today)
        }
        // 1回目: 同じ日、ほかのスキルを 10 枚解いた後。
        XCTAssertFalse(due(others: 9, today: "2026-11-15"))
        XCTAssertTrue(due(others: 10, today: "2026-11-15"))
        XCTAssertFalse(due(others: 20, had: true, today: "2026-11-15"))
        // 2回目: 翌日以降、その日の 3 枚目から。
        XCTAssertFalse(due(answered: 1, today: "2026-11-17"))
        XCTAssertTrue(due(answered: 2, today: "2026-11-17"))
        XCTAssertFalse(due(answered: 2, shown: true, today: "2026-11-17"))
        // 今は先へ進んでよくない点には出さない。
        XCTAssertFalse(due(isCleared: false, answered: 5, today: "2026-11-17"))
        // 定着後: 予定の日を過ぎた勉強日に。
        XCTAssertFalse(due(status: "mastered", next: "2026-11-20", answered: 5, today: "2026-11-19"))
        XCTAssertTrue(due(status: "mastered", next: "2026-11-19", isCleared: false, answered: 2, today: "2026-11-25"))
    }

    func testReviewIntervals() {
        XCTAssertEqual(TimelineRules.nextReview(reviewCount: 0, from: "2026-10-23"), "2026-10-26")
        XCTAssertEqual(TimelineRules.nextReview(reviewCount: 1, from: "2026-10-23"), "2026-10-30")
        XCTAssertEqual(TimelineRules.nextReview(reviewCount: 5, from: "2026-10-23"), "2026-11-13")
        var due = F.skill("d", status: "mastered")
        due.nextReviewAt = "2026-10-23"
        var later = F.skill("l", status: "mastered")
        later.nextReviewAt = "2026-10-24"
        XCTAssertEqual(TimelineRules.reviewDue([due, later], today: "2026-10-23").map(\.id), ["d"])
    }

    func testSplitAndStuck() {
        let results = Array(repeating: (typeName: "x e^x", correct: true), count: 3) + Array(repeating: (typeName: "x sin x", correct: false), count: 2)
        XCTAssertEqual(TimelineRules.splitCandidate(results: results)?.bad, "x sin x")
        XCTAssertNil(TimelineRules.splitCandidate(results: Array(results.prefix(4))))
        let wrongs = Array(repeating: (skill: "s", correct: false, day: "2026-10-23", partial: false), count: 3)
        XCTAssertEqual(TimelineRules.stuckToday(results: wrongs, today: "2026-10-23"), ["s"])
        // 途中に誤り(書き直しを省いただけなど)は数えない。
        let withPartial = Array(wrongs.prefix(2)) + [(skill: "s", correct: false, day: "2026-10-23", partial: true)]
        XCTAssertEqual(TimelineRules.stuckToday(results: withPartial, today: "2026-10-23"), [])
        let twoDays = [(skill: "s", correct: false, day: "2026-10-22"), (skill: "s", correct: false, day: "2026-10-22"),
                       (skill: "s", correct: false, day: "2026-10-23"), (skill: "s", correct: false, day: "2026-10-23")]
        XCTAssertEqual(TimelineRules.stuckTwoDays(results: twoDays, today: "2026-10-23"), ["s"])
    }

    func testUnitHomeCountsOnlyLevelThreeFirstTryWithoutHints() {
        let card = F.card("c", level: 3, subunitID: "sub")
        XCTAssertTrue(TimelineRules.countsForUnitHome(card: card, firstTry: true, assisted: false))
        XCTAssertFalse(TimelineRules.countsForUnitHome(card: card, firstTry: false, assisted: false))
        XCTAssertFalse(TimelineRules.countsForUnitHome(card: card, firstTry: true, assisted: true))
        XCTAssertFalse(TimelineRules.countsForUnitHome(card: F.card("c2", level: 2, subunitID: "sub"), firstTry: true, assisted: false))
        XCTAssertFalse(TimelineRules.countsForUnitHome(card: F.card("e", level: 3, origin: "easier", subunitID: "sub"), firstTry: true, assisted: false))
    }

    // MARK: 先へ進む判定(Issue #154)

    func testClearedNeedsFourOfTheLastFive() {
        XCTAssertFalse(TimelineRules.isCleared([true, true, true, true]))
        XCTAssertTrue(TimelineRules.isCleared([false, true, true, true, true]))
        XCTAssertTrue(TimelineRules.isCleared([true, false, true, true, true]))
        XCTAssertFalse(TimelineRules.isCleared([true, true, true, true, true, false, false]))
        XCTAssertEqual(TimelineRules.firstClearedIndex([false, false, true, true, true, true, false, true]), 5)
        XCTAssertNil(TimelineRules.firstClearedIndex([false, true, false, true, true]))
    }

    func testGoalReadiness() {
        // ○× の無い前提はゴールの問題の中で確かめる。答案が 5 問に足りない前提は判定できないので先に出させる。
        let ready = TimelineRules.goalReadiness(prerequisites: ["law", "vector"], marks: ["law": [false, true, true, true, true]])
        XCTAssertTrue(ready.ready)
        XCTAssertEqual(ready.needsEvidence, [])
        let short = TimelineRules.goalReadiness(prerequisites: ["law", "constant"], marks: ["law": [true, true, true, true, true], "constant": [true, true]])
        XCTAssertFalse(short.ready)
        XCTAssertEqual(short.needsEvidence, ["constant"])
        let failing = TimelineRules.goalReadiness(prerequisites: ["law"], marks: ["law": [true, false, true, false, true]])
        XCTAssertFalse(failing.ready)
    }

    func testLevelCapIsPerSkill() {
        XCTAssertNil(TimelineRules.skillLevelCap([(true, 2), (false, 2)]))
        XCTAssertEqual(TimelineRules.skillLevelCap([(false, 2), (false, 2), (true, 2)]), 1)
        XCTAssertNil(TimelineRules.skillLevelCap([(false, 1), (true, 2), (true, 2), (true, 3), (false, 3)]))
    }

    func testGoalAndSurpriseCardsAreNotDiscarded() {
        let wrong = F.card("w", origin: "easier")
        let goal = F.card("g", position: 2, skills: ["goal.sub"])
        let surprise = F.card("s", position: 3, payload: ["surprise": .string("law")])
        let plain = F.card("p", position: 4)
        let next = TimelineRules.next(after: wrong, outcome: .wrong, queue: [goal, surprise, plain], rapid: [F.card("r", origin: "rapid")], wrongBefore: true)
        XCTAssertEqual(next.discardIDs, ["p"])
        let skipped = TimelineRules.next(after: F.card("x", chain: ("c", 1, 2)), outcome: .skipped, queue: [F.card("y", chain: ("c", 2, 2)), F.card("z", chain: ("c", 2, 2), skills: ["goal.sub"])],
                                         rapid: [], wrongBefore: false)
        XCTAssertEqual(skipped.discardIDs, ["y"])
    }

    func testGoalCardsCountForUnitHomeAtAnyLevel() {
        XCTAssertTrue(TimelineRules.countsForUnitHome(card: F.card("g", level: 1, skills: ["goal.sub"], subunitID: "sub"), firstTry: true, assisted: false))
        XCTAssertFalse(TimelineRules.countsForUnitHome(card: F.card("c", level: 1, skills: ["law"], subunitID: "sub"), firstTry: true, assisted: false))
    }
}
