import XCTest
@testable import strius

/// 点検器: 正しい型は通し、問題の数・定まらない答え・崩れた表示・間違った公式を見つけて、理由を返す。
final class DrillValidatorTests: XCTestCase {
    typealias S = DrillTestSupport

    private func inspect(_ template: DrillTemplate) -> DrillInspection {
        DrillValidator().inspect(template)
    }

    private func assertFails(_ template: DrillTemplate, code: String, _ expected: String, line: UInt = #line) {
        let inspection: DrillInspection = inspect(template)
        XCTAssertFalse(inspection.passed, line: line)
        XCTAssertTrue(inspection.issues.contains { (issue: DrillIssue) -> Bool in issue.code == code && issue.message.contains(expected) }, inspection.feedback, line: line)
    }

    /// x² の係数 a と解 r1・r2 から作る二次方程式(答えから逆算する形)。
    private func quadratic(answer: String = "$x = {roots}$", constraints: [String] = ["r1 != r2"]) -> DrillTemplate {
        S.template(variables: [S.integer("a", 1, 3), S.integer("r1", -6, 6), S.integer("r2", -6, 6)],
                   lets: [DrillLet(name: "b", expr: "-a * (r1 + r2)"), DrillLet(name: "c", expr: "a * r1 * r2")],
                   constraints: constraints,
                   parts: [DrillPart(name: "f", kind: "sum", terms: [DrillTerm(coef: "a", body: "x^{2}"), DrillTerm(coef: "b", body: "x"), DrillTerm(coef: "c")]),
                           DrillPart(name: "roots", kind: "list", items: ["r1", "r2"], sort: true, unique: true)],
                   prompt: "次の二次方程式を解きなさい。", math: "{f} = 0", answer: answer,
                   checks: [DrillCheck(kind: "root", left: "{f}", variable: "x", solutions: ["{roots}"])])
    }

    func testGoodTemplatePasses() {
        let inspection: DrillInspection = inspect(quadratic())
        XCTAssertEqual(inspection.issues, [])
        XCTAssertTrue(inspection.exhaustive)
        XCTAssertEqual(inspection.examined, 3 * 13 * 13)
        XCTAssertEqual(inspection.satisfying, 3 * 13 * 12)
        XCTAssertTrue(inspection.numericallyChecked)
        // r1 と r2 を入れ替えた組は同じ問題になる。
        XCTAssertEqual(inspection.distinct, 3 * 13 * 12 / 2)
    }

    func testLargeDomainsAreSampled() {
        let template: DrillTemplate = S.template(variables: [S.integer("a", 1, 99), S.integer("b", 1, 99), S.integer("c", 1, 99)], lets: [DrillLet(name: "s", expr: "a + b + c")],
                                                 math: "{a} + {b} + {c}", answer: "${s}$", checks: [DrillCheck(kind: "value", tex: "{a} + {b} + {c}", equals: "s")])
        let inspection: DrillInspection = inspect(template)
        XCTAssertEqual(inspection.issues, [])
        XCTAssertFalse(inspection.exhaustive)
        XCTAssertEqual(inspection.examined, DrillValidator.sampleCount)
    }

    func testTooFewProblems() {
        let template: DrillTemplate = S.template(variables: [S.integer("a", 1, 5)], math: "{a} + 1", answer: "$0$")
        assertFails(template, code: "count", "作れる問題が少なすぎます(全部で 5 通り")
    }

    func testNoSatisfyingAssignment() {
        let template: DrillTemplate = S.template(variables: [S.integer("a", 1, 50)], constraints: ["a > 99"], math: "{a} + 1", answer: "$0$")
        assertFails(template, code: "count", "1 つもありません")
    }

    func testLowAcceptance() {
        // 判別式が平方数になる組だけを残すと、ほとんどの組が外れる。
        let template: DrillTemplate = S.template(variables: [S.integer("a", 1, 9), S.integer("b", -40, 40), S.integer("c", -40, 40)], lets: [DrillLet(name: "d", expr: "b^2 - 4*a*c")],
                                                 constraints: ["d == 49"], math: "{a}x^{2} + {b|paren}x + {c|paren} = 0", answer: "$0$")
        assertFails(template, code: "count", "割合が低すぎます")
    }

    func testUndefinedAnswerIsFound() {
        // b = 0 の時に 0 で割る。条件で外していないので落ちる。
        let template: DrillTemplate = S.template(variables: [S.integer("a", 1, 9), S.integer("b", -4, 4)], lets: [DrillLet(name: "r", expr: "a / b")], math: "{a} \\div {b|paren}", answer: "${r}$")
        assertFails(template, code: "undefined", "0 で割っています")
        var fixed: DrillTemplate = template
        fixed.constraints = ["b != 0"]
        XCTAssertEqual(inspect(fixed).issues, [])
    }

