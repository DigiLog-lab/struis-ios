import GRDB
import XCTest
@testable import strius

/// 利用枠で止まった時のタイムライン(#62・#78): 作り置きのカードを出さず、5枚も頼まず、案内(`UsageLimitSheet`)へ移る。
/// 解いている途中のカードは出したまま。枠が戻ったら手元のカードから続ける。
@MainActor
final class TimelineUsageLimitTests: XCTestCase {
    private typealias F = TimelineFixture

    /// ターンを数えるだけのランナー(すぐ失敗を返す)。
    private final class CountingRunner: TurnRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var kinds: [TurnPlan.Kind] = []
        var started: [TurnPlan.Kind] { lock.withLock { kinds } }
        struct Refused: Error {}
        func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome {
            lock.withLock { kinds.append(plan.kind) }
            throw Refused()
        }
        func interrupt(planID: String) async {}
    }

    /// 単元 1 つと、解いている途中のカード(`c1`)・作り置きのカード(`c2`)。
    private func ledger(inProgress: Bool = true) async throws -> Ledger {
        let ledger = try Ledger.inMemory()
        let now = LedgerClock.now()
        try await ledger.commit { db in
            var workbook = try WorkbookMachine(loading: db)
            _ = workbook.createUnit(title: "二次関数", outcome: "", source: "consult", subunits: [.init(title: "平方完成", n: 2)], firstStage: 1)
            var timeline = try TimelineMachine(loading: db)
            if inProgress { timeline.put("test", F.card("c1", status: "shown", createdAt: now)) }
            timeline.put("test", F.card("c2", status: "unused", position: 1, createdAt: now))
            return (workbook.events + timeline.events, ())
        }
        return ledger
    }

    private func batchRequests(_ ledger: Ledger) async throws -> Int {
        try await ledger.read { db in try TimelineBatchRecord.fetchCount(db) }
    }

    func testTheCardInProgressStaysAndTheStockedCardIsNotShownAtTheLimit() async throws {
        let ledger = try await ledger()
        let runner = CountingRunner()
        let store = TimelineStore(ledger: ledger, turns: TurnCoordinator(ledger: ledger, assets: AssetCache(), runner: runner))
        var denial: UsageDenial? = .limitReached
        store.newWorkDenial = { denial }
        await store.start()
        XCTAssertEqual(store.currentID, "c1", "解いている途中のカードは出す")
        XCTAssertEqual(store.phase, .solving)
        XCTAssertNil(store.limitPrompt)

        // 途中のカードを終えた(飛ばした)後、作り置きのカードは出さずに案内へ。
        await store.goNext()
        XCTAssertEqual(store.phase, .limitReached(.limitReached))
        XCTAssertNil(store.currentID, "作り置きのカード(c2)を出さない")
        XCTAssertEqual(store.limitPrompt?.denial, .limitReached, "案内のシートを出す")
        let batches = try await batchRequests(ledger)
        XCTAssertEqual(batches, 0, "上限に達したら新しい5枚を頼まない")
        XCTAssertFalse(runner.started.contains(.timelineBatch))

        // 案内を閉じた・まだ戻っていない: 止まったまま。
        store.limitPrompt = nil
        store.recheckUsage()
        XCTAssertEqual(store.phase, .limitReached(.limitReached))
        XCTAssertNil(store.limitPrompt, "確かめ直しで同じ案内を繰り返し出さない")

        // 購入・期間の切り替えで枠が戻った: 手元のカードから続ける。
        denial = nil
        store.recheckUsage()
        XCTAssertEqual(store.currentID, "c2")
        XCTAssertEqual(store.phase, .solving)
    }

    func testWithoutAPlanAndNoTrialLeftTheTimelineLeadsToThePlans() async throws {
        let ledger = try await ledger(inProgress: false)
        let store = TimelineStore(ledger: ledger, turns: TurnCoordinator(ledger: ledger, assets: AssetCache(), runner: CountingRunner()))
        store.newWorkDenial = { .noPlan }
        await store.start()
        XCTAssertEqual(store.phase, .limitReached(.noPlan))
        XCTAssertNil(store.currentID)
        XCTAssertEqual(store.limitPrompt?.denial, .noPlan, "購入の画面へ案内する")
        let batches = try await batchRequests(ledger)
        XCTAssertEqual(batches, 0)
    }
}
