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
        XCTAssertTrue(TimelineFigure.mentionsFigure("右のグラフは $y=a\\sin bx$ の形です。"))
        XCTAssertFalse(TimelineFigure.mentionsFigure("次の関数のグラフの周期を求めなさい。"))
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
    /// 交点の名前は、通る線にも角の弧にも掛からない向きに置く。平行の印は交点を避ける(2026-11-19 の実際の出題で、
    /// 交点 Q の名前が横切る線に重なり、平行の印が交点 F に重なった)。
    func testIntersectionLabelsAndMarksAvoidTheLines() throws {
        let figure = try XCTUnwrap(TimelineFigure(try json([
            "points": [["name": "P", "x": 0, "y": 2], ["name": "E", "x": 2, "y": 2], ["name": "Q", "x": 6, "y": 2], ["name": "R", "x": 0, "y": 0],
                       ["name": "F", "x": 3.11, "y": 0], ["name": "S", "x": 6, "y": 0], ["name": "U", "x": 1.5, "y": 2.9]],
            "segments": [["from": "P", "to": "Q", "dashed": false, "ticks": 0, "arrows": 1], ["from": "R", "to": "S", "dashed": false, "ticks": 0, "arrows": 1],
                         ["from": "U", "to": "F", "dashed": false, "ticks": 0, "arrows": 0]],
            "angles": [["vertex": "E", "from": "Q", "to": "F", "label": "61°", "arcs": 1, "right": false]],
            "circles": [],
        ])))
        XCTAssertEqual(figure.defects, [])
        let e = try XCTUnwrap(figure.point("E"))
        let label = figure.labelDirection(of: e)
        // 画面の座標の向きを図の向き(y 上向き)に戻して、線と弧の向きから十分に離れているか。
        let angle = atan2(-label.dy, label.dx) * 180 / .pi
        for blocked in [0.0, 180, -180, 119, -61, -30] {
            XCTAssertGreaterThan(abs(angle - blocked), 25, "E の名前が \(blocked)° の線か弧に近い: \(angle)")
        }
        // 下の平行線の印は、交点 F(線の 0.52 の所)から離す。
        let rs = try XCTUnwrap(figure.segments.first { $0.from == "R" })
        XCTAssertGreaterThan(abs(figure.markPosition(of: rs) - 3.11 / 6), 0.1)
        // 上の平行線の印も、E(線の 1/3 の所)から離す。
        let pq = try XCTUnwrap(figure.segments.first { $0.from == "P" })
        XCTAssertGreaterThan(abs(figure.markPosition(of: pq) - 1.0 / 3), 0.15)
        // 途中に点の無い線は真ん中。
        XCTAssertEqual(figure.markPosition(of: TimelineFigure.Segment(from: "R", to: "P", dashed: false, ticks: 1, arrows: 0)), 0.5)
    }
    /// 名前の無い交点(長方形の対角線)も避ける(2026-11-19 の実際の出題で、対角線の等しい長さの印が交わる所に重なった)。
    func testMarksAvoidUnnamedCrossings() throws {
        let figure = try XCTUnwrap(TimelineFigure(try json([
            "points": [["name": "A", "x": 0, "y": 0], ["name": "B", "x": 0, "y": 3], ["name": "C", "x": 4, "y": 3], ["name": "D", "x": 4, "y": 0]],
            "segments": [["from": "A", "to": "C", "dashed": false, "ticks": 2, "arrows": 0], ["from": "D", "to": "B", "dashed": false, "ticks": 2, "arrows": 0],
                         ["from": "A", "to": "B", "dashed": false, "ticks": 1, "arrows": 0]],
            "angles": [], "circles": [],
        ])))
        let ac = try XCTUnwrap(figure.segments.first { $0.from == "A" && $0.to == "C" })
        XCTAssertGreaterThan(abs(figure.markPosition(of: ac) - 0.5), 0.1)
        let ab = try XCTUnwrap(figure.segments.first { $0.to == "B" && $0.from == "A" })
        XCTAssertEqual(figure.markPosition(of: ab), 0.5)
    }
    // MARK: グラフ・立体・印の点検(2026-11-19)

    private func seg(_ from: String, _ to: String, ticks: Int = 0, arrows: Int = 0) -> [String: Any] {
        ["from": from, "to": to, "dashed": false, "ticks": ticks, "arrows": arrows, "head": false, "label": ""]
    }

    func testEqualLengthAndParallelMarksMustMatchTheCoordinates() throws {
        // 平行四辺形 ABCD: AB∥DC・AB=DC は正しい。AD に AB と同じ印を付けると長さが違う。
        let base: [String: Any] = [
            "points": [["name": "A", "x": 0, "y": 0], ["name": "B", "x": 4, "y": 0], ["name": "C", "x": 5, "y": 2], ["name": "D", "x": 1, "y": 2]],
            "angles": [], "circles": [],
        ]
        var good = base
        good["segments"] = [seg("A", "B", ticks: 1, arrows: 1), seg("D", "C", ticks: 1, arrows: 1), seg("B", "C", arrows: 2), seg("A", "D", arrows: 2)]
        XCTAssertEqual(try XCTUnwrap(TimelineFigure(try json(good))).defects, [])
        var bad = base
        bad["segments"] = [seg("A", "B", ticks: 1), seg("A", "D", ticks: 1), seg("A", "C", arrows: 1), seg("B", "D", arrows: 1)]
        let defects = try XCTUnwrap(TimelineFigure(try json(bad))).defects
        XCTAssertTrue(defects.contains { $0.contains("equal-length ticks") }, "\(defects)")
        XCTAssertTrue(defects.contains { $0.contains("marked parallel") }, "\(defects)")
    }

    func testAnglesWithTheSameArcsMustBeEqual() throws {
        var object = triangle()
        object["angles"] = [["vertex": "B", "from": "A", "to": "C", "label": "", "arcs": 2, "right": false],
                            ["vertex": "C", "from": "B", "to": "A", "label": "", "arcs": 2, "right": false]]
        XCTAssertTrue(try XCTUnwrap(TimelineFigure(try json(object))).defects.contains { $0.contains("arcs (equal)") })
        // 1 本の弧はただの印なので、大きさが違ってもよい。
        object["angles"] = [["vertex": "B", "from": "A", "to": "C", "label": "", "arcs": 1, "right": false],
                            ["vertex": "C", "from": "B", "to": "A", "label": "", "arcs": 1, "right": false]]
        XCTAssertEqual(try XCTUnwrap(TimelineFigure(try json(object))).defects, [])
    }

    func testAGraphWithAxesCurvesAndAFill() throws {
        let figure = try XCTUnwrap(TimelineFigure(try json([
            "points": [["name": "A", "x": 1, "y": 1, "z": 0], ["name": "B", "x": 3, "y": 9, "z": 0]],
            "segments": [], "angles": [], "circles": [], "arcs": [], "regions": [],
            "axes": ["x_min": -2, "x_max": 4, "y_min": -1, "y_max": 10, "ticks": true, "grid": false, "pi_ticks": false],
            "curves": [["expr": "x^2", "x_expr": "", "y_expr": "", "from": -2, "to": 4, "dashed": false, "label": "$y=x^2$"],
                       ["expr": "4*x-3", "x_expr": "", "y_expr": "", "from": -2, "to": 4, "dashed": false, "label": ""]],
            "fills": [["upper": "4*x-3", "lower": "x^2", "from": 1, "to": 3]],
        ])))
        XCTAssertEqual(figure.defects, [])
        XCTAssertEqual(figure.bounds, CGRect(x: -2, y: -1, width: 6, height: 11))
        XCTAssertFalse(figure.isSpace)
        let samples = figure.samples(of: figure.curves[0]).compactMap { $0 }
        XCTAssertEqual(samples.count, 481)
        XCTAssertEqual(try XCTUnwrap(samples.last).y, 16, accuracy: 1e-9)
        // A は曲線の上にあるので、名前は曲線の接線の向きを避ける(真上・真下のどちらかの側)。
        let direction = figure.labelDirection(of: figure.points[0])
        XCTAssertGreaterThan(abs(direction.dy), 0.3, "\(direction)")
        XCTAssertFalse(TimelineFigure.displayLabel("$y=x^2$").contains("$"))
        XCTAssertFalse(TimelineFigure.displayLabel("$y=x^2$").contains("^"))
    }

    func testRejectsAGraphWhoseCurveIsOutsideTheWindowOrUnreadable() throws {
        let figure = try XCTUnwrap(TimelineFigure(try json([
            "points": [["name": "P", "x": 9, "y": 0, "z": 0]], "segments": [], "angles": [], "circles": [], "arcs": [], "regions": [],
            "axes": ["x_min": -2, "x_max": 2, "y_min": -2, "y_max": 2, "ticks": true, "grid": false, "pi_ticks": false],
            "curves": [["expr": "x^2+10", "x_expr": "", "y_expr": "", "from": -2, "to": 2, "dashed": false, "label": ""],
                       ["expr": "", "x_expr": "cos(t", "y_expr": "sin(t)", "from": 0, "to": 6.3, "dashed": false, "label": "円"]],
            "fills": [],
        ])))
        let defects = figure.defects
        XCTAssertTrue(defects.contains { $0.contains("outside the axes window") && $0.contains("P") }, "\(defects)")
        XCTAssertTrue(defects.contains { $0.contains("almost outside") }, "\(defects)")
        XCTAssertTrue(defects.contains { $0.contains("cannot be read") }, "\(defects)")
    }

    func testAParametricCircleAndPiTicks() throws {
        let figure = try XCTUnwrap(TimelineFigure(try json([
            "points": [], "segments": [], "angles": [], "circles": [], "arcs": [], "regions": [],
            "axes": ["x_min": -3, "x_max": 3, "y_min": -3, "y_max": 3, "ticks": true, "grid": false, "pi_ticks": true],
            "curves": [["expr": "", "x_expr": "2*cos(t)", "y_expr": "2*sin(t)", "from": 0, "to": 6.2832, "dashed": false, "label": ""]],
            "fills": [],
        ])))
        XCTAssertEqual(figure.defects, [])
        XCTAssertTrue(try XCTUnwrap(figure.axes).piTicks)
        let first = try XCTUnwrap(figure.samples(of: figure.curves[0]).first ?? nil)
        XCTAssertEqual(first.x, 2, accuracy: 1e-9)
    }

    /// 立体(立方体): 直角と長さは立体の座標で確かめ、描く位置は斜めから見た図(奥は右上へ半分)。
    func testASolidIsCheckedInSpaceAndDrawnObliquely() throws {
        let cube: [[String: Any]] = [
            ["name": "A", "x": 0, "y": 0, "z": 0], ["name": "B", "x": 4, "y": 0, "z": 0], ["name": "C", "x": 4, "y": 4, "z": 0], ["name": "D", "x": 0, "y": 4, "z": 0],
            ["name": "E", "x": 0, "y": 0, "z": 4], ["name": "F", "x": 4, "y": 0, "z": 4], ["name": "G", "x": 4, "y": 4, "z": 4], ["name": "H", "x": 0, "y": 4, "z": 4],
        ]
        let figure = try XCTUnwrap(TimelineFigure(try json([
            "points": cube,
            "segments": [seg("A", "B", ticks: 1), seg("B", "C"), seg("C", "D"), seg("D", "A"), seg("E", "F"), seg("F", "G"), seg("G", "H"), seg("H", "E"),
                         seg("A", "E", ticks: 1), seg("B", "F"), seg("C", "G"), seg("D", "H"), seg("A", "G")],
            // ∠ABC は見取図では 90° に見えないが、立体では直角。∠GAC は立体の対角線の角(約 35.3°)。
            "angles": [["vertex": "B", "from": "A", "to": "C", "label": "", "arcs": 1, "right": true],
                       ["vertex": "A", "from": "C", "to": "G", "label": "35°", "arcs": 1, "right": false]],
            "circles": [], "arcs": [], "regions": [["points": ["A", "C", "G", "E"]]], "axes": NSNull(), "curves": [], "fills": [],
        ])))
        XCTAssertTrue(figure.isSpace)
        XCTAssertEqual(figure.defects, [])
        let d = figure.plane(try XCTUnwrap(figure.point("D")))
        XCTAssertEqual(d.x, 2 * cos(35 * Double.pi / 180), accuracy: 1e-9)
        XCTAssertEqual(d.y, 2 * sin(35 * Double.pi / 180), accuracy: 1e-9)
    }

    func testAnArcNeedsBothEndsOnOneCircle() throws {
        var object: [String: Any] = [
            "points": [["name": "O", "x": 0, "y": 0, "z": 0], ["name": "A", "x": 3, "y": 0, "z": 0], ["name": "B", "x": 0, "y": 3, "z": 0], ["name": "C", "x": 0, "y": 2, "z": 0]],
            "segments": [seg("O", "A"), seg("O", "B")], "angles": [], "circles": [], "regions": [], "curves": [], "fills": [],
            "arcs": [["center": "O", "from": "A", "to": "B", "label": ""]],
        ]
        XCTAssertEqual(try XCTUnwrap(TimelineFigure(try json(object))).defects, [])
        object["arcs"] = [["center": "O", "from": "A", "to": "C", "label": ""]]
        XCTAssertTrue(try XCTUnwrap(TimelineFigure(try json(object))).defects.contains { $0.contains("not on one circle") })
    }
    /// 名前が `_` で始まる点は、ヒストグラムの棒の角などに使うだけの点。重なっていても断らない。
    func testHiddenPointsAreOnlyCorners() throws {
        let figure = try XCTUnwrap(TimelineFigure(try json([
            "points": [["name": "_1", "x": 0, "y": 0, "z": 0], ["name": "_2", "x": 0, "y": 0.01, "z": 0], ["name": "_3", "x": 10, "y": 3, "z": 0],
                       ["name": "_4", "x": 10, "y": 0, "z": 0]],
            "segments": [], "angles": [], "circles": [], "arcs": [], "regions": [["points": ["_1", "_2", "_3", "_4"]]],
            "axes": ["x_min": -1, "x_max": 12, "y_min": -1, "y_max": 5, "ticks": true, "grid": false, "pi_ticks": false], "curves": [], "fills": [],
        ])))
        XCTAssertTrue(figure.points.allSatisfy(\.isHidden))
        XCTAssertEqual(figure.defects, [])
    }
    // MARK: Codex のレビューの指摘(2026-11-19)

    /// 中心から反時計回りに 270° 回る弧は、両端の点より外まで描く範囲に入れる。
    func testTheBoundsIncludeTheWholeArc() throws {
        let figure = try XCTUnwrap(TimelineFigure(try json([
            "points": [["name": "O", "x": 0, "y": 0, "z": 0], ["name": "A", "x": 1, "y": 0, "z": 0], ["name": "B", "x": 0, "y": -1, "z": 0]],
            "segments": [seg("O", "A"), seg("O", "B")], "angles": [], "circles": [], "regions": [], "curves": [], "fills": [],
            "arcs": [["center": "O", "from": "A", "to": "B", "label": ""]],
        ])))
        let bounds = try XCTUnwrap(figure.bounds)
        XCTAssertEqual(bounds.minX, -1, accuracy: 1e-6)
        XCTAssertEqual(bounds.maxY, 1, accuracy: 1e-6)
    }

    /// 質問・解説に添える問題の文に、図の点・線分・印・曲線が入る(チャットの先生は図を見られない)。
    func testTheProblemTextForQuestionsDescribesTheFigure() throws {
        var payload: [String: LedgerJSON] = ["figure": try json(triangle())]
        payload["steps"] = .emptyArray
        let card = F.card("c", payload: payload)
        let text = TimelineCards.problemLines(card).joined(separator: "\n")
        XCTAssertTrue(text.contains("(問題の図)"), text)
        XCTAssertTrue(text.contains("A(3.98, 7.18)"), text)
        XCTAssertTrue(text.contains("∠ABC「61°」"), text)
        let graph = F.card("g", payload: ["figure": try json([
            "points": [], "segments": [], "angles": [], "circles": [], "arcs": [], "regions": [],
            "axes": ["x_min": -2, "x_max": 4, "y_min": -1, "y_max": 10, "ticks": true, "grid": false, "pi_ticks": false],
            "curves": [["expr": "x^2", "x_expr": "", "y_expr": "", "from": -2, "to": 4, "dashed": false, "label": "$y=x^2$"]], "fills": [],
        ])])
        XCTAssertTrue(TimelineCards.problemLines(graph).joined().contains("y = x^2(x は -2〜4)"))
        XCTAssertFalse(TimelineCards.problemLines(F.card("n")).joined().contains("問題の図"))
    }
}
