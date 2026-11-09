import GRDB
import XCTest
@testable import strius

/// 答えの読み取り(Issue #101): 写真の答案の最後の答えだけを読み、正しい答えの式と一致すれば途中を読まずに ○。
/// 一致しない・読めない・失敗した時は、いつもの採点に回す。
final class TimelineAnswerReadTests: XCTestCase {
    typealias F = TimelineFixture

    private func waitUntil(_ condition: @escaping () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("時間内に終わらなかった")
    }

    /// 正しい答えの式がある solve のカード(答えは -5)。
    private static func keyedCard(_ id: String, skills: [String] = ["s1"], status: String = "shown", position: Int = 0, createdAt: String = F.now) -> TimelineCardRecord {
        var card = F.card(id, status: status, position: position, skills: skills, createdAt: createdAt)
        card.answerKey = "-5"
        card.answerExpr = "-5"
        return card
    }

    private func reply(readable: Bool = true, _ answer: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["readable": readable, "learner_answer": answer]), as: UTF8.self)
    }

    private func outcome(_ text: String, status: TurnOutcome.Status = .completed) -> TurnOutcome {
        TurnOutcome(planID: "p", round: 1, status: status, codexThreadID: nil, codexTurnID: nil, finalText: text,
                    executions: [], rateLimits: nil, files: [], error: status == .completed ? nil : "boom", elapsedMs: 1)
    }

    private func capturedLedger(skills: [String] = ["s1"]) async throws -> (Ledger, String) {
        let ledger = try Ledger.inMemory()
        let id: String = try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", Self.keyedCard("c1", skills: skills))
            let id = timeline.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 12, assisted: false)
            return (timeline.events, id)
        }
        return (ledger, id)
    }

    private func apply(_ ledger: Ledger, _ id: String, _ outcome: TurnOutcome) async throws -> TimelineTurns.FollowUp {
        try await ledger.commit { db in
            let applied = try TimelineTurns.apply(kind: .timelineAnswer, targetID: id, outcome: outcome, model: "m", db: db)
            return (applied.events, applied.followUp)
        }
    }

    private func attempt(_ ledger: Ledger, _ id: String) async throws -> TimelineAttemptRecord? {
        try await ledger.read { db in try TimelineAttemptRecord.fetchOne(db, key: id) }
    }

    // MARK: どのターンから始めるか

    func testOnlySolveCardsWithAnAnswerExpressionStartWithTheAnswerRead() {
        XCTAssertEqual(TimelineTurns.firstGradingKind(for: Self.keyedCard("a")), .timelineAnswer)
        XCTAssertEqual(TimelineTurns.firstGradingKind(for: F.card("b")), .timelineGrading, "正しい答えの式が無ければ照合できない")
        var fill = Self.keyedCard("c")
        fill.kind = TimelineCards.Kind.fillLine.rawValue
        XCTAssertEqual(TimelineTurns.firstGradingKind(for: fill), .timelineGrading)
    }

    func testTheRequestDoesNotCarryTheAnswer() {
        let card = Self.keyedCard("c1")
        let request = TimelineTurns.answerRequest(attempt: F.attempt("a", card: "c1", verdict: "grading"), card: card)
        XCTAssertNil(request["answer_key"], "正しい答えを渡すと、読み取りが正しい答えに引っ張られる")
        XCTAssertNil(request["answer_expr"])
        XCTAssertEqual(request["problem"]?.stringValue, card.prompt)
    }

    // MARK: 反映

    func testAMatchingAnswerIsCorrectWithoutReadingTheWorkOrAReview() async throws {
        let (ledger, id) = try await capturedLedger(skills: ["s1", "s2"])
        let followUp = try await apply(ledger, id, outcome(reply("\\frac{-10}{2}")))
        XCTAssertNil(followUp.grading)
        XCTAssertNil(followUp.review, "途中を疑うのは、同じスキルで × が出た後の見直しだけ")
        let row = try XCTUnwrap(try await attempt(ledger, id))
        XCTAssertEqual(row.verdict, "correct")
        XCTAssertEqual(row.grade, "correct")
        XCTAssertEqual(row.notes, TimelineTurns.answerOnlyNote)
        XCTAssertEqual(row.learnerAnswer, "\\frac{-10}{2}")
        XCTAssertEqual(row.skillMarks, ["s1": "correct", "s2": "correct"], "見直しを頼まないので、スキルを置いたままにしない")
        XCTAssertEqual(row.skillsPending, false)
        let log = try await ledger.read { db in try TimelineMachine(loading: db).todayLog.map(\.text).joined(separator: "\n") }
        XCTAssertTrue(log.contains(TimelineTurns.answerOnlyNote), "答えだけで ○ にしたことは、今日の記録で見直し・出題に伝わる")
    }

    func testAnAnswerWithTheLeftSideStillMatches() async throws {
        let (ledger, id) = try await capturedLedger()
        let followUp = try await apply(ledger, id, outcome(reply("y = -5")))
        XCTAssertNil(followUp.grading)
        let verdict = try await attempt(ledger, id)?.verdict
        XCTAssertEqual(verdict, "correct")
    }

    func testADifferentAnswerGoesToTheUsualGrading() async throws {
        let (ledger, id) = try await capturedLedger()
        let followUp = try await apply(ledger, id, outcome(reply("5")))
        XCTAssertEqual(followUp.grading, id)
        let verdict = try await attempt(ledger, id)?.verdict
        XCTAssertEqual(verdict, "grading", "× はいつもの採点が決める(読み違い・正しい答えの誤りがあり得る)")
    }

    func testUnreadableUnparsableOrFailedReadsGoToTheUsualGrading() async throws {
        for (label, result) in [
            ("読めない", outcome(reply(readable: false, ""))),
            ("式として比べられない", outcome(reply("マイナス五"))),
            ("返事が JSON でない", outcome("読めませんでした")),
            ("ターンが失敗した", outcome("", status: .failed)),
        ] {
            let (ledger, id) = try await capturedLedger()
            let followUp = try await apply(ledger, id, result)
            XCTAssertEqual(followUp.grading, id, label)
            XCTAssertFalse(followUp.retry, label)
            let verdict = try await attempt(ledger, id)?.verdict
            XCTAssertEqual(verdict, "grading", label)
        }
    }

    func testAnAnswerReadAfterTheAttemptWasGradedChangesNothing() async throws {
        let (ledger, id) = try await capturedLedger()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            _ = timeline.applyGrading(attemptID: id, grading: TimelineMachine.Grading(grade: "wrong", learnerAnswer: "5"))
            return (timeline.events, ())
        }
        let followUp = try await apply(ledger, id, outcome(reply("-5")))
        XCTAssertNil(followUp.grading)
        let verdict = try await attempt(ledger, id)?.verdict
        XCTAssertEqual(verdict, "wrong")
    }

    func testTheAnswerReadUsesNoToolsAndTheLowestEffort() async throws {
        let answerTools = NativeToolRouter.definitions(for: .timelineAnswer) as NSArray
        XCTAssertTrue(answerTools.isEqual(NativeToolRouter.definitions(for: .chat)), "台帳・答案の拡大の道具を足さない")
        XCTAssertFalse(answerTools.isEqual(NativeToolRouter.definitions(for: .timelineGrading)))
        let ledger = try Ledger.inMemory()
        let timeline: TimelineMachine = try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", Self.keyedCard("c1"))
            _ = timeline.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 12, assisted: false)
            return (timeline.events, timeline)
        }
        let attemptID = try XCTUnwrap(timeline.attempts.keys.first)
        let plan = try await TimelineTurns.answer(composer: TurnComposer(assets: AssetCache()), planID: "p1", attemptID: attemptID, timeline: timeline)
        XCTAssertEqual(plan.kind, .timelineAnswer)
        XCTAssertEqual(plan.thread.effort, "low")
        XCTAssertNil(plan.thread.developerInstructions)
        XCTAssertFalse(plan.turn.text.contains("-5"), "正しい答えを依頼に入れない")
        XCTAssertEqual(plan.turn.images.count, 1)
    }

    // MARK: 画面の流れ

    /// 答えの読み取りは `answer` を返し、いつもの採点は誤答を返す。ほかはモック。
    @MainActor private final class AnswerRunner: TurnRunning {
        let answer: String
        private(set) var kinds: [TurnPlan.Kind] = []
        init(answer: String) { self.answer = answer }

        func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome {
            kinds.append(plan.kind)
            let text: String
            switch plan.kind {
            case .timelineAnswer:
                text = String(decoding: try JSONSerialization.data(withJSONObject: ["readable": true, "learner_answer": answer]), as: UTF8.self)
            case .timelineGrading:
                text = #"{"readable":true,"grade":"wrong","learner_answer":"5","skill_ids":[],"transcript":"5","notes":"","comment":"符号が違います。","key_suspect":false}"#
            default:
                return try await MockTurnRunner().run(plan, progress: progress)
            }
            return TurnOutcome(planID: plan.id, round: plan.round, status: .completed, codexThreadID: nil, codexTurnID: nil, finalText: text,
                               executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: 1)
        }

        func interrupt(planID: String) async {}
    }

    @MainActor
    private func submitted(answer: String) async throws -> (TimelineStore, AnswerRunner, String) {
        let ledger = try Ledger.inMemory()
        let now = LedgerClock.now()
        try await ledger.commit { db in
            var workbook = try WorkbookMachine(loading: db)
            _ = workbook.createUnit(title: "二次関数", outcome: "", source: "consult", subunits: [.init(title: "最大と最小", n: 2)], firstStage: 1)
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", Self.keyedCard("c1", createdAt: now))
            timeline.put("test", Self.keyedCard("c2", status: "unused", position: 1, createdAt: now))
            return (workbook.events + timeline.events, ())
        }
        let runner = AnswerRunner(answer: answer)
        let store = TimelineStore(ledger: ledger, turns: TurnCoordinator(ledger: ledger, assets: AssetCache(), runner: runner))
        await store.start()
        XCTAssertEqual(store.currentID, "c1")
        await store.submit(image: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        let attemptID = try XCTUnwrap(store.lastAttemptID)
        try await waitUntil {
            await store.reload()
            return store.phase == .result
        }
        return (store, runner, attemptID)
    }

    @MainActor
    func testAMatchingAnswerShowsTheResultWithoutTheUsualGrading() async throws {
        let (store, runner, attemptID) = try await submitted(answer: "-5")
        XCTAssertEqual(store.machine.attempts[attemptID]?.verdict, "correct")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(runner.kinds.contains(.timelineGrading), "答えが合えば、いつもの採点は回さない")
        XCTAssertFalse(runner.kinds.contains(.timelineReview), "答えだけの ○ では見直しを頼まない")
    }

    @MainActor
    func testADifferentAnswerShowsTheUsualGradingResult() async throws {
        let (store, runner, attemptID) = try await submitted(answer: "5")
        XCTAssertEqual(store.machine.attempts[attemptID]?.verdict, "wrong")
        XCTAssertEqual(store.machine.attempts[attemptID]?.feedback, "符号が違います。")
        XCTAssertEqual(Array(runner.kinds.prefix(2)), [.timelineAnswer, .timelineGrading])
    }
}
