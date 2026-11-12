import Foundation
import XCTest
@testable import strius

/// 型を書かせる依頼と、その返事の点検(`DrillAuthoring`)。指示文と JSON Schema が書式とずれていないことも確かめる。
final class DrillAuthoringTests: XCTestCase {
    private let request: DrillAuthoringRequest = DrillAuthoringRequest(
        skillID: "math.m1.complete_square_vertex", name: "平方完成して頂点を求める", kind: "procedure",
        solved: [DrillSolvedExample(prompt: "次の二次関数を平方完成して、グラフの頂点の座標を求めなさい。", math: "y = 2x^{2} - 8x + 5", answer: "$(2,\\ -3)$")]
    )

    private func fixture(_ path: String) throws -> String {
        let root: URL = try XCTUnwrap(DrillTestSupport.fixturesRoot())
        return try String(contentsOf: root.appendingPathComponent(path), encoding: String.Encoding.utf8)
    }

    /// リポジトリのファイルを読む。ソースが手元に無い環境では、指示文と JSON Schema はアプリに入っているものを読み、
    /// それ以外(仕様書)を使うテストは飛ばす。
    private func repositoryFile(_ path: String) throws -> String {
        if let root: URL = DrillTestSupport.repositoryRoot() {
            return try String(contentsOf: root.appendingPathComponent(path), encoding: String.Encoding.utf8)
        }
        let prompts: String = "strius/Resources/Prompts/"
        if path.hasPrefix(prompts), let bundled: URL = Bundle.main.url(forResource: "Prompts", withExtension: nil) {
            return try String(contentsOf: bundled.appendingPathComponent(String(path.dropFirst(prompts.count))), encoding: String.Encoding.utf8)
        }
        throw XCTSkip("\(path) がこの環境から読めません")
    }

    private func reply(template: String) -> String {
        "{\"template\": \(template), \"reason\": \"\"}"
    }

    /// 答えの式だけを書き換えた、点検に落ちる型(頂点の y 座標を 1 ずらす)。
    private func brokenTemplate() throws -> String {
        let good: String = try fixture("math/math.m1.complete_square_vertex.json")
        let broken: String = good.replacingOccurrences(of: "\"expr\": \"a*p^2 + q\"", with: "\"expr\": \"a*p^2 + q + 1\"")
        XCTAssertNotEqual(good, broken)
        return broken
    }

    func testInputCarriesTheSkillAndTheSolvedProblems() throws {
        let text: String = try DrillAuthoring.input(for: request)
        let tree: DrillJSON = try JSONDecoder().decode(DrillJSON.self, from: Data(text.utf8))
        let expected: DrillJSON = DrillJSON.object([
            "skill": DrillJSON.object(["id": DrillJSON.string("math.m1.complete_square_vertex"), "name": DrillJSON.string("平方完成して頂点を求める"), "kind": DrillJSON.string("procedure")]),
            "solved": DrillJSON.array([DrillJSON.object([
                "prompt": DrillJSON.string("次の二次関数を平方完成して、グラフの頂点の座標を求めなさい。"),
                "math": DrillJSON.string("y = 2x^{2} - 8x + 5"), "answer": DrillJSON.string("$(2,\\ -3)$"),
            ])]),
        ])
        XCTAssertEqual(tree, expected)
    }

    func testOnlyCalculationSkillsAreAsked() {
        XCTAssertTrue(DrillAuthoring.isCandidate(kind: "procedure"))
        XCTAssertTrue(DrillAuthoring.isCandidate(kind: "combination"))
        XCTAssertFalse(DrillAuthoring.isCandidate(kind: "concept"))
        XCTAssertFalse(DrillAuthoring.isCandidate(kind: "memorized"))
    }

