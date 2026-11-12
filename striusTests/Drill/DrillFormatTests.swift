import XCTest
@testable import strius

/// 表示の整形規則: 係数 1 を書かない、+- を - にする、x^1 を x にする、0 の項を書かない、など。
final class DrillFormatTests: XCTestCase {
    typealias S = DrillTestSupport

    private func sum(_ terms: [DrillTerm], _ values: [(String, Int)]) throws -> String {
        let variables: [DrillVariable] = values.map { (name: String, value: Int) -> DrillVariable in S.integer(name, value, value) }
        let template: DrillTemplate = S.template(variables: variables, parts: [DrillPart(name: "f", kind: "sum", terms: terms)], math: "{f}", answer: "$0$")
        let problem: DrillProblem? = try S.problem(template, values: values.map { (_: String, value: Int) -> DrillValue in S.number(value) })
        return try XCTUnwrap(problem).math
    }

    private let quadratic: [DrillTerm] = [DrillTerm(coef: "a", body: "x^{2}"), DrillTerm(coef: "b", body: "x"), DrillTerm(coef: "c")]

    func testSumOmitsCoefficientOne() throws {
        XCTAssertEqual(try sum(quadratic, [("a", 1), ("b", 1), ("c", 1)]), "x^{2} + x + 1")
        XCTAssertEqual(try sum(quadratic, [("a", -1), ("b", -1), ("c", -1)]), "-x^{2} - x - 1")
    }

    func testSumTurnsPlusMinusIntoMinus() throws {
        XCTAssertEqual(try sum(quadratic, [("a", 2), ("b", -3), ("c", -5)]), "2x^{2} - 3x - 5")
    }

    func testSumSkipsZeroTerms() throws {
        XCTAssertEqual(try sum(quadratic, [("a", 2), ("b", 0), ("c", -5)]), "2x^{2} - 5")
        XCTAssertEqual(try sum(quadratic, [("a", 0), ("b", -1), ("c", 0)]), "-x")
        XCTAssertEqual(try sum(quadratic, [("a", 0), ("b", 0), ("c", 0)]), "0")
    }

    func testPowersDropExponentOneAndZero() throws {
        let terms: [DrillTerm] = [DrillTerm(coef: "a", powers: [DrillPower(base: "x", exp: "n"), DrillPower(base: "y", exp: "m")])]
        XCTAssertEqual(try sum(terms, [("a", 3), ("n", 2), ("m", 1)]), "3x^{2}y")
        XCTAssertEqual(try sum(terms, [("a", 1), ("n", 1), ("m", 0)]), "x")
        XCTAssertEqual(try sum(terms, [("a", -1), ("n", 0), ("m", 0)]), "-1")
        XCTAssertEqual(try sum(terms, [("a", 2), ("n", 12), ("m", -1)]), "2x^{12}y^{-1}")
    }

    func testTimesPutsADotBeforeNumbers() throws {
        let terms: [DrillTerm] = [DrillTerm(coef: "a", body: "2^{n-1}", times: true), DrillTerm(coef: "c")]
        XCTAssertEqual(try sum(terms, [("a", 3), ("c", 1)]), "3 \\cdot 2^{n-1} + 1")
        XCTAssertEqual(try sum(terms, [("a", 1), ("c", -1)]), "2^{n-1} - 1")
    }

    func testFractionAndSurdCoefficients() throws {
        let terms: [DrillTerm] = [DrillTerm(coef: "a/2", body: "x"), DrillTerm(coef: "sqrt(b)", body: "y"), DrillTerm(coef: "-1/3")]
        XCTAssertEqual(try sum(terms, [("a", 3), ("b", 12)]), "\\frac{3}{2}x + 2\\sqrt{3}y - \\frac{1}{3}")
        XCTAssertEqual(try sum(terms, [("a", 2), ("b", 1)]), "x + y - \\frac{1}{3}")
    }

