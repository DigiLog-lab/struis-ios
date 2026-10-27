import GRDB
import XCTest
@testable import strius

/// Issue #46「5枚をまとめて作る呼び出し」: 先頭を採点と揃える、渡すもの、モックでの往復。
final class TimelineTurnsTests: XCTestCase {
    typealias F = TimelineFixture

    func testBatchGradingAndReviewShareTheSamePrefix() async throws {
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
        let review = try await TimelineTurns.review(composer: composer, planID: "p3", attemptID: attemptID, workbook: workbook, timeline: timeline)
        XCTAssertEqual(batch.kind, .timelineBatch)
        // 基本指示と今日の記録が 3 つで同じ。今回の仕事は会話の最初の発話に置く。
        XCTAssertEqual(batch.thread.baseInstructions, grading.thread.baseInstructions)
        XCTAssertEqual(review.thread.baseInstructions, grading.thread.baseInstructions)
        XCTAssertNil(grading.thread.developerInstructions)
        XCTAssertEqual(batch.thread.developerText, grading.thread.developerText)
        XCTAssertEqual(review.thread.developerText, grading.thread.developerText)
        // 採点中の答案は一覧に載せず、今回の材料に入れる(結果が出ても一覧の前の部分が変わらない)。
        XCTAssertFalse(grading.thread.developerText?.contains(attemptID) == true)
        XCTAssertTrue(grading.turn?.text.contains(attemptID) == true)
        XCTAssertTrue(grading.turn?.text.hasPrefix("# 今回の仕事: 採点") == true)
        XCTAssertTrue(batch.turn?.text.hasPrefix("# 今回の仕事: 次の5枚") == true)
        // 考える深さは 3 つとも medium(深さが違うとキャッシュが分かれることがある)。
        for plan in [batch, grading, review] {
            XCTAssertEqual(plan.thread.effort, "medium")
            XCTAssertEqual(plan.thread.config["model_reasoning_effort"]?.stringValue, "medium")
        }
        // 道具の説明は基本指示の側(今日の記録の前)。今の単元とスキルの一覧は基本指示に入れない(今日の記録の最初の 1 件)。
        let base = try await composer.assets.text(grading.thread.baseInstructions)
        XCTAssertTrue(base.hasSuffix(NativeToolRouter.instructions))
        XCTAssertFalse(base.contains("## 今の単元"))
        func tools(_ kind: TurnPlan.Kind) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: NativeToolRouter.definitions(for: kind), options: [.sortedKeys]), as: UTF8.self)
        }
        XCTAssertEqual(try tools(batch.kind), try tools(grading.kind))
        XCTAssertEqual(try tools(review.kind), try tools(grading.kind))
        for name in ["timeline_query", "timeline_add_card", "timeline_ask", "timeline_revise", "timeline_descend", "timeline_notice"] {
            XCTAssertTrue(try tools(.timelineGrading).contains(name), name)
        }
        XCTAssertFalse(try tools(.chat).contains("timeline_query"))
        XCTAssertEqual(ClaudeTranslation.tailCacheTTL(kind: "timeline_grading"), "5m")
        XCTAssertEqual(ClaudeTranslation.version(kind: "timeline_grading"), 4)
        XCTAssertEqual(ClaudeTranslation.version(kind: "timeline_review"), 4)
        XCTAssertEqual(ClaudeTranslation.version(kind: "timeline_batch"), 4)
        XCTAssertEqual(ClaudeTranslation.version(kind: "timeline_graph"), ClaudeTranslation.current)
        XCTAssertEqual(ClaudeTranslation.version(kind: "chat"), ClaudeTranslation.current)
        let marker = try XCTUnwrap(batch.turn?.text.range(of: "# 今回の材料"))
        let request = try XCTUnwrap(LedgerJSON.parse(String(batch.turn!.text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(request["accuracy_last_10"]?.doubleValue, 0.9)
        // 判定の手順(段の上げ下げの向き・目標)や、直近10問の要約は渡さない。
        XCTAssertNil(request["direction"])
        XCTAssertNil(request["recent"])
        XCTAssertEqual(grading.turn?.images.count, 1)
        // 処理ごとの作業フォルダの場所が、Codex の Skill の一覧として先頭に入らない。
        XCTAssertTrue(batch.workspace.files.isEmpty)
        XCTAssertTrue(grading.workspace.files.isEmpty)
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
