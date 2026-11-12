import XCTest
@testable import strius

/// 型の式: 許した演算と関数だけを読み、値が定まらない時と次元が合わない時は投げる。
final class DrillExpressionTests: XCTestCase {
    typealias S = DrillTestSupport

    func testArithmeticAndPrecedence() throws {
        XCTAssertEqual(try S.evaluate("1 + 2 * 3"), S.number(7))
        XCTAssertEqual(try S.evaluate("(1 + 2) * 3"), S.number(9))
        XCTAssertEqual(try S.evaluate("7 / 2"), S.number(7, 2))
        XCTAssertEqual(try S.evaluate("0.1 + 0.2"), S.number(3, 10))
        XCTAssertEqual(try S.evaluate("2 * a - b", ["a": S.number(3), "b": S.number(-4)]), S.number(10))
        XCTAssertEqual(try S.evaluate("1.5e2"), S.number(150))
    }

    func testComparisonsAndLogic() throws {
        XCTAssertEqual(try S.evaluate("1/3 < 0.34 and not (2 == 3)"), DrillValue.bool(true))
        XCTAssertEqual(try S.evaluate("1 > 2 or 2 >= 2"), DrillValue.bool(true))
        XCTAssertEqual(try S.evaluate("sqrt(2) * sqrt(2) == 2"), DrillValue.bool(true))
        XCTAssertEqual(try S.evaluate("'sin' == 'cos'"), DrillValue.bool(false))
        XCTAssertEqual(try S.evaluate("if(1 < 2, 10, 20)"), S.number(10))
        // == は誤差なしの数どうしを厳密に比べる。approx は数値として近いかで比べる。
        XCTAssertEqual(try S.evaluate("1/3 == 0.3333333333"), DrillValue.bool(false))
        XCTAssertEqual(try S.evaluate("approx(1/3, 0.3333333333)"), DrillValue.bool(true))
        XCTAssertEqual(try S.evaluate("approx(1.414 * sind(45), 1, 0.001)"), DrillValue.bool(true))
        XCTAssertEqual(try S.evaluate("approx(1.5, 1, 0.001)"), DrillValue.bool(false))
        // 条件で選ばれなかった側は評価しない(0 で割る式があっても投げない)。
        XCTAssertEqual(try S.evaluate("if(true, 1, 1/0)"), S.number(1))
    }

    func testIntegerFunctions() throws {
        XCTAssertEqual(try S.evaluate("gcd(12, 18)"), S.number(6))
        XCTAssertEqual(try S.evaluate("lcm(4, 6, 10)"), S.number(60))
        XCTAssertEqual(try S.evaluate("mod(-7, 3)"), S.number(2))
        XCTAssertEqual(try S.evaluate("quot(-7, 3)"), S.number(-3))
        XCTAssertEqual(try S.evaluate("factorial(5)"), S.number(120))
        XCTAssertEqual(try S.evaluate("comb(6, 2)"), S.number(15))
        XCTAssertEqual(try S.evaluate("perm(6, 2)"), S.number(30))
        XCTAssertEqual(try S.evaluate("num(6/8) + den(6/8)"), S.number(7))
        XCTAssertEqual(try S.evaluate("is_square(49/4)"), DrillValue.bool(true))
        XCTAssertEqual(try S.evaluate("is_square(12)"), DrillValue.bool(false))
        XCTAssertEqual(try S.evaluate("is_prime(97)"), DrillValue.bool(true))
        XCTAssertEqual(try S.evaluate("to_base(5, 2)"), S.number(101))
        XCTAssertEqual(try S.evaluate("median(5, 1, 4, 2)"), S.number(3))
        XCTAssertEqual(try S.evaluate("max(1/2, 1/3, 0.4)"), S.number(1, 2))
        XCTAssertEqual(try S.evaluate("floor(-7/2) + ceil(7/2)"), S.number(0))
        XCTAssertEqual(try S.evaluate("round(2.345, 2)"), S.number(47, 20))
        XCTAssertEqual(try S.evaluate("sig(1234, 2)"), S.number(1200))
    }

    func testRecordFields() throws {
        let record: DrillValue = DrillValue.record(["tex": DrillValue.text("\\sin"), "sign": S.number(-1)])
        XCTAssertEqual(try S.evaluate("f.sign * 3", ["f": record]), S.number(-3))
        XCTAssertEqual(try S.evaluate("f.tex == '\\sin'", ["f": record]), DrillValue.bool(true))
        XCTAssertThrowsError(try S.evaluate("f.missing", ["f": record]))
    }

    func testUndefinedValuesThrow() {
        for source: String in ["1 / 0", "sqrt(-1)", "ln(-2)", "asin(2)", "factorial(-1)", "comb(3, 5)", "mod(3, 0)", "1 / (2 - 2)"] {
            XCTAssertThrowsError(try S.evaluate(source), source) { (error: Error) -> Void in
                guard case DrillExpression.EvaluationError.undefined = error else { return XCTFail("\(source): \(error)") }
            }
        }
    }