    func testNegativeSquareRootIsFound() {
        let template: DrillTemplate = S.template(variables: [S.integer("a", -9, 30)], lets: [DrillLet(name: "r", expr: "sqrt(a)")], math: "\\sqrt{{a}}", answer: "${r}$")
        assertFails(template, code: "undefined", "負の数の平方根")
    }

    func testWrongFormulaFailsNumericCheck() {
        // b の符号を間違えた型。解を代入すると合わない。
        var wrong: DrillTemplate = quadratic()
        wrong.lets[0] = DrillLet(name: "b", expr: "a * (r1 + r2)")
        assertFails(wrong, code: "numeric", "成り立ちません")
        XCTAssertFalse(inspect(wrong).numericallyChecked)
    }

    func testWrongDerivativeFailsNumericCheck() {
        func template(answerCoefficient: String) -> DrillTemplate {
            S.template(variables: [S.integer("a", 2, 9), S.integer("n", 2, 6)],
                       parts: [DrillPart(name: "f", kind: "sum", terms: [DrillTerm(coef: "a", powers: [DrillPower(base: "x", exp: "n")])]),
                               DrillPart(name: "d", kind: "sum", terms: [DrillTerm(coef: answerCoefficient, powers: [DrillPower(base: "x", exp: "n - 1")])])],
                       prompt: "次の関数を微分しなさい。", math: "y = {f}", answer: "$y' = {d}$",
                       checks: [DrillCheck(kind: "derivative", function: "{f}", answer: "{d}", variable: "x")])
        }
        XCTAssertEqual(inspect(template(answerCoefficient: "a * n")).issues, [])
        assertFails(template(answerCoefficient: "a * (n - 1)"), code: "numeric", "微分した値")
    }

    func testWrongIntegralFailsNumericCheck() {
        func template(answer: String) -> DrillTemplate {
            S.template(variables: [S.integer("a", 2, 7), S.integer("hi", 1, 5)], lets: [DrillLet(name: "s", expr: answer)],
                       prompt: "次の定積分を求めなさい。", math: "\\int_{0}^{{hi}} {a}x^{2}\\,dx", answer: "${s}$",
                       checks: [DrillCheck(kind: "definite_integral", answer: "{s}", variable: "x", integrand: "{a}x^{2}", from: "0", to: "hi")])
        }
        XCTAssertEqual(inspect(template(answer: "a * hi^3 / 3")).issues, [])
        assertFails(template(answer: "a * hi^3 / 2"), code: "numeric", "積分は")
    }

    func testInequalityCheck() {
        func template(solution: String) -> DrillTemplate {
            S.template(variables: [S.integer("a", 2, 9), S.integer("b", -20, 20)], lets: [DrillLet(name: "r", expr: "-b / a")],
                       parts: [DrillPart(name: "f", kind: "sum", terms: [DrillTerm(coef: "-a", body: "x"), DrillTerm(coef: "-b")])],
                       prompt: "次の不等式を解きなさい。", math: "{f} < 0", answer: "$x > {r}$",
                       checks: [DrillCheck(kind: "inequality", left: "{f}", right: "0", variable: "x", solution: solution, relation: "<")])
        }
        XCTAssertEqual(inspect(template(solution: "x > r")).issues, [])
        // 負の数で割った時に不等号の向きを変え忘れた解。
        assertFails(template(solution: "x < r"), code: "numeric", "不等式")
    }

    func testDisplayProblemsAreFound() {
        // 係数をそのまま差し込むと、1x や +-3 が出る。
        let raw: DrillTemplate = S.template(variables: [S.integer("a", -3, 3), S.integer("b", -9, 9)], math: "{a}x + {b}", answer: "$0$")
        let inspection: DrillInspection = inspect(raw)
        XCTAssertTrue(inspection.issues.contains { (issue: DrillIssue) -> Bool in issue.code == "display" && issue.message.contains("係数の 1 は書きません") }, inspection.feedback)
        XCTAssertTrue(inspection.issues.contains { (issue: DrillIssue) -> Bool in issue.code == "display" && issue.message.contains("符号が重なっています") }, inspection.feedback)
        XCTAssertTrue(inspection.issues.contains { (issue: DrillIssue) -> Bool in issue.code == "display" && issue.message.contains("係数が 0 の項") }, inspection.feedback)
    }

    func testUnsimplifiedAnswerIsFound() {
        let template: DrillTemplate = S.template(variables: [S.integer("a", 2, 60)], math: "\\sqrt{{a}}", answer: "$\\sqrt{{a}}$")
        assertFails(template, code: "display", "答えの平方根が整理されていません")
    }

    func testRealNumberWithoutDigitsIsFound() {
        let template: DrillTemplate = S.template(variables: [S.integer("a", 2, 60)], lets: [DrillLet(name: "r", expr: "ln(a)")], math: "\\log {a}", answer: "${r}$")
        assertFails(template, code: "undefined", "桁数を決めずに表示")
    }

