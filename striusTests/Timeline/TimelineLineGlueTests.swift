import XCTest
@testable import strius

/// 問いの文の、行中の式とその前後の語の間で行を折らない(#176)。文節の糊は `TimelineLinePhraseTests`。
final class TimelineLineGlueTests: XCTestCase {
    private let nbsp: String = "\u{00A0}"
    private let joiner: String = "\u{2060}"

    func testSpacesAroundInlineMathDoNotBreak() {
        let source: String = "点 $B$ に $q_B=-3.0\\times10^{-9}\\,\\mathrm{C}$ があります。"
        XCTAssertEqual(TimelineLineGlue.joinMath(source),
                       "点\(nbsp)$B$\(nbsp)に\(nbsp)$q_B=-3.0\\times10^{-9}\\,\\mathrm{C}$\(nbsp)があります。")
    }

    func testBreaksAfterPunctuationAndNewlineStay() {
        // 読点の後の空白と改行は残す(条件ごとの区切りでは折れてよい)。
        let source: String = "$q_A$、 $q_B$\n$r$"
        XCTAssertEqual(TimelineLineGlue.joinMath(source), "$q_A$、 $q_B$\n$r$")
    }

    func testJoinsMathToTextWithoutSpace() {
        XCTAssertEqual(TimelineLineGlue.joinMath("点$A$に"), "点\(joiner)$A$\(joiner)に")
    }

    func testDisplayMathAndEscapedDollarAreLeftAlone() {
        XCTAssertEqual(TimelineLineGlue.joinMath("次の式 $$x^2$$ を見なさい"), "次の式 $$x^2$$ を見なさい")
        XCTAssertEqual(TimelineLineGlue.joinMath("代金は \\$5 です"), "代金は \\$5 です")
    }

    func testTextWithoutMathIsUnchanged() {
        XCTAssertEqual(TimelineLineGlue.joinMath("次の問いに答えなさい。"), "次の問いに答えなさい。")
    }
}

/// 日本語の文節の途中では折らない(#176)。語の切れ目は端末の辞書で決まるので、折れてはいけない所だけを確かめる。
final class TimelineLinePhraseTests: XCTestCase {
    private let joiner: Character = "\u{2060}"

    /// 折れてよい位置(糊の無い文字の間)の、前の文字までの文字列。
    private func breakPoints(_ glued: String) -> [String] {
        var points: [String] = []
        var seen: String = ""
        var previous: Character?
        for character in glued {
            if let previous, previous != joiner, character != joiner { points.append(seen) }
            if character != joiner { seen.append(character) }
            previous = character
        }
        return points
    }

    func testParticlesStayWithTheWordBefore() {
        let points: [String] = breakPoints(TimelineLineGlue.apply("次の問いに答えなさい。"))
        XCTAssertFalse(points.contains("次の問い"), "「問い」と「に」の間で折れる: \(points)")
        XCTAssertFalse(points.contains("次"), "「次」と「の」の間で折れる: \(points)")
        XCTAssertFalse(points.contains("次の問いに答"), "「答え」の途中で折れる: \(points)")
    }

    func testWordsAreNotSplit() {
        let points: [String] = breakPoints(TimelineLineGlue.apply("軸上の原点に置きます。"))
        XCTAssertFalse(points.contains("軸上の原"), "「原点」の途中で折れる: \(points)")
    }

    func testNumberStaysWithItsCounter() {
        let points: [String] = breakPoints(TimelineLineGlue.apply("2点の電荷"))
        XCTAssertFalse(points.contains("2"), "「2」と「点」の間で折れる: \(points)")
    }

    func testMathIsLeftAlone() {
        let source: String = "$\\frac{1}{2}$"
        XCTAssertEqual(TimelineLineGlue.joinPhrases(source), source)
    }
}