    func testSyntaxErrors() {
        // 掛け算の「*」は省けない。知らない文字も読まない。
        for source: String in ["2x", "(1 + 2", "1 +", "a b", "1 $ 2", ""] {
            XCTAssertThrowsError(try DrillExpression.parse(source), source)
        }
        XCTAssertThrowsError(try S.evaluate("unknown + 1")) { (error: Error) -> Void in
            XCTAssertEqual(error as? DrillExpression.EvaluationError, DrillExpression.EvaluationError.unknownName("unknown"))
        }
        XCTAssertThrowsError(try S.evaluate("system(1)")) { (error: Error) -> Void in
            XCTAssertEqual(error as? DrillExpression.EvaluationError, DrillExpression.EvaluationError.unknownFunction("system"))
        }
    }

    func testNamesAreCollected() throws {
        XCTAssertEqual(try DrillExpression.parse("a * sqrt(b) + f.sign - pi").names, ["a", "b", "f", "pi"])
        XCTAssertEqual(try DrillExpression.parse("gcd(a, max(b, 2))").functionNames, ["gcd", "max"])
    }

    // MARK: 単位

    func testQuantitiesCarryDimensions() throws {
        // F = m a: 2 kg × 3 m/s² = 6 N
        let force: DrillValue = try S.evaluate("q(2, 'kg') * q(3, 'm/s^2')")
        XCTAssertEqual(try S.evaluate("value(f, 'N')", ["f": force]), S.number(6))
        // 72 km/h = 20 m/s
        XCTAssertEqual(try S.evaluate("value(q(72, 'km/h'), 'm/s')"), S.number(20))
        // 0.50 mol/L × 200 mL = 0.10 mol
        XCTAssertEqual(try S.evaluate("value(q(0.5, 'mol/L') * q(200, 'mL'), 'mol')"), S.number(1, 10))
        // 周期 T = 2π√(L/g) の次元は秒
        XCTAssertNoThrow(try S.evaluate("value(2 * pi * sqrt(q(1, 'm') / q(9.8, 'm/s^2')), 's')"))
        // 運動エネルギー (1/2) m v² は J
        XCTAssertEqual(try S.evaluate("value(q(2, 'kg') * q(3, 'm/s')^2 / 2, 'J')"), S.number(9))
    }

    func testDimensionMismatchThrows() {
        for source: String in ["q(1, 'm') + q(1, 's')", "q(1, 'm') < q(1, 'kg')", "value(q(1, 'm'), 's')", "sin(q(1, 'm'))", "2 ^ q(1, 'm')", "q(1, 'm') + 1"] {
            XCTAssertThrowsError(try S.evaluate(source), source) { (error: Error) -> Void in
                guard case DrillExpression.EvaluationError.dimension = error else { return XCTFail("\(source): \(error)") }
            }
        }
        // 0 はどの次元とも足せる・比べられる。
        XCTAssertNoThrow(try S.evaluate("q(3, 'm') > 0"))
    }

    func testUnitsParse() throws {
        XCTAssertEqual(try DrillUnit.parse("kg*m/s^2").dimension, try DrillUnit.parse("N").dimension)
        XCTAssertEqual(try DrillUnit.parse("J/(mol*K)").dimension, try DrillUnit.parse("Pa*m^3/(mol*K)").dimension)
        XCTAssertEqual(try DrillUnit.parse("km").scale, DrillNumber(integer: 1000))
        XCTAssertEqual(try DrillUnit.parse("mL").scale.rational, S.rational(1, 1_000_000))
        XCTAssertEqual(try DrillUnit.parse("uF").scale.rational, S.rational(1, 1_000_000))
        XCTAssertEqual(try DrillUnit.parse("1/mol").dimension, try DrillUnit.parse("mol").dimension.power(S.rational(-1)))
        XCTAssertThrowsError(try DrillUnit.parse("furlong"))
        XCTAssertThrowsError(try DrillUnit.parse("m/"))
    }

    func testUnitTeX() throws {
        XCTAssertEqual(try DrillUnit.parse("m/s^2").tex, "\\mathrm{m/s^{2}}")
        XCTAssertEqual(try DrillUnit.parse("kg*m/s^2").tex, "\\mathrm{kg \\cdot m/s^{2}}")
        XCTAssertEqual(try DrillUnit.parse("J/(mol*K)").tex, "\\mathrm{J/(mol \\cdot K)}")
        XCTAssertEqual(try DrillUnit.parse("ohm").tex, "\\mathrm{\\Omega }")
        XCTAssertEqual(try DrillUnit.parse("uF").tex, "\\mathrm{\\mu F}")
        XCTAssertEqual(try DrillUnit.parse("deg").tex, "^{\\circ}")
    }
}
