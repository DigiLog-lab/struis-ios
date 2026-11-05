import GRDB
import XCTest
@testable import strius

/// 2026-10-24 の見直し「フリーズを起こさない作り」: 保存が終わるまで裏で動く許可を持つ、返らないターンを上限で
/// 打ち切る、ターンの段階を台帳に残す。
final class TimelineTurnSafetyTests: XCTestCase {
    typealias F = TimelineFixture

    /// 返らないターン(上限で打ち切られる)。
    @MainActor private final class HangingRunner: TurnRunning {
        private(set) var interrupted: [String] = []

        func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome {
            TurnStage.report("startup")
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }

        func interrupt(planID: String) async { interrupted.append(planID) }
    }

    /// 段階を知らせてから、モックの結果を返す。
    @MainActor private final class StagedRunner: TurnRunning {
        func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome {
            TurnStage.report("startup")
            TurnStage.report("runtime_ready")
            TurnStage.report("turn_started")
            // 段階の書き込みが完了の記録より先に入るようにする(完了で消されないことを確かめる)。
            try await Task.sleep(for: .milliseconds(300))
            return try await MockTurnRunner().run(plan, progress: progress)
        }

        func interrupt(planID: String) async {}
    }

    private func waitUntil(_ condition: @escaping () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("時間内に終わらなかった")
    }

    private func cardsBatch(_ ledger: Ledger) async throws -> String {
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            let id = timeline.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: nil, levelCap: nil)
            return (timeline.events, id)
        }
    }

    func testBackgroundActivityIsHeldUntilTheResultIsSaved() async throws {
        let ledger = try Ledger.inMemory()
        let counts = LockedValues()
        _ = await ledger.observe { events in
            if events.contains(where: { $0.kind == "turn.completed" }) { counts.append(BackgroundTurnActivity.shared.runningCount) }
        }
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(), runner: MockTurnRunner())
        let batchID = try await cardsBatch(ledger)
        await turns.startTimeline(kind: .timelineBatch, targetID: batchID)
        try await waitUntil { !counts.values.isEmpty }
        XCTAssertEqual(counts.values.count, 1)
        XCTAssertGreaterThan(counts.values[0], 0, "保存の最中に裏で動く許可を返していた")
        try await waitUntil { BackgroundTurnActivity.shared.runningCount == 0 }
    }

    @MainActor func testHangingGradingFailsAtTheLimitAndReopensTheCard() async throws {
        let ledger = try Ledger.inMemory()
        let runner = HangingRunner()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(), runner: runner)
        await turns.setTimeLimits([TurnPlan.Kind.timelineGrading.rawValue: .milliseconds(300)])
        let attemptID: String = try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", F.card("c1", status: "shown"))
            let id = timeline.recordCapture(cardID: "c1", capturePath: "t.jpg", seconds: 12, assisted: false)
            return (timeline.events, id)
        }
        let before = try await ledger.read { db in try TimelineCardRecord.fetchOne(db, key: "c1")?.status }
        XCTAssertEqual(before, "answered")
        let started = Date()
        await turns.startTimeline(kind: .timelineGrading, targetID: attemptID)
        try await waitUntil {
            try await ledger.read { db in try TimelineAttemptRecord.fetchOne(db, key: attemptID)?.verdict } != "grading"
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let (attempt, card, turn) = try await ledger.read { db in
            (try TimelineAttemptRecord.fetchOne(db, key: attemptID), try TimelineCardRecord.fetchOne(db, key: "c1"),
             try TurnRecord.filter(Column("target_id") == attemptID).fetchOne(db))
        }
        XCTAssertEqual(attempt?.verdict, "failed")
        XCTAssertEqual(card?.status, "shown", "採点できなかったカードに戻る")
        XCTAssertEqual(turn?.status, "failed")
        let executions = turn?.executions.arrayValue ?? []
        XCTAssertTrue(executions.contains { $0["type"]?.stringValue == "time_limit" })
        XCTAssertTrue(executions.contains { $0["type"]?.stringValue == "stage" && $0["stage"]?.stringValue == "startup" }, "どこで待っていたかが残る")
        let interrupted = await runner.interrupted
        XCTAssertEqual(interrupted.count, 1, "時間切れの後は止める")
    }

    @MainActor func testStagesSurviveTheCompletedTurn() async throws {
        let ledger = try Ledger.inMemory()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(), runner: StagedRunner())
        let batchID = try await cardsBatch(ledger)
        await turns.startTimeline(kind: .timelineBatch, targetID: batchID)
        try await waitUntil {
            try await ledger.read { db in try TimelineBatchRecord.fetchOne(db, key: batchID)?.status } == "ready"
        }
        let turn = try await ledger.read { db in try TurnRecord.filter(Column("target_id") == batchID).fetchOne(db) }
        XCTAssertEqual(turn?.status, "completed")
        let stages = (turn?.executions.arrayValue ?? []).filter { $0["type"]?.stringValue == "stage" }.compactMap { $0["stage"]?.stringValue }
        XCTAssertEqual(Set(stages), ["startup", "runtime_ready", "turn_started"])
        XCTAssertTrue((turn?.executions.arrayValue ?? []).allSatisfy { $0["type"]?.stringValue != "stage" || $0["at"]?.stringValue != nil })
    }
}

/// 別のスレッドから足していく値。
private final class LockedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    func append(_ value: Int) { lock.withLock { stored.append(value) } }
    var values: [Int] { lock.withLock { stored } }
}
