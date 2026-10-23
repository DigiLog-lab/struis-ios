import XCTest
@testable import strius

/// 検算の式(Issue #46「保存する前に数式で検算する」)。
final class TimelineExpressionTests: XCTestCase {
    func testEquivalentForms() {
        XCTAssertEqual(TimelineExpression.equivalent("2*x^2-8*x+3", "2*(x-2)^2-5"), true)
        XCTAssertEqual(TimelineExpression.equivalent("2x^2 - 8x + 3", "2(x − 2)² − 5"), true)
        // 形が違うだけの正解(y = 3x − 1 と y − 2 = 3(x − 1) を右辺に直したもの)。
        XCTAssertEqual(TimelineExpression.equivalent("y = 3x - 1", "3(x - 1) + 2"), true)
        XCTAssertEqual(TimelineExpression.equivalent("2*(x-2)^2+5", "2*(x-2)^2-5"), false)
        XCTAssertEqual(TimelineExpression.equivalent("\\frac{1}{2}x", "x/2"), true)
        XCTAssertEqual(TimelineExpression.equivalent("(2, -5)", "(2, −5)"), true)
        XCTAssertEqual(TimelineExpression.equivalent("(2, -5)", "(2, 5)"), false)
        XCTAssertEqual(TimelineExpression.equivalent("sinx*cosx", "sin(2x)/2"), true)
        XCTAssertEqual(TimelineExpression.equivalent("2*2^2-8*2+3", "-5"), true)
    }

    func testUnreadableIsNotAFailure() {
        XCTAssertNil(TimelineExpression.equivalent("最小値は -5", "-5"))
        XCTAssertTrue(TimelineCards.verificationFailures([("最小値", "-5")]).isEmpty)
        XCTAssertEqual(TimelineCards.verificationFailures([("2*x^2-8*x+3", "2*(x-2)^2+5")]).count, 1)
    }

    func testVertex() throws {
        let vertex = try XCTUnwrap(TimelineExpression.vertex(of: "3(x - 2)^2 - 5"))
        XCTAssertEqual(vertex.x, 2, accuracy: 1e-9)
        XCTAssertEqual(vertex.y, -5, accuracy: 1e-9)
        XCTAssertNil(TimelineExpression.vertex(of: "2x + 1"))
        XCTAssertNil(TimelineExpression.vertex(of: "x^3"))
    }
}
