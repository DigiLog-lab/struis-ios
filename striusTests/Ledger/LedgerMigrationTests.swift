import GRDB
import XCTest
@testable import strius

/// 移行の順 (Issue #57): タイムライン (#46) だけが済んだ台帳 `v1`〜`v5` と、iCloud 同期 (#51) だけが済んだ台帳
/// `v1`+`sync-v1` の両方から、今の版に上げられる。
final class LedgerMigrationTests: XCTestCase {
    typealias F = TimelineFixture

    private let timelineOnly = ["v1", "v2-timeline", "v3-timeline-expansion", "v4-timeline-review", "v5-timeline-log"]
    private let syncOnly = ["v1", "sync-v1"]

    /// 単元と、タイムラインの行(スキル・5枚の依頼・カード・答案・今日の記録)がある台帳。
    private func source() async throws -> Ledger {
        let ledger = try Ledger.inMemory()
        try await ledger.commit { db in
            var workbook = try WorkbookMachine(loading: db)
            let unitID = workbook.createUnit(title: "二次関数", outcome: "", source: "consult", subunits: [.init(title: "頂点", n: 2)], firstStage: 3)
            let subunitID = workbook.orderedSubunits(unitID: unitID)[0].id
            var timeline = try TimelineMachine(loading: db)
            var skill = F.skill("quad.vertex_form")
            skill.unitId = unitID
            timeline.put("test", skill)
            _ = timeline.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: nil, levelCap: nil)
            timeline.put("test", F.card("c1", skills: ["quad.vertex_form"], subunitID: subunitID))
            _ = timeline.recordCapture(cardID: "c1", capturePath: "timeline-c1.jpg", seconds: 12, assisted: false)
            timeline.appendLog(kind: "note", text: "記録")
            return (workbook.events + timeline.events, ())
        }
        return ledger
    }

    private func oldLedger(_ migrations: [String]) throws -> (URL, DatabaseQueue) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("struis-migration-\(UUID().uuidString)").appendingPathComponent("ledger.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: url.path)
        try LedgerSchema.migrator(migrations).migrate(queue)
        let applied = try queue.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        XCTAssertEqual(Set(applied), Set(migrations))
        return (url, queue)
    }

    private func applied(_ ledger: Ledger) async throws -> Set<String> {
        Set(try await ledger.queue.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") })
    }

    func testTheRegistrationOrderPutsTheTimelineBeforeTheSync() {
        XCTAssertEqual(LedgerSchema.migrations.map(\.id), timelineOnly + ["sync-v1"])
    }

    /// タイムラインの版で使っていた台帳(`v1`〜`v5`)に `sync-v1` を流す。前のイベントは元の端末とその連番が付き、送る対象になる。
    func testLedgerWithTheTimelineMigrationsUpgradesToTheSync() async throws {
        let source = try await source()
        let stored = try await source.events()
        let (url, queue) = try oldLedger(timelineOnly)
        try await queue.write { db in
            for event in stored {
                // 前の版の `ledger_events` には origin の列が無い。
                try db.execute(sql: "INSERT INTO ledger_events (device_id, kind, entity, entity_id, payload, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                               arguments: [event.deviceId, event.kind, event.entity, event.entityId, event.payload, event.createdAt])
                try event.event!.apply(to: db)
            }
        }
        try queue.close()

        let ledger = try Ledger(path: url)
        let ids = try await applied(ledger)
        XCTAssertEqual(ids, Set(LedgerSchema.migrations.map(\.id)))
        let digest = try await ledger.projectionDigest()
        let expected = try await source.projectionDigest()
        XCTAssertEqual(digest, expected, "射影はそのまま")
        let timeline = try await ledger.read { db in try TimelineMachine(loading: db) }
        XCTAssertEqual(timeline.cards["c1"]?.status, "answered")
        XCTAssertEqual(timeline.log.count, 1)
        // 前のイベントにも元の端末と連番が付き、全部が送る対象になる。
        let outbox = try await ledger.syncOutbox(limit: 1_000)
        XCTAssertEqual(outbox.events.count, stored.count)
        XCTAssertTrue(outbox.events.contains { $0.entity == LedgerEntity.timelineLog.rawValue })
        XCTAssertEqual(Set(outbox.events.map(\.originDeviceID)), Set(stored.map(\.deviceId)))

        // 上げた台帳から、別の端末へそのまま届く。
        let cloud = FakeCloud()
        let engine = LedgerSyncEngine(ledger: ledger, transport: FakeTransport(cloud: cloud), build: "2 (1)")
        let other = try Ledger.inMemory()
        try await engine.sync()
        try await LedgerSyncEngine(ledger: other, transport: FakeTransport(cloud: cloud), build: "2 (1)").sync()
        let otherDigest = try await other.projectionDigest()
        XCTAssertEqual(otherDigest, expected)
        // 新しく書いても連番は重ならない。
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            timeline.appendLog(kind: "note", text: "上げた後")
            return (timeline.events, ())
        }
        let after = try await ledger.syncOutbox(limit: 1_000)
        XCTAssertEqual(after.events.count, 1)
    }

    /// iCloud 同期の版で使っていた台帳(`v1`+`sync-v1`)に `v2`〜`v5` を流す。その版で読めずに保留したタイムラインの
    /// イベントは、版が上がった後の適用し直しで反映される。
    func testLedgerWithTheSyncMigrationUpgradesToTheTimeline() async throws {
        let source = try await source()
        let records = try await source.events().compactMap(SyncEventRecord.init)
        XCTAssertFalse(records.isEmpty)
        let (url, queue) = try oldLedger(syncOnly)
        let (_, thread) = ChatRepository.createThread(title: "この端末の会話")
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO ledger_meta (key, value) VALUES ('device_id', 'sync-only-device')")
            for record in records {
                if record.entity.hasPrefix("timeline_") {
                    // #51 の版はタイムラインの表を知らない。
                    try Ledger.park(record, reason: "unknown entity \(record.entity)", build: "1 (1)", db)
                } else {
                    _ = try Ledger.ingest(record, removed: [], build: "1 (1)", into: db)
                }
            }
            // この端末で書いたイベント(挿入時に origin が埋まる)。
            try StoredLedgerEvent(deviceId: "sync-only-device", event: thread, createdAt: LedgerClock.now()).insert(db)
            try thread.apply(to: db)
        }
        let localOrigin = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT origin_device_id FROM ledger_events WHERE entity_id = ?", arguments: [thread.entityID])
        }
        XCTAssertEqual(localOrigin, "sync-only-device")
        try queue.close()

        let ledger = try Ledger(path: url)
        XCTAssertEqual(ledger.deviceID, "sync-only-device")
        let ids = try await applied(ledger)
        XCTAssertEqual(ids, Set(LedgerSchema.migrations.map(\.id)))
        let counts = try await ledger.syncCounts()
        XCTAssertGreaterThan(counts.pending, 0)

        let retried = try await ledger.retryPendingSync(build: "2 (1)") { _ in nil }
        XCTAssertEqual(retried.pending, 0)
        XCTAssertEqual(retried.applied + retried.stored, records.filter { $0.entity.hasPrefix("timeline_") }.count)
        let after = try await ledger.syncCounts()
        XCTAssertEqual(after.pending, 0)
        let timeline = try await ledger.read { db in try TimelineMachine(loading: db) }
        XCTAssertEqual(timeline.cards["c1"]?.status, "answered")
        XCTAssertNotNil(timeline.skills["quad.vertex_form"])
        XCTAssertEqual(timeline.log.count, 1)
        // 元の端末のイベントとして取り込まれ、送り返さない。
        let outbox = try await ledger.syncOutbox(limit: 1_000)
        XCTAssertFalse(outbox.events.contains { $0.entity.hasPrefix("timeline_") })
        // 作り直しても同じ(タイムラインのイベントは ledger_events に入っている)。
        let digest = try await ledger.projectionDigest()
        try await ledger.rebuild()
        let rebuilt = try await ledger.projectionDigest()
        XCTAssertEqual(rebuilt, digest)
    }
}