    func testNumberForms() throws {
        XCTAssertEqual(try S.tex("-3/4"), "-\\frac{3}{4}")
        XCTAssertEqual(try S.tex("6/3"), "2")
        XCTAssertEqual(try S.tex("sqrt(12)"), "2\\sqrt{3}")
        XCTAssertEqual(try S.tex("sqrt(1/2)"), "\\frac{\\sqrt{2}}{2}")
        XCTAssertEqual(try S.tex("-sqrt(3)/2"), "-\\frac{\\sqrt{3}}{2}")
        XCTAssertEqual(try S.tex("(1 + sqrt(5))/2"), "\\frac{1+\\sqrt{5}}{2}")
        XCTAssertEqual(try S.tex("(1 - sqrt(5))/2"), "\\frac{1-\\sqrt{5}}{2}")
        XCTAssertEqual(try S.tex("-1 - sqrt(2)"), "-(1+\\sqrt{2})")
        XCTAssertEqual(try S.tex("2 + 3*i"), "2+3i")
        XCTAssertEqual(try S.tex("-i"), "-i")
        XCTAssertEqual(try S.tex("(1 - csqrt(-3))/2"), "\\frac{1}{2}-\\frac{\\sqrt{3}}{2}i")
        // 実部・虚部がそれぞれ 2 項になる複素数。実部の符号は項ごとに付ける(-√2-√6 を -√2+√6 と書かない)。
        XCTAssertEqual(try S.tex("(-2 - 2*sqrt(3)*i) * (sqrt(2)/2 - sqrt(2)/2*i)"), "-\\sqrt{2}-\\sqrt{6}+(\\sqrt{2}-\\sqrt{6})i")
        XCTAssertEqual(try S.tex("(sind(15) + i*sind(75)) * -1"), "\\frac{\\sqrt{2}-\\sqrt{6}}{4}-\\frac{\\sqrt{2}+\\sqrt{6}}{4}i")
        XCTAssertEqual(try S.tex("-sqrt(2) - sqrt(6) - (sqrt(2) + sqrt(3))*i"), "-\\sqrt{2}-\\sqrt{6}-(\\sqrt{2}+\\sqrt{3})i")
    }

    func testSignModes() throws {
        XCTAssertEqual(try S.tex("3", ["+"]), "+3")
        XCTAssertEqual(try S.tex("-3", ["+"]), "-3")
        XCTAssertEqual(try S.tex("1", ["coef"]), "")
        XCTAssertEqual(try S.tex("-1", ["coef"]), "-")
        XCTAssertEqual(try S.tex("-1", ["+coef"]), "-")
        XCTAssertEqual(try S.tex("1", ["+coef"]), "+")
        XCTAssertEqual(try S.tex("5/2", ["+coef"]), "+\\frac{5}{2}")
        XCTAssertEqual(try S.tex("-3", ["paren"]), "(-3)")
        XCTAssertEqual(try S.tex("3", ["paren"]), "3")
        XCTAssertEqual(try S.tex("3", ["+paren"]), "(+3)")
        XCTAssertEqual(try S.tex("-1/2", ["+paren"]), "(-\\frac{1}{2})")
        // 項が 2 つ以上の数は、正でもかっこで囲む。全部の項が負なら、符号を中に配る(前は -1-√2 を (-1+√2) と出していた)。
        XCTAssertEqual(try S.tex("-1 - sqrt(2)", ["paren"]), "(-1-\\sqrt{2})")
        XCTAssertEqual(try S.tex("1 + sqrt(2)", ["paren"]), "(1+\\sqrt{2})")
        XCTAssertEqual(try S.tex("-1 + sqrt(2)", ["paren"]), "(-1+\\sqrt{2})")
        XCTAssertEqual(try S.tex("-1 - sqrt(2)", ["+paren"]), "(-1-\\sqrt{2})")
        XCTAssertEqual(try S.tex("1 + sqrt(2)", ["+paren"]), "(+1+\\sqrt{2})")
        XCTAssertEqual(try S.tex("(-1 - sqrt(5))/2", ["paren"]), "(-\\frac{1+\\sqrt{5}}{2})")
        XCTAssertEqual(try S.tex("2 + 3*i", ["paren"]), "(2+3i)")
        XCTAssertEqual(try S.tex("-1 - sqrt(2)"), "-(1+\\sqrt{2})")
        XCTAssertEqual(try S.tex("-3", ["abs"]), "3")
        XCTAssertEqual(try S.tex("1 + sqrt(2)", ["coef"]), "(1+\\sqrt{2})")
    }

