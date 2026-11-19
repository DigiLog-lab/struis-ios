import CoreGraphics
import XCTest
@testable import strius

/// 図形の問題の図(2026-11-19 のプロトタイプ): 読み取り、受け取る前の点検、やさしい版への引き継ぎ、画面に収まること。
final class TimelineFigureTests: XCTestCase {
    typealias F = TimelineFixture

    /// ∠ABC = 61°、∠ACB = 50° の三角形(座標は角度から計算した値)。
    private func triangle(labelB: String = "61°", labelA: String = "$x$") -> [String: Any] {
        [
            "points": [["name": "A", "x": 3.978079, "y": 7.176645], ["name": "B", "x": 0, "y": 0], ["name": "C", "x": 10, "y": 0]],
            "segments": [["from": "A", "to": "B", "dashed": false, "ticks": 0, "arrows": 0],
                         ["from": "B", "to": "C", "dashed": false, "ticks": 0, "arrows": 0],
                         ["from": "C", "to": "A", "dashed": false, "ticks": 0, "arrows": 0]],
            "angles": [["vertex": "B", "from": "A", "to": "C", "label": labelB, "arcs": 1, "right": false],
                       ["vertex": "C", "from": "B", "to": "A", "label": "50^\\circ", "arcs": 2, "right": false],
                       ["vertex": "A", "from": "B", "to": "C", "label": labelA, "arcs": 1, "right": false]],
            "circles": [],
        ]
    }

