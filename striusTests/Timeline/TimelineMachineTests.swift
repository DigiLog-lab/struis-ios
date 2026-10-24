import GRDB
import XCTest
@testable import strius

/// Issue #46: 5枚の受け取り(作り直しは 1 回)、採点(答えが間違っていた問題)、やさしい版、組み合わせのミス、単元ホームとの数え合い。
final class TimelineMachineTests: XCTestCase {
    typealias F = TimelineFixture

    func testBatchRetriesOnceThenKeepsOnlyAcceptableCards() throws {
        var machine = F.machine()
        machine.put("test", F.skill("a"))
        let id = machine.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: 0.5, levelCap: 2)
        let good = F.draftJSON(level: 2, skills: ["a"])
        let unknownSkill = F.draftJSON(level: 2, skills: ["zzz"])
        let tooHard = F.draftJSON(level: 4, skills: ["a"])
        XCTAssertEqual(machine.applyBatch(id: id, batch: try F.batch(cards: [good, unknownSkill, tooHard])), .retry)
        XCTAssertEqual(machine.batches[id]?.retries, 1)
        XCTAssertEqual(machine.batches[id]?.rejected.count, 2)
        XCTAssertEqual(machine.applyBatch(id: id, batch: try F.batch(cards: [good, unknownSkill])), .applied(cards: 1))
        XCTAssertEqual(machine.batches[id]?.status, "ready")
        XCTAssertEqual(machine.queue.count, 1)
        XCTAssertEqual(machine.rapidCards.count, 3)
    }

    func testChainsAreLinkedAcrossTheBatch() throws {
        var machine = F.machine()
        let id = machine.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: nil, levelCap: nil)
        let cards = (1...3).map { F.draftJSON(level: $0 + 1, chain: ["position": $0, "total": 3, "changed": $0 == 1 ? NSNull() : "a", "previous": NSNull()]) }
        _ = machine.applyBatch(id: id, batch: try F.batch(cards: cards))
        let chains = Set(machine.queue.compactMap(TimelineRules.chainID))
        XCTAssertEqual(chains.count, 1)
        XCTAssertEqual(machine.queue.compactMap { TimelineRules.chainPosition($0)?.position }, [1, 2, 3])
        XCTAssertEqual(machine.queue[1].chain?["changed"]?.stringValue, "a")
    }

    func testDerivedKindsAreBuiltWhenTheBatchAsksForThem() throws {
        var machine = F.machine()
        let id = machine.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: nil, levelCap: nil)
        _ = machine.applyBatch(id: id, batch: try F.batch(cards: [F.draftJSON(kind: "order"), F.draftJSON(kind: "sort")]))
        XCTAssertEqual(machine.queue.map(\.kind), ["order", "sort"])
        XCTAssertNotNil(machine.queue[0].payload["shuffled"])
        XCTAssertEqual(machine.queue[1].prompt, "軸 x = 2 を含む？")
    }

    private func gradingJSON(verdict: String, keySuspect: Bool = false, errors: [[String: String]] = []) throws -> TimelineMachine.Grading {
        let object: [String: Any] = ["readable": true, "solved_answer": "-4", "learner_answer": "-4", "learner_expr": "-4", "verdict": verdict,
                                     "key_suspect": keySuspect, "checkpoints": [["text": "a < 2", "result": "correct"], ["text": "a ≥ 2", "result": "missing"]],
                                     "errors": errors, "cause": "connection", "feedback": ""]
        return try TimelineMachine.Grading.parse(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    func testBrokenAnswerKeyGivesTheLearnerACorrectAndDropsTheProblem() throws {
        var machine = F.machine()
        machine.put("test", F.card("c1", level: 3, skills: ["a"], subunitID: "sub"))
        let attempt = machine.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 40, assisted: false)
        let outcome = machine.applyGrading(attemptID: attempt, grading: try gradingJSON(verdict: "correct", keySuspect: true))
        XCTAssertEqual(outcome.verdict, "correct")
        XCTAssertTrue(outcome.broken)
        XCTAssertFalse(outcome.countsForUnitHome)
        XCTAssertEqual(machine.cards["c1"]?.status, "broken")
        XCTAssertFalse(machine.attempts[attempt]!.countsForAccuracy)
        XCTAssertTrue(machine.changes.values.contains { $0.kind == "broken_problem" && $0.detail["type_name"]?.stringValue == "型" })
    }

    func testWrongAnswerRecordsCheckpointsAndCombinationNode() throws {
        var machine = F.machine()
        machine.put("test", F.skill("neg_square"))
        machine.put("test", F.skill("coords"))
        machine.put("test", F.card("c1", level: 3, skills: ["neg_square", "coords"]))
        let attempt = machine.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 40, assisted: false)
        let outcome = machine.applyGrading(attemptID: attempt, grading: try gradingJSON(verdict: "wrong", errors: [
            ["kind": "combination", "where": "x = -3", "wrote": "y = -9", "correct": "y = 9", "detail": "x = -3 の時の y を求めていない"],
        ]))
        XCTAssertEqual(outcome.verdict, "wrong")
        XCTAssertEqual(machine.attempts[attempt]?.checkpointResults.arrayValue?.count, 2)
        XCTAssertEqual(machine.attempts[attempt]?.errors[0]?["wrote"]?.stringValue, "y = -9")
        let combo = machine.skills.values.first { $0.kind == "combination" }
        XCTAssertNotNil(combo)
        XCTAssertEqual(Set(machine.directPrerequisites(of: combo!.id)), ["neg_square", "coords"])
        // やさしい版は AI を待たずに作れる。
        let easier = try XCTUnwrap(machine.makeEasier(of: "c1"))
        XCTAssertEqual(machine.cards[easier]?.origin, "easier")
        XCTAssertEqual(machine.queue.first?.id, nil)  // やさしい版は 5 枚の並びとは別
    }

    func testUpperProblemFirstTryAssumesPrerequisites() throws {
        var machine = F.machine()
        machine.put("test", F.skill("upper"))
        machine.put("test", F.skill("lower"))
        machine.addEdge(skillID: "upper", requires: "lower", relation: "prerequisite", source: "initial", note: "")
        machine.put("test", F.card("c1", level: 3, skills: ["upper"]))
        let attempt = machine.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 20, assisted: false)
        _ = machine.applyGrading(attemptID: attempt, grading: try gradingJSON(verdict: "correct"))
        XCTAssertEqual(machine.skills["lower"]?.status, "assumed")
    }

    func testStaleCardsAreDiscardedButTheResumeCardIsKept() {
        var machine = F.machine()
        let yesterday = "2026-10-22T06:00:00.000000Z"
        machine.put("test", F.card("old", createdAt: yesterday))
        machine.put("test", F.card("keep", createdAt: yesterday))
        machine.put("test", F.card("r", origin: "rapid", createdAt: yesterday))
        machine.discardStale(keep: ["keep"])
        XCTAssertEqual(machine.cards["old"]?.status, "discarded")
        XCTAssertEqual(machine.cards["keep"]?.status, "unused")
        XCTAssertEqual(machine.cards["r"]?.status, "unused")
    }
}
