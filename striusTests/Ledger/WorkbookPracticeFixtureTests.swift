import XCTest
@testable import strius

/// `-workbook-practice-ready` の準備が本物の規則で類題の合格と演習の一枚を作ること。
final class WorkbookPracticeFixtureTests: XCTestCase {
    func testPracticeFixtureUsesRealRulesAndStartsBeforeAnyPracticeAnswer() throws {
        var machine = WorkbookMachine()
        let unitID = machine.createUnit(title: "二次関数", outcome: "", source: "consult",
            subunits: [.init(title: "頂点", n: 5)], firstStage: 3)
        let subunitID = try XCTUnwrap(machine.orderedSubunits(unitID: unitID).first?.id)
        try LedgerFixtures.seedReadyPractice(&machine, subunitID: subunitID)
        let subunit = try XCTUnwrap(machine.subunits[subunitID])
        XCTAssertEqual(subunit.stage, 4)
        let practice = try XCTUnwrap(machine.openSet(subunitID: subunitID))
        XCTAssertEqual(practice.kind, "practice")
        XCTAssertEqual(practice.problemIds.count, 5)
        XCTAssertEqual(practice.status, "open")
        XCTAssertTrue(machine.practiceAttemptsOf(subunitID: subunitID).isEmpty)
        XCTAssertEqual(machine.attemptsOf(subunitID: subunitID).count, 1)
        XCTAssertEqual(machine.sets.values.filter { $0.kind == "example" && $0.status == "graded" }.count, 1)
    }
}
