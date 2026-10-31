import GRDB
import XCTest
@testable import strius

/// タイムラインの「問題を用意しています」から抜けない(2026-10-31 の実機)の直しと、待ちの画面の途中経過。
/// - 手元にカードが無い時の5枚は先回りにしない(知識グラフなどの先回りの後ろに並ばない)
/// - 行だけ `requested` のまま、働いているターンの無い依頼は閉じて頼み直す
/// - 枠を待っている間は「AI の応答を待っています」と言わず、何の後に始まるかを出す
final class TimelineBatchWaitTests: XCTestCase {
    /// 止められるまで返らないターン(待っている間の状態を見る)。`TurnRunning` は MainActor の protocol なので MainActor のクラスにする。
    @MainActor private final class HangingRunner: TurnRunning {
        struct Stopped: Error {}
        private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
        private var stopped: Set<String> = []
        /// テストを終えた: この後に来るターン(枠を待っていた・組んでいた)もすぐ返す(次のテストに残さない)。
        private var closed = false

        func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome {
            if !closed, !stopped.contains(plan.id) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in waiting[plan.id] = continuation }
            }
            throw Stopped()
        }

        func interrupt(planID: String) async {
            stopped.insert(planID)
            waiting.removeValue(forKey: planID)?.resume()
        }

        func stopAll() {
            closed = true
            for (id, continuation) in waiting {
                stopped.insert(id)
                continuation.resume()
            }
            waiting.removeAll()
        }
    }

    /// 止まっているターンを全部返し、裏で動く許可(`BackgroundTurnActivity`)がすべて返るまで待つ。
    /// 返らないターンを残すと、次のテストの「保存が済むまで許可を持つ」の確かめが終わらない。
    @MainActor
    private func finish(_ runner: HangingRunner) async throws {
        runner.stopAll()
        try await waitUntil { BackgroundTurnActivity.shared.runningCount == 0 }
    }

    private func waitUntil(_ condition: @escaping () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("時間内に終わらなかった")
    }

    /// 単元 1 つ(小単元 1 つ)の台帳。
    private func unitLedger() async throws -> Ledger {
        let ledger: Ledger = try Ledger.inMemory()
        try await ledger.commit { db in
            var workbook = try WorkbookMachine(loading: db)
            _ = workbook.createUnit(title: "二次関数", outcome: "", source: "consult", subunits: [.init(title: "平方完成", n: 2)], firstStage: 1)
            return (workbook.events, ())
        }
        return ledger
    }

    // MARK: 手元にカードが無い時の5枚は、学習者が待っている依頼として通す

    @MainActor
    func testBatchRequestedWithNoCardOnHandIsNotAPrefetch() async throws {
        let ledger: Ledger = try await unitLedger()
        let runner = HangingRunner()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: runner)
        let store = TimelineStore(ledger: ledger, turns: turns)
        await store.start()
        XCTAssertEqual(store.phase, .waiting)
        let batchID: String = try XCTUnwrap(store.awaitedBatchID, "待ちの画面は、待っている依頼を知っている")
        var turnID: String?
        try await waitUntil {
            turnID = try await ledger.read { db in
                try TurnRecord.filter(Column("kind") == TurnPlan.Kind.timelineBatch.rawValue && Column("target_id") == batchID).fetchOne(db)?.id
            }
            return turnID != nil
        }
        let id: String = try XCTUnwrap(turnID)
        let prefetches: Set<String> = await turns.prefetchTurns
        XCTAssertFalse(prefetches.contains(id), "学習者が待っている5枚を、先回りの後ろに並べない")
        let working: Bool = await turns.isWorking(on: batchID)
        XCTAssertTrue(working)
        try await finish(runner)
    }

    // MARK: 持ち主のいない依頼は閉じて頼み直す

    @MainActor
    func testRequestedBatchWithNoTurnIsClosedAndRequestedAgain() async throws {
        let ledger: Ledger = try await unitLedger()
        // 前のプロセスが行だけ書いて止められた依頼(ターンの行が無い)。
        let orphanID: String = try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            let id: String = timeline.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: nil, levelCap: nil)
            return (timeline.events, id)
        }
        let runner = HangingRunner()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: runner)
        await turns.resumeUnfinished()
        let store = TimelineStore(ledger: ledger, turns: turns)
        await store.start()
        XCTAssertEqual(store.machine.batches[orphanID]?.status, "failed")
        XCTAssertEqual(store.machine.batches[orphanID]?.error, TimelineTurns.abandonedBatch)
        let awaited: String = try XCTUnwrap(store.awaitedBatchID)
        XCTAssertNotEqual(awaited, orphanID, "新しい依頼を待つ")
        XCTAssertEqual(store.machine.batches[awaited]?.status, "requested")
        try await finish(runner)
    }

    @MainActor
    func testTurnLeftBeforeTheRelaunchIsRecomposedWithTheCurrentSettings() async throws {
        let ledger: Ledger = try await unitLedger()
        let batchID: String = try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            let id: String = timeline.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: nil, levelCap: nil)
            return (timeline.events, id)
        }
        try await ledger.append([.upsert("turn.queued", TurnRecord(
            id: "t-left", kind: TurnPlan.Kind.timelineBatch.rawValue, targetId: batchID, threadId: nil, status: "queued", round: 1, plan: .emptyObject,
            outcome: nil, codexThreadId: nil, codexTurnId: nil, executions: .emptyArray, error: nil,
            createdAt: LedgerClock.now(), startedAt: nil, completedAt: nil
        ))])
        let runner = HangingRunner()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: runner)
        let before: Bool = await turns.isWorking(on: batchID)
        XCTAssertTrue(before, "起動時の後始末の前は、残った行をこれから組み直されるものとして数える")
        // 後始末: 前のプロセスのプランは流さず、行を閉じて今の設定で組み直す(まだ requested の依頼なので)。
        await turns.resumeUnfinished()
        let (left, fresh): (TurnRecord?, [TurnRecord]) = try await ledger.read { db in
            (try TurnRecord.fetchOne(db, key: "t-left"),
             try TurnRecord.filter(Column("target_id") == batchID && Column("id") != "t-left").fetchAll(db))
        }
        XCTAssertEqual(left?.status, "interrupted", "前のプロセスのプランは流さない")
        XCTAssertEqual(fresh.count, 1, "今の設定で組み直した")
        let after: Bool = await turns.isWorking(on: batchID)
        XCTAssertTrue(after)
        try await finish(runner)
    }

    // MARK: 起動時に流さない古いプラン

    func testStalePlansAreNotResumed() {
        let now = Date(timeIntervalSince1970: 1_793_404_800)
        let recent: String = LedgerClock.iso(now.addingTimeInterval(-3600))
        let old: String = LedgerClock.iso(now.addingTimeInterval(-25 * 3600))
        XCTAssertNil(TurnCoordinator.staleReason(createdAt: recent, planProvider: .anthropic, current: .anthropic, now: now))
        XCTAssertNil(TurnCoordinator.staleReason(createdAt: recent, planProvider: nil, current: .openai, now: now))
        XCTAssertNotNil(TurnCoordinator.staleReason(createdAt: old, planProvider: .anthropic, current: .anthropic, now: now), "1 日を超えたプラン")
        XCTAssertNotNil(TurnCoordinator.staleReason(createdAt: recent, planProvider: nil, current: .anthropic, now: now), "ChatGPT で組んだプランを Claude の設定で流さない")
        XCTAssertNotNil(TurnCoordinator.staleReason(createdAt: recent, planProvider: .anthropic, current: .openai, now: now))
    }

    // MARK: 待ちの画面の「止める」

    @MainActor
    func testStoppingTheWaitShowsTheRetry() async throws {
        let ledger: Ledger = try await unitLedger()
        let runner = HangingRunner()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: runner)
        let store = TimelineStore(ledger: ledger, turns: turns)
        await store.start()
        let batchID: String = try XCTUnwrap(store.awaitedBatchID)
        try await waitUntil { await turns.isWorking(on: batchID) }
        await store.stopBatch()
        try await waitUntil {
            await store.reload()
            if case .batchFailed = store.phase { return true }
            return false
        }
        try await finish(runner)
    }

    func testFailureReasonsAreShownInPlainWords() {
        XCTAssertEqual(TimelineTurns.batchFailureReason("interrupted"), "止めました。")
        XCTAssertEqual(TimelineTurns.batchFailureReason(TimelineTurns.abandonedBatch), "作っている途中で処理が止まっていました。")
        XCTAssertEqual(TimelineTurns.batchFailureReason("time limit 180s"), "時間内に問題が届かなかったので止めました。")
        XCTAssertEqual(TimelineTurns.batchFailureReason(""), "")
        XCTAssertEqual(TimelineTurns.batchFailureReason("something else"), "something else", "分からない理由は隠さない")
    }

    // MARK: 枠を待っている間の言葉

    func testSlotWaitNamesTheWorkThatIsRunning() {
        XCTAssertEqual(TurnCoordinator.slotWaitText(holders: []), "前の作業が終わりしだい始めます")
        XCTAssertEqual(TurnCoordinator.slotWaitText(holders: [.timelineGraph, .timelineGraph]), "先に動いている作業（学ぶ順番の地図づくり）が終わりしだい始めます")
        let both: String = TurnCoordinator.slotWaitText(holders: [.timelineGrading, .workbookSet])
        XCTAssertTrue(both.contains("答案の採点") && both.contains("単元の問題づくり"))
    }

    func testSlotWaitIsNotDescribedAsWaitingForTheModel() {
        let start = Date(timeIntervalSince1970: 0)
        var activity = TurnActivity(startedAt: start)
        activity.waitingForSlot = "先に動いている作業（学ぶ順番の地図づくり）が終わりしだい始めます"
        let early = TurnSilence.statement(for: activity, now: start.addingTimeInterval(15))
        XCTAssertEqual(early?.text, activity.waitingForSlot)
        XCTAssertEqual(early?.offersChoice, false)
        let late = TurnSilence.statement(for: activity, now: start.addingTimeInterval(61))
        XCTAssertEqual(late?.offersChoice, true, "1 分を超えたら止めるか待つかを選べる")
        activity.keepWaitingAt = start.addingTimeInterval(62)
        XCTAssertEqual(TurnSilence.statement(for: activity, now: start.addingTimeInterval(90))?.offersChoice, false, "待つを選んだ後は聞き直さない")
    }

    @MainActor
    func testBoardRestartsTheSilenceWhenTheSlotIsTaken() {
        let board = TurnActivityBoard()
        let start = Date(timeIntervalSince1970: 0)
        let generation: Int = board.begin("k", at: start)
        board.slotWait("k", text: "前の作業が終わりしだい始めます", generation: generation, at: start.addingTimeInterval(1))
        XCTAssertEqual(board.activity("k")?.waitingForSlot, "前の作業が終わりしだい始めます")
        board.slotWait("k", text: nil, generation: generation, at: start.addingTimeInterval(100))
        let activity: TurnActivity? = board.activity("k")
        XCTAssertNil(activity?.waitingForSlot)
        XCTAssertEqual(activity?.startedAt, start.addingTimeInterval(100), "AI の沈黙は枠を取れた時から数える")
    }

    @MainActor
    func testAcquireReportsTheWaitAndItsEnd() async throws {
        let ledger: Ledger = try Ledger.inMemory()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: HangingRunner())
        let first: Bool = await turns.acquire(kind: .timelineGrading, turnID: "a")
        let second: Bool = await turns.acquire(kind: .timelineGraph, turnID: "b")
        XCTAssertTrue(first && second)
        let texts = LockedTexts()
        let waiter = Task { await turns.acquire(kind: .timelineBatch, turnID: "c") { text in texts.append(text) } }
        try await waitUntil { !texts.values.isEmpty }
        let shown: String = try XCTUnwrap(texts.values.first ?? nil)
        XCTAssertTrue(shown.contains("答案の採点") && shown.contains("学ぶ順番の地図づくり"), shown)
        await turns.release(turnID: "a", kind: .timelineGrading, acquired: true)
        let acquired: Bool = await waiter.value
        XCTAssertTrue(acquired)
        XCTAssertEqual(texts.values.count, 2, "待ち始めた時と、枠を取れた時の 2 回")
        XCTAssertNil(texts.values.last!, "枠を取れたら待ちの言葉を消す")
    }

    // MARK: 5枚を書いている途中

    func testBatchPartialCountsWrittenCards() {
        let text = #"{"reason":"r","cards":[{"kind":"solve","type_name":"平方完成","prompt":"p"},{"kind":"order","type_name":"並べ替え","prompt":"q"}"#
        let partial = TurnActivityLabels.structuredPartial(taskType: TurnPlan.Kind.timelineBatch.rawValue, text: text)
        XCTAssertEqual(partial?.done, 2)
        XCTAssertEqual(partial?.label, "2 問目まで書きました（並べ替え）")
        XCTAssertEqual(partial?.items, [], "点検の前の問題文は見せない")
    }

    private final class LockedTexts: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String?] = []
        var values: [String?] { lock.withLock { stored } }
        func append(_ text: String?) { lock.withLock { stored.append(text) } }
    }
}
