import XCTest
@testable import strius

/// 画面の不整合の修正(信頼性計画 P5 の 2〜6、レーン D、2026-10-03)の単体の受け入れ。
/// 実表示はシミュレータの証跡(関連する画面・動作)で確かめる。
@MainActor
final class ScreenConsistencyTests: XCTestCase {
    // MARK: D6 数式で始まる箇条書き

    func testBulletStartingWithMathBecomesBullet() {
        let text = "判別式の符号で決まります。\n- $D>0$: 異なる実数の解が2つ\n- \\(D=0\\): 重解\n- **注意**: 係数に注意"
        let lines = ChatTextReadability.bulletize(text).components(separatedBy: "\n")
        XCTAssertEqual(lines[1], "• $D>0$: 異なる実数の解が2つ")
        XCTAssertEqual(lines[2], "• \\(D=0\\): 重解")
        XCTAssertEqual(lines[3], "• **注意**: 係数に注意")
    }

    func testBareExpressionLineKeepsItsSign() {
        // 区切りの無い式は、行頭の符号を消さない(従来どおり)。
        XCTAssertEqual(ChatTextReadability.bulletize("- 3x + 6 = 0"), "- 3x + 6 = 0")
        XCTAssertEqual(ChatTextReadability.bulletize("- 解なし"), "• 解なし")
    }

    // MARK: D7 一覧のプレビュー

    func testPreviewTurnsLatexIntoReadableText() {
        XCTAssertEqual(MathPlainText.preview("\\(D>0\\) のときは解が 2 つです。"), "D > 0 のときは解が 2 つです。")
        XCTAssertEqual(MathPlainText.preview("判別式は $D=b^2-4ac$"), "判別式は D = b²−4ac")
        XCTAssertEqual(MathPlainText.readable("$\\frac{b}{2a}$"), "b/(2a)")
        XCTAssertFalse(MathPlainText.preview("$$x^{2}$$\n\n**重要**").contains("$"))
    }

    // MARK: D15 止まった返事を畳む

    private func message(_ role: MessageRole, _ status: MessageStatus) -> ChatMessage {
        ChatMessage(id: UUID(), role: role, status: status, plainText: "x", blocks: [], metadata: nil, createdAt: Date(), completedAt: nil)
    }

    func testStoppedReplyFoldsOnceTheNextReplyArrives() {
        let stopped = message(.assistant, .failed)
        let pending = message(.assistant, .pending)
        let alone = [message(.user, .completed), stopped, message(.user, .completed)]
        XCTAssertTrue(ChatTimeline.foldedReplyIDs(alone).isEmpty, "次の返事が無い間は「送り直す」を残す")
        XCTAssertEqual(ChatTimeline.foldedReplyIDs(alone + [pending]), [stopped.id])
        let lastFailed = message(.assistant, .failed)
        XCTAssertEqual(ChatTimeline.foldedReplyIDs(alone + [pending, message(.user, .completed), lastFailed]), [stopped.id], "最後の止まった返事は畳まない")
    }

    // MARK: D12 紙を綴じる先

    private func machine() -> WorkbookMachine {
        var machine = WorkbookMachine()
        var clock = 0
        machine.now = {
            clock += 1
            return String(format: "2026-10-03T00:%02d:%02d.000Z", clock / 60 % 60, clock % 60)
        }
        return machine
    }

