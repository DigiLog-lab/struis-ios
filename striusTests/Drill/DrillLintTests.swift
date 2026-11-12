import XCTest
@testable import strius

/// 表示の点検: 崩れた表示を見つけ、正しい表示は通す。
final class DrillLintTests: XCTestCase {
    private func found(_ math: String, answer: Bool = false) -> [String] {
        DrillLint.mathIssues(math, isAnswer: answer)
    }

    private func assertClean(_ math: String, answer: Bool = false, line: UInt = #line) {
        XCTAssertEqual(found(math, answer: answer), [], math, line: line)
    }

    private func assertFlagged(_ math: String, _ expected: String, answer: Bool = false, line: UInt = #line) {
        let issues: [String] = found(math, answer: answer)
        XCTAssertTrue(issues.contains { (issue: String) -> Bool in issue.contains(expected) }, "\(math): \(issues)", line: line)
    }

    func testCleanExpressions() {
        for math: String in [
            "2x^{2} - 3x + 1", "y = -(x - 2)^{2} + 5", "\\frac{-1 \\pm \\sqrt{5}}{2}", "(-3) + (+5) - (-2)", "3 \\times (-2)",
            "\\int_{0}^{1} (3x^{2} - 2x)\\,dx", "\\sum_{k=1}^{10} k^{2}", "\\left[ x^{3} \\right]_{0}^{1}", "x_{1} + x_1 y", "10x + 100y - 0.5z",
            "2.0\\,\\mathrm{kg}", "1\\,\\mathrm{mol}", "1.0 \\times 10^{-14}", "3.0 \\times 10\\,\\mathrm{m/s}", "\\mathrm{H_2O}", "2\\mathrm{H_2} + \\mathrm{O_2} \\longrightarrow 2\\mathrm{H_2O}",
            "\\begin{pmatrix} 1 & 0 \\\\ 0 & 1 \\end{pmatrix}", "\\begin{cases} x + y = 1 \\\\ x - y = 0 \\end{cases}", "0 < x < 1", "x = 0,\\ 1", "f(1) = 0", "(1,\\ 2)",
            "\\sin 30^{\\circ}", "25^{\\circ}\\mathrm{C}", "\\log_{10} 2", "a_{n} = 3 \\cdot 2^{n-1}", "e^{-x}", "x^{-1}", "{}_{5}\\mathrm{C}_{2}", "\\vec{a} \\cdot \\vec{b}",
            "\\text{右向きに } 3.0\\,\\mathrm{N}", "1 - x", "x - 1", "\\frac{1}{x}", "\\frac{x + 1}{-x + 2}",
        ] {
            assertClean(math)
        }
        assertClean("\\frac{2}{3}", answer: true)
        assertClean("2\\sqrt{3}", answer: true)
        assertClean("\\frac{\\sqrt{6}}{3}", answer: true)
    }

    func testSigns() {
        assertFlagged("x^{2} + -3x", "符号が重なっています")
        assertFlagged("x - -3", "符号が重なっています")
        assertFlagged("3 \\times -2", "かっこで囲みます")
        assertFlagged("x^{2} + 0", "0 を足したり引いたりしています")
        assertFlagged("x = -0", "-0")
    }

    func testCoefficients() {
        assertFlagged("1x + 2", "係数の 1 は書きません")
        assertFlagged("y = -1x", "係数の 1 は書きません")
        assertFlagged("1\\sqrt{2}", "係数の 1 は書きません")
        assertFlagged("1(x + 2)", "係数の 1 は書きません")
        assertFlagged("0x + 3", "係数が 0 の項があります")
        assertFlagged("3 + 0\\pi", "係数が 0 の項があります")
    }

    func testExponents() {
        assertFlagged("x^{1} + 2", "1 乗は指数を書きません")
        assertFlagged("x^1 + 2", "1 乗は指数を書きません")
        assertFlagged("x^{0}", "0 乗になっている")
        assertFlagged("x^12", "波かっこで囲みます")
    }

    func testFractionsAndRoots() {
        assertFlagged("\\frac{x}{1}", "分母が 1 の分数")
        assertFlagged("\\frac{0}{3}", "分子が 0 の分数")
        assertFlagged("\\frac{3}{-4}", "分母が負の数")
        assertFlagged("\\frac{}{2}", "空です")
        assertFlagged("\\sqrt{-4}", "根号の中が負の数")
        assertFlagged("\\frac{6}{4}", "約分できる分数", answer: true)
        assertFlagged("\\sqrt{12}", "平方根が整理されていません", answer: true)
        assertFlagged("\\sqrt{1}", "\\sqrt{1} は 1 と書きます", answer: true)
        // 問題文では、約分や整理の前の形を見せてよい。
        assertClean("\\frac{6}{4} + \\sqrt{12}")
    }

    func testStructure() {
        assertFlagged("\\frac{1}{2", "波かっこが閉じていません")
        assertFlagged("x^{2}}", "波かっこ「}」が多すぎます")
        assertFlagged("f() + 1", "空のかっこ")
        assertFlagged("x + {} y", "空の波かっこ")
        assertFlagged("\\dfrac{1}{2} + \\badcommand{x}", "命令「\\badcommand」は画面で描けません")
        assertFlagged("\\begin{tabular} x \\end{tabular}", "環境「tabular」は画面で描けません")
        assertFlagged("x = nan", "値が数になっていません")
        assertFlagged("0.30000000000000004", "小数の桁が多すぎます")
    }

    func testMixedText() {
        func issues(prompt: String = "計算しなさい。", math: String = "", answer: String = "$1$") -> [String] {
            DrillLint.issues(in: DrillProblem(prompt: prompt, math: math, answer: answer))
        }
        XCTAssertEqual(issues(prompt: "質量 $2.0\\,\\mathrm{kg}$ の物体に $3.0\\,\\mathrm{N}$ の力を加えた。", answer: "右向きに $1.5\\,\\mathrm{m/s^{2}}$"), [])
        XCTAssertTrue(issues(prompt: "式 $x + 1 を計算").contains { (issue: String) -> Bool in issue.contains("「$」が閉じていません") })
        XCTAssertTrue(issues(prompt: "x^{2} を微分しなさい。").contains { (issue: String) -> Bool in issue.contains("「$…$」の外") })
        XCTAssertTrue(issues(answer: "\\frac{1}{2}").contains { (issue: String) -> Bool in issue.contains("「$…$」の外") })
        XCTAssertTrue(issues(math: "$x + 1$").contains { (issue: String) -> Bool in issue.contains("「$」は要りません") })
        XCTAssertTrue(issues(prompt: " ").contains("問題文が空です"))
        XCTAssertTrue(issues(answer: "$\\sqrt{8}$").contains { (issue: String) -> Bool in issue.contains("平方根が整理されていません") })
    }
}
