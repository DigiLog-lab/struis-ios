import XCTest
@testable import strius

/// 答えの欄: 計算機向けに書かれた式を LaTeX に直す(実機 2026-10-26: `pi^2/8+1` の pi が斜体の p・i になった)。
final class TimelinePlainMathTests: XCTestCase {
    func testWrittenFormulasBecomeLaTeX() {
        XCTAssertEqual(TimelinePlainMath.latex("pi^2/8+1"), "\\frac{\\pi^{2}}{8}+1")
        XCTAssertEqual(TimelinePlainMath.latex("π²/8 + 1"), "\\frac{\\pi^{2}}{8}+1")
        XCTAssertEqual(TimelinePlainMath.latex("-1/6"), "-\\frac{1}{6}")
        XCTAssertEqual(TimelinePlainMath.latex("-cos(5x)/5"), "-\\frac{\\cos(5 x)}{5}")
        XCTAssertEqual(TimelinePlainMath.latex("(sin 4x + sin 2x)/2"), "\\frac{\\sin 4 x+\\sin 2 x}{2}")
        XCTAssertEqual(TimelinePlainMath.latex("(1/2){sin 8x + sin(-2x)}"), "\\frac{1}{2} \\{\\sin 8 x+\\sin(-2 x)\\}")
        XCTAssertEqual(TimelinePlainMath.latex("cos(5π/2) = 0, sin(7π/2) = -1"),
                       "\\cos\\left(\\frac{5 \\pi}{2}\\right) = 0,\\ \\sin\\left(\\frac{7 \\pi}{2}\\right) = -1")
        XCTAssertEqual(TimelinePlainMath.latex("sqrt(2)/2"), "\\frac{\\sqrt{2}}{2}")
        XCTAssertEqual(TimelinePlainMath.latex("2*3"), "2 \\cdot 3")
    }

    func testLeavesPlainOrUnreadableTextAlone() {
        // 数字・符号だけは文字のままでよい。
        XCTAssertNil(TimelinePlainMath.latex("0"))
        XCTAssertNil(TimelinePlainMath.latex("-1"))
        // すでに LaTeX・日本語を含む文・英単語は直さない。
        XCTAssertNil(TimelinePlainMath.latex("\\frac{\\pi}{2}+1"))
        XCTAssertNil(TimelinePlainMath.latex("(1/2)π² + sin π(最終値は未記入)"))
        XCTAssertNil(TimelinePlainMath.latex("Yes"))
        XCTAssertNil(TimelinePlainMath.latex("(1/2"))
    }
}
