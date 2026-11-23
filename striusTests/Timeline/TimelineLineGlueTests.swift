import XCTest
@testable import strius

/// 問いの文の、行中の式とその前後の語の間で行を折らない(#176)。
final class TimelineLineGlueTests: XCTestCase {
    private let nbsp: String = "\u{00A0}"
    private let joiner: String = "\u{2060}"

    func testSpacesAroundInlineMathDoNotBreak() {
        let source: String = "点 $B$ に $q_B=-3.0\\times10^{-9}\\,\\mathrm{C}$ があります。"
        XCTAssertEqual(TimelineLineGlue.apply(source),
                       "点\(nbsp)$B$\(nbsp)に\(nbsp)$q_B=-3.0\\times10^{-9}\\,\\mathrm{C}$\(nbsp)があります。")
    }

    func testBreaksAfterPunctuationAndNewlineStay() {
        // 読点の後の空白と改行は残す(条件ごとの区切りでは折れてよい)。
        let source: String = "$q_A$、 $q_B$\n$r$"
        XCTAssertEqual(TimelineLineGlue.apply(source), "$q_A$、 $q_B$\n$r$")
    }

    func testJoinsMathToTextWithoutSpace() {
        XCTAssertEqual(TimelineLineGlue.apply("点$A$に"), "点\(joiner)$A$\(joiner)に")
    }

    func testDisplayMathAndEscapedDollarAreLeftAlone() {
        XCTAssertEqual(TimelineLineGlue.apply("次の式 $$x^2$$ を見なさい"), "次の式 $$x^2$$ を見なさい")
        XCTAssertEqual(TimelineLineGlue.apply("代金は \\$5 です"), "代金は \\$5 です")
    }

    func testTextWithoutMathIsUnchanged() {
        XCTAssertEqual(TimelineLineGlue.apply("次の問いに答えなさい。"), "次の問いに答えなさい。")
    }
}
