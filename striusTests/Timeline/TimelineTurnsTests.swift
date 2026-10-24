import GRDB
import XCTest
@testable import strius

/// Issue #46「5枚をまとめて作る呼び出し」: 先頭を採点と揃える、渡すもの、モックでの往復。
final class TimelineTurnsTests: XCTestCase {
    typealias F = TimelineFixture

    func testBatchAndGradingShareTheSamePrefix() async throws {
        let ledger = try Ledger.inMemory()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            _ = timeline.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: 0.9, levelCap: nil)
            timeline.put("test", F.card("c1"))
            _ = timeline.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 3, assisted: false)
            return (timeline.events, ())
        }
        let (workbook, timeline) = try await ledger.read { db in (try WorkbookMachine(loading: db), try TimelineMachine(loading: db)) }
        let composer = TurnComposer(assets: AssetCache(lenient: true))
        let batchID = timeline.batches.keys.first!
        let attemptID = timeline.attempts.keys.first!
        let batch = try await TimelineTurns.batch(composer: composer, planID: "p1", batchID: batchID, workbook: workbook, timeline: timeline)
        let grading = try await TimelineTurns.grading(composer: composer, planID: "p2", attemptID: attemptID, workbook: workbook, timeline: timeline)
        XCTAssertEqual(batch.kind, .timelineBatch)
        XCTAssertEqual(batch.thread.baseInstructions, grading.thread.baseInstructions)
        XCTAssertNotEqual(batch.thread.developerInstructions?.asset, grading.thread.developerInstructions?.asset)
        func tools(_ kind: TurnPlan.Kind) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: NativeToolRouter.definitions(for: kind), options: [.sortedKeys]), as: UTF8.self)
        }
        XCTAssertEqual(try tools(batch.kind), try tools(grading.kind))
        XCTAssertTrue(try tools(.timelineBatch).contains("timeline_query"))
        XCTAssertFalse(try tools(.chat).contains("timeline_query"))
        XCTAssertEqual(ClaudeTranslation.tailCacheTTL(kind: "timeline_batch"), "1h")
        let request = try XCTUnwrap(LedgerJSON.parse(batch.turn!.text))
        XCTAssertEqual(request["target_accuracy"]?.doubleValue, 0.8)
        XCTAssertEqual(request["direction"]?.stringValue, "raise")
        XCTAssertEqual(grading.turn?.images.count, 1)
        XCTAssertTrue(batch.workspace.files.contains { $0.path == ".agents/skills/timeline-query/SKILL.md" })
    }

    func testMockBatchAndGraphPassTheirOwnChecks() throws {
        var machine = F.machine()
        let graph = MockTurnRunner.timelineGraph(["task": "build"])
        let output = try JSONDecoder().decode(TimelineGraph.Output.self, from: JSONSerialization.data(withJSONObject: graph))
        XCTAssertTrue(machine.applyGraph(output, source: "initial", unitID: nil).isEmpty)
        let id = machine.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: nil, levelCap: nil)
        let batch = MockTurnRunner.timelineBatch(["allowed_skill_ids": machine.activeSkills.map(\.id)], round: 1)
        let parsed = try TimelineCards.Batch.parse(String(decoding: try JSONSerialization.data(withJSONObject: batch), as: UTF8.self))
        XCTAssertEqual(machine.applyBatch(id: id, batch: parsed), .applied(cards: 5))
        XCTAssertEqual(machine.queue.map(\.kind), ["solve", "solve", "sort", "solve", "order"])
    }

    func testCoordinatorRunsTheBatchTurnWithTheMockRunner() async throws {
        let ledger = try Ledger.inMemory()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: MockTurnRunner())
        let batchID: String = try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            let id = timeline.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: nil, levelCap: nil)
            return (timeline.events, id)
        }
        await turns.startTimeline(kind: .timelineBatch, targetID: batchID)
        for _ in 0..<100 {
            let status = try await ledger.read { db in try TimelineBatchRecord.fetchOne(db, key: batchID)?.status }
            if status != "requested" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let machine = try await ledger.read { db in try TimelineMachine(loading: db) }
        XCTAssertEqual(machine.batches[batchID]?.status, "ready")
        XCTAssertEqual(machine.queue.count, 5)
        XCTAssertEqual(machine.batches[batchID]?.reason.isEmpty, false)
    }

    func testTimelineAnswersCountTowardTheUnitHomePass() async throws {
        let ledger = try Ledger.inMemory()
        let subunitID: String = try await ledger.commit { db in
            var workbook = try WorkbookMachine(loading: db)
            let unitID = workbook.createUnit(title: "二次関数", outcome: "", source: "consult", subunits: [.init(title: "最大と最小", n: 2)], firstStage: 4)
            let subunitID = workbook.orderedSubunits(unitID: unitID)[0].id
            var subunit = workbook.subunits[subunitID]!
            subunit.status = "active"
            workbook.put("test", subunit)
            return (workbook.events, subunitID)
        }
        for index in 0..<2 {
            let attemptID: String = try await ledger.commit { db in
                var timeline = try TimelineMachine(loading: db)
                timeline.put("test", F.card("card\(index)", level: 3, subunitID: subunitID))
                let attempt = timeline.recordCapture(cardID: "card\(index)", capturePath: "t.jpg", seconds: 20, assisted: false)
                return (timeline.events, attempt)
            }
            let turn = TurnOutcome(planID: "p", round: 1, status: .completed, codexThreadID: nil, codexTurnID: nil,
                                   finalText: String(decoding: try JSONSerialization.data(withJSONObject: ["readable": true, "verdict": "correct", "key_suspect": false]), as: UTF8.self),
                                   executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: 0)
            try await ledger.commit { db in
                let applied = try TimelineTurns.apply(kind: .timelineGrading, targetID: attemptID, outcome: turn, model: "m", db: db)
                return (applied.events, ())
            }
        }
        let status = try await ledger.read { db in try WorkbookMachine(loading: db).subunits[subunitID]?.status }
        XCTAssertEqual(status, "passed")
        let sources = try await ledger.read { db in try WorkbookMachine(loading: db).problemsOf(subunitID: subunitID).map(\.source) }
        XCTAssertEqual(sources, ["timeline", "timeline"])
    }
}
