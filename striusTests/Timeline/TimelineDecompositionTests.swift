import GRDB
import XCTest
@testable import strius

/// 2026-10-24 の見直し「グラフの作り方と1段下りる仕組み」: 1段ごとの点検(循環の線だけを捨てる・経由で届く直接の線を
/// 消す)、1段下りる条件、小単元の到達目標から1段ずつ分解してよくある勘違いまで続くこと。
final class TimelineDecompositionTests: XCTestCase {
    typealias F = TimelineFixture
    typealias D = TimelineGraph.Decomposition

    private func skill(_ id: String, expansion: String? = "pending", unitID: String? = "unit") -> TimelineSkillRecord {
        var row = F.skill(id)
        row.expansion = expansion
        row.unitId = unitID
        return row
    }

    private func use(_ id: String, inUnit: Bool = true) -> D.Use {
        D.Use(id: id, name: id, kind: "procedure", inUnit: inUnit)
    }

    private func decomposition(_ node: String, _ uses: [D.Use]) -> D {
        D(items: [D.Item(nodeId: node, problem: "典型的な問題", steps: [D.Step(text: "手順", uses: uses)])], notes: "")
    }

    func testCycleEdgesAreDroppedAndTheRestIsAccepted() {
        var machine = F.machine()
        machine.put("test", skill("fourier.poly_series"))
        machine.put("test", skill("fourier.write_series"))
        // 級数で書く には 多項式の級数 が要る(既にある線)。
        machine.addEdge(skillID: "fourier.write_series", requires: "fourier.poly_series", relation: "prerequisite", source: "build", note: "")
        let output = decomposition("fourier.poly_series", [use("fourier.write_series"), use("Calc.Product Rule", inUnit: false), use("fourier.coefficients")])
        let result = machine.applyDecomposition(output, requested: ["fourier.poly_series": "unit"], descend: false)
        // 循環を作る線だけを捨てて記録する。
        XCTAssertEqual(result.droppedCycles, ["fourier.write_series -> fourier.poly_series"])
        XCTAssertEqual(Set(result.added), ["calc.product_rule", "fourier.coefficients"], "ID は正規化してから置く")
        XCTAssertEqual(machine.directPrerequisites(of: "fourier.poly_series"), ["calc.product_rule", "fourier.coefficients"])
        XCTAssertEqual(machine.skills["fourier.poly_series"]?.expansion, "done")
        // 今の単元の中身は次の段で分解、前に習う内容は置くだけ(まだ掘っていない)。
        XCTAssertEqual(machine.skills["fourier.coefficients"]?.expansion, "pending")
        XCTAssertEqual(machine.skills["calc.product_rule"]?.expansion, "unexplored")
        XCTAssertEqual(machine.skills["fourier.coefficients"]?.unitId, "unit")
        let change = machine.changes.values.first { $0.kind == "decompose" }
        XCTAssertEqual(change?.detail["dropped_cycle_edges"]?.arrayValue?.compactMap(\.stringValue), ["fourier.write_series -> fourier.poly_series"])
        XCTAssertNil(TimelineGraph.cycle(in: machine.edges.values.filter { $0.relation == "prerequisite" }.map { (from: $0.requiresSkillId, to: $0.skillId) }))
    }

    func testDirectEdgeReachableThroughAnotherNodeIsRemoved() {
        var machine = F.machine()
        machine.put("test", skill("quad.min_value"))
        machine.put("test", skill("quad.vertex_form", expansion: "done"))
        machine.put("test", skill("quad.expand", expansion: "unexplored"))
        // 最小値 ← 展開(直接)、平方完成 ← 展開。
        machine.addEdge(skillID: "quad.min_value", requires: "quad.expand", relation: "prerequisite", source: "initial", note: "")
        machine.addEdge(skillID: "quad.vertex_form", requires: "quad.expand", relation: "prerequisite", source: "initial", note: "")
        // 最小値 を分解すると 平方完成 を使う: 展開 は 平方完成 を経由して届くので、直接の線は消す。
        let result = machine.applyDecomposition(decomposition("quad.min_value", [use("quad.vertex_form"), use("quad.expand")]), requested: ["quad.min_value": "unit"], descend: false)
        XCTAssertEqual(result.removedRedundant, ["quad.expand -> quad.min_value"])
        XCTAssertEqual(machine.directPrerequisites(of: "quad.min_value"), ["quad.vertex_form"])
        XCTAssertEqual(machine.directPrerequisites(of: "quad.vertex_form"), ["quad.expand"])
        XCTAssertEqual(TimelineGraph.redundantEdges([(from: "a", to: "b"), (from: "b", to: "c"), (from: "a", to: "c")]).map { "\($0.from)\($0.to)" }, ["ac"])
    }

