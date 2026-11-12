import XCTest
@testable import strius

/// 生成器: 条件を満たす組だけを選ぶ。種が同じなら同じ並び。直前と同じ問題は避ける。
final class DrillGeneratorTests: XCTestCase {
    typealias S = DrillTestSupport

    /// (x + a)(x + b) を展開する型。
    private var expansion: DrillTemplate {
        S.template(variables: [S.integer("a", -9, 9, exclude: [0]), S.integer("b", -9, 9, exclude: [0])],
                   lets: [DrillLet(name: "s", expr: "a + b"), DrillLet(name: "p", expr: "a * b")],
                   constraints: ["a <= b"],
                   parts: [DrillPart(name: "left", kind: "sum", terms: [DrillTerm(coef: "1", body: "x"), DrillTerm(coef: "a")]),
                           DrillPart(name: "right", kind: "sum", terms: [DrillTerm(coef: "1", body: "x"), DrillTerm(coef: "b")]),
                           DrillPart(name: "expanded", kind: "sum", terms: [DrillTerm(coef: "1", body: "x^{2}"), DrillTerm(coef: "s", body: "x"), DrillTerm(coef: "p")])],
                   prompt: "次の式を展開しなさい。", math: "({left})({right})", answer: "${expanded}$",
                   checks: [DrillCheck(kind: "identity", left: "({left})({right})", right: "{expanded}")])
    }

    func testSameSeedGivesSameProblems() throws {
        let generator: DrillGenerator = try DrillGenerator(template: expansion)
        func run(seed: UInt64) throws -> [DrillProblem] {
            var random: DrillSeededRandom = DrillSeededRandom(seed: seed)
            var previous: DrillProblem? = nil
            var out: [DrillProblem] = []
            for _ in 0..<30 {
                let problem: DrillProblem = try generator.next(using: &random, avoiding: previous)
                out.append(problem)
                previous = problem
            }
            return out
        }
        XCTAssertEqual(try run(seed: 42), try run(seed: 42))
        XCTAssertNotEqual(try run(seed: 42), try run(seed: 43))
    }

    func testSeededProblemsAreFixed() throws {
        // 乱数の並びが変わると、保存した種から同じ問題を作り直せなくなる。値を固定して気づけるようにする。
        var random: DrillSeededRandom = DrillSeededRandom(seed: 20261112)
        let first: DrillProblem = try DrillGenerator(template: expansion).next(using: &random)
        XCTAssertEqual(first.math, "(x - 8)(x - 7)")
        XCTAssertEqual(first.answer, "$x^{2} - 15x + 56$")
    }

    func testConstraintsHold() throws {
        let generator: DrillGenerator = try DrillGenerator(template: expansion)
        var random: DrillSeededRandom = DrillSeededRandom(seed: 7)
        for _ in 0..<200 {
            let values: [DrillValue] = generator.draw(using: &random)
            guard let instance: DrillCompiledTemplate.Instance = try generator.compiled.instance(values: values) else { continue }
            XCTAssertEqual(try S.evaluate("a <= b and a != 0 and b != 0", instance.scope), DrillValue.bool(true))
        }
    }

    func testNeverRepeatsThePreviousProblem() throws {
        // 2 通りしか作れない型でも、直前と同じ問題は続けて出さない。
        let template: DrillTemplate = S.template(variables: [S.integer("a", 1, 2)], math: "{a} + 1", answer: "$0$")
        let generator: DrillGenerator = try DrillGenerator(template: template)
        var random: DrillSeededRandom = DrillSeededRandom(seed: 3)
        var previous: DrillProblem = try generator.next(using: &random)
        for _ in 0..<50 {
            let next: DrillProblem = try generator.next(using: &random, avoiding: previous)
            XCTAssertNotEqual(next.key, previous.key)
            previous = next
        }
    }

    func testSingleProblemTemplateStillProduces() throws {
        let template: DrillTemplate = S.template(variables: [S.integer("a", 1, 1)], math: "{a} + 1", answer: "$2$")
        let generator: DrillGenerator = try DrillGenerator(template: template)
        var random: DrillSeededRandom = DrillSeededRandom(seed: 3)
        let first: DrillProblem = try generator.next(using: &random)
        XCTAssertEqual(try generator.next(using: &random, avoiding: first), first)
    }

    func testUnsatisfiableTemplateThrows() throws {
        let template: DrillTemplate = S.template(variables: [S.integer("a", 1, 5)], constraints: ["a > 9"], math: "{a}", answer: "$0$")
        var random: DrillSeededRandom = DrillSeededRandom(seed: 3)
        XCTAssertThrowsError(try DrillGenerator(template: template).next(using: &random))
    }