    func testDecimals() throws {
        XCTAssertEqual(try S.tex("1/4", ["dec"]), "0.25")
        XCTAssertEqual(try S.tex("3", ["dec"]), "3")
        XCTAssertEqual(try S.tex("2/3", ["dec:2"]), "0.67")
        XCTAssertEqual(try S.tex("-0.125", ["dec:2"]), "-0.13")
        XCTAssertEqual(try S.tex("2", ["dec:1"]), "2.0")
        XCTAssertEqual(try S.tex("-0.04", ["dec:1"]), "0.0")
        XCTAssertEqual(try S.tex("ln(2)", ["dec:3"]), "0.693")
        XCTAssertThrowsError(try S.tex("1/3", ["dec"]))
        XCTAssertThrowsError(try S.tex("ln(2)"))
    }

    func testSignificantFigures() throws {
        XCTAssertEqual(try S.tex("2", ["sig:2"]), "2.0")
        XCTAssertEqual(try S.tex("17", ["sig:2"]), "17")
        XCTAssertEqual(try S.tex("19.6", ["sig:2"]), "20")
        XCTAssertEqual(try S.tex("0.0123", ["sig:2"]), "0.012")
        XCTAssertEqual(try S.tex("340", ["sig:2"]), "3.4 \\times 10^{2}")
        XCTAssertEqual(try S.tex("299792458", ["sig:2"]), "3.0 \\times 10^{8}")
        XCTAssertEqual(try S.tex("0.00012", ["sig:2"]), "1.2 \\times 10^{-4}")
        XCTAssertEqual(try S.tex("99.96", ["sig:3"]), "100")
        XCTAssertEqual(try S.tex("0.0995", ["sig:2"]), "0.10")
        XCTAssertEqual(try S.tex("25", ["sci:2"]), "2.5 \\times 10")
        XCTAssertEqual(try S.tex("6.02e23", ["sig:3"]), "6.02 \\times 10^{23}")
        XCTAssertEqual(try S.tex("0", ["sig:2"]), "0.0")
        XCTAssertEqual(try S.tex("-9.8", ["sig:2"]), "-9.8")
        XCTAssertEqual(try S.tex("sqrt(2)", ["sig:3"]), "1.41")
        // a × 10^n は、絶対値や符号つきではかっこを付けず、係数として使う時だけかっこで囲む。
        XCTAssertEqual(try S.tex("-1200", ["abs", "sig:2"]), "1.2 \\times 10^{3}")
        XCTAssertEqual(try S.tex("-1200", ["sig:2"]), "-1.2 \\times 10^{3}")
        XCTAssertEqual(try S.tex("1200", ["+", "sig:2"]), "+1.2 \\times 10^{3}")
        XCTAssertEqual(try S.tex("1200", ["coef", "sig:2"]), "(1.2 \\times 10^{3})")
    }

    func testTinyAndHugeConstantsStayExact() throws {
        // 6.6 × 10⁻³⁴ のような定数は Int に収まらないが、Int128 の分数で誤差なしに持つ。丸めの境目(2.25 → 2.3)もぶれない。
        XCTAssertEqual(try S.tex("2.5e-30 * 3.0e8^2", ["sig:2"]), "2.3 \\times 10^{-13}")
        XCTAssertEqual(try S.tex("6.6e-34 * 3.0e8 / 3.0e-7", ["sig:2"]), "6.6 \\times 10^{-19}")
        XCTAssertEqual(try S.tex("6.02e23 * 0.25", ["sig:3"]), "1.51 \\times 10^{23}")
        XCTAssertEqual(try S.tex("1.6e-19 * 1.0e7 * 5.0e-3", ["sig:2"]), "8.0 \\times 10^{-15}")
        // Int に収まる所まで戻れば、普通の分数として扱う。
        XCTAssertEqual(try S.evaluate("6.6e-34 / 6.6e-34 * 3"), S.number(3))
        XCTAssertEqual(try S.evaluate("6.6e-34 * 2 == 13.2e-34"), DrillValue.bool(true))
        XCTAssertEqual(try S.evaluate("6.6e-34 < 1"), DrillValue.bool(true))
        // 桁を決めずには表示できない。
        XCTAssertThrowsError(try S.tex("6.6e-34"))
    }

    func testRoundingAtTheBoundaryIsRejectedForRealNumbers() {
        // 誤差なしの 2.5 は 3 に丸められる。実数の計算で 2.5 になった値は、誤差でどちらにも転ぶので断る。
        XCTAssertEqual(try S.tex("2.5", ["sig:1"]), "3")
        XCTAssertThrowsError(try S.tex("5 * sin(pi / 6)", ["sig:1"]))
    }

