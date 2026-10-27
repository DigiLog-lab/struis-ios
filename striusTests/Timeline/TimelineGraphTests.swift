import GRDB
import XCTest
@testable import strius

/// Issue #46「知識グラフ」: 点検(ID の重複・存在しない点への線・前提の輪)、操作の列、WITH RECURSIVE の問い合わせ。
final class TimelineGraphTests: XCTestCase {
    typealias Node = TimelineGraph.Node
    typealias Edge = TimelineGraph.Edge

    private func output(_ nodes: [Node], _ edges: [Edge], start: String? = nil) -> TimelineGraph.Output {
        TimelineGraph.Output(nodes: nodes, edges: edges, ops: [], startNodeId: start, notes: "")
    }

    private let quadratic: [Node] = [
        Node(id: "quad.expand", name: "展開", kind: "procedure", unitId: nil),
        Node(id: "quad.vertex_form", name: "平方完成", kind: "procedure", unitId: nil),
        Node(id: "quad.axis_vs_range", name: "軸と範囲の位置", kind: "concept", unitId: nil),
        Node(id: "quad.min_moving_range", name: "範囲が動くときの最小値", kind: "combination", unitId: nil),
    ]
    private let quadraticEdges: [Edge] = [
        Edge(from: "quad.expand", to: "quad.vertex_form", relation: "prerequisite", note: ""),
        Edge(from: "quad.vertex_form", to: "quad.min_moving_range", relation: "prerequisite", note: ""),
        Edge(from: "quad.axis_vs_range", to: "quad.min_moving_range", relation: "prerequisite", note: ""),
        Edge(from: "quad.axis_vs_range", to: "quad.axis_vs_range", relation: "misconception", note: "範囲の端だけを比べて頂点を見落とす"),
    ]

    func testValidationRejectsDuplicatesUnknownNodesAndCycles() {
        let duplicate = TimelineGraph.validate(nodes: quadratic + [quadratic[0]], edges: [], existing: [:], existingEdges: [])
        XCTAssertTrue(duplicate.contains(.duplicateNode("quad.expand")))
        let unknown = TimelineGraph.validate(nodes: quadratic, edges: [Edge(from: "nope", to: "quad.expand", relation: "prerequisite", note: "")], existing: [:], existingEdges: [])
        XCTAssertTrue(unknown.contains(.unknownNode("nope")))
        let cycle = TimelineGraph.validate(nodes: quadratic, edges: quadraticEdges + [Edge(from: "quad.min_moving_range", to: "quad.expand", relation: "prerequisite", note: "")], existing: [:], existingEdges: [])
        XCTAssertTrue(cycle.contains { if case .cycle = $0 { true } else { false } })
        XCTAssertTrue(TimelineGraph.validate(nodes: quadratic, edges: quadraticEdges, existing: [:], existingEdges: []).isEmpty)
        // 誤解の線(自分自身)は輪にしない。
        XCTAssertNil(TimelineGraph.cycle(in: [(from: "a", to: "b")]))
        XCTAssertNotNil(TimelineGraph.cycle(in: [(from: "a", to: "b"), (from: "b", to: "a")]))
    }

    func testRecursivePrerequisiteQueryThroughTheLedger() async throws {
        let ledger = try Ledger.inMemory()
        try await ledger.commit { db in
            var machine = try TimelineMachine(loading: db)
            XCTAssertTrue(machine.applyGraph(self.output(self.quadratic, self.quadraticEdges, start: "quad.vertex_form"), source: "initial", unitID: "u").isEmpty)
            var mastered = machine.skills["quad.vertex_form"]!
            mastered.status = "mastered"
            machine.put("test.mastered", mastered)
            return (machine.events, ())
        }
        let rows = try await ledger.read { db in try TimelineGraph.unmasteredPrerequisites(db: db, skillID: "quad.min_moving_range") }
        // 平方完成は定着しているので出さない。展開は 2 段先。
        XCTAssertEqual(rows.map(\.id), ["quad.axis_vs_range", "quad.expand"])
        XCTAssertEqual(rows.map(\.depth), [1, 2])
        let text = try await ledger.read { db in try TimelineGraph.query(db: db, arguments: ["query": .string("prerequisites"), "skill_id": .string("quad.min_moving_range")]) }
        XCTAssertTrue(text.contains("軸と範囲の位置(quad.axis_vs_range、練習中、1段先)"))
        let misconceptions = try await ledger.read { db in try TimelineGraph.query(db: db, arguments: ["query": .string("misconceptions"), "skill_id": .string("quad.min_moving_range")]) }
        XCTAssertTrue(misconceptions.contains("頂点を見落とす"))
        // 台帳を作り直しても同じ。
        let before = try await ledger.projectionDigest()
        try await ledger.rebuild()
        let after = try await ledger.projectionDigest()
        XCTAssertEqual(before, after)
    }

    func testReviewOperationsSplitAndCarryOverTheRecord() throws {
        var machine = TimelineFixture.machine()
        XCTAssertTrue(machine.applyGraph(output(quadratic, quadraticEdges), source: "initial", unitID: nil).isEmpty)
        var vertex = machine.skills["quad.vertex_form"]!
        vertex.correctDates = ["2026-10-20", "2026-10-21"]
        vertex.attempts = 4
        machine.put("test", vertex)
        machine.put("test", TimelineFixture.card("c1", skills: ["quad.vertex_form"]))
        let split = TimelineGraph.Operation(op: "split_node", node: nil, nodeIds: ["quad.vertex_form"], into: [
            Node(id: "quad.vertex_form_int", name: "平方完成(整数)", kind: "procedure", unitId: nil),
            Node(id: "quad.vertex_form_frac", name: "平方完成(分数)", kind: "procedure", unitId: nil),
        ], edge: nil, evidence: ["a1"], reason: "分数の時だけ ×")
        XCTAssertTrue(machine.applyGraphOps([split], source: "review").isEmpty)
        XCTAssertEqual(machine.skills["quad.vertex_form"]?.replacedBy, ["quad.vertex_form_int", "quad.vertex_form_frac"])
        XCTAssertEqual(machine.skills["quad.vertex_form_frac"]?.correctDates, ["2026-10-20", "2026-10-21"])
        XCTAssertEqual(machine.skills["quad.vertex_form_frac"]?.attempts, 4)
        XCTAssertEqual(machine.cards["c1"]?.skills, ["quad.vertex_form_int", "quad.vertex_form_frac"])
        // 線も付け替える: 展開 → 分けた両方。
        XCTAssertTrue(machine.directPrerequisites(of: "quad.vertex_form_frac").contains("quad.expand"))
        XCTAssertFalse(machine.activeSkills.contains { $0.id == "quad.vertex_form" })
        // 輪を作る操作は受け取らない(何も変えない)。
        let before = machine.edges.count
        let bad = TimelineGraph.Operation(op: "add_edge", node: nil, nodeIds: [], into: [], edge: Edge(from: "quad.min_moving_range", to: "quad.expand", relation: "prerequisite", note: ""), evidence: [], reason: "")
        XCTAssertFalse(machine.applyGraphOps([bad], source: "review").isEmpty)
        XCTAssertEqual(machine.edges.count, before)
    }
}
