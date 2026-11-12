import XCTest
@testable import strius

/// 数の持ち方: 分数と平方根は誤差なしで計算する。
final class DrillNumberTests: XCTestCase {
    typealias S = DrillTestSupport

    func testRationalIsReducedWithPositiveDenominator() {
        XCTAssertEqual(S.rational(6, -4), S.rational(-3, 2))
        XCTAssertEqual(S.rational(6, -4).denominator, 2)
        XCTAssertNil(DrillRational(1, 0))
    }

    func testRationalArithmetic() {
        XCTAssertEqual(S.rational(1, 2).adding(S.rational(1, 3)), S.rational(5, 6))
        XCTAssertEqual(S.rational(1, 2).subtracting(S.rational(1, 3)), S.rational(1, 6))
        XCTAssertEqual(S.rational(2, 3).multiplied(by: S.rational(9, 4)), S.rational(3, 2))
        XCTAssertEqual(S.rational(2, 3).divided(by: S.rational(4, 9)), S.rational(3, 2))
        XCTAssertNil(S.rational(1).divided(by: DrillRational.zero))
        XCTAssertEqual(S.rational(-2, 3).power(3), S.rational(-8, 27))
        XCTAssertEqual(S.rational(2).power(-2), S.rational(1, 4))
        XCTAssertNil(DrillRational.zero.power(-1))
    }

    func testRationalOverflowReturnsNil() {
        XCTAssertNil(S.rational(Int.max - 1).adding(S.rational(Int.max - 1)))
        XCTAssertNil(S.rational(Int.max / 2).multiplied(by: S.rational(3)))
        XCTAssertNil(S.rational(10).power(40))
    }

    func testRationalRounding() {
        XCTAssertEqual(S.rational(-7, 2).floorValue, -4)
        XCTAssertEqual(S.rational(7, 2).floorValue, 3)
        XCTAssertEqual(S.rational(5, 2).roundedValue, 3)
        XCTAssertEqual(S.rational(-5, 2).roundedValue, -3)
        XCTAssertEqual(S.rational(7, 3).roundedValue, 2)
    }

    func testDecimalTextIsReadExactly() {
        XCTAssertEqual(DrillRational(decimal: "0.1"), S.rational(1, 10))
        XCTAssertEqual(DrillRational(decimal: "-2.50"), S.rational(-5, 2))
        XCTAssertEqual(DrillRational(decimal: "6.0e3"), S.rational(6000))
        XCTAssertEqual(DrillRational(decimal: "1e-14"), S.rational(1, 100_000_000_000_000))
        XCTAssertNil(DrillRational(decimal: "6.02e23"))
        XCTAssertNil(DrillRational(decimal: "abc"))
        XCTAssertEqual(DrillNumber(json: 0.1).rational, S.rational(1, 10))
        XCTAssertEqual(DrillNumber(json: 6.02e23), DrillNumber.real(6.02e23))
    }

    func testSquareRootIsSimplified() {
        // √12 = 2√3、√(1/2) = √2/2、√49 = 7
        XCTAssertEqual(DrillExact.squareRoot(of: S.rational(12)), DrillExact(terms: [3: S.rational(2)]))
        XCTAssertEqual(DrillExact.squareRoot(of: S.rational(1, 2)), DrillExact(terms: [2: S.rational(1, 2)]))
        XCTAssertEqual(DrillExact.squareRoot(of: S.rational(49)), DrillExact(integer: 7))
        XCTAssertEqual(DrillExact.squareRoot(of: S.rational(-4)), DrillExact(terms: [-1: S.rational(2)]))
    }

    func testSurdProductsAndReciprocals() throws {
        // √2 × √6 = 2√3
        let product: DrillExact = try XCTUnwrap(DrillExact(terms: [2: S.rational(1)]).multiplied(by: DrillExact(terms: [6: S.rational(1)])))
        XCTAssertEqual(product, DrillExact(terms: [3: S.rational(2)]))
        // 1 / (√3 + √2) = √3 - √2
        let inverse: DrillExact = try XCTUnwrap(DrillExact(terms: [3: S.rational(1), 2: S.rational(1)]).reciprocal)
        XCTAssertEqual(inverse, DrillExact(terms: [3: S.rational(1), 2: S.rational(-1)]))
        // 1 / √2 = √2 / 2
        XCTAssertEqual(DrillExact(terms: [2: S.rational(1)]).reciprocal, DrillExact(terms: [2: S.rational(1, 2)]))
        XCTAssertNil(DrillExact.zero.reciprocal)
    }