    func testPassingReplyIsReadyToStore() throws {
        let source: String = try fixture("math/math.m1.complete_square_vertex.json")
        var session: DrillAuthoringSession = DrillAuthoringSession(request: request)
        let step: DrillAuthoringStep = session.receive(reply: reply(template: source))
        guard case DrillAuthoringStep.finished(DrillAuthoringOutcome.ready(let json, let numericallyChecked, let problems)) = step else {
            return XCTFail("保存できるはず: \(step)")
        }
        XCTAssertTrue(numericallyChecked)
        XCTAssertGreaterThanOrEqual(problems, DrillValidator.minimumProblems)
        XCTAssertEqual(try DrillTemplate.decode(json: json), try DrillTemplate.decode(json: source), "保存する JSON は、書かれた型と同じ中身")
        XCTAssertEqual(session.attempts, 1)
    }

    func testFailingReplyGetsOneRewriteAndThenTheSkillIsExcluded() throws {
        let broken: String = try brokenTemplate()
        var session: DrillAuthoringSession = DrillAuthoringSession(request: request)
        let first: DrillAuthoringStep = session.receive(reply: reply(template: broken))
        guard case DrillAuthoringStep.retry(let message) = first else { return XCTFail("1 回目は書き直しを頼む: \(first)") }
        XCTAssertTrue(message.contains("数値の点検"), message)
        XCTAssertTrue(message.contains("この 1 回だけ"), message)

        let second: DrillAuthoringStep = session.receive(reply: reply(template: broken))
        guard case DrillAuthoringStep.finished(DrillAuthoringOutcome.excluded(let reasons, let declined)) = second else { return XCTFail("2 回目も落ちたら外す: \(second)") }
        XCTAssertFalse(declined)
        XCTAssertFalse(reasons.isEmpty)
        XCTAssertEqual(session.attempts, 2)

        // 結論が出た後に届いた返事は数えない(3 回目は書かせない)。
        let third: DrillAuthoringStep = session.receive(reply: reply(template: try fixture("math/math.m1.complete_square_vertex.json")))
        XCTAssertEqual(third, second)
        XCTAssertEqual(session.attempts, 2)
    }

    func testRewriteThatPassesIsStored() throws {
        var session: DrillAuthoringSession = DrillAuthoringSession(request: request)
        guard case DrillAuthoringStep.retry = session.receive(reply: reply(template: try brokenTemplate())) else { return XCTFail("1 回目は書き直しを頼む") }
        let second: DrillAuthoringStep = session.receive(reply: reply(template: try fixture("math/math.m1.complete_square_vertex.json")))
        guard case DrillAuthoringStep.finished(DrillAuthoringOutcome.ready) = second else { return XCTFail("書き直しが通れば保存する: \(second)") }
    }

    func testDeclinedSkillIsExcludedWithoutARewrite() {
        var session: DrillAuthoringSession = DrillAuthoringSession(request: request)
        let step: DrillAuthoringStep = session.receive(reply: "{\"template\": null, \"reason\": \"グラフを見て答える問題で、数字を入れ替える計算ではない\"}")
        XCTAssertEqual(step, DrillAuthoringStep.finished(DrillAuthoringOutcome.excluded(reasons: ["グラフを見て答える問題で、数字を入れ替える計算ではない"], declined: true)))
        XCTAssertEqual(session.attempts, 1)
    }

    func testTemplateForAnotherSkillIsRejected() throws {
        let other: String = try fixture("math/math.m1.quadratic_inequality.json")
        let review: DrillAuthoring.Review = DrillAuthoring.review(reply: reply(template: other), request: request, validator: DrillValidator())
        guard case DrillAuthoring.Review.rejected(let reasons) = review else { return XCTFail("別の点の型は受け取らない: \(review)") }
        XCTAssertTrue(reasons.first?.contains("skill_id") ?? false, "\(reasons)")
    }