    func testDimensionMismatchIsFound() {
        // 力を kg·m/s と書き間違えた型。
        let variables: [DrillVariable] = [DrillVariable(name: "m", kind: "decimal", min: 1.0, max: 9.5, step: 0.5, unit: "kg", sig: 2), DrillVariable(name: "a", kind: "decimal", min: 1.0, max: 9.5, step: 0.5, unit: "m/s^2", sig: 2)]
        let wrong: DrillTemplate = S.template(variables: variables, lets: [DrillLet(name: "f", expr: "m * a", unit: "kg*m/s", sig: 2)], prompt: "質量 ${m|q}$ の物体に加速度 ${a|q}$ を生じさせる力の大きさを求めなさい。",
                                              math: "", answer: "${f|q}$", subject: "physics")
        assertFails(wrong, code: "undefined", "単位「kg*m/s」が合いません")
        var right: DrillTemplate = wrong
        right.lets = [DrillLet(name: "f", expr: "m * a", unit: "N", sig: 2)]
        XCTAssertEqual(inspect(right).issues, [])
    }

    func testShapeProblems() {
        var noReason: DrillTemplate = quadratic()
        noReason.checks = []
        assertFails(noReason, code: "shape", "checks が空です")
        var both: DrillTemplate = quadratic()
        both.noNumericCheck = "理由"
        assertFails(both, code: "shape", "どちらか一方")
        var subject: DrillTemplate = quadratic()
        subject.subject = "history"
        assertFails(subject, code: "shape", "subject は")
        let fixed: DrillTemplate = S.template(variables: [S.integer("a", 1, 50)], math: "1 + 1", answer: "$2$")
        assertFails(fixed, code: "shape", "差し込みが 1 つもありません")
        var badCheck: DrillTemplate = quadratic()
        badCheck.checks = [DrillCheck(kind: "magic")]
        assertFails(badCheck, code: "compile", "kind「magic」はありません")
        var missingField: DrillTemplate = quadratic()
        missingField.checks = [DrillCheck(kind: "root", left: "{f}", variable: "x")]
        assertFails(missingField, code: "compile", "「solutions」が要ります")
    }

    func testJSONIsDecodedStrictly() {
        let good: String = """
        {"format": 1, "skill_id": "arith.add", "title": "足し算", "subject": "math",
         "variables": [{"name": "a", "kind": "integer", "min": 1, "max": 9}, {"name": "b", "kind": "integer", "min": 1, "max": 9}],
         "lets": [{"name": "s", "expr": "a + b"}],
         "prompt": "次の計算をしなさい。", "math": "{a} + {b}", "answer": "${s}$",
         "checks": [{"kind": "value", "tex": "{a} + {b}", "equals": "s"}]}
        """
        let accepted: (template: DrillTemplate?, inspection: DrillInspection) = DrillValidator().inspect(json: good)
        XCTAssertEqual(accepted.inspection.issues, [])
        XCTAssertEqual(accepted.template?.skillId, "arith.add")

        // キーの書き間違い(constraint)は黙って無視せず、断る。
        let typo: String = good.replacingOccurrences(of: "\"lets\"", with: "\"constraint\": [\"a != b\"], \"lets\"")
        XCTAssertTrue(DrillValidator().inspect(json: typo).inspection.feedback.contains("書式に無いキーがあります: 型.constraint"))
        let nested: String = good.replacingOccurrences(of: "\"min\": 1, \"max\": 9}, {", with: "\"min\": 1, \"max\": 9, \"range\": 3}, {")
        XCTAssertTrue(DrillValidator().inspect(json: nested).inspection.feedback.contains("variables[0].range"))
        let missing: String = good.replacingOccurrences(of: "\"prompt\": \"次の計算をしなさい。\", ", with: "")
        XCTAssertTrue(DrillValidator().inspect(json: missing).inspection.feedback.contains("必要なキー「prompt」がありません"))
        XCTAssertTrue(DrillValidator().inspect(json: "ここに JSON が無い").inspection.feedback.contains("JSON として読めません"))
        let wrongFormat: String = good.replacingOccurrences(of: "\"format\": 1", with: "\"format\": 9")
        XCTAssertTrue(DrillValidator().inspect(json: wrongFormat).inspection.feedback.contains("format は 1"))
    }

    func testRenderProbeIsUsed() {
        // 端末では、画面の数式描画(SwiftMath)で読めるかも確かめる。読めない式があれば落ちる。
        let validator: DrillValidator = DrillValidator(renderProbe: { (latex: String) -> String? in latex.contains("x^{2}") ? "読めない命令" : nil })
        let inspection: DrillInspection = validator.inspect(quadratic())
        XCTAssertTrue(inspection.issues.contains { (issue: DrillIssue) -> Bool in issue.code == "display" && issue.message.contains("画面で式を描けません(読めない命令)") }, inspection.feedback)
    }

    func testCanonicalJSONRoundTrips() throws {
        let template: DrillTemplate = quadratic()
        let decoded: DrillTemplate = try DrillTemplate.decode(json: try template.canonicalJSON())
        XCTAssertEqual(decoded, template)
    }
}
