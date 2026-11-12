import GRDB
import XCTest
@testable import strius

/// オフライン反復の「問題の型」の控え(`DrillTemplateStore`、台帳の移行 `v7-drill-templates`)。
final class DrillTemplateStoreTests: XCTestCase {
    typealias F = TimelineFixture

    private func fixture(_ path: String) throws -> String {
        let root: URL = try XCTUnwrap(DrillTestSupport.fixturesRoot())
        return try String(contentsOf: root.appendingPathComponent(path), encoding: String.Encoding.utf8)
    }

    /// 実際の型を、返事の点検(`DrillAuthoringSession`)に通して保存できる結論にする。
    private func readyOutcome(_ path: String, skillID: String) throws -> DrillAuthoringOutcome {
        let request: DrillAuthoringRequest = DrillAuthoringRequest(skillID: skillID, name: "テスト", kind: "procedure", solved: [])
        var session: DrillAuthoringSession = DrillAuthoringSession(request: request)
        let step: DrillAuthoringStep = session.receive(reply: "{\"template\": \(try fixture(path)), \"reason\": \"\"}")
        guard case DrillAuthoringStep.finished(let outcome) = step, case DrillAuthoringOutcome.ready = outcome else {
            XCTFail("点検を通るはず: \(step)")
            return DrillAuthoringOutcome.excluded(reasons: [], declined: false)
        }
        return outcome
    }

    func testCheckedTemplateIsStoredAndReadBack() async throws {
        let ledger: Ledger = try Ledger.inMemory()
        let store: DrillTemplateStore = DrillTemplateStore(queue: ledger.queue)
        let skillID: String = "math.m1.complete_square_vertex"
        XCTAssertTrue(try store.needsAuthoring(skillID: skillID))
        XCTAssertNil(try store.template(for: skillID))

        try store.save(skillID: skillID, outcome: try readyOutcome("math/math.m1.complete_square_vertex.json", skillID: skillID))

        XCTAssertFalse(try store.needsAuthoring(skillID: skillID))
        let stored: DrillTemplate = try XCTUnwrap(try store.template(for: skillID))
        XCTAssertEqual(stored, try DrillTemplate.decode(json: try fixture("math/math.m1.complete_square_vertex.json")))
        XCTAssertEqual(try store.readySkillIDs(), [skillID])
        let entry: DrillTemplateStore.Entry = try XCTUnwrap(try store.entry(for: skillID))
        XCTAssertEqual(entry.status, DrillTemplateStore.statusReady)
        XCTAssertTrue(entry.numericCheck)
        XCTAssertGreaterThanOrEqual(entry.problems, DrillValidator.minimumProblems)
        // 保存した型から、そのまま問題を作れる。
        var random: DrillSeededRandom = DrillSeededRandom(seed: 7)
        let problem: DrillProblem = try DrillGenerator(template: stored).next(using: &random)
        XCTAssertFalse(problem.answer.isEmpty)
    }

    func testExcludedSkillIsRememberedAndNotAskedAgain() async throws {
        let ledger: Ledger = try Ledger.inMemory()
        let store: DrillTemplateStore = DrillTemplateStore(queue: ledger.queue)
        try store.save(skillID: "graph.read_slope", outcome: DrillAuthoringOutcome.excluded(reasons: ["グラフを見て答える問題"], declined: true))

        XCTAssertFalse(try store.needsAuthoring(skillID: "graph.read_slope"), "同じ書式の版の間は頼み直さない")
        XCTAssertNil(try store.template(for: "graph.read_slope"))
        XCTAssertEqual(try store.readySkillIDs(), [])
        XCTAssertEqual(try store.excludedReasons(for: "graph.read_slope"), ["グラフを見て答える問題"])
        XCTAssertEqual(try store.entry(for: "graph.read_slope")?.declined, true)
    }