    func testUnreadableRepliesAreRejectedWithAReason() throws {
        let validator: DrillValidator = DrillValidator()
        for text: String in ["型を書きました。", "{\"reason\": \"\"}", "{\"template\": {\"format\": 1}, \"reason\": \"\"}", "{\"template\": \"x\", \"reason\": \"\"}"] {
            guard case DrillAuthoring.Review.rejected(let reasons) = DrillAuthoring.review(reply: text, request: request, validator: validator) else {
                XCTFail("受け取らないはず: \(text)")
                continue
            }
            XCTAssertFalse(reasons.isEmpty, text)
        }
    }

    func testRenderProbeFailureIsAReasonForARewrite() throws {
        let validator: DrillValidator = DrillValidator(renderProbe: { (latex: String) -> String? in latex.contains("x^{2}") ? "描けない" : nil })
        let review: DrillAuthoring.Review = DrillAuthoring.review(reply: reply(template: try fixture("math/math.m1.complete_square_vertex.json")), request: request, validator: validator)
        guard case DrillAuthoring.Review.rejected(let reasons) = review else { return XCTFail("画面で描けない型は受け取らない") }
        XCTAssertTrue(reasons.contains { (reason: String) -> Bool in reason.contains("画面で式を描けません") }, "\(reasons)")
    }

    // MARK: - 指示文と JSON Schema

    func testReplySchemaWrapsTheTemplateSchema() throws {
        let templateSchema: String = try repositoryFile("strius/Resources/Prompts/drill_template.json")
        let schema: DrillJSON = try JSONDecoder().decode(DrillJSON.self, from: Data(try DrillAuthoring.replySchema(templateSchema: templateSchema).utf8))
        guard case DrillJSON.object(let top) = schema, case DrillJSON.object(let properties)? = top["properties"],
              case DrillJSON.object(let template)? = properties["template"], case DrillJSON.array(let choices)? = template["anyOf"] else {
            return XCTFail("形が違う")
        }
        XCTAssertEqual(top["required"], DrillJSON.array([DrillJSON.string("template"), DrillJSON.string("reason")]))
        XCTAssertEqual(choices.first, try JSONDecoder().decode(DrillJSON.self, from: Data(templateSchema.utf8)))
        XCTAssertEqual(choices.last, DrillJSON.object(["type": DrillJSON.string("null")]))
    }

    /// JSON Schema のキーが、解釈器が読むキー(`DrillTemplateKeys`)と同じ。片方だけに足すと、AI が書けるのに端末が断る(またはその逆)。
    func testSchemaKeysMatchTheInterpreter() throws {
        let schema: DrillJSON = try JSONDecoder().decode(DrillJSON.self, from: Data(try repositoryFile("strius/Resources/Prompts/drill_template.json").utf8))
        func properties(_ path: [String]) -> Set<String>? {
            var node: DrillJSON = schema
            for key: String in path {
                guard case DrillJSON.object(let fields) = node, let next: DrillJSON = fields[key] else { return nil }
                node = next
            }
            guard case DrillJSON.object(let fields) = node, case DrillJSON.object(let found)? = fields["properties"] else { return nil }
            XCTAssertEqual(fields["additionalProperties"], DrillJSON.bool(false), "\(path)")
            return Set(found.keys)
        }
        XCTAssertEqual(properties([]), DrillTemplateKeys.template)
        XCTAssertEqual(properties(["properties", "variables", "items"]), DrillTemplateKeys.variable)
        XCTAssertEqual(properties(["properties", "variables", "items", "properties", "numerator"]), DrillTemplateKeys.range)
        XCTAssertEqual(properties(["properties", "variables", "items", "properties", "denominator"]), DrillTemplateKeys.range)
        XCTAssertEqual(properties(["properties", "lets", "items"]), DrillTemplateKeys.letKeys)
        XCTAssertEqual(properties(["properties", "parts", "items"]), DrillTemplateKeys.part)
        XCTAssertEqual(properties(["properties", "parts", "items", "properties", "terms", "items"]), DrillTemplateKeys.term)
        XCTAssertEqual(properties(["properties", "parts", "items", "properties", "terms", "items", "properties", "powers", "items"]), DrillTemplateKeys.power)
        XCTAssertEqual(properties(["properties", "parts", "items", "properties", "powers", "items"]), DrillTemplateKeys.power)
        XCTAssertEqual(properties(["properties", "parts", "items", "properties", "cases", "items"]), DrillTemplateKeys.caseKeys)
        XCTAssertEqual(properties(["properties", "checks", "items"]), DrillTemplateKeys.check)
        XCTAssertEqual(properties(["properties", "checks", "items", "properties", "equations", "items"]), DrillTemplateKeys.equation)
    }

