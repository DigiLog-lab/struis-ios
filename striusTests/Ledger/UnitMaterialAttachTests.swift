import XCTest
@testable import strius

/// 計画の後に撮り足す(#132): 撮った資料のページや授業の回を小単元に付け、大学の授業なら進んだ回の小単元を足す。
final class UnitMaterialAttachTests: XCTestCase {
    private func seed(_ ledger: Ledger, route: String, refs: [String] = ["", "", ""]) async throws -> String {
        try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let specs = ["二次関数のグラフ", "最大・最小", "二次不等式"].enumerated().map { index, title in
                WorkbookMachine.SubunitSpec(title: title, outcome: "\(title)の問題が解ける", n: 4, ref: refs[index])
            }
            let unitID = machine.createUnit(title: "二次関数", outcome: "", source: "consult", subunits: specs, overview: .object(["route": .string(route)]))
            return (machine.events, unitID)
        }
    }

    private func machine(_ ledger: Ledger) async throws -> WorkbookMachine {
        try await ledger.read { db in try WorkbookMachine(loading: db) }
    }

    func testThePlansPagesAreShownNextToEachSubunit() async throws {
        let ledger = try Ledger.inMemory()
        let unitID = try await seed(ledger, route: "range", refs: ["p.62〜65", "", "第4回"])
        let unit = try await machine(ledger)
        let rows = unit.orderedSubunits(unitID: unitID).map(unit.subunitSummary)
        XCTAssertEqual(rows.map(\.ref), ["p.62〜65", nil, "第4回"])
    }

    func testAttachingPagesSetsThemOnTheSubunitsWithoutAddingAny() async throws {
        let ledger = try Ledger.inMemory()
        let unitID = try await seed(ledger, route: "range", refs: ["p.62〜65", "", ""])
        let request = try XCTUnwrap(UnitMaterialAttacher.request(machine: try await machine(ledger), unitID: unitID, universityLearner: true))
        XCTAssertFalse(request.isCourse, "計画が中高の範囲なら、大学生でも授業の回は足さない")
        let subunits = try XCTUnwrap(request.json["subunits"]?.arrayValue)
        XCTAssertEqual(subunits.first?["ref"]?.stringValue, "p.62〜65", "今付いているページも渡す")

        // AI の返事: 知らない小単元への割り当てと、中高の単元に足そうとした小単元は捨てる。
        let ids = subunits.compactMap { $0["id"]?.stringValue }
        let text = """
        {"readable": true, "assignments": [{"subunit_id": "\(ids[1])", "ref": "p.74〜79"}, {"subunit_id": "nope", "ref": "p.1"}],
         "new_subunits": [{"title": "余分", "outcome": "", "n": 4, "scoring_unit": "", "ref": "p.100"}]}
        """
        let attachment = try XCTUnwrap(OnboardingTurns.parseAttachment(text, subunitIDs: request.subunitIDs, isCourse: request.isCourse))
        XCTAssertEqual(attachment.assignments.count, 1)
        XCTAssertTrue(attachment.newSubunits.isEmpty)
        try await ledger.commit { db in
            var workbook = try WorkbookMachine(loading: db)
            UnitMaterialAttacher.apply(attachment, unitID: unitID, to: &workbook)
            return (workbook.events, ())
        }
        let after = try await machine(ledger)
        XCTAssertEqual(after.orderedSubunits(unitID: unitID).map { after.subunitSummary($0).ref }, ["p.62〜65", "p.74〜79", nil])
    }

    func testAttachingALaterLectureAddsItsSubunitAndReopensAPassedUnit() async throws {
        let ledger = try Ledger.inMemory()
        let unitID = try await seed(ledger, route: "university", refs: ["第1回", "第2回", "第3回"])
        // 全部合格した単元。
        try await ledger.commit { db in
            var workbook = try WorkbookMachine(loading: db)
            for row in workbook.orderedSubunits(unitID: unitID) { workbook.passByCheck(subunitID: row.id) }
            return (workbook.events, ())
        }
        XCTAssertEqual(try await machine(ledger).units[unitID]?.status, "passed")
        let request = try XCTUnwrap(UnitMaterialAttacher.request(machine: try await machine(ledger), unitID: unitID, universityLearner: false))
        XCTAssertTrue(request.isCourse)

        let reply = String(decoding: try JSONSerialization.data(withJSONObject: MockTurnRunner.materialAttachment(
            ["is_course": true, "subunits": [] as [Any]])), as: UTF8.self)
        let attachment = try XCTUnwrap(OnboardingTurns.parseAttachment(reply, subunitIDs: request.subunitIDs, isCourse: true))
        try await ledger.commit { db in
            var workbook = try WorkbookMachine(loading: db)
            UnitMaterialAttacher.apply(attachment, unitID: unitID, to: &workbook)
            return (workbook.events, ())
        }
        let after = try await machine(ledger)
        let rows = after.orderedSubunits(unitID: unitID)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.last?.title, "ジョルダン標準形")
        XCTAssertEqual(after.subunitSummary(rows[3]).ref, "第9回")
        XCTAssertEqual(rows.last?.status, "active", "足した回はすぐ学べる")
        XCTAssertEqual(after.units[unitID]?.status, "active")
    }

    func testThePlanCarriesThePageOrLectureOfEachSubunit() throws {
        let mock = MockTurnRunner.onboardingPlan(["topic": "線形代数Ⅱ", "material": ["lectures": [["number": 4, "title": "核と像"]]]])
        let draft = try XCTUnwrap(OnboardingTurns.parsePlan(String(decoding: try JSONSerialization.data(withJSONObject: mock), as: UTF8.self)))
        XCTAssertEqual(draft.subunits.first?.ref, "第4回")
        XCTAssertNil(draft.subunits.last?.ref, "分からない小単元には付けない")
    }

    func testAttachmentTurnIsNewWorkForTheUsageGate() async throws {
        let plan = try await OnboardingTurns.attachPlan(assets: AssetCache(), planID: "p", request: .object(["task": .string("attach_material")]), imagePaths: [])
        XCTAssertFalse(UsageRequest.of(kind: plan.kind, turnAdmitted: false).finishing)
    }
}
