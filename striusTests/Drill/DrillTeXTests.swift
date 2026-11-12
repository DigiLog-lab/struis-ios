import XCTest
@testable import strius

/// 画面に出す LaTeX の式を数値にする(数値の点検に使う)。
final class DrillTeXTests: XCTestCase {
    private func value(_ source: String, _ bindings: [String: Double] = [:], file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let items: [DrillTeX] = try DrillTeX.parse(source)
        XCTAssertEqual(items.count, 1, file: file, line: line)
        let bound: [String: DrillComplex] = bindings.mapValues { (double: Double) -> DrillComplex in DrillComplex(double) }
        let result: DrillComplex = try XCTUnwrap(items[0].evaluate(bound), file: file, line: line)
        XCTAssertEqual(result.imaginary, 0, accuracy: 1e-9, file: file, line: line)
        return result.real
    }

    func testArithmetic() throws {
        XCTAssertEqual(try value("1 + 2 \\times 3"), 7)
        XCTAssertEqual(try value("(-3) + (+5) - (-2)"), 4)
        XCTAssertEqual(try value("6 \\div 4"), 1.5)
        XCTAssertEqual(try value("-3^{2}"), -9)
        XCTAssertEqual(try value("(-3)^{2}"), 9)
        XCTAssertEqual(try value("2 \\cdot 3^2"), 18)
        XCTAssertEqual(try value("\\frac{1}{2} + \\frac{1}{3}"), 5.0 / 6, accuracy: 1e-12)
        XCTAssertEqual(try value("-\\frac{3}{4} \\times (-\\frac{2}{3})"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try value("\\left( 1 + 2 \\right)^{2}"), 9)
        XCTAssertEqual(try value("5!"), 120)
        XCTAssertEqual(try value("|3 - 5| + |-2|"), 4)
        XCTAssertEqual(try value("2|1 - 4|"), 6)
    }

    func testImplicitMultiplicationAndPowers() throws {
        XCTAssertEqual(try value("2x^{2} - 3x + 1", ["x": 2]), 3)
        XCTAssertEqual(try value("3(x + 1)(x - 2)", ["x": 3]), 12)
        XCTAssertEqual(try value("-x^2", ["x": 3]), -9)
        XCTAssertEqual(try value("3x^{2}y", ["x": 2, "y": 5]), 60)
        XCTAssertEqual(try value("x_1 + x_{2}", ["x_1": 2, "x_2": 3]), 5)
        XCTAssertEqual(try value("2^{-x}", ["x": 3]), 0.125)
        XCTAssertEqual(try value("e^{2x}", ["x": 0.5]), M_E, accuracy: 1e-12)
        XCTAssertEqual(try value("\\theta^{2}", ["theta": 3]), 9)
    }

    func testRootsAndFunctions() throws {
        XCTAssertEqual(try value("2\\sqrt{3} \\times \\sqrt{3}"), 6, accuracy: 1e-12)
        XCTAssertEqual(try value("\\sqrt[3]{-8}"), -2, accuracy: 1e-12)
        XCTAssertEqual(try value("\\frac{-1 + \\sqrt{5}}{2}"), 0.6180339887, accuracy: 1e-9)
        XCTAssertEqual(try value("\\sin \\frac{\\pi}{6}"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try value("\\sin 30^{\\circ}"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try value("\\sin 2x \\cos x", ["x": 0.4]), sin(0.8) * cos(0.4), accuracy: 1e-12)
        XCTAssertEqual(try value("\\sin^{2} x + \\cos^{2} x", ["x": 1.3]), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("2\\sin(x + 1)", ["x": 0.2]), 2 * sin(1.2), accuracy: 1e-12)
        XCTAssertEqual(try value("\\log_{2} 8"), 3, accuracy: 1e-12)
        XCTAssertEqual(try value("\\log_{10} 1000"), 3, accuracy: 1e-12)
        // \log は自然対数(数学 III の書き方)。
        XCTAssertEqual(try value("\\log x", ["x": M_E]), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("x\\ln x - x", ["x": 2]), 2 * log(2) - 2, accuracy: 1e-12)
        XCTAssertEqual(try value("\\tan^{-1} 1"), Double.pi / 4, accuracy: 1e-12)
    }

    func testListsAndPlusMinus() throws {
        let items: [DrillTeX] = try DrillTeX.parse("\\frac{-1 \\pm \\sqrt{5}}{2},\\ 3")
        let values: [DrillComplex] = try XCTUnwrap(DrillTeX.values(of: items, bindings: [:]))
        XCTAssertEqual(values.map { (value: DrillComplex) -> Double in (value.real * 1000).rounded() / 1000 }, [0.618, -1.618, 3])
        let imaginary: [DrillComplex] = try XCTUnwrap(DrillTeX.values(of: try DrillTeX.parse("2 \\pm 3i"), bindings: [:]))
        XCTAssertEqual(imaginary, [DrillComplex(2, 3), DrillComplex(2, -3)])
    }

    func testComplexArithmetic() throws {
        let item: DrillTeX = try XCTUnwrap(try DrillTeX.parse("\\frac{1 + 2i}{3 - 4i}").first)
        let value: DrillComplex = try XCTUnwrap(item.evaluate([:]))
        XCTAssertEqual(value.real, -0.2, accuracy: 1e-12)
        XCTAssertEqual(value.imaginary, 0.4, accuracy: 1e-12)
    }

    func testUndefinedValues() throws {
        for source: String in ["\\frac{1}{x}", "\\tan x", "\\log_{1} 5"] {
            let item: DrillTeX = try XCTUnwrap(try DrillTeX.parse(source).first)
            XCTAssertNil(item.evaluate(["x": source == "\\tan x" ? DrillComplex(Double.pi / 2) : DrillComplex.zero]), source)
        }
        // 値を入れていない文字があれば、数値にならない。
        XCTAssertNil(try XCTUnwrap(try DrillTeX.parse("x + k").first).evaluate(["x": DrillComplex.one]))
    }

    func testUnreadableSourcesThrow() {
        for source: String in ["", "x^12", "\\frac{1}{", "\\mathrm{kg}", "\\text{答え}", "1 +", "x = 2", "\\begin{pmatrix} 1 \\end{pmatrix}", "{}"] {
            XCTAssertThrowsError(try DrillTeX.parse(source), source)
        }
    }

    func testSymbols() throws {
        XCTAssertEqual(try XCTUnwrap(try DrillTeX.parse("a x^{2} + e^{x} + \\pi i + y'").first).symbols, ["a", "x", "y'"])
    }

    func testNumerics() throws {
        let cube: (Double) -> DrillComplex? = { (x: Double) -> DrillComplex? in DrillComplex(x * x * x) }
        XCTAssertEqual(try XCTUnwrap(DrillNumerics.derivative(cube, at: 2, order: 1)).real, 12, accuracy: 1e-7)
        XCTAssertEqual(try XCTUnwrap(DrillNumerics.derivative(cube, at: 2, order: 2)).real, 12, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(DrillNumerics.integral(cube, from: 0, to: 2)).real, 4, accuracy: 1e-10)
        let sine: (Double) -> DrillComplex? = { (x: Double) -> DrillComplex? in DrillComplex(sin(x)) }
        XCTAssertEqual(try XCTUnwrap(DrillNumerics.integral(sine, from: 0, to: Double.pi)).real, 2, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(DrillNumerics.integral(sine, from: 1, to: 0)).real, cos(1) - 1, accuracy: 1e-10)
    }
}
