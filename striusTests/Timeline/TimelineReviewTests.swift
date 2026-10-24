import GRDB
import XCTest
@testable import strius

/// 2026-10-25 の改修: 3 つの正誤、スキルの ID で付ける ○×、今日の答案の一覧、見直し、台帳に書く tool、キャッシュの先頭。
final class TimelineReviewTests: XCTestCase {
    typealias F = TimelineFixture

    private func grading(_ grade: String, skills: [String], answer: String = "0", notes: String = "", transcript: String = "") throws -> TimelineMachine.Grading {
        let object: [String: Any] = ["readable": true, "grade": grade, "learner_answer": answer, "skill_ids": skills, "transcript": transcript,
                                     "notes": notes, "comment": "", "key_suspect": false]
        return try TimelineMachine.Grading.parse(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    private func machine() -> TimelineMachine {
        var machine = F.machine()
        machine.put("test", F.skill("fourier.antiderivative_trig"))
        machine.put("test", F.skill("fourier.trig_values"))
        machine.put("test", F.card("c1", level: 2, skills: ["fourier.trig_values", "fourier.antiderivative_trig"]))
        return machine
    }

    // MARK: 採点

    func testAnswerRightButWorkWrongIsPartialAndMarksOnlyTheNamedSkillWrong() throws {
        var machine = machine()
        let attempt = machine.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 40, assisted: false)
        // 21:25 ∫₀^π cos 2x dx: 原始関数を −2 sin 2x と書いたが、sin の値が 0 なので答えは 0 で合った。
        let outcome = machine.applyGrading(attemptID: attempt, grading: try grading("partial", skills: ["fourier.antiderivative_trig"],
                                                                                     notes: "原始関数の係数と符号が違う", transcript: "[-2 sin 2x]_0^π = 0"))
        XCTAssertEqual(outcome.verdict, "wrong", "途中が間違っていれば、切り替え・正答率・定着では × として数える")
        let row = try XCTUnwrap(machine.attempts[attempt])
        XCTAssertEqual(row.grade, "partial")
        XCTAssertEqual(row.skillMarks, ["fourier.antiderivative_trig": "wrong"])
        XCTAssertEqual(machine.skills["fourier.antiderivative_trig"]?.attempts, 1)
        XCTAssertEqual(machine.skills["fourier.antiderivative_trig"]?.correctDays, 0)
        // 名前の挙がっていない「三角関数の値」には何も付けない(カード全体の正誤をカードの全スキルに付けない)。
        XCTAssertEqual(machine.skills["fourier.trig_values"]?.attempts, 0)
        XCTAssertEqual(machine.skillResults.map(\.skill), ["fourier.antiderivative_trig"])
    }

    func testTwoOrMoreSkillIDsAreHeldForTheReviewAndUnknownIDsAreDropped() throws {
        var machine = machine()
        let attempt = machine.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 40, assisted: false)
        _ = machine.applyGrading(attemptID: attempt, grading: try grading("wrong", skills: ["fourier.antiderivative_trig", "fourier.trig_values", "nowhere.skill"]))
        let row = try XCTUnwrap(machine.attempts[attempt])
        XCTAssertEqual(row.skillIds, ["fourier.antiderivative_trig", "fourier.trig_values"])
        XCTAssertEqual(row.skillsPending, true)
        XCTAssertNil(row.skillMarks)
        XCTAssertEqual(machine.skills.values.map(\.attempts).reduce(0, +), 0, "2 つ以上なら付けずに置く")

        // 見直しで決める。
        let text = #"{"skill_results":[{"attempt_id":"\#(attempt)","skill_id":"fourier.antiderivative_trig","result":"wrong"},{"attempt_id":"\#(attempt)","skill_id":"fourier.trig_values","result":"correct"}],"notes":"下端の符号の誤り。cos 0 の値は合っている"}"#
        machine.applyReview(targetID: attempt, review: try TimelineMachine.Review.parse(text))
        let reviewed = try XCTUnwrap(machine.attempts[attempt])
        XCTAssertEqual(reviewed.skillMarks, ["fourier.antiderivative_trig": "wrong", "fourier.trig_values": "correct"])
        XCTAssertEqual(reviewed.skillsPending, false)
        XCTAssertNotNil(reviewed.reviewedAt)
        XCTAssertEqual(reviewed.reviewNotes, "下端の符号の誤り。cos 0 の値は合っている")
        XCTAssertEqual(machine.skills["fourier.antiderivative_trig"]?.attempts, 1)
        XCTAssertEqual(machine.skills["fourier.trig_values"]?.correctDays, 1)
    }