    func testUndefinedAssignmentsAreSkipped() throws {
        // b = 0 の組は答えが定まらない。生成器は選び直して、出題を止めない。
        let template: DrillTemplate = S.template(variables: [S.integer("a", 1, 9), S.integer("b", 0, 1)], lets: [DrillLet(name: "r", expr: "a / b")], math: "{a} \\div {b}", answer: "${r}$")
        var random: DrillSeededRandom = DrillSeededRandom(seed: 5)
        let generator: DrillGenerator = try DrillGenerator(template: template)
        for _ in 0..<20 {
            XCTAssertTrue(try generator.next(using: &random).math.hasSuffix("\\div 1"))
        }
    }

    func testVariableKinds() throws {
        let variables: [DrillVariable] = [
            DrillVariable(name: "d", kind: "decimal", min: 0.5, max: 1.5, step: 0.5),
            DrillVariable(name: "f", kind: "fraction", numerator: DrillIntegerRange(min: 1, max: 3), denominator: DrillIntegerRange(min: 2, max: 4)),
            DrillVariable(name: "c", kind: "choice", options: [DrillOption.record(["tex": DrillScalar.text("\\sin"), "k": DrillScalar.number(1)]), DrillOption.record(["tex": DrillScalar.text("\\cos"), "k": DrillScalar.number(2)])]),
            DrillVariable(name: "g", kind: "constant", value: 9.8),
            DrillVariable(name: "n", kind: "integer", min: 2, max: 10, step: 4, exclude: [6]),
        ]
        let compiled: DrillCompiledTemplate = try DrillCompiledTemplate(S.template(variables: variables, math: "{d} {f} {c.tex} {g} {n}", answer: "$0$"))
        XCTAssertEqual(compiled.variables[0].domain, [S.number(1, 2), S.number(1), S.number(3, 2)])
        // 分数は約分した形で分母が 2 以上のものだけ(2/4 は 1/2 と同じなので 1 回、2/2 は入らない)。
        XCTAssertEqual(Set(compiled.variables[1].domain), Set([S.number(1, 2), S.number(3, 2), S.number(1, 3), S.number(2, 3), S.number(1, 4), S.number(3, 4)]))
        XCTAssertEqual(compiled.variables[2].domain.count, 2)
        XCTAssertEqual(compiled.variables[3].domain, [S.number(49, 5)])
        XCTAssertEqual(compiled.variables[4].domain, [S.number(2), S.number(10)])
        XCTAssertEqual(try S.problem(compiled.template, values: [S.number(1, 2), S.number(2, 3), compiled.variables[2].domain[1], S.number(49, 5), S.number(10)])?.math, "0.5 \\frac{2}{3} \\cos 9.8 10")
    }

    func testCompileErrors() {
        func fails(_ template: DrillTemplate, _ expected: String, line: UInt = #line) {
            XCTAssertThrowsError(try DrillCompiledTemplate(template), line: line) { (error: Error) -> Void in
                XCTAssertTrue((error as? DrillFailure)?.message.contains(expected) ?? false, "\(error)", line: line)
            }
        }
        fails(S.template(variables: [S.integer("a", 1, 5), S.integer("a", 1, 5)], math: "{a}", answer: "$0$"), "2 回")
        fails(S.template(variables: [S.integer("pi", 1, 5)], math: "1", answer: "$0$"), "定数や演算の名前")
        fails(S.template(variables: [S.integer("a", 5, 1)], math: "{a}", answer: "$0$"), "min ≤ max")
        fails(S.template(variables: [S.integer("a", 1, 5)], lets: [DrillLet(name: "b", expr: "a + c")], math: "{a}", answer: "$0$"), "ここより前にありません")
        fails(S.template(variables: [S.integer("a", 1, 5)], lets: [DrillLet(name: "b", expr: "2a")], math: "{a}", answer: "$0$"), "「*」は省けません")
        fails(S.template(variables: [S.integer("a", 1, 5)], lets: [DrillLet(name: "b", expr: "eval(a)")], math: "{a}", answer: "$0$"), "関数「eval」はありません")
        fails(S.template(variables: [DrillVariable(name: "a", kind: "integer", min: 1, max: 5, unit: "parsec")], math: "{a}", answer: "$0$"), "単位「parsec」を知りません")
        fails(S.template(variables: [DrillVariable(name: "a", kind: "matrix")], math: "{a}", answer: "$0$"), "kind「matrix」はありません")
        fails(S.template(variables: [S.integer("a", 1, 5)], parts: [DrillPart(name: "p", kind: "sum")], math: "{a}", answer: "$0$"), "terms が要ります")
        fails(S.template(variables: [S.integer("a", 1, 1_000_000)], math: "{a}", answer: "$0$"), "多すぎます")
    }
}