    /// 指示文の例は、実際に書いた型そのもので、点検を通る(作り物の例を AI に見せない)。
    func testInstructionExamplesAreRealTemplatesThatPass() throws {
        let instructions: String = try repositoryFile("strius/Resources/Prompts/drill_template_instructions.md")
        let pieces: [String] = instructions.components(separatedBy: "<!-- fixture: ")
        XCTAssertGreaterThanOrEqual(pieces.count - 1, 3, "例は 3 つ以上")
        for piece: String in pieces.dropFirst() {
            let path: String = try XCTUnwrap(piece.components(separatedBy: " -->").first)
            let afterFence: String = try XCTUnwrap(piece.components(separatedBy: "```json\n").dropFirst().first, path)
            let body: String = try XCTUnwrap(afterFence.components(separatedBy: "\n```").first, path)
            let shown: DrillTemplate = try DrillTemplate.decode(json: body)
            XCTAssertEqual(shown, try DrillTemplate.decode(json: try fixture(path)), "\(path) の例が、型のファイルと違う")
            let inspection: DrillInspection = DrillValidator().inspect(shown)
            XCTAssertTrue(inspection.passed, "\(path): \(inspection.feedback)")
        }
    }

    /// 指示文の「書式」は、仕様書(docs/offline-drill/format.md)の同じ範囲の写し。仕様書を直したら指示文も直す。
    func testInstructionsCarryTheFormatReference() throws {
        let instructions: String = try repositoryFile("strius/Resources/Prompts/drill_template_instructions.md")
        let specification: String = try repositoryFile("docs/offline-drill/format.md")
        let start: Range<String.Index> = try XCTUnwrap(specification.range(of: "| キー | 必須 | 中身 |"))
        let end: Range<String.Index> = try XCTUnwrap(specification.range(of: "## 点検(端末の中で、保存する前に)"))
        let reference: String = String(specification[start.lowerBound..<end.lowerBound])
            .replacingOccurrences(of: "\n### ", with: "\n#### ")
            .replacingOccurrences(of: "\n## ", with: "\n### ")
            .replacingOccurrences(of: "対応する知識グラフの点の ID(`TimelineSkillRecord.id`)。", with: "対応する知識グラフの点の ID(入力の `skill.id`)。")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        XCTAssertTrue(instructions.contains(reference), "指示文の「書式」が docs/offline-drill/format.md と違う")
    }

    /// 解釈器が読めるものは、全部が指示文に書いてある(書いていない関数や部品は、AI が使えない)。
    func testInstructionsNameEverythingTheInterpreterReads() throws {
        let instructions: String = try repositoryFile("strius/Resources/Prompts/drill_template_instructions.md")
        for name: String in DrillFunctions.arity.keys.sorted() {
            XCTAssertTrue(instructions.contains("`\(name)(") || instructions.contains("`\(name)`"), "関数 \(name) が指示文に無い")
        }
        let words: [String] = ["integer", "decimal", "fraction", "choice", "constant", "sum", "product", "text", "select", "list", "pm",
                               "identity", "value", "derivative", "antiderivative", "definite_integral", "root", "system", "inequality", "assert", "series", "limit", "ode",
                               "coef", "+coef", "paren", "+paren", "abs", "dec", "sig:n", "sci:n", "overpi", "unit"]
        for word: String in words {
            XCTAssertTrue(instructions.contains("`\(word)`"), "\(word) が指示文に無い")
        }
    }
}