    func testLegacyGradingWithoutSkillIDsStillReads() throws {
        var machine = machine()
        let attempt = machine.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 40, assisted: false)
        let legacy = try TimelineMachine.Grading.parse(#"{"readable":true,"verdict":"correct","learner_answer":"0","feedback":"正解です。"}"#)
        XCTAssertEqual(legacy.grade, "correct")
        XCTAssertNil(legacy.skillIds)
        _ = machine.applyGrading(attemptID: attempt, grading: legacy)
        XCTAssertEqual(machine.attempts[attempt]?.feedback, "正解です。")
        XCTAssertEqual(machine.attempts[attempt]?.verdict, "correct")
    }

    // MARK: 今日の答案の一覧

    func testTodaysLogCarriesNotesAndTranscriptAndOnlyGrowsAtTheEnd() throws {
        var machine = machine()
        machine.put("test", F.card("c2", level: 2, skills: ["fourier.antiderivative_trig"]))
        let first = machine.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 40, assisted: false)
        _ = machine.applyGrading(attemptID: first, grading: try grading("partial", skills: ["fourier.antiderivative_trig"], notes: "符号の誤り", transcript: "[-sin x]_0^π"))
        let before = TimelineTurns.answerLog(timeline: machine)
        XCTAssertTrue(before.contains("答えは合うが途中に誤り"))
        XCTAssertTrue(before.contains("符号の誤り"))
        XCTAssertTrue(before.contains("[-sin x]_0^π"))
        XCTAssertTrue(before.contains(first))
        let second = machine.recordCapture(cardID: "c2", capturePath: "u.jpg", seconds: 50, assisted: false)
        _ = machine.applyGrading(attemptID: second, grading: try grading("correct", skills: ["fourier.antiderivative_trig"]))
        let after = TimelineTurns.answerLog(timeline: machine)
        XCTAssertTrue(after.hasPrefix(before), "前の依頼の一覧はそのまま残り、後ろに足すだけ(キャッシュが読める)")
    }

    // MARK: 台帳に書く tool

    func testWriteToolsPutCardsNextAndReviseAnEarlierJudgement() throws {
        var machine = machine()
        machine.put("test", F.card("next", level: 2, position: 10, skills: ["fourier.trig_values"]))
        let attempt = machine.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 40, assisted: false)
        _ = machine.applyGrading(attemptID: attempt, grading: try grading("correct", skills: ["fourier.antiderivative_trig"]))
        XCTAssertEqual(machine.skills["fourier.antiderivative_trig"]?.correctDays, 1)

        let added = TimelineWriteTools.apply(name: "timeline_add_card", arguments: [
            "prompt": .string("次の定積分を計算しなさい。"), "math": .string("\\int_0^{\\pi/2} \\cos 2x \\, dx"), "answer_key": .string("0"),
            "skill_ids": .array([.string("fourier.antiderivative_trig")]), "note": .string("区間を左右非対称にして確かめる"),
        ], machine: &machine)
        XCTAssertTrue(added.success)
        XCTAssertEqual(machine.queue.first?.origin, "review", "確かめの 1 問は、生徒が次に解く位置に入る")
        let asked = TimelineWriteTools.apply(name: "timeline_ask", arguments: ["question": .string("この記号はどちらですか。"), "options": .array([.string("1/3"), .string("-1/3")])], machine: &machine)
        XCTAssertTrue(asked.success)
        XCTAssertEqual(machine.queue.first?.kind, "ask")

        let revised = TimelineWriteTools.apply(name: "timeline_revise", arguments: [
            "attempt_id": .string(attempt), "grade": .string("partial"), "note": .string("途中の原始関数が違っていた"),
        ], machine: &machine)
        XCTAssertTrue(revised.success, revised.text)
        let row = try XCTUnwrap(machine.attempts[attempt])
        XCTAssertEqual(row.grade, "partial")
        XCTAssertEqual(row.verdict, "wrong")
        XCTAssertEqual(row.skillMarks, ["fourier.antiderivative_trig": "wrong"])
        XCTAssertTrue(row.reviewNotes?.contains("途中の原始関数が違っていた") == true)
        XCTAssertTrue(machine.changes.values.contains { $0.kind == "revise_grade" })
        let notice = TimelineWriteTools.apply(name: "timeline_notice", arguments: ["text": .string("前の問題の判定を直しました。")], machine: &machine)
        XCTAssertTrue(notice.success)
        XCTAssertEqual(machine.queue.first?.kind, "notice")
        XCTAssertFalse(TimelineWriteTools.apply(name: "timeline_revise", arguments: ["attempt_id": .string("nope"), "grade": .string("wrong"), "note": .string("")], machine: &machine).success)
    }

    func testSQLQueryReadsTheLedgerAndRefusesWrites() async throws {
        let ledger = try Ledger.inMemory()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", F.skill("fourier.trig_values"))
            return (timeline.events, ())
        }
        let rows = try await ledger.read { db in try TimelineGraph.query(db: db, arguments: ["query": .string("sql"), "sql": .string("SELECT id, status FROM timeline_skills")]) }
        XCTAssertTrue(rows.contains("fourier.trig_values"), rows)
        let write = try await ledger.read { db in try TimelineGraph.query(db: db, arguments: ["query": .string("sql"), "sql": .string("DELETE FROM timeline_skills")]) }
        XCTAssertFalse(write.contains("(0 行)"))
        let sneaky = try await ledger.read { db in try TimelineGraph.query(db: db, arguments: ["query": .string("sql"), "sql": .string("WITH x AS (SELECT 1) DELETE FROM timeline_skills")]) }
        XCTAssertTrue(sneaky.contains("できませんでした"), sneaky)
        let still = try await ledger.read { db in try TimelineSkillRecord.fetchCount(db) }
        XCTAssertEqual(still, 1)
    }

    // MARK: 出題

    func testUnreadableChecksAreNoLongerPassed() {
        XCTAssertEqual(TimelineCards.verificationFailures([("∫ sin x dx", "1")]).count, 1)
        XCTAssertTrue(TimelineCards.verificationFailures([("2*2^2-8*2+3", "-5")]).isEmpty)
    }

    func testNumericVariantAndEasierAreRecordedSeparately() throws {
        var machine = F.machine()
        machine.put("test", F.card("base", level: 2, payload: ["variant": .object(["level": .number(2), "prompt": .string("数値を変えた"), "math": .string("y = x^2 + 1"),
                                                                                  "question": .string(""), "answer_key": .string("1"), "answer_expr": .string("1"),
                                                                                  "checkpoints": .array([])])]))
        let variant = try XCTUnwrap(machine.makeEasier(of: "base", preferVariant: true))
        XCTAssertEqual(machine.cards[variant]?.origin, "variant")
        // 数値を変えた問題も ×: 元のカードのやさしくした問題(「一段戻す」)へ。
        let next = TimelineRules.next(after: machine.cards[variant]!, outcome: .wrong, queue: [], rapid: [], wrongBefore: false, base: machine.cards["base"])
        XCTAssertEqual(next.makeEasierOf, "base")
        let easier = try XCTUnwrap(machine.makeEasier(of: "base"))
        XCTAssertNotEqual(easier, variant)
        XCTAssertEqual(machine.cards[easier]?.origin, "easier")
        // 数値を変えた問題は正答率に数える(やさしくした問題は数えない)。
        XCTAssertTrue(TimelineRules.countsForAccuracy(card: machine.cards[variant]!, isFirstOfDay: false, verdict: "correct"))
        XCTAssertFalse(TimelineRules.countsForAccuracy(card: machine.cards[easier]!, isFirstOfDay: false, verdict: "correct"))
    }

    // MARK: キャッシュ

    /// Codex が送る形を真似た、2 回の採点の要求(作業フォルダの場所・問題・画像が違う)。
    private func codexGrading(planID: String, log: String, problem: String) -> [String: Any] {
        [
            "model": "claude-sonnet-5-5", "instructions": "BASE\n\nSHARED\n\nUNIT",
            "tools": [["type": "namespace", "name": "struis", "tools": [["type": "function", "name": "timeline_query", "parameters": ["type": "object", "properties": [:]]]]]],
            "reasoning": ["effort": "low"], "text": ["format": ["type": "json_schema", "schema": ["type": "object", "properties": ["grade": ["type": "string"]]]]],
            "input": [
                ["type": "message", "role": "developer", "content": [["type": "input_text", "text": log + "\n\n<permissions instructions>Full access.</permissions instructions>"]]],
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context><cwd>/workspace/\(planID)</cwd></environment_context>"]]],
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "# 今回の仕事: 採点\n\n# 今回の材料\n" + problem],
                                                               ["type": "input_image", "image_url": "data:image/jpeg;base64,/9j/4AAQ"]]],
            ],
        ]
    }

    func testVersionThreeKeepsTheSharedPrefixAndMarksTheSharedPartAndTheLog() throws {
        var options = ClaudeRequestTranslator.Options()
        options.translation = ClaudeTranslation.tutor
        options.tailCacheTTL = ClaudeTranslation.tailCacheTTL(kind: "timeline_grading")
        let log1 = "# 今日の答案\n\n## 21:25 答案 a1"
        let log2 = log1 + "\n\n## 21:27 答案 a2"
        let first = try ClaudeRequestTranslator.translate(codexGrading(planID: "plan-1", log: log1, problem: "{\"problem\":\"cos 2x\"}"), options: options).body
        let second = try ClaudeRequestTranslator.translate(codexGrading(planID: "plan-2", log: log2, problem: "{\"problem\":\"cos x\"}"), options: options).body
        let system1 = try XCTUnwrap(first["system"] as? [[String: Any]])
        let system2 = try XCTUnwrap(second["system"] as? [[String: Any]])
        XCTAssertEqual(system1.count, 2)
        XCTAssertEqual(system1[0]["text"] as? String, "BASE\n\nSHARED\n\nUNIT")
        XCTAssertEqual(system1[0]["cache_control"] as? [String: String], ["type": "ephemeral"], "寿命は 5 分")
        XCTAssertEqual(system1[1]["cache_control"] as? [String: String], ["type": "ephemeral"])
        // 1 つ目(どの依頼にも同じもの)は 2 回で 1 文字も違わない。作業フォルダの場所は先頭に入らない。
        let block1 = try JSONSerialization.data(withJSONObject: system1[0], options: [.sortedKeys])
        let block2 = try JSONSerialization.data(withJSONObject: system2[0], options: [.sortedKeys])
        XCTAssertEqual(block1, block2)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: system1), as: UTF8.self).contains("plan-1"))
        XCTAssertTrue((system2[1]["text"] as? String)?.hasPrefix(log1) == true)
        let tools1 = try JSONSerialization.data(withJSONObject: first["tools"] ?? [], options: [.sortedKeys])
        let tools2 = try JSONSerialization.data(withJSONObject: second["tools"] ?? [], options: [.sortedKeys])
        XCTAssertEqual(tools1, tools2)

        // 版 2(会話・単元ホーム)の形は変えない。
        options.translation = 2
        let legacy = try ClaudeRequestTranslator.translate(codexGrading(planID: "plan-1", log: log1, problem: "{}"), options: options).body
        XCTAssertEqual((legacy["system"] as? [[String: Any]])?.count, 1)
    }
}
