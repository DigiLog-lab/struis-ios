import GRDB
import XCTest
@testable import strius

/// PR #47 に付いた Codex のレビュー指摘 7 件(2026-10-27): 単元の削除、判定を直した時の ○×、やり方を見た後のヒントあり、
/// 5枚の依頼の失敗、選ぶカードの選択、飛ばした時の続き、グラフと式を結ぶ の表示範囲。
final class TimelineReviewFindingsTests: XCTestCase {
    typealias F = TimelineFixture

    /// どのターンも失敗する(5枚の依頼が失敗した時の画面を見る)。
    @MainActor private final class FailingRunner: TurnRunning {
        struct Failure: Error {}
        func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome { throw Failure() }
        func interrupt(planID: String) async {}
    }

    private func waitUntil(_ condition: @escaping () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("時間内に終わらなかった")
    }

    /// 単元 1 つ(小単元 2 つ)の台帳。
    private func unitLedger() async throws -> (Ledger, unitID: String, subunitIDs: [String]) {
        let ledger = try Ledger.inMemory()
        let (unitID, subunitIDs): (String, [String]) = try await ledger.commit { db in
            var workbook = try WorkbookMachine(loading: db)
            let unitID = workbook.createUnit(title: "フーリエ級数", outcome: "", source: "consult",
                                             subunits: [.init(title: "係数を求める", n: 2), .init(title: "級数で書く", n: 2)], firstStage: 1)
            return (workbook.events, (unitID, workbook.orderedSubunits(unitID: unitID).map(\.id)))
        }
        return (ledger, unitID, subunitIDs)
    }