    func testPiForms() throws {
        XCTAssertEqual(try S.tex("2", ["pi"]), "2\\pi")
        XCTAssertEqual(try S.tex("1", ["pi"]), "\\pi")
        XCTAssertEqual(try S.tex("1/3", ["pi"]), "\\frac{\\pi}{3}")
        XCTAssertEqual(try S.tex("-2/3", ["pi"]), "-\\frac{2}{3}\\pi")
        XCTAssertEqual(try S.tex("0", ["pi"]), "0")
        XCTAssertEqual(try S.tex("4", ["overpi"]), "\\frac{4}{\\pi}")
        XCTAssertEqual(try S.tex("-2/3", ["overpi"]), "-\\frac{2}{3\\pi}")
    }

    func testPlusMinus() throws {
        XCTAssertEqual(try DrillCompiledTemplate.plusMinus(center: S.rational(-1, 2), radicand: S.rational(5), scale: S.rational(1, 2)), "\\frac{-1 \\pm \\sqrt{5}}{2}")
        XCTAssertEqual(try DrillCompiledTemplate.plusMinus(center: S.rational(1), radicand: S.rational(8), scale: S.rational(1, 2)), "1 \\pm \\sqrt{2}")
        XCTAssertEqual(try DrillCompiledTemplate.plusMinus(center: S.rational(0), radicand: S.rational(6), scale: S.rational(1, 2)), "\\pm \\frac{\\sqrt{6}}{2}")
        XCTAssertEqual(try DrillCompiledTemplate.plusMinus(center: S.rational(-1, 2), radicand: S.rational(-3), scale: S.rational(1, 2)), "\\frac{-1 \\pm \\sqrt{3}i}{2}")
        XCTAssertEqual(try DrillCompiledTemplate.plusMinus(center: S.rational(2), radicand: S.rational(-4), scale: S.rational(1)), "2 \\pm 2i")
        // 根号が外れる時は、2 つの値を小さい順に並べる。
        XCTAssertEqual(try DrillCompiledTemplate.plusMinus(center: S.rational(1), radicand: S.rational(9), scale: S.rational(1)), "-2,\\ 4")
        XCTAssertEqual(try DrillCompiledTemplate.plusMinus(center: S.rational(3), radicand: S.rational(0), scale: S.rational(1)), "3")
    }

    // MARK: 差し込み

    func testPlaceholderKeepsBracesAfterScriptsAndCommands() throws {
        let template: DrillTemplate = S.template(variables: [S.integer("n", 12, 12), S.integer("d", 15, 15)], math: "x^{n} + a_{n} + \\frac{n}{d} + \\sqrt{d} + {n}", answer: "$0$")
        let problem: DrillProblem = try XCTUnwrap(try S.problem(template, values: [S.number(12), S.number(15)]))
        XCTAssertEqual(problem.math, "x^{12} + a_{12} + \\frac{12}{15} + \\sqrt{15} + 12")
    }

    func testNamesInsideTextCommandsAreNotPlaceholders() throws {
        // \mathrm{pH} の pH、\vec{a} の a は、同じ名前の変数があっても文字のまま。
        let template: DrillTemplate = S.template(variables: [S.integer("pH", 3, 3), S.integer("a", 2, 2)], math: "\\mathrm{pH} = {pH},\\ \\vec{a} = {a}", answer: "$0$")
        let problem: DrillProblem = try XCTUnwrap(try S.problem(template, values: [S.number(3), S.number(2)]))
        XCTAssertEqual(problem.math, "\\mathrm{pH} = 3,\\ \\vec{a} = 2")
    }

    func testUndeclaredBracesStayAsLaTeX() throws {
        let template: DrillTemplate = S.template(variables: [S.integer("k", 2, 2)], math: "\\frac{x}{y} + {k}^{m}", answer: "$0$")
        let problem: DrillProblem = try XCTUnwrap(try S.problem(template, values: [S.number(2)]))
        XCTAssertEqual(problem.math, "\\frac{x}{y} + 2^{m}")
    }

    func testUnknownPlaceholderWithFormatIsRejected() {
        let template: DrillTemplate = S.template(variables: [S.integer("k", 2, 2)], math: "{missing|coef}x", answer: "$0$")
        XCTAssertThrowsError(try DrillCompiledTemplate(template))
        let unknownFormat: DrillTemplate = S.template(variables: [S.integer("k", 2, 2)], math: "{k|bold}x", answer: "$0$")
        XCTAssertThrowsError(try DrillCompiledTemplate(unknownFormat))
    }

