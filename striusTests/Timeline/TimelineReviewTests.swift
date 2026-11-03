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

    // MARK: 今日の記録

    private func workbook() -> WorkbookMachine {
        var workbook = WorkbookMachine()
        workbook.units["u1"] = WorkbookUnitRecord(id: "u1", title: "フーリエ級数", outcome: "", status: "active", source: "manual", position: 0,
                                                  overview: .emptyObject, createdAt: F.now, updatedAt: F.now, passedAt: nil)
        return workbook
    }

    /// 前回の今日の記録(終わりの印を除いた本文)が、今回の記録の先頭とバイト単位で一致し、その後ろに区切りが続く。
    private func assertGrows(_ before: String, _ after: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(before.hasSuffix(ClaudeTranslation.logEnd), message, file: file, line: line)
        let body = String(before.dropLast(ClaudeTranslation.logEnd.count))
        XCTAssertTrue(after.utf8.starts(with: (body + ClaudeTranslation.blockSeparator).utf8), message, file: file, line: line)
        XCTAssertNotEqual(before, after, message, file: file, line: line)
    }

    func testTodaysLogIsWrittenWhenThingsHappenAndOnlyGrowsAtTheEnd() throws {
        var machine = machine()
        let workbook = workbook()
        machine.put("test", F.card("c2", level: 2, skills: ["fourier.antiderivative_trig"]))
        // その日最初の依頼: 今の単元とスキルの一覧が最初の 1 件。
        TimelineTurns.syncLog(workbook: workbook, timeline: &machine)
        let start = TimelineTurns.answerLog(timeline: machine)
        XCTAssertTrue(start.contains("## 今の単元\n- フーリエ級数(u1)"))
        XCTAssertTrue(start.contains("fourier.trig_values"))

        // 2 問続けて撮り、後に撮った方の採点が先に終わる: 記録は保存した順(撮った順ではない)。
        let first = machine.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 40, assisted: false)
        let second = machine.recordCapture(cardID: "c2", capturePath: "u.jpg", seconds: 50, assisted: false)
        XCTAssertEqual(TimelineTurns.answerLog(timeline: machine), start, "採点中の答案は記録に載せない")
        _ = machine.applyGrading(attemptID: second, grading: try grading("correct", skills: ["fourier.antiderivative_trig"]))
        let afterSecond = TimelineTurns.answerLog(timeline: machine)
        assertGrows(start, afterSecond, "採点が終わった")
        _ = machine.applyGrading(attemptID: first, grading: try grading("partial", skills: ["fourier.trig_values", "fourier.antiderivative_trig"],
                                                                    notes: "符号の誤り", transcript: "[-sin x]_0^π"))
        let afterFirst = TimelineTurns.answerLog(timeline: machine)
        assertGrows(afterSecond, afterFirst, "前に撮った答案の採点が後から終わった")
        XCTAssertLessThan(try XCTUnwrap(afterFirst.range(of: "答案 \(second)")).lowerBound, try XCTUnwrap(afterFirst.range(of: "答案 \(first)")).lowerBound)
        XCTAssertTrue(afterFirst.contains("答えは合うが途中に誤り"))
        XCTAssertTrue(afterFirst.contains("符号の誤り"))
        XCTAssertTrue(afterFirst.contains("[-sin x]_0^π"))
        XCTAssertTrue(afterFirst.contains("(○× は見直しで決める)"))

        // 見直しの結果(メモと確定したスキルの ○×): 前の答案の項目は書き換えず、後ろに足す。
        let review = try TimelineMachine.Review.parse(#"{"notes":"原始関数の係数を落としている","skill_results":[{"attempt_id":"\#(first)","skill_id":"fourier.antiderivative_trig","result":"wrong"},{"attempt_id":"\#(first)","skill_id":"fourier.trig_values","result":"correct"}]}"#)
        machine.applyReview(targetID: first, review: review)
        let afterReview = TimelineTurns.answerLog(timeline: machine)
        assertGrows(afterFirst, afterReview, "見直しの結果")
        XCTAssertTrue(afterReview.contains("原始関数の係数を落としている"))
        XCTAssertTrue(afterReview.contains("fourier.antiderivative_trig(fourier.antiderivative_trig) ×"))

        // 判定の取り消し。
        XCTAssertNil(machine.revise(attemptID: second, grade: "wrong", marks: nil, note: "途中の符号が違っていた"))
        let afterRevise = TimelineTurns.answerLog(timeline: machine)
        assertGrows(afterReview, afterRevise, "判定の取り消し")
        XCTAssertTrue(afterRevise.contains("判定を直した(答案 \(second): 正解 → 誤答)"))
        XCTAssertTrue(afterRevise.contains("理由: 途中の符号が違っていた"))

        // 生徒の申し出。
        machine.recordDispute(attemptID: first, text: "途中も合っているはずです")
        XCTAssertEqual(machine.attempts[first]?.disputedAt, F.now)
        let afterDispute = TimelineTurns.answerLog(timeline: machine)
        assertGrows(afterRevise, afterDispute, "申し出")
        XCTAssertTrue(afterDispute.contains("途中も合っているはずです"))

        // スキルが足された: 次の依頼の前に、足された分だけが後ろに入る(基本指示は変わらない)。
        TimelineTurns.syncLog(workbook: workbook, timeline: &machine)
        XCTAssertEqual(TimelineTurns.answerLog(timeline: machine), afterDispute, "変わった分が無ければ何も足さない")
        machine.put("test", F.skill("fourier.sin_kpi"))
        TimelineTurns.syncLog(workbook: workbook, timeline: &machine)
        let afterSkill = TimelineTurns.answerLog(timeline: machine)
        assertGrows(afterDispute, afterSkill, "スキルが足された")
        XCTAssertTrue(afterSkill.hasSuffix("## スキルが足された\n- fourier.sin_kpi(fourier.sin_kpi)" + ClaudeTranslation.logEnd))

        // 飛ばした答案と理由。
        machine.put("test", F.card("c3", level: 2))
        let skipped = machine.recordSkip(cardID: "c3", seconds: 5)
        machine.setSkipReason(attemptID: skipped, reason: "too_hard")
        let afterSkip = TimelineTurns.answerLog(timeline: machine)
        assertGrows(afterSkill, afterSkip, "飛ばした")
        XCTAssertTrue(afterSkip.contains("を飛ばした理由: 難しすぎる"))
    }

    func testFirstContextOfTheDayGoesBeforeAnswersLoggedBeforeTheFirstRequest() throws {
        var machine = machine()
        machine.put("test", F.card("c2", level: 2))
        let skipped = machine.recordSkip(cardID: "c2", seconds: 3)
        TimelineTurns.syncLog(workbook: workbook(), timeline: &machine)
        let entries = machine.todayLog
        XCTAssertEqual(entries.map(\.kind), ["context", "attempt"])
        XCTAssertEqual(entries.last?.attemptId, skipped)
        // この版より前の答案(記録が無い)は、次の依頼の前に足す。
        machine.put("test", F.attempt("old", card: "c1", verdict: "correct"))
        TimelineTurns.syncLog(workbook: workbook(), timeline: &machine)
        XCTAssertEqual(machine.todayLog.last?.attemptId, "old")
        // 別の日の記録は載せない。
        machine.now = { "2026-10-24T06:00:00.000000Z" }
        XCTAssertEqual(TimelineTurns.answerLog(timeline: machine), "# 今日の記録" + ClaudeTranslation.blockSeparator + "まだありません。" + ClaudeTranslation.logEnd)
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

    private func schema(_ name: String) -> String {
        ClaudeTranslation.schemaInstruction(["type": "object", "properties": [name: ["type": "string"]], "required": [name]])
    }

    /// タイムラインの依頼の system(`ClaudeTurn` が版 4 で送るもの): 基本指示と、developer 指示(今日の記録)。
    private func system(log: String, schema: String) -> [[String: Any]] {
        ClaudeTranslation.tutorSystem(parts: ["BASE\n\nSHARED\n\nTOOLS", log], schema: schema)
    }

    func testVersionFourSendsEachLogEntryAsABlockAndKeepsTheSharedPartByteForByte() throws {
        var machine = machine()
        TimelineTurns.syncLog(workbook: workbook(), timeline: &machine)
        let attempt = machine.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 40, assisted: false)
        _ = machine.applyGrading(attemptID: attempt, grading: try grading("correct", skills: ["fourier.antiderivative_trig"]))
        let log1 = TimelineTurns.answerLog(timeline: machine)
        machine.recordDispute(attemptID: attempt, text: "")
        let log2 = TimelineTurns.answerLog(timeline: machine)

        XCTAssertEqual(ClaudeTranslation.version(kind: "timeline_grading"), 4)
        let system1: [[String: Any]] = system(log: log1, schema: schema("grade"))
        let system2: [[String: Any]] = system(log: log2, schema: schema("notes"))
        let system3: [[String: Any]] = system(log: log2, schema: schema("cards"))
        // 基本指示 + 記録の見出し + 単元とスキル + 答案 1 件 + 出力の形。
        XCTAssertEqual(system1.count, 5)
        XCTAssertEqual(system2.count, 6, "申し出の 1 件が増えた")
        XCTAssertEqual(system1[0]["text"] as? String, "BASE\n\nSHARED\n\nTOOLS")
        let hour: [String: String] = ["type": "ephemeral", "ttl": "1h"]
        XCTAssertEqual(system1[0]["cache_control"] as? [String: String], hour, "基本指示の最後に 1 時間の印")
        XCTAssertEqual(system1[3]["cache_control"] as? [String: String], hour, "今日の記録の最後のブロックに 1 時間の印")
        XCTAssertEqual(system2[4]["cache_control"] as? [String: String], hour)
        XCTAssertEqual(system1.filter { $0["cache_control"] != nil }.count, 2)
        XCTAssertEqual(system2.filter { $0["cache_control"] != nil }.count, 2)
        XCTAssertTrue((system1[4]["text"] as? String)?.contains("JSON Schema") == true, "出力の形は文章で、記録の後ろ")
        XCTAssertNil(system1[4]["cache_control"])
        XCTAssertTrue((system1[3]["text"] as? String)?.hasPrefix("## ") == true)
        XCTAssertFalse(system1.contains { ($0["text"] as? String)?.contains("struis:block") == true || ($0["text"] as? String)?.contains("struis:log-end") == true },
                       "区切りの印はモデルに送らない")

        // 採点 → 見直し → 出題で、基本指示と今日の記録(前回の印まで)は 1 バイトも違わない。
        func bytes(_ blocks: ArraySlice<[String: Any]>) throws -> Data { try JSONSerialization.data(withJSONObject: Array(blocks).map { $0.filter { $0.key != "cache_control" } }, options: [.sortedKeys]) }
        XCTAssertEqual(try bytes(system1[0...3]), try bytes(system2[0...3]))
        XCTAssertEqual(try bytes(system2[0...4]), try bytes(system3[0...4]))
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: system2[0...4].map { $0 }, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: system3[0...4].map { $0 }, options: [.sortedKeys]))
        // tools(system より前のキャッシュの先頭)は、タイムラインの依頼の種類をまたいで同じ。
        func tools(_ kind: TurnPlan.Kind) throws -> Data {
            let names: ClaudeToolNames = ClaudeToolNames(responsesTools: NativeToolRouter.definitions(for: kind) + [ClaudeTurn.viewImageTool], sorted: true)
            return try JSONSerialization.data(withJSONObject: names.claudeTools, options: [.sortedKeys])
        }
        XCTAssertEqual(try tools(.timelineGrading), try tools(.timelineBatch))
        XCTAssertEqual(try tools(.timelineGrading), try tools(.timelineReview))

        // 記録の終わりより後ろに足した注記は、印の無い別のブロックにする。
        let noted: [[String: Any]] = system(log: log1 + "\n\nStruis note", schema: schema("grade"))
        XCTAssertEqual(noted.count, 6)
        XCTAssertEqual(noted[4]["text"] as? String, "Struis note")
        XCTAssertNil(noted[4]["cache_control"])
        XCTAssertEqual(noted[3]["cache_control"] as? [String: String], hour)
    }

    func testVersionFourMarksTheTailOnlyForContinuationsAfterATool() throws {
        let translation: Int = ClaudeTranslation.version(kind: "timeline_review")
        let start: [[String: Any]] = [["role": "user", "content": [["type": "text", "text": "# 今回の仕事: 見直し"]]]]
        XCTAssertFalse(ClaudeTranslation.marksTail(translation: translation, messages: start), "turn_start")

        // 頼み直し(validation_repair): 前の返事の後ろに、理由を添えた同じ仕事が来る。
        let repair: [[String: Any]] = start + [
            ["role": "assistant", "content": [["type": "text", "text": "読めない返事"]]],
            ["role": "user", "content": [["type": "text", "text": "# 前の返事について"]]],
        ]
        XCTAssertFalse(ClaudeTranslation.marksTail(translation: translation, messages: repair), "validation_repair")

        // 道具を使った後の続き(continuation)だけ、末尾に 5 分の印。
        let continuation: [[String: Any]] = start + [
            ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_1", "name": "struis__timeline_query", "input": [String: Any]()]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "rows"]]],
        ]
        XCTAssertTrue(ClaudeTranslation.marksTail(translation: translation, messages: continuation))
        // 末尾の印は 5 分(既定の ttl なし)。1 時間の印は system の 2 つのまま。
        XCTAssertEqual(ClaudeTranslation.tailCacheTTL(kind: "timeline_review"), "5m")
        XCTAssertEqual(ClaudeTranslation.cacheControl(ttl: nil) as? [String: String], ["type": "ephemeral"])
        let log: String = "# 今日の記録" + ClaudeTranslation.blockSeparator + "まだありません。" + ClaudeTranslation.logEnd
        XCTAssertEqual(system(log: log, schema: schema("notes")).filter { $0["cache_control"] != nil }.count, 2, "1 時間の印は今のまま")

        // 版 2(会話・単元ホーム)は最初の要求にも付ける。
        XCTAssertTrue(ClaudeTranslation.marksTail(translation: 2, messages: start))
    }

    func testRepliesWithProseBeforeTheJSONAreRead() throws {
        // 10/27 15:51 の採点と同じ形: 日本語の文 → JSON(文字列の中に {・}・\\frac)。
        let gradingReply = #"""
        画像の手書きは次のように読めます。

        - 1行目: ∫_0^{π/2} sin2x dx = [-\frac{1}{2}cos2x]_0^{π/2}
        - 2行目: 1/2 + 1/2 = 1 }

        {"readable":true,"grade":"correct","learner_answer":"1","skill_ids":["fourier.antiderivative_trig"],"transcript":"$[-\\frac{1}{2}\\cos 2x]_0^{\\pi/2}$","notes":"原始関数 {符号} も正しく、$\\frac{1}{2}+\\frac{1}{2}=1$ と計算できています。","comment":"よくできました。","key_suspect":false}
        """#
        let grading = try TimelineMachine.Grading.parse(gradingReply)
        XCTAssertEqual(grading.grade, "correct")
        XCTAssertEqual(grading.skillIds, ["fourier.antiderivative_trig"])
        XCTAssertEqual(grading.notes, #"原始関数 {符号} も正しく、$\frac{1}{2}+\frac{1}{2}=1$ と計算できています。"#)

        // 10/27 15:45 の見直しと同じ形(入れ子のオブジェクトと、文字列の中のエスケープした引用符)。
        let reviewReply = #"""
        handwriting を確認すると、次のように計算しています。{ 途中の括弧
        {"skill_results":[{"attempt_id":"a1","skill_id":"fourier.antiderivative_trig","result":"correct"}],"notes":"\"\\frac{1}{2}\" の {係数} は正しい。かなり慎重または中断があった可能性がある。"}
        """#
        let review = try TimelineMachine.Review.parse(reviewReply)
        XCTAssertEqual(review.notes, #""\frac{1}{2}" の {係数} は正しい。かなり慎重または中断があった可能性がある。"#)
        XCTAssertEqual(review.skillResults.count, 1)

        let batch = try TimelineCards.Batch.parse("次の 5 枚です。\n```json\n{\"reason\":\"符号 {−} を確かめる\",\"cards\":[]}\n```")
        XCTAssertEqual(batch.reason, "符号 {−} を確かめる")

        // 取り出したものも読めない時だけ、頼み直しに回す。
        XCTAssertThrowsError(try TimelineMachine.Grading.parse("読めました。{\"grade\": "))
        XCTAssertThrowsError(try TimelineMachine.Review.parse("JSON はありません"))
        XCTAssertEqual(TimelineReply.lastObject(in: #"前 {"a":"}{\\"} 後"#), #"{"a":"}{\\"}"#)
    }

    func testTimelineRequestsCompareCacheDiagnosticsAcrossKinds() {
        XCTAssertEqual(ClaudeTranslation.diagnosticsKey(threadID: "t1", kind: "timeline_grading"), ClaudeTranslation.diagnosticsKey(threadID: "t2", kind: "timeline_review"))
        XCTAssertEqual(ClaudeTranslation.diagnosticsKey(threadID: "t3", kind: "timeline_batch"), "timeline-tutor")
        XCTAssertEqual(ClaudeTranslation.diagnosticsKey(threadID: "t4", kind: "chat"), "t4")
        XCTAssertEqual(ClaudeTranslation.diagnosticsKey(threadID: "t5", kind: "timeline_graph"), "t5")
        // 設定でモデルを切り替えた後は、同じモデルの直前の依頼と比べる。
        XCTAssertEqual(ClaudeTranslation.diagnosticsKey(threadID: "t6", kind: "timeline_grading", model: "claude-haiku-5-5"),
                       ClaudeTranslation.diagnosticsKey(threadID: "t7", kind: "timeline_batch", model: "claude-haiku-5-5"))
        XCTAssertNotEqual(ClaudeTranslation.diagnosticsKey(threadID: "t6", kind: "timeline_grading", model: "claude-haiku-5-5"),
                          ClaudeTranslation.diagnosticsKey(threadID: "t6", kind: "timeline_grading", model: "claude-sonnet-5-5"))
        XCTAssertEqual(ClaudeTranslation.diagnosticsKey(threadID: "t8", kind: "chat", model: "claude-haiku-5-5"), "t8")
        XCTAssertEqual(ClaudeTranslation.systemCacheTTL(translation: 4, tail: "5m"), "1h")
    }

    // MARK: 形に合わない返事

    func testUnreadableReplyIsAskedAgainOnceWithTheReason() async throws {
        let ledger = try Ledger.inMemory()
        let attemptID: String = try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", F.card("c1"))
            let id = timeline.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 3, assisted: false)
            return (timeline.events, id)
        }
        func outcome(_ round: Int, _ text: String) -> TurnOutcome {
            TurnOutcome(planID: "p", round: round, status: .completed, codexThreadID: nil, codexTurnID: nil, finalText: text, executions: [],
                        rateLimits: nil, files: [], error: nil, elapsedMs: 1)
        }
        let first = try await ledger.commit { db in
            let applied = try TimelineTurns.apply(kind: .timelineGrading, targetID: attemptID, outcome: outcome(1, "採点しました"), model: "m", db: db)
            return (applied.events, applied.followUp)
        }
        XCTAssertTrue(first.retry)
        XCTAssertTrue(first.repair?.contains("JSON") == true, first.repair ?? "")
        var verdict = try await ledger.read { db in try TimelineAttemptRecord.fetchOne(db, key: attemptID)?.verdict }
        XCTAssertEqual(verdict, "grading", "頼み直す間は採点中のまま")
        let text = TimelineTurns.turnText(task: "# 今回の仕事: 採点", materials: .emptyObject, repair: first.repair)
        XCTAssertTrue(text.hasPrefix("# 今回の仕事: 採点"), "今回の仕事と材料は同じ")
        XCTAssertTrue(text.contains("# 前の返事について"))
        let second = try await ledger.commit { db in
            let applied = try TimelineTurns.apply(kind: .timelineGrading, targetID: attemptID, outcome: outcome(2, "やはり読めませんでした"), model: "m", db: db)
            return (applied.events, applied.followUp)
        }
        XCTAssertFalse(second.retry, "頼み直すのは 1 回だけ")
        verdict = try await ledger.read { db in try TimelineAttemptRecord.fetchOne(db, key: attemptID)?.verdict }
        XCTAssertEqual(verdict, "failed")
        XCTAssertEqual(TimelineTurns.parseProblem(DecodingError.keyNotFound(TimelineMachine.Grading.CodingKeys.grade, .init(codingPath: [], debugDescription: "")), text: "{}"), "項目 grade がありません")
    }
}
