import GRDB
import XCTest
@testable import strius

/// タイムラインの新しい形(`TimelinePlanMode`): Opus を呼ぶ時(その日最初・採点の返事から)と、続くスレッドの決まり。
final class TimelinePlanModeTests: XCTestCase {
    typealias F = TimelineFixture

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: TimelinePlanMode.defaultsKey)
        TimelinePlanMode.reset()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TimelinePlanMode.defaultsKey)
        TimelinePlanMode.reset()
        super.tearDown()
    }

    /// 計画が届いた状態にする(Opus の返事を反映した時と同じ形)。
    @discardableResult
    private static func readyPlan(_ plan: String, timeline: inout TimelineMachine) -> String {
        let id = TimelinePlanMode.insertPlanRequest(log: "", timeline: &timeline)
        var row = timeline.batches[id]!
        row.request = .object(["task": .string("plan"), "plan": .string(plan)])
        row.status = "ready"
        timeline.put("timeline.plan_ready", row)
        return id
    }

    func testMorningPlanIsRequestedOncePerDay() {
        var timeline = F.machine()
        let first = TimelinePlanMode.requestPlan(trigger: .morning, timeline: &timeline)
        XCTAssertNotNil(first)
        XCTAssertEqual(timeline.batches[first!]?.request["trigger"]?.stringValue, "morning")
        XCTAssertNil(TimelinePlanMode.requestPlan(trigger: .morning, timeline: &timeline), "返事を待っている間は頼まない")
        timeline.failBatch(id: first!, error: "boom")
        XCTAssertNil(TimelinePlanMode.requestPlan(trigger: .morning, timeline: &timeline), "失敗しても、その日はもう頼まない")
        timeline.now = { "2026-10-24T06:00:00.000000Z" }
        XCTAssertNotNil(TimelinePlanMode.requestPlan(trigger: .morning, timeline: &timeline), "次の日は頼む")
    }

    func testMorningIsOffWhenPlanModeIsOff() {
        UserDefaults.standard.removeObject(forKey: TimelinePlanMode.defaultsKey)
        var timeline = F.machine()
        XCTAssertNil(TimelinePlanMode.requestPlan(trigger: .morning, timeline: &timeline))
    }

    func testEscalationWaitsForFiveAnswersAndHappensOncePerDay() {
        var timeline = F.machine()
        Self.readyPlan("focus: クーロン", timeline: &timeline)
        for index in 1...4 {
            timeline.put("test", F.attempt("a\(index)", card: "c1", verdict: "wrong", createdAt: "2026-10-23T07:00:0\(index).000000Z"))
        }
        XCTAssertNil(TimelinePlanMode.requestPlan(trigger: .escalation, reason: "1/r が続く", timeline: &timeline), "計画のあと 4 問では呼ばない")
        timeline.put("test", F.attempt("a5", card: "c1", verdict: "skipped", createdAt: "2026-10-23T07:00:05.000000Z"))
        let escalation = TimelinePlanMode.requestPlan(trigger: .escalation, reason: "1/r が続く", timeline: &timeline)
        XCTAssertNotNil(escalation, "飛ばしも数えて 5 問で呼ぶ")
        XCTAssertEqual(timeline.batches[escalation!]?.request["reason"]?.stringValue, "1/r が続く")
        XCTAssertEqual(timeline.batches[escalation!]?.request["trigger"]?.stringValue, "escalation")

        // 届いた計画のあとに 5 問解いても、その日 2 回目は呼ばない。
        timeline.now = { "2026-10-23T08:00:00.000000Z" }
        // アプリが返事を反映する時と同じく、依頼の中身(trigger・reason)は残して計画を足し、記録を外す。
        var row = timeline.batches[escalation!]!
        var request = row.request.objectValue ?? [:]
        request["plan"] = .string("focus: 比")
        request["log"] = nil
        row.request = .object(request)
        row.status = "ready"
        row.updatedAt = timeline.now()
        timeline.put("timeline.plan_ready", row)
        for index in 1...5 {
            timeline.put("test", F.attempt("b\(index)", card: "c1", verdict: "wrong", createdAt: "2026-10-23T09:00:0\(index).000000Z"))
        }
        XCTAssertNil(TimelinePlanMode.requestPlan(trigger: .escalation, reason: "まだ続く", timeline: &timeline))
        XCTAssertEqual(TimelinePlanMode.latestPlan(timeline), "focus: 比")
    }

    func testPlanLogReadsTheLastStudyDayInTheMorningAndTodayOnEscalation() {
        var timeline = F.machine(now: "2026-10-21T06:00:00.000000Z")
        timeline.appendLog(kind: "attempt", text: "おとといの答案")
        timeline.now = { "2026-10-22T06:00:00.000000Z" }
        timeline.appendLog(kind: "attempt", text: "前に学習した日の答案")
        timeline.now = { "2026-10-23T06:00:00.000000Z" }
        Self.readyPlan("focus: クーロン", timeline: &timeline)
        let morning = TimelinePlanMode.planLog(trigger: .morning, reason: nil, timeline: timeline)
        XCTAssertTrue(morning.contains("前に学習した日の答案"), morning)
        XCTAssertTrue(morning.contains("2026-10-22"), morning)
        XCTAssertFalse(morning.contains("おとといの答案"), "読むのは前に学習した 1 日だけ")
        XCTAssertTrue(morning.contains("focus: クーロン"), "今の計画を土台にさせる")

        timeline.appendLog(kind: "attempt", text: "今日の答案")
        let escalation = TimelinePlanMode.planLog(trigger: .escalation, reason: "1/r が 3 回", timeline: timeline)
        XCTAssertTrue(escalation.contains("1/r が 3 回"), escalation)
        XCTAssertTrue(escalation.contains("今日の答案"), escalation)
        XCTAssertFalse(escalation.contains("前に学習した日の答案"), escalation)
    }

    func testThreadContinuesOnlyWithThePlanItStartedWith() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        TimelinePlanMode.remember(turnID: "turn-1", planID: "plan-a")
        TimelinePlanMode.touch(threadID: "thread-1", turnID: "turn-1", now: start)
        XCTAssertEqual(TimelinePlanMode.session(planID: "plan-a", now: start.addingTimeInterval(600)), "thread-1")
        XCTAssertNil(TimelinePlanMode.session(planID: "plan-b", now: start.addingTimeInterval(600)), "新しい計画が届いたら新しいスレッド")
        XCTAssertNil(TimelinePlanMode.session(planID: "plan-a", now: start.addingTimeInterval(3_601)), "1 時間を過ぎたら新しいスレッド")

        // 計画を控えていないターン(この版より前に組んだターン)は、続くスレッドを書き換えない。
        TimelinePlanMode.touch(threadID: "thread-2", turnID: "turn-unknown", now: start)
        XCTAssertEqual(TimelinePlanMode.session(planID: "plan-a", now: start.addingTimeInterval(1)), "thread-1")

        // 計画がまだ無い時に始めたスレッドは、計画が無い間だけ続ける。
        TimelinePlanMode.remember(turnID: "turn-2", planID: nil)
        TimelinePlanMode.touch(threadID: "thread-3", turnID: "turn-2", now: start)
        XCTAssertEqual(TimelinePlanMode.session(planID: nil, now: start.addingTimeInterval(1)), "thread-3")
        XCTAssertNil(TimelinePlanMode.session(planID: "plan-a", now: start.addingTimeInterval(1)))
    }

    func testGradingAsksForEscalationAndResumesTheThreadOfTheSamePlan() async throws {
        let ledger = try Ledger.inMemory()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            Self.readyPlan("focus: クーロン", timeline: &timeline)
            timeline.put("test", F.card("c1"))
            _ = timeline.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 3, assisted: false)
            return (timeline.events, ())
        }
        let (workbook, timeline) = try await ledger.read { db in (try WorkbookMachine(loading: db), try TimelineMachine(loading: db)) }
        let composer = TurnComposer(assets: AssetCache())
        let attemptID = try XCTUnwrap(timeline.attempts.keys.first)

        let first = try await TimelineTurns.grading(composer: composer, planID: "turn-1", attemptID: attemptID, workbook: workbook, timeline: timeline)
        XCTAssertNil(first.thread.codexThreadID)
        XCTAssertTrue(first.thread.developerText?.contains("focus: クーロン") == true)
        XCTAssertTrue(first.thread.developerText?.contains("escalate_when") == true, "計画の見直しを頼む決まりはスレッドの先頭に置く")
        XCTAssertFalse(first.turn?.text.contains("escalate_when") == true, "今回の仕事は今までと同じ")
        let required = first.turn?.outputSchema?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(required.contains("escalate"), "\(required)")

        TimelinePlanMode.touch(threadID: "thread-1", turnID: "turn-1")
        let second = try await TimelineTurns.grading(composer: composer, planID: "turn-2", attemptID: attemptID, workbook: workbook, timeline: timeline)
        XCTAssertEqual(second.thread.codexThreadID, "thread-1")
        XCTAssertEqual(second.thread.developerText, first.thread.developerText, "続けるスレッドの先頭は変えない")
    }

    func testGradingReplyWithAReasonRequestsAPlanOnce() async throws {
        let ledger = try Ledger.inMemory()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", F.card("c1"))
            timeline.put("test", F.card("c2"))
            _ = timeline.recordCapture(cardID: "c1", capturePath: "t1.jpg", seconds: 3, assisted: false)
            _ = timeline.recordCapture(cardID: "c2", capturePath: "t2.jpg", seconds: 3, assisted: false)
            return (timeline.events, ())
        }
        let attemptIDs = try await ledger.read { db in try TimelineMachine(loading: db).attempts.keys.sorted() }
        func reply(_ escalate: String) throws -> TurnOutcome {
            let body: [String: Any] = ["readable": true, "grade": "wrong", "learner_answer": "6.0", "skill_ids": [], "transcript": "",
                                       "notes": "", "comment": "距離の 2 乗を見直しましょう。", "key_suspect": false, "escalate": escalate]
            return TurnOutcome(planID: "turn-\(UUID().uuidString)", round: 1, status: .completed, codexThreadID: nil, codexTurnID: nil,
                               finalText: String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self),
                               executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: 0)
        }
        let firstOutcome = try reply("距離の比で 1/r 扱いが、分けた問題でも 2 回続いた")
        let first = try await ledger.commit { db in
            let applied = try TimelineTurns.apply(kind: .timelineGrading, targetID: attemptIDs[0], outcome: firstOutcome, model: "m", db: db)
            return (applied.events, applied.followUp)
        }
        let planID = try XCTUnwrap(first.nextGraph, "計画がまだ無いので、すぐ呼ぶ")
        let row = try await ledger.read { db in try TimelineBatchRecord.fetchOne(db, key: planID) }
        XCTAssertEqual(row?.purpose, "plan")
        XCTAssertEqual(row?.request["trigger"]?.stringValue, "escalation")
        XCTAssertTrue(row?.request["log"]?.stringValue?.contains("1/r 扱い") == true)

        let secondOutcome = try reply("まだ続く")
        let second = try await ledger.commit { db in
            let applied = try TimelineTurns.apply(kind: .timelineGrading, targetID: attemptIDs[1], outcome: secondOutcome, model: "m", db: db)
            return (applied.events, applied.followUp)
        }
        XCTAssertNil(second.nextGraph, "返事を待っている間・その日 2 回目は呼ばない")
    }
}
