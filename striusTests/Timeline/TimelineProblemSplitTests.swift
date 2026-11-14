import XCTest
@testable import strius

/// 組み替えたカードの元の問題(`TimelineCards.problemLine` が作る「問題文 + 空白 + `$式$`」)を、問題文と式に分ける。
final class TimelineProblemSplitTests: XCTestCase {
    func testSplitsTheMathAppendedByProblemLine() {
        let line = TimelineCards.problemLine(prompt: "次の2つの点電荷について、間に働く静電気力の種類を選びなさい。", math: "q_1 = +4\\,\\mu C, q_2 = -2\\,\\mu C")
        let parts = TimelineProblemView.split(line)
        XCTAssertEqual(parts.text, "次の2つの点電荷について、間に働く静電気力の種類を選びなさい。")
        XCTAssertEqual(parts.math, "q_1 = +4\\,\\mu C, q_2 = -2\\,\\mu C")
    }

    func testKeepsTextWithoutAppendedMath() {
        let parts = TimelineProblemView.split("片方の電荷だけを 2 倍にすると、クーロン力は何倍になりますか。")
        XCTAssertEqual(parts.text, "片方の電荷だけを 2 倍にすると、クーロン力は何倍になりますか。")
        XCTAssertEqual(parts.math, "")
    }

    func testMathOnly() {
        let parts = TimelineProblemView.split(TimelineCards.problemLine(prompt: "", math: "x^2-5x+6=0"))
        XCTAssertEqual(parts.text, "")
        XCTAssertEqual(parts.math, "x^2-5x+6=0")
    }

    func testDoesNotSplitMathInsideTheSentence() {
        // 空白を挟まずに文に続く式は、文の一部なので分けない。
        let parts = TimelineProblemView.split("関数は$f(x)=x^2$")
        XCTAssertEqual(parts.text, "関数は$f(x)=x^2$")
        XCTAssertEqual(parts.math, "")
        // 文の途中に式があっても、末尾に足した式だけを分ける。
        let mixed = TimelineProblemView.split("$a>0$ のとき、最小値を求めなさい。 $y=a(x-1)^2+3$")
        XCTAssertEqual(mixed.text, "$a>0$ のとき、最小値を求めなさい。")
        XCTAssertEqual(mixed.math, "y=a(x-1)^2+3")
    }

    func testDisplayMathIsLeftAlone() {
        let parts = TimelineProblemView.split("次の式を計算しなさい。 $$\\int_0^1 x\\,dx$$")
        XCTAssertEqual(parts.math, "")
    }
}
