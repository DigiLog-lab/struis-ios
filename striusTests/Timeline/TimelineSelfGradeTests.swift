import XCTest
@testable import strius

/// iPhone の自分で丸付け: ○× の記録の形、見直し待ちの数え直し、5 問の区切り。
final class TimelineSelfGradeTests: XCTestCase {
    typealias F = TimelineFixture

    private func at(_ second: Int) -> String {
        String(format: "2026-10-23T06:00:%02d.000000Z", second)
    }

    /// 自分で付けた ○×(写真なし・印つき)。
    private func selfGraded(_ id: String, card: String, correct: Bool, second: Int) -> TimelineAttemptRecord {
        var attempt = F.attempt(id, card: card, verdict: correct ? "correct" : "wrong", createdAt: at(second))
        attempt.checkpointResults = .array([TimelineRules.selfGradeMarker])
        return attempt
    }

    /// 写真を撮って採点した記録。
    private func graded(_ id: String, card: String, verdict: String, second: Int) -> TimelineAttemptRecord {
        var attempt = F.attempt(id, card: card, verdict: verdict, createdAt: at(second))
        attempt.capturePath = "timeline-\(id).jpg"
        return attempt
    }

    // MARK: 記録の形

    func testSelfGradeIsWrittenInTheSameShapeAsDeviceGradedCards() {
        var machine = F.machine()
        machine.put("test", F.card("c1", status: "shown"))
        machine.put("test", F.card("c2", status: "shown"))
        let wrong = machine.recordSelfGrade(cardID: "c1", correct: false, seconds: 42, assisted: false)
        let correct = machine.recordSelfGrade(cardID: "c2", correct: true, seconds: 20, assisted: false)

        guard let w = machine.attempts[wrong] else { return XCTFail("記録が無い") }
        XCTAssertNil(w.capturePath)
        XCTAssertEqual(w.verdict, "wrong")
        XCTAssertEqual(w.seconds, 42)
        XCTAssertTrue(TimelineRules.isSelfGraded(w))
        XCTAssertEqual(machine.attempts[correct]?.verdict, "correct")
        // 解いた問題の結果なので、正答率に数える(タップで答えるカードとの違いはここだけ)。
        XCTAssertEqual(machine.attempts[correct]?.countsForAccuracy, true)
        XCTAssertEqual(machine.cards["c1"]?.status, "answered")
        // 同期で他の端末に届くのは、ふつうの記録の出来事。
        XCTAssertTrue(machine.events.contains { $0.kind == "timeline.attempt_recorded" && $0.entityID == wrong })
    }

    func testSelfGradeRoundTripsThroughJSONSoOtherDevicesReadTheMarker() throws {
        let original = selfGraded("a1", card: "c1", correct: false, second: 1)
        let decoded = try JSONDecoder().decode(TimelineAttemptRecord.self, from: JSONEncoder().encode(original))
        XCTAssertTrue(TimelineRules.isSelfGraded(decoded))
        XCTAssertEqual(TimelineRules.reviewPending([decoded]).map(\.cardId), ["c1"])
    }

    // MARK: 見直し待ち

    func testPendingIsTheCardsWhoseLatestRecordIsASelfGradedWrong() {
        let attempts = [
            selfGraded("a1", card: "c1", correct: false, second: 1),
            selfGraded("a2", card: "c2", correct: true, second: 2),
            selfGraded("a3", card: "c3", correct: false, second: 3),
            // タップで答えるカードの ×(印なし)は見直し待ちにしない。
            F.attempt("a4", card: "c4", verdict: "wrong", createdAt: at(4)),
            // 撮って採点した × も見直し待ちにしない(解説はもう出ている)。
            graded("a5", card: "c5", verdict: "wrong", second: 5),
        ]
        XCTAssertEqual(TimelineRules.reviewPending(attempts).map(\.cardId), ["c1", "c3"])
    }

    func testShootingTheReviewClearsThePendingCard() {
        let attempts = [
            selfGraded("a1", card: "c1", correct: false, second: 1),
            selfGraded("a2", card: "c2", correct: false, second: 2),
            graded("a3", card: "c1", verdict: "wrong", second: 3),
        ]
        XCTAssertEqual(TimelineRules.reviewPending(attempts).map(\.cardId), ["c2"])
        // 採点中(結果待ち)でも、写真が最後の記録なので外れる。
        let grading = [selfGraded("a1", card: "c1", correct: false, second: 1), graded("a2", card: "c1", verdict: "grading", second: 2)]
        XCTAssertTrue(TimelineRules.reviewPending(grading).isEmpty)
    }

    // MARK: 5 問の区切り

    func testReviewIsDueEveryFiveProblemsCountingFromTheOldestPendingWrong() {
        var attempts = [
            selfGraded("a0", card: "c0", correct: true, second: 0),
            selfGraded("a1", card: "c1", correct: false, second: 1),
        ]
        XCTAssertFalse(TimelineRules.reviewDue(attempts))
        for n in 2...4 { attempts.append(selfGraded("a\(n)", card: "c\(n)", correct: true, second: n)) }
        XCTAssertFalse(TimelineRules.reviewDue(attempts), "× から 4 問")
        attempts.append(F.attempt("a5", card: "c5", verdict: "skipped", createdAt: at(5)))
        XCTAssertTrue(TimelineRules.reviewDue(attempts), "× から 5 問(飛ばしたのも 1 問に数える)")
        // 「あとで」: 何も保存しないので、次は 10 問目。
        attempts.append(selfGraded("a6", card: "c6", correct: true, second: 6))
        XCTAssertFalse(TimelineRules.reviewDue(attempts))
        for n in 7...10 { attempts.append(selfGraded("a\(n)", card: "c\(n)", correct: true, second: n)) }
        XCTAssertTrue(TimelineRules.reviewDue(attempts))
    }

    func testNothingIsDueWithoutAPendingWrong() {
        let attempts = (0..<5).map { selfGraded("a\($0)", card: "c\($0)", correct: true, second: $0) }
        XCTAssertFalse(TimelineRules.reviewDue(attempts))
    }

    // MARK: 続けての ×

    func testSelfGradedWrongsDoNotCountTowardTwoWrongsInARow() {
        let attempts = [
            selfGraded("a1", card: "c1", correct: false, second: 1),
            selfGraded("a2", card: "c2", correct: false, second: 2),
        ]
        XCTAssertFalse(TimelineRules.twoWrongInARow(attempts.filter(TimelineRules.countsTowardWrongStreak)))
        let photographed = [graded("a1", card: "c1", verdict: "wrong", second: 1), graded("a2", card: "c2", verdict: "wrong", second: 2)]
        XCTAssertTrue(TimelineRules.twoWrongInARow(photographed.filter(TimelineRules.countsTowardWrongStreak)))
    }
}
