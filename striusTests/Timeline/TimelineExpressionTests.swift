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

    /// 読めない検算式は確かめられないので、通さない(2026-10-25: 前は欠けにしなかった)。
    func testUnreadableChecksAreDefects() {
        XCTAssertNil(TimelineExpression.equivalent("最小値は -5", "-5"))
        XCTAssertEqual(TimelineCards.verificationFailures([("最小値", "-5")]).count, 1)
        XCTAssertEqual(TimelineCards.verificationFailures([("2*x^2-8*x+3", "2*(x-2)^2+5")]).count, 1)
    }

    func testVertex() throws {
        let vertex = try XCTUnwrap(TimelineExpression.vertex(of: "3(x - 2)^2 - 5"))
        XCTAssertEqual(vertex.x, 2, accuracy: 1e-9)
        XCTAssertEqual(vertex.y, -5, accuracy: 1e-9)
        XCTAssertNil(TimelineExpression.vertex(of: "2x + 1"))
        XCTAssertNil(TimelineExpression.vertex(of: "x^3"))
    }

    /// 9e9・3e-6 を指数の書き方として読む。前は e を自然対数の底として掛け、正しい検算でもカードを却下していた(Issue #154)。
    func testScientificNotationInChecks() {
        XCTAssertEqual(TimelineExpression.equivalent("9e9*3e-6*1e-6/0.3^2", "0.3"), true)
        XCTAssertEqual(TimelineExpression.equivalent("9e9*5e-6*6e-6/3^2", "3e-2"), true)
        XCTAssertEqual(TimelineExpression.equivalent("1.6E+3", "1600"), true)
        // 指数が続かない e は今までどおり自然対数の底。
        XCTAssertEqual(TimelineExpression.equivalent("2e", "2*exp(1)"), true)
        XCTAssertEqual(TimelineCards.verificationFailures([("9e9*3e-6*4e-6/0.2^2", "2.7")]), [])
    }

    /// 0.001 未満の値は割合で比べる(前は差が 1e-6 未満なら一致とみなした)。
    func testSmallValuesCompareRelatively() {
        XCTAssertEqual(TimelineExpression.equivalent("7.2e-7", "7.2e-8"), false)
        XCTAssertEqual(TimelineExpression.equivalent("1.35e-4", "1.35*10^(-4)"), true)
        XCTAssertEqual(TimelineExpression.equivalent("sin(pi)", "0"), true)
        XCTAssertEqual(TimelineExpression.equivalent("1/3", "0.333333"), true)
    }
}