    private func json(_ object: Any) throws -> LedgerJSON {
        try JSONDecoder().decode(LedgerJSON.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testReadsAFigureAndAcceptsMatchingAngles() throws {
        let figure = try XCTUnwrap(TimelineFigure(try json(triangle())))
        XCTAssertEqual(figure.points.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(figure.angles[1].arcs, 2)
        XCTAssertEqual(try XCTUnwrap(figure.degrees(of: figure.angles[0])), 61, accuracy: 0.01)
        XCTAssertEqual(figure.defects, [])
        XCTAssertNil(TimelineFigure(.null))
        XCTAssertNil(TimelineFigure(try json(["points": [], "segments": [], "angles": [], "circles": []])))
    }

    func testRejectsAnAngleWhoseLabelDoesNotMatchTheCoordinates() throws {
        let figure = try XCTUnwrap(TimelineFigure(try json(triangle(labelB: "70°"))))
        XCTAssertEqual(figure.defects.count, 1)
        XCTAssertTrue(figure.defects[0].contains("labeled 70°"), figure.defects[0])
        // 4° 以内のずれは、教科書の図と同じく許す。
        XCTAssertEqual(TimelineFigure(try json(triangle(labelB: "63°")))?.defects, [])
    }

    func testRejectsUnknownPointsOverlapsAndAWrongRightAngle() throws {
        var object = triangle()
        object["segments"] = [["from": "A", "to": "Z", "dashed": false, "ticks": 0, "arrows": 0]]
        object["angles"] = [["vertex": "B", "from": "A", "to": "C", "label": "", "arcs": 1, "right": true]]
        var points = object["points"] as! [[String: Any]]
        points.append(["name": "D", "x": 0.01, "y": 0.01])
        object["points"] = points
        let defects = try XCTUnwrap(TimelineFigure(try json(object))).defects
        XCTAssertTrue(defects.contains { $0.contains("unknown points Z") }, "\(defects)")
        XCTAssertTrue(defects.contains { $0.contains("marked right") }, "\(defects)")
        XCTAssertTrue(defects.contains { $0.contains("B and D overlap") }, "\(defects)")
    }

    func testReadsDegreeLabels() {
        XCTAssertEqual(TimelineFigure.labeledDegrees("61°"), 61)
        XCTAssertEqual(TimelineFigure.labeledDegrees("$53^\\circ$"), 53)
        XCTAssertEqual(TimelineFigure.labeledDegrees("37.5度"), 37.5)
        XCTAssertNil(TimelineFigure.labeledDegrees("$x$"))
        XCTAssertNil(TimelineFigure.labeledDegrees("?"))
        XCTAssertEqual(TimelineFigure.displayLabel("$53^\\circ$"), "53°")
    }

    func testAProblemThatRefersToAFigureNeedsOne() throws {
        XCTAssertTrue(TimelineFigure.mentionsFigure("右の図で、AE∥BC である。"))
        XCTAssertFalse(TimelineFigure.mentionsFigure("合同な図形の対応する角は等しい。"))
        var draft = F.draftJSON()
        draft["prompt"] = "右の図で、$\\angle x$ の大きさを求めなさい。"
        draft["figure"] = NSNull()
        let defects = TimelineCards.defects(try F.batch(cards: [draft]).cards[0], allowedSkills: [], levelCap: nil)
        XCTAssertTrue(defects.contains { $0.contains("figure is null") }, "\(defects)")
        draft["figure"] = triangle()
        XCTAssertEqual(TimelineCards.figureDefects(try F.batch(cards: [draft]).cards[0]), [])
        draft["figure"] = triangle(labelB: "80°")
        XCTAssertFalse(TimelineCards.figureDefects(try F.batch(cards: [draft]).cards[0]).isEmpty)
    }

    func testTheCardKeepsItsFigureAndTheEasierVersionBorrowsIt() throws {
        var machine = F.machine()
        let id = machine.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: nil, levelCap: nil)
        var draft = F.draftJSON()
        draft["prompt"] = "右の図で、$x$ の大きさを求めなさい。"
        draft["figure"] = triangle()
        draft["easier"] = ["level": 1, "prompt": "図の $\\angle ABC$ と $\\angle ACB$ の和を求めなさい。", "math": "", "question": "",
                           "answer_key": "111", "answer_expr": "111", "checkpoints": [], "figure": NSNull()]
        XCTAssertEqual(machine.applyBatch(id: id, batch: try F.batch(cards: [draft])), .applied(cards: 1))
        let card = try XCTUnwrap(machine.queue.first)
        XCTAssertNotNil(TimelineFigure(card.payload["figure"]))
        let easierID = try XCTUnwrap(machine.makeEasier(of: card.id))
        XCTAssertEqual(machine.cards[easierID]?.payload["figure"], card.payload["figure"])
        // 図を持たない問題は、図を持たない。
        let plain = machine.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: nil, levelCap: nil)
        _ = machine.applyBatch(id: plain, batch: try F.batch(cards: [F.draftJSON()]))
        XCTAssertNil(machine.queue.last?.payload["figure"])
    }

    func testTheGradingRequestCarriesTheFigure() throws {
        let figure = try json(triangle())
        let card = F.card("c", payload: ["figure": figure])
        let attempt = F.attempt("a", card: "c", verdict: "pending")
        XCTAssertEqual(TimelineTurns.gradingRequest(attempt: attempt, card: card)["figure"], figure)
        XCTAssertNil(TimelineTurns.gradingRequest(attempt: attempt, card: F.card("d"))["figure"])
    }

    func testEveryPointFitsInsideTheFrame() throws {
        let figure = try XCTUnwrap(TimelineFigure(try json(triangle())))
        let size = CGSize(width: 360, height: 360 / figure.aspectRatio)
        let place = figure.transform(in: size, inset: 26)
        for point in figure.points {
            let p = place(point)
            XCTAssertTrue(p.x >= 25.9 && p.x <= size.width - 25.9 && p.y >= 25.9 && p.y <= size.height - 25.9, "\(point.name) \(p)")
        }
        // y は上向きの座標なので、A は画面では上。
        XCTAssertLessThan(place(figure.points[0]).y, place(figure.points[1]).y)
        // B の名前は線の反対側(左下)に置く。
        let direction = figure.labelDirection(of: figure.points[1])
        XCTAssertLessThan(direction.dx, 0)
        XCTAssertGreaterThan(direction.dy, 0)
    }
}