    func testComplexNumbersAreExact() throws {
        // i × i = -1、(1 + 2i)(3 - i) = 5 + 5i、(1 + 2i) / (3 - 4i) = -1/5 + 2/5 i
        let i: DrillExact = DrillExact.imaginaryUnit
        XCTAssertEqual(i.multiplied(by: i), DrillExact(integer: -1))
        XCTAssertEqual(try S.evaluate("(1 + 2*i) * (3 - i)"), try S.evaluate("5 + 5*i"))
        XCTAssertEqual(try S.evaluate("(1 + 2*i) / (3 - 4*i)"), try S.evaluate("-1/5 + 2/5*i"))
        XCTAssertEqual(try S.evaluate("abs(3 - 4*i)"), S.number(5))
        XCTAssertEqual(try S.evaluate("conj(2 + 3*i)"), try S.evaluate("2 - 3*i"))
        // √3 i × √3 i = -3
        XCTAssertEqual(try S.evaluate("csqrt(-3) * csqrt(-3)"), S.number(-3))
    }

    func testExactTrigonometry() throws {
        XCTAssertEqual(try S.evaluate("sind(30)"), S.number(1, 2))
        XCTAssertEqual(try S.evaluate("cosd(60)"), S.number(1, 2))
        XCTAssertEqual(try S.evaluate("sind(45)^2"), S.number(1, 2))
        XCTAssertEqual(try S.evaluate("tand(45)"), S.number(1))
        XCTAssertEqual(try S.evaluate("cosd(120)"), S.number(-1, 2))
        XCTAssertEqual(try S.evaluate("sind(-90)"), S.number(-1))
        // sin 75° = (√6 + √2) / 4、tan 15° = 2 - √3
        XCTAssertEqual(try S.tex("sind(75)"), "\\frac{\\sqrt{2}+\\sqrt{6}}{4}")
        XCTAssertEqual(try S.tex("tand(15)"), "2-\\sqrt{3}")
        XCTAssertThrowsError(try S.evaluate("tand(90)"))
        XCTAssertEqual(try S.evaluate("asind(1/2)"), S.number(30))
        XCTAssertEqual(try S.evaluate("acosd(-sqrt(2)/2)"), S.number(135))
    }

    func testExactLogarithms() throws {
        XCTAssertEqual(try S.evaluate("log(2, 8)"), S.number(3))
        XCTAssertEqual(try S.evaluate("log(4, 8)"), S.number(3, 2))
        XCTAssertEqual(try S.evaluate("log(3, 1/9)"), S.number(-2))
        XCTAssertEqual(try S.evaluate("log10(1000)"), S.number(3))
        XCTAssertEqual(try S.evaluate("ln(1)"), S.number(0))
        XCTAssertThrowsError(try S.evaluate("ln(0)"))
        XCTAssertThrowsError(try S.evaluate("log(1, 5)"))
    }

    func testPowers() throws {
        XCTAssertEqual(try S.evaluate("2^10"), S.number(1024))
        XCTAssertEqual(try S.evaluate("-2^2"), S.number(-4))
        XCTAssertEqual(try S.evaluate("(-2)^2"), S.number(4))
        XCTAssertEqual(try S.evaluate("2^-1"), S.number(1, 2))
        XCTAssertEqual(try S.evaluate("8^(2/3)"), S.number(4))
        XCTAssertEqual(try S.evaluate("(-8)^(1/3)"), S.number(-2))
        XCTAssertEqual(try S.evaluate("12^(1/2)"), try S.evaluate("2*sqrt(3)"))
        XCTAssertEqual(try S.evaluate("(1 + sqrt(2))^2"), try S.evaluate("3 + 2*sqrt(2)"))
        XCTAssertThrowsError(try S.evaluate("0^(-1)"))
        XCTAssertThrowsError(try S.evaluate("(-4)^(1/2)"))
    }
}