    func testFreeCaptureBindsToSubunitWithoutProblems() throws {
        var machine = machine()
        let unitID = machine.createUnit(title: "判別式", outcome: "", source: "consult", subunits: [.init(title: "判別式を計算できる", n: 5), .init(title: "解の個数", n: 5)], firstStage: 4)
        let subunitID = machine.orderedSubunits(unitID: unitID)[0].id
        _ = try machine.createCapture(id: "cap", imagePath: "x.jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, subunitID: nil, setID: nil)
        let context = machine.gradingContext(capture: machine.captures["cap"]!)
        let match = WorkbookMachine.subunitMatchID(subunitID)
        XCTAssertNotNil(context.known[match], "問題の無い小単元が照合の対象に入っていない")
        let items: [WorkbookMachine.GradingResult.Item] = [
            .init(label: "(1)", promptText: "2x^2+3x-1=0 の判別式", matchedProblemId: match, verdict: "correct", errorTag: "", note: ""),
            .init(label: "(2)", promptText: "x^2-4x+4=0 の判別式", matchedProblemId: match, verdict: "wrong", errorTag: "符号", note: ""),
        ]
        let outcome = try machine.applyGradingResult(captureID: "cap", graded: .init(readable: true, items: items, candidates: [], newSubunit: nil, note: ""), context: context)
        XCTAssertEqual(outcome.status, "graded")
        XCTAssertEqual(outcome.subunitID, subunitID)
        XCTAssertEqual(machine.problems.values.filter { $0.subunitId == subunitID }.count, 2, "紙の 2 問がマスとして足されていない")
    }

    func testSubunitMatchIsNeverShownAsCandidateProblem() throws {
        var machine = machine()
        let unitID = machine.createUnit(title: "u", outcome: "", source: "consult", subunits: [.init(title: "s", n: 5)], firstStage: 4)
        let subunitID = machine.orderedSubunits(unitID: unitID)[0].id
        _ = try machine.createCapture(id: "cap", imagePath: "x.jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, subunitID: nil, setID: nil)
        let context = machine.gradingContext(capture: machine.captures["cap"]!)
        let rows = machine.candidateRows(context: context, candidates: [.init(problemId: WorkbookMachine.subunitMatchID(subunitID), reason: "")], fallback: true)
        XCTAssertTrue(rows.isEmpty)
    }

    func testTriageAssignsEveryItemOfThePaper() throws {
        var machine = machine()
        let unitID = machine.createUnit(title: "u", outcome: "", source: "consult", subunits: [.init(title: "s", n: 5)], firstStage: 4)
        let subunitID = machine.orderedSubunits(unitID: unitID)[0].id
        machine.put("capture.triaged", WorkbookCaptureRecord(
            id: "cap", status: "triage", imagePath: "x.jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, context: .emptyObject,
            subunitId: nil, setId: nil,
            verdicts: .array([
                .object(["label": .string("(1)"), "prompt_text": .string("問 1"), "verdict": .string("correct"), "error_tag": .string(""), "note": .string("")]),
                .object(["label": .string("(2)"), "prompt_text": .string("問 2"), "verdict": .string("wrong"), "error_tag": .string(""), "note": .string("")]),
            ]),
            summary: .emptyObject, candidates: .emptyArray, error: nil, createdAt: "2026-10-03T00:00:00.000Z", updatedAt: "2026-10-03T00:00:00.000Z", gradedAt: nil
        ))
        let view = try machine.assign(captureID: "cap", assignment: .newProblem(subunitID: subunitID), verdictOverride: nil)
        XCTAssertEqual(view.verdicts.count, 2)
        XCTAssertEqual(Set(view.verdicts.compactMap(\.problemId)).count, 2, "2 問目が綴じられていない")
        XCTAssertEqual(machine.attempts.values.filter { $0.subunitId == subunitID }.count, 2)
    }

    func testRelatedDestinationComesFirstAndFormulaDistinguishes() throws {
        var machine = machine()
        let first = machine.createUnit(title: "二次関数", outcome: "", source: "consult", subunits: [.init(title: "括弧を外して整理できる", n: 5)], firstStage: 4)
        let second = machine.createUnit(title: "判別式と二次不等式", outcome: "", source: "consult", subunits: [.init(title: "判別式を計算できる", n: 5)], firstStage: 4)
        let subunits = try (machine.orderedSubunits(unitID: first) + machine.orderedSubunits(unitID: second)).map { try machine.subunitSummary(id: $0.id) }
        let ranked = WorkbookTriageRanking.rank(subunits: subunits, paperText: "2x^2+3x-1=0 の判別式を求めよ。", candidateSubunitIDs: [])
        XCTAssertEqual(ranked.first?.title, "判別式を計算できる")
        XCTAssertEqual(
            WorkbookTriageRanking.distinguishing("次の式の括弧を外し、同類項をまとめなさい。$-2(3x-4)+5x$"),
            "$-2(3x-4)+5x$\n次の式の括弧を外し、同類項をまとめなさい。…"
        )
    }

    // MARK: D14 会話に出た式を避ける

    func testGeneratedProblemReusingConversationExpressionIsDetected() {
        let conversation = ConversationExpressions.expressions(in: "$x^2-6x+5=(x-3)^2-4$ になります。") + ConversationExpressions.expressions(in: "x^2-6x+5 を平方完成して")
        XCTAssertFalse(ConversationExpressions.overlaps(prompts: ["$x^2 - 6x + 5$ を平方完成しなさい。"], avoid: conversation).isEmpty)
        XCTAssertTrue(ConversationExpressions.overlaps(prompts: ["$x^2+4x+1$ を平方完成しなさい。"], avoid: conversation).isEmpty)
        // 一般の形は避ける式にしない。
        XCTAssertTrue(ConversationExpressions.overlaps(prompts: ["判別式 $b^2-4ac$ を計算しなさい。"], avoid: ConversationExpressions.expressions(in: "$D=b^2-4ac$")).isEmpty)
    }

    func testSetReusingConversationExpressionIsComposedAgainOnce() throws {
        var machine = machine()
        let unitID = machine.createUnit(title: "u", outcome: "", source: "consult", subunits: [.init(title: "s", n: 1)], firstStage: 3)
        let subunitID = machine.orderedSubunits(unitID: unitID)[0].id
        let spec = try machine.nextSetSpec(subunitID: subunitID)
        let setID = machine.insertGeneratingSet(subunitID: subunitID, spec: spec)
        let draft = #"{"problems":[{"prompt":"$x^2-6x+5$ を平方完成しなさい。","answer_key":"(x-3)^2-4"}]}"#
        let outcome = TurnOutcome(planID: "p", round: 1, status: .completed, codexThreadID: nil, codexTurnID: nil, finalText: draft, executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: 1)
        let avoid = ConversationExpressions.expressions(in: "$x^2-6x+5=(x-3)^2-4$")
        let first = TurnApplier.set(machine: &machine, setID: setID, outcome: outcome, avoidExpressions: avoid)
        XCTAssertEqual(first.setIDToGenerate, setID, "会話の式と同じ問題で組み直していない")
        XCTAssertTrue(machine.sets[setID]!.problemIds.isEmpty)
        XCTAssertEqual(machine.sets[setID]!.gate["rejected_expressions"]?.arrayValue?.isEmpty, false)
        let second = TurnApplier.set(machine: &machine, setID: setID, outcome: outcome, avoidExpressions: avoid)
        XCTAssertNil(second.setIDToGenerate, "組み直しは 1 回だけ")
        XCTAssertEqual(machine.sets[setID]!.problemIds.count, 1)
    }

    // MARK: D13 プラン名

    func testInternalPlanNamesAreNotShown() {
        XCTAssertNil(CodexPlanName.display("prolite"))
        XCTAssertEqual(CodexPlanName.display("plus"), "Plus")
        XCTAssertNil(CodexPlanName.display(nil))
    }
}