    func testPartsCanBeParenthesized() throws {
        let parts: [DrillPart] = [
            DrillPart(name: "p", kind: "sum", terms: [DrillTerm(coef: "1", body: "x"), DrillTerm(coef: "a")]),
            DrillPart(name: "single", kind: "sum", terms: [DrillTerm(coef: "b", body: "x")]),
        ]
        let template: DrillTemplate = S.template(variables: [S.integer("a", -3, 3), S.integer("b", -3, 3)], parts: parts, math: "{b|coef}{p|paren} + 2{single|paren}", answer: "$0$")
        XCTAssertEqual(try S.problem(template, values: [S.number(-2), S.number(-1)])?.math, "-(x - 2) + 2(-x)")
        XCTAssertEqual(try S.problem(template, values: [S.number(3), S.number(1)])?.math, "(x + 3) + 2x")
    }

    func testQuantityDisplay() throws {
        let variables: [DrillVariable] = [
            DrillVariable(name: "m", kind: "decimal", min: 2.0, max: 2.0, step: 0.5, unit: "kg", sig: 2),
            DrillVariable(name: "v", kind: "integer", min: 72, max: 72, unit: "km/h"),
            DrillVariable(name: "g", kind: "constant", value: 9.8, unit: "m/s^2", sig: 2),
        ]
        let lets: [DrillLet] = [DrillLet(name: "w", expr: "m * g", unit: "N", sig: 2), DrillLet(name: "u", expr: "v", unit: "m/s"), DrillLet(name: "k", expr: "m * u^2 / 2", unit: "J", sig: 2)]
        let template: DrillTemplate = S.template(variables: variables, lets: lets, prompt: "質量 ${m|q}$、速さ ${v|q}$、重力加速度 ${g|q}$", math: "", answer: "${w|q}$、${u|q}$、${k|q}$、${k|unit}$")
        let problem: DrillProblem = try S.problem(template)
        XCTAssertEqual(problem.prompt, "質量 $2.0\\,\\mathrm{kg}$、速さ $72\\,\\mathrm{km/h}$、重力加速度 $9.8\\,\\mathrm{m/s^{2}}$")
        XCTAssertEqual(problem.answer, "$20\\,\\mathrm{N}$、$20\\,\\mathrm{m/s}$、$4.0 \\times 10^{2}\\,\\mathrm{J}$、$\\mathrm{J}$")
    }

    func testLetUnitMustMatchDimension() throws {
        let variables: [DrillVariable] = [DrillVariable(name: "m", kind: "integer", min: 1, max: 30, unit: "kg"), DrillVariable(name: "a", kind: "integer", min: 1, max: 9, unit: "m/s^2")]
        let wrong: DrillTemplate = S.template(variables: variables, lets: [DrillLet(name: "f", expr: "m * a", unit: "J")], prompt: "${m|q}$ ${a|q}$", math: "", answer: "${f|q}$")
        XCTAssertThrowsError(try S.problem(wrong, values: [S.number(1), S.number(1)])) { (error: Error) -> Void in
            XCTAssertTrue((error as? DrillFailure)?.message.contains("単位「J」が合いません") ?? false, "\(error)")
        }
    }


    /// abs は、値の絶対値を取ってから書く(前は符号を外すだけで、1-√2 が (1-√2) のまま、3+4i が (3+4i) のままだった)。
    func testAbsoluteValueIsTakenFromTheValue() throws {
        XCTAssertEqual(try S.tex("-3", ["abs"]), "3")
        XCTAssertEqual(try S.tex("1 - sqrt(2)", ["abs"]), "-1+\\sqrt{2}")
        XCTAssertEqual(try S.tex("-1 - sqrt(2)", ["abs"]), "1+\\sqrt{2}")
        XCTAssertEqual(try S.tex("3 + 4*i", ["abs"]), "5")
        XCTAssertEqual(try S.tex("-3/4", ["abs"]), "\\frac{3}{4}")
        XCTAssertEqual(try S.evaluate("abs(1 - sqrt(2)) == sqrt(2) - 1"), DrillValue.bool(true))
        XCTAssertEqual(try S.evaluate("abs(3 + 4*i)"), S.number(5))
    }
}