    func testSavingAgainReplacesTheRowAndKeepsTheFirstTime() async throws {
        let ledger: Ledger = try Ledger.inMemory()
        let store: DrillTemplateStore = DrillTemplateStore(queue: ledger.queue)
        let skillID: String = "math.m1.quadratic_inequality"
        try store.save(skillID: skillID, outcome: DrillAuthoringOutcome.excluded(reasons: ["数値の点検が合わない"], declined: false))
        let first: DrillTemplateStore.Entry = try XCTUnwrap(try store.entry(for: skillID))
        try store.save(skillID: skillID, outcome: try readyOutcome("math/math.m1.quadratic_inequality.json", skillID: skillID))
        let second: DrillTemplateStore.Entry = try XCTUnwrap(try store.entry(for: skillID))
        XCTAssertEqual(second.status, DrillTemplateStore.statusReady)
        XCTAssertEqual(second.createdAt, first.createdAt)
        XCTAssertEqual(second.reasons, "[]")
        let rows: Int = try await ledger.queue.read { (db: Database) -> Int in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM drill_templates") ?? 0 }
        XCTAssertEqual(rows, 1)
    }

    func testTemplateWrittenForAnOlderFormatIsAskedAgain() async throws {
        let ledger: Ledger = try Ledger.inMemory()
        let store: DrillTemplateStore = DrillTemplateStore(queue: ledger.queue)
        let skillID: String = "math.m1.complete_square_vertex"
        try store.save(skillID: skillID, outcome: try readyOutcome("math/math.m1.complete_square_vertex.json", skillID: skillID))
        try await ledger.queue.write { (db: Database) -> Void in
            try db.execute(sql: "UPDATE drill_templates SET format = ? WHERE skill_id = ?", arguments: [DrillTemplate.currentFormat - 1, skillID])
        }
        XCTAssertTrue(try store.needsAuthoring(skillID: skillID))
        XCTAssertNil(try store.template(for: skillID), "前の書式の版の型は出さない")
        XCTAssertEqual(try store.readySkillIDs(), [])
    }

    /// 前の版の台帳(`v6` まで)を開くと、表が足される。
    func testLedgerFromThePreviousVersionGetsTheTable() async throws {
        let url: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("struis-drill-\(UUID().uuidString)").appendingPathComponent("ledger.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous: [String] = LedgerSchema.migrations.map(\.id).filter { (id: String) -> Bool in id != "v7-drill-templates" }
        let queue: DatabaseQueue = try DatabaseQueue(path: url.path)
        try LedgerSchema.migrator(previous).migrate(queue)
        let before: Bool = try await queue.read { (db: Database) -> Bool in try db.tableExists("drill_templates") }
        XCTAssertFalse(before)
        try queue.close()

        let ledger: Ledger = try Ledger(path: url)
        let store: DrillTemplateStore = DrillTemplateStore(queue: ledger.queue)
        try store.save(skillID: "s", outcome: DrillAuthoringOutcome.excluded(reasons: ["理由"], declined: false))
        XCTAssertEqual(try store.excludedReasons(for: "s"), ["理由"])
    }

    /// 単元を消すと、その単元の点の型も消える(他の単元の点の型は残る)。
    func testDeletingAUnitErasesTheTemplatesOfItsSkills() async throws {
        let ledger: Ledger = try Ledger.inMemory()
        let unitID: String = try await ledger.commit { (db: Database) -> (events: [LedgerEvent], result: String) in
            var workbook: WorkbookMachine = try WorkbookMachine(loading: db)
            let unitID: String = workbook.createUnit(title: "二次関数", outcome: "", source: "consult", subunits: [.init(title: "頂点", n: 2)], firstStage: 3)
            var timeline: TimelineMachine = try TimelineMachine(loading: db)
            var owned: TimelineSkillRecord = F.skill("quad.vertex_form")
            owned.unitId = unitID
            timeline.put("test", owned)
            timeline.put("test", F.skill("calc.product_rule"))
            return (events: workbook.events + timeline.events, result: unitID)
        }
        let store: DrillTemplateStore = DrillTemplateStore(queue: ledger.queue)
        try store.save(skillID: "quad.vertex_form", outcome: DrillAuthoringOutcome.excluded(reasons: ["a"], declined: false))
        try store.save(skillID: "calc.product_rule", outcome: DrillAuthoringOutcome.excluded(reasons: ["b"], declined: false))

        _ = try await ledger.deleteUnit(id: unitID)

        XCTAssertNil(try store.entry(for: "quad.vertex_form"))
        XCTAssertNotNil(try store.entry(for: "calc.product_rule"))
    }
}