    /// 同じ点で 2 回 × を採点した後の、1段下りる依頼の行。
    private func gradeTwice(kinds: [String]) async throws -> [TimelineBatchRecord] {
        let ledger = try Ledger.inMemory()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", self.skill("calc.product_rule", expansion: "unexplored", unitID: nil))
            return (timeline.events, ())
        }
        for (index, kind) in kinds.enumerated() {
            let attemptID: String = try await ledger.commit { db in
                var timeline = try TimelineMachine(loading: db)
                timeline.put("test", F.card("card\(index)", skills: ["calc.product_rule"]))
                let id = timeline.recordCapture(cardID: "card\(index)", capturePath: "t.jpg", seconds: 20, assisted: false)
                return (timeline.events, id)
            }
            let grading: [String: Any] = ["readable": true, "verdict": "wrong", "key_suspect": false, "cause": "unknown",
                                          "errors": [["kind": kind, "where": "", "wrote": "", "correct": "", "detail": ""]]]
            let turn = TurnOutcome(planID: "p", round: 1, status: .completed, codexThreadID: nil, codexTurnID: nil,
                                   finalText: String(decoding: try JSONSerialization.data(withJSONObject: grading), as: UTF8.self),
                                   executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: 0)
            try await ledger.commit { db in
                let applied = try TimelineTurns.apply(kind: .timelineGrading, targetID: attemptID, outcome: turn, model: "m", db: db)
                return (applied.events, ())
            }
        }
        return try await ledger.read { db in try TimelineBatchRecord.fetchAll(db).filter { $0.purpose == "graph_descend" } }
    }

    func testGradingNeverDescendsByItself() async throws {
        // いつ下りるかは見直しのモデルに任せる: 採点の反映では、概念の誤りが 2 回続いても依頼を出さない。
        let rows = try await gradeTwice(kinds: ["calculation", "concept"])
        XCTAssertTrue(rows.isEmpty)
    }

    func testDescendToolAsksForDirectPrerequisitesAndRunsAfterTheTurn() async throws {
        let ledger = try Ledger.inMemory()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", self.skill("calc.product_rule", expansion: "unexplored", unitID: nil))
            timeline.put("test", self.skill("calc.chain_rule", expansion: "done", unitID: nil))
            return (timeline.events, ())
        }
        func call(_ skillID: String) async throws -> (success: Bool, text: String) {
            try await ledger.commit { db in
                var timeline = try TimelineMachine(loading: db)
                let result = TimelineWriteTools.apply(name: "timeline_descend", arguments: ["skill_id": .string(skillID), "note": .string("積の微分で項を落とす")],
                                                      machine: &timeline, workbook: try WorkbookMachine(loading: db))
                return (timeline.events, result)
            }
        }
        let first = try await call("calc.product_rule")
        XCTAssertTrue(first.success, first.text)
        let again = try await call("calc.product_rule")
        XCTAssertFalse(again.success, "同じ点で二度は頼まない")
        let dug = try await call("calc.chain_rule")
        XCTAssertFalse(dug.success, "直前の前提を調べ済みの点")
        let unknown = try await call("nope")
        XCTAssertFalse(unknown.success, "グラフに無い点")
        let rows = try await ledger.read { db in try TimelineBatchRecord.fetchAll(db).filter { $0.purpose == "graph_descend" } }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.request["skill_id"]?.stringValue, "calc.product_rule")
        XCTAssertEqual(rows.first?.request["reason"]?.stringValue, "積の微分で項を落とす")
        XCTAssertEqual(rows.first?.request["only_direct_prerequisites"]?.boolValue, true)
        // 道具を呼んだターン(見直し)が終わったら、その依頼を続けて頼む。
        let failed = TurnOutcome(planID: "p", round: 1, status: .failed, codexThreadID: nil, codexTurnID: nil, finalText: "",
                                 executions: [], rateLimits: nil, files: [], error: "x", elapsedMs: 0)
        let attemptID: String = try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", F.card("card0", skills: ["calc.product_rule"]))
            let id = timeline.recordCapture(cardID: "card0", capturePath: "t.jpg", seconds: 20, assisted: false)
            return (timeline.events, id)
        }
        let next: String? = try await ledger.commit { db in
            let applied = try TimelineTurns.apply(kind: .timelineReview, targetID: attemptID, outcome: failed, model: "m", db: db)
            return (applied.events, applied.followUp.nextGraph)
        }
        XCTAssertEqual(next, rows.first?.id)
    }

    func testFirstWrongShowsTheSameSkillWithOtherNumbers() throws {
        var machine = F.machine()
        var payload = F.card("c1").payload.objectValue ?? [:]
        payload["variant"] = .object(["level": .number(2), "prompt": .string("数値だけ変えた問題"), "math": .string("y = 3x^2 - 6x + 1"), "question": .string(""),
                                      "answer_key": .string("-2"), "answer_expr": .string("-2"), "checkpoints": .array([])])
        machine.put("test", F.card("c1", payload: payload))
        let variant = try XCTUnwrap(machine.makeEasier(of: "c1", preferVariant: true))
        XCTAssertEqual(machine.cards[variant]?.prompt, "数値だけ変えた問題")
        XCTAssertEqual(machine.cards[variant]?.level, 2, "形と段は同じ")
        var other = F.machine()
        other.put("test", F.card("c2"))
        let easier = try XCTUnwrap(other.makeEasier(of: "c2", preferVariant: true))
        XCTAssertEqual(other.cards[easier]?.prompt, "やさしい版", "数値を変えた問題が無ければやさしい版")
    }

    func testBuildDecomposesTheUnitStepByStepThenAddsMisconceptions() async throws {
        let ledger = try Ledger.inMemory()
        let subunitID: String = try await ledger.commit { db in
            var workbook = try WorkbookMachine(loading: db)
            let unitID = workbook.createUnit(title: "二次関数", outcome: "", source: "consult", subunits: [.init(title: "最大と最小", n: 2)], firstStage: 1)
            return (workbook.events, workbook.orderedSubunits(unitID: unitID)[0].id)
        }
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: MockTurnRunner())
        let buildID: String? = try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            let workbook = try WorkbookMachine(loading: db)
            let request = try XCTUnwrap(TimelineGraphSchedule.next(timeline: timeline, workbook: workbook))
            XCTAssertEqual(request, .build)
            let id = TimelineTurns.insertGraphRequest(request, timeline: &timeline, workbook: workbook, profile: nil)
            return (timeline.events, id)
        }
        await turns.startTimeline(kind: .timelineGraph, targetID: try XCTUnwrap(buildID))
        for _ in 0..<200 {
            let done = try await ledger.read { db in
                let rows = try TimelineBatchRecord.fetchAll(db)
                return rows.contains { $0.purpose == "graph_misconceptions" && $0.status != "requested" }
            }
            if done { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let timeline = try await ledger.read { db in try TimelineMachine(loading: db) }
        let goal = try XCTUnwrap(timeline.skills.values.first { $0.unitId == subunitID })
        // 一番上の点は小単元 ID、分解で出た点は単元 ID。
        XCTAssertEqual(goal.expansion, "done")
        XCTAssertEqual(timeline.directPrerequisites(of: goal.id), ["quad.axis_vs_range", "quad.vertex_form"])
        XCTAssertEqual(timeline.skills["quad.vertex_form"]?.expansion, "done")
        XCTAssertEqual(timeline.skills["quad.expand"]?.expansion, "unexplored", "前に習う内容は置くだけ")
        XCTAssertNotEqual(timeline.skills["quad.vertex_form"]?.unitId, subunitID)
        XCTAssertTrue(timeline.pendingSkills.isEmpty)
        XCTAssertEqual(timeline.batches.values.filter { $0.purpose == "graph_step" }.count, 1)
        XCTAssertTrue(timeline.batches.values.filter { $0.purpose.hasPrefix("graph") }.allSatisfy { $0.status == "ready" })
        XCTAssertTrue(timeline.edges.values.contains { $0.relation == "misconception" })
        // 構築の行があるので、開き直しても頼まない。
        let workbook = try await ledger.read { db in try WorkbookMachine(loading: db) }
        XCTAssertNil(TimelineGraphSchedule.next(timeline: timeline, workbook: workbook))
    }
}