    @MainActor
    private func store(_ ledger: Ledger) -> TimelineStore {
        TimelineStore(ledger: ledger, turns: TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: FailingRunner()))
    }

    private func grading(_ grade: String, skills: [String]) throws -> TimelineMachine.Grading {
        let object: [String: Any] = ["readable": true, "grade": grade, "learner_answer": "0", "skill_ids": skills, "transcript": "",
                                     "notes": "", "comment": "", "key_suspect": false]
        return try TimelineMachine.Grading.parse(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    // MARK: 1 小単元の目標の点も単元の削除で消す

    func testDeletingAUnitRemovesSubunitGoalNodesAndTheirEdges() async throws {
        let (ledger, unitID, subunitIDs) = try await unitLedger()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            var goal = F.skill("fourier.goal_coefficients"); goal.unitId = subunitIDs[0]
            var step = F.skill("fourier.integrate_trig"); step.unitId = unitID
            var other = F.skill("calc.product_rule"); other.unitId = "other-unit"
            timeline.put("test", goal); timeline.put("test", step); timeline.put("test", other)
            timeline.addEdge(skillID: "fourier.goal_coefficients", requires: "calc.product_rule", relation: "prerequisite", source: "initial", note: "")
            return (timeline.events, ())
        }
        let (scope, edgeIDs) = try await ledger.read { db in
            (try UnitDeletion.scope(db: db, unitID: unitID), try TimelineMachine(loading: db).edges.keys.map { $0 })
        }
        XCTAssertTrue(scope.contains(.timelineSkills, "fourier.goal_coefficients"), "小単元の ID を持つ目標の点")
        XCTAssertTrue(scope.contains(.timelineSkills, "fourier.integrate_trig"))
        XCTAssertFalse(scope.contains(.timelineSkills, "calc.product_rule"), "他の単元の点は残す")
        XCTAssertEqual(edgeIDs.count, 1)
        XCTAssertTrue(edgeIDs.allSatisfy { scope.contains(.timelineSkillEdges, $0) }, "目標の点の線も消す")
    }

    // MARK: 2 判定を直したら、前の印を足したままにしない

    func testRevisingAGradeReplacesTheEarlierMarkInsteadOfAddingOne() throws {
        var machine = F.machine()
        // 前の日までに 2 日 ○: 今日の ○ で定着になる。
        machine.put("test", F.skill("s", dates: ["2026-10-20", "2026-10-21"]))
        machine.put("test", F.card("c1", skills: ["s"]))
        let attempt = machine.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 40, assisted: false)
        _ = machine.applyGrading(attemptID: attempt, grading: try grading("correct", skills: ["s"]))
        XCTAssertEqual(machine.skills["s"]?.status, "mastered")
        XCTAssertEqual(machine.skills["s"]?.attempts, 1)

        // 見直しで誤答に直す: 今日の ○ は取り消し、定着の前に戻る(定着の後の × として基準を 4 に上げない)。
        XCTAssertNil(machine.revise(attemptID: attempt, grade: "wrong", marks: nil, note: "途中の符号"))
        let revised = try XCTUnwrap(machine.skills["s"])
        XCTAssertEqual(revised.attempts, 1, "1 つの答案は 1 回だけ数える")
        XCTAssertEqual(revised.correctDates, ["2026-10-20", "2026-10-21"])
        XCTAssertEqual(revised.status, "practicing")
        XCTAssertEqual(revised.masteryThreshold, 3)
        XCTAssertNil(revised.nextReviewAt)

        // もう一度正解に直す: 元の状態と同じになる。
        XCTAssertNil(machine.revise(attemptID: attempt, grade: "correct", marks: nil, note: "読み違いだった"))
        let back = try XCTUnwrap(machine.skills["s"])
        XCTAssertEqual(back.attempts, 1)
        XCTAssertEqual(back.correctDates, ["2026-10-20", "2026-10-21", "2026-10-23"])
        XCTAssertEqual(back.status, "mastered")
    }

    func testReviewThatOverridesAMarkRecomputesTheSkill() throws {
        var machine = F.machine()
        machine.put("test", F.skill("s"))
        machine.put("test", F.card("c1", skills: ["s"]))
        let attempt = machine.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 40, assisted: false)
        _ = machine.applyGrading(attemptID: attempt, grading: try grading("correct", skills: ["s"]))
        XCTAssertEqual(machine.skills["s"]?.correctDates, ["2026-10-23"])
        let review = try TimelineMachine.Review.parse(#"{"notes":"","skill_results":[{"attempt_id":"\#(attempt)","skill_id":"s","result":"wrong"}]}"#)
        machine.applyReview(targetID: attempt, review: review)
        XCTAssertEqual(machine.skills["s"]?.attempts, 1)
        XCTAssertEqual(machine.skills["s"]?.correctDates, [])
    }

    // MARK: 3 「同じ形」を挟んで戻っても、ヒントありのまま

    @MainActor
    func testReturningFromTheSameFormKeepsTheOriginalAssisted() async throws {
        let (ledger, _, _) = try await unitLedger()
        let now = LedgerClock.now()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", F.card("c1", level: 4, status: "shown", createdAt: now))
            timeline.put("test", F.card("c2", status: "unused", position: 1, createdAt: now))
            return (timeline.events, ())
        }
        let store = store(ledger)
        await store.start()
        XCTAssertEqual(store.currentID, "c1")
        XCTAssertFalse(store.isAssisted)
        store.openHowto()
        await store.solveSameForm()
        let easier = try XCTUnwrap(store.currentID)
        XCTAssertNotEqual(easier, "c1")
        XCTAssertTrue(store.isAssisted, "やり方を見た直後の同じ形")
        store.show("c1")
        XCTAssertTrue(store.isAssisted, "元の問題に戻っても、ヒントあり")
        store.show("c2")
        XCTAssertFalse(store.isAssisted, "別のカードはヒントなし")
    }

    // MARK: 4 5枚の依頼が失敗したら待ちを抜ける

    @MainActor
    func testFailedBatchLeavesTheWaitingScreenWithARetry() async throws {
        let (ledger, _, _) = try await unitLedger()
        let store = store(ledger)
        await store.start()
        try await waitUntil {
            await store.reload()
            if case .batchFailed = store.phase { return true }
            return false
        }
        let before = store.machine.batches.values.filter { $0.purpose == "cards" }.count
        await store.retryBatch()
        XCTAssertGreaterThan(store.machine.batches.values.filter { $0.purpose == "cards" }.count, before, "もう一度で頼み直す")
    }

    // MARK: 5 カードが変わったら選択を初めに戻す

    func testChoiceStateResetsWhenTheCardChanges() {
        let a = F.card("a", kind: "order", payload: ["shuffled": .array([2, 0, 1].map { .number($0) })])
        let b = F.card("b", kind: "order", payload: ["shuffled": .array([1, 0].map { .number($0) })])
        var state = TimelineChoiceState()
        state.follow(a)
        XCTAssertEqual(state.order, [2, 0, 1])
        state.chosen = 1
        state.pairs = [0: 2]
        state.sorted = [true]
        state.pickedGraph = 0
        state.order = [0, 1, 2]
        state.follow(a)
        XCTAssertEqual(state.chosen, 1, "同じカードのままなら残す")
        state.follow(b)
        XCTAssertEqual(state.cardID, "b")
        XCTAssertNil(state.chosen)
        XCTAssertTrue(state.pairs.isEmpty)
        XCTAssertTrue(state.sorted.isEmpty)
        XCTAssertNil(state.pickedGraph)
        XCTAssertEqual(state.order, [1, 0])
    }

    // MARK: 6 飛ばした時も、同じ続きのカードを捨てる

    @MainActor
    func testSkippingDiscardsTheRestOfTheSameChain() async throws {
        let (ledger, _, _) = try await unitLedger()
        let now = LedgerClock.now()
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", F.card("c1", status: "shown", chain: ("k", 1, 2), createdAt: now))
            timeline.put("test", F.card("c2", status: "unused", position: 1, chain: ("k", 2, 2), createdAt: now))
            return (timeline.events, ())
        }
        let store = store(ledger)
        await store.start()
        XCTAssertEqual(store.currentID, "c1")
        await store.skip()
        XCTAssertEqual(store.machine.cards["c2"]?.status, "discarded")
        XCTAssertNotEqual(store.currentID, "c2", "飛ばした続きの次の問題を出さない")
    }

    // MARK: 7 グラフと式を結ぶ: 3つのグラフが見分けられる範囲

    func testGraphMatchIsNotBuiltWhenTheGraphsCannotBeTold() throws {
        // 上下に大きくずれた式: 頂点の近くで 3 を足した違いが、高さの中で見えない。
        XCTAssertNil(TimelineCards.plotWindow(["x^2+20", "-(x^2+20)", "(x^2+20)+3"]))
        var card = F.card("c1", skills: [])
        card.answerExpr = "x^2+20"
        card.math = "y = x^2 + 20"
        XCTAssertNil(TimelineCards.derive(.graphMatch, from: card))
    }

    func testGraphMatchWindowKeepsEveryCurveInsideAndApart() throws {
        let exprs = ["2*(x-2)^2-5", "-(2*(x-2)^2-5)", "(2*(x-2)^2-5)+3"]
        let window = try XCTUnwrap(TimelineCards.plotWindow(exprs))
        XCTAssertTrue(window.x.contains(2), "頂点が見える")
        let parsed = try exprs.map { try TimelineExpression.parse($0) }
        let xs = stride(from: window.x.lowerBound, through: window.x.upperBound, by: (window.x.upperBound - window.x.lowerBound) / 50).map { $0 }
        for f in parsed { for x in xs { XCTAssertTrue(window.y.contains(try XCTUnwrap(f.evaluate(["x": x]))), "線が端で切れない") } }
        // 保存した範囲を読み直せる。
        XCTAssertEqual(TimelineCards.PlotWindow(window.json), window)
        // 組み替えたカードに範囲が入る。
        var machine = F.machine()
        let id = machine.insertCard(from: try F.batch(cards: [F.draftJSON()]).cards[0], batchID: "b", position: 1, chain: nil)
        let derived = try XCTUnwrap(TimelineCards.derive(.graphMatch, from: machine.cards[id]!))
        XCTAssertNotNil(TimelineCards.PlotWindow(derived.payload["plot"]))
    }
}
