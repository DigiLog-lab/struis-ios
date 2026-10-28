import XCTest
@testable import strius

/// Issue #46「タイムラインに混ぜるカード10種」: 受け取る前の点検と、材料からの組み替え・端末の中の採点。
final class TimelineCardsTests: XCTestCase {
    typealias F = TimelineFixture

    private func draft(_ json: [String: Any]) throws -> TimelineCards.Draft {
        try F.batch(cards: [json]).cards[0]
    }

    func testDefects() throws {
        XCTAssertTrue(TimelineCards.defects(try draft(F.draftJSON(skills: ["a"])), allowedSkills: ["a"], levelCap: nil).isEmpty)
        XCTAssertFalse(TimelineCards.defects(try draft(F.draftJSON(skills: ["zzz"])), allowedSkills: ["a"], levelCap: nil).isEmpty)
        XCTAssertFalse(TimelineCards.defects(try draft(F.draftJSON(level: 3)), allowedSkills: [], levelCap: 2).isEmpty)
        // 検算: 答えが合わないカードは受け取らない。
        let wrong = F.draftJSON(checks: [["left": "2*x^2-8*x+3", "right": "2*(x-2)^2+5"]])
        XCTAssertTrue(TimelineCards.defects(try draft(wrong), allowedSkills: [], levelCap: nil).contains { $0.hasPrefix("check failed") })
        XCTAssertFalse(TimelineCards.defects(try draft(F.draftJSON(kind: "sort", facts: [:])), allowedSkills: [], levelCap: nil).isEmpty)
    }

    private func base() throws -> TimelineCardRecord {
        var machine = F.machine()
        let id = machine.insertCard(from: try draft(F.draftJSON()), batchID: "b", position: 1, chain: nil)
        return machine.cards[id]!
    }

    func testEveryTemplateKindCanBeBuiltFromOneProblem() throws {
        let card = try base()
        for kind in [TimelineCards.Kind.order, .findError, .nextStep, .fillLine, .graphMatch, .sort, .predict, .inverse, .reason] {
            XCTAssertNotNil(TimelineCards.derive(kind, from: card), "\(kind) を組み替えられない")
        }
        // 03 は AI が作った文が無ければ作らない。
        XCTAssertNil(TimelineCards.derive(.compare, from: card))
    }

    func testOnDeviceGrading() throws {
        let card = try base()
        func make(_ kind: TimelineCards.Kind) -> TimelineCardRecord {
            var copy = card
            copy.kind = kind.rawValue
            copy.payload = .object((card.payload.objectValue ?? [:]).merging(TimelineCards.derive(kind, from: card)!.payload) { _, new in new })
            return copy
        }
        let order = make(.order)
        XCTAssertTrue(TimelineCards.grade(order, answer: .array([0, 1, 2, 3].map { .number($0) })))
        XCTAssertFalse(TimelineCards.grade(order, answer: .array([1, 0, 2, 3].map { .number($0) })))
        let findError = make(.findError)
        XCTAssertEqual(findError.payload["answer_index"]?.intValue, 2)
        XCTAssertTrue(TimelineCards.grade(findError, answer: .number(2)))
        let sort = make(.sort)
        let truth = sort.payload["items"]!.arrayValue!.map { LedgerJSON.bool($0["right"]!.boolValue!) }
        XCTAssertTrue(TimelineCards.grade(sort, answer: .array(truth)))
        let predict = make(.predict)
        XCTAssertTrue(TimelineCards.grade(predict, answer: .number(1)))  // 答えは −5(負)
        let graph = make(.graphMatch)
        XCTAssertTrue(TimelineCards.grade(graph, answer: graph.payload["graph_order"]!))
    }

    func testWrittenAnswersAreCheckedWithMath() throws {
        let card = try base()
        var inverse = card
        inverse.kind = "inverse"
        inverse.payload = .object((card.payload.objectValue ?? [:]).merging(TimelineCards.derive(.inverse, from: card)!.payload) { _, new in new })
        // 答えは何通りもある: 頂点が (2, −5) なら ○。
        XCTAssertEqual(TimelineCards.gradeWritten(inverse, learnerExpr: "3(x - 2)^2 - 5"), true)
        XCTAssertEqual(TimelineCards.gradeWritten(inverse, learnerExpr: "-(x-2)^2-5"), true)
        XCTAssertEqual(TimelineCards.gradeWritten(inverse, learnerExpr: "(x+2)^2-5"), false)
        var fill = card
        fill.kind = "fill_line"
        fill.payload = .object((card.payload.objectValue ?? [:]).merging(TimelineCards.derive(.fillLine, from: card)!.payload) { _, new in new })
        // 隠した行は 3 行目(= 2(x − 2)^2 − 5)。
        XCTAssertEqual(TimelineCards.gradeWritten(fill, learnerExpr: "2(x-2)^2-5"), true)
        XCTAssertEqual(TimelineCards.gradeWritten(fill, learnerExpr: "2(x-2)^2+5"), false)
    }
}
