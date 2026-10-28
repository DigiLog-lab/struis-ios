import GRDB
import XCTest
@testable import strius

/// iCloud 同期 (Issue #51) の受け入れ: 2つのインメモリ台帳を、CloudKit の代わりの偽の transport でつなぐ。
/// CloudKit には依存しない(記録の形は `CloudKitSyncTransport` と同じ `SyncRecord`)。
final class LedgerSyncTests: XCTestCase {
    private struct Device {
        let ledger: Ledger
        let engine: LedgerSyncEngine
        var root: URL { ledger.deletionRoot }
    }

    private func device(_ cloud: FakeCloud, build: String = "1 (1)") throws -> Device {
        let ledger = try Ledger.inMemory()
        return Device(ledger: ledger, engine: LedgerSyncEngine(ledger: ledger, transport: FakeTransport(cloud: cloud), build: build, eventBatch: 7, fileBatch: 2))
    }

    private func write(_ text: String, to path: String, in device: Device, modified: Date? = nil) throws {
        let url = device.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    private func read(_ path: String, in device: Device) -> String? {
        (try? Data(contentsOf: device.root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A unit with a graded capture, as in `LedgerTests.testGradingUpdatesStageAndAttemptsThroughEvents`.
    private func seedGradedUnit(_ ledger: Ledger, captureID: String = "cap-sync") async throws -> (unitID: String, subunitID: String) {
        let (unitID, subunitID, context): (String, String, WorkbookMachine.GradingContext) = try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let unitID = machine.createUnit(title: "二次関数", outcome: "頂点が分かる", source: "consult", subunits: [.init(title: "頂点", n: 2)], firstStage: 3)
            let subunitID = machine.orderedSubunits(unitID: unitID)[0].id
            let setID = machine.insertGeneratingSet(subunitID: subunitID, spec: try machine.nextSetSpec(subunitID: subunitID))
            let ids = machine.addProblems(subunitID: subunitID, problems: [.init(prompt: "y=x^2-2x+1 の頂点")], source: "generated")
            machine.fillSet(setID: setID, problemIDs: ids)
            _ = try machine.createCapture(id: captureID, imagePath: "\(captureID).jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, subunitID: nil, setID: setID)
            return (machine.events, (unitID, subunitID, machine.gradingContext(capture: machine.captures[captureID]!)))
        }
        let problemID = context.subunits[0]["problems"]!.arrayValue![0]["id"]!.stringValue!
        let graded = WorkbookMachine.GradingResult(
            readable: true,
            items: [.init(label: "問1", promptText: "y=x^2-2x+1 の頂点", matchedProblemId: problemID, verdict: "correct", errorTag: "", note: "正しい")],
            candidates: [], newSubunit: nil, note: ""
        )
        let _: Void = try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            _ = try machine.applyGradingResult(captureID: captureID, graded: graded, context: context)
            return (machine.events, ())
        }
        return (unitID, subunitID)
    }

    private func events(_ ledger: Ledger) async throws -> [SyncEventRecord] {
        try await ledger.events().compactMap(SyncEventRecord.init)
    }

    // MARK: - 1. 単元・問題・採点が、もう片方に同じ射影で届く

    func testUnitProblemsAndGradingReachTheOtherDevice() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        _ = try await seedGradedUnit(a.ledger)
        try write("jpeg", to: "captures/cap-sync.jpg", in: a)
        try write("schema_version: 1\n", to: "memory/current/session.yaml", in: a)
        try await a.engine.sync()
        try await b.engine.sync()

        let source = try await a.ledger.projectionDigest()
        let target = try await b.ledger.projectionDigest()
        XCTAssertFalse(source.isEmpty)
        XCTAssertEqual(source, target)
        XCTAssertEqual(read("captures/cap-sync.jpg", in: b), "jpeg")
        XCTAssertEqual(read("memory/current/session.yaml", in: b), "schema_version: 1\n")
        let sourceCount = try await a.ledger.eventCount()
        let targetCount = try await b.ledger.eventCount()
        XCTAssertEqual(sourceCount, targetCount)
        // 取り込んだイベントは元の端末の ID と連番のまま。再生しても同じ射影になる。
        let origins = Set(try await events(b.ledger).map(\.originDeviceID))
        XCTAssertEqual(origins, [a.ledger.deviceID])
        try await b.ledger.rebuild()
        let rebuilt = try await b.ledger.projectionDigest()
        XCTAssertEqual(rebuilt, source)
        let counts = try await a.ledger.syncCounts()
        XCTAssertEqual(counts, Ledger.SyncCounts(unsent: 0, pending: 0))
    }

    // MARK: - 2. 同じイベントを2回届けても変わらない

    func testDeliveringTheSameEventsTwiceChangesNothing() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        _ = try await seedGradedUnit(a.ledger)
        try await a.engine.sync()
        try await b.engine.sync()
        let digest = try await b.ledger.projectionDigest()
        let count = try await b.ledger.eventCount()

        let again = try await events(a.ledger)
        let result = try await b.ledger.ingest(again, build: "1 (1)")
        XCTAssertEqual(result, Ledger.IngestResult())
        await cloud.redeliverEverything()
        try await b.engine.sync()

        let digestAfter = try await b.ledger.projectionDigest()
        let countAfter = try await b.ledger.eventCount()
        XCTAssertEqual(digestAfter, digest)
        XCTAssertEqual(countAfter, count)
    }

    // MARK: - 3. 同じ行を両方で変えると、後に書いた方が両方で勝つ

    func testTheLaterWriteOfARowWinsOnBothDevicesInAnyOrder() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        let (thread, created) = ChatRepository.createThread(title: "最初")
        try await a.ledger.append([created])
        try await a.engine.sync()
        try await b.engine.sync()

        var renamedA = thread; renamedA.title = "A で変えた"
        try await a.ledger.append([.upsert("thread.renamed", renamedA)])
        try await Task.sleep(for: .milliseconds(5))
        var renamedB = thread; renamedB.title = "B で後から変えた"
        try await b.ledger.append([.upsert("thread.renamed", renamedB)])
        // B の変更が先に CloudKit に入っても、A の古い変更が後から B に届いても同じ。
        try await b.engine.sync()
        try await a.engine.sync()
        try await b.engine.sync()

        for ledger in [a.ledger, b.ledger] {
            let title = try await ledger.read { db in try ThreadRecord.fetchOne(db, key: thread.id)?.title }
            XCTAssertEqual(title, "B で後から変えた")
        }
        let digestA = try await a.ledger.projectionDigest()
        let digestB = try await b.ledger.projectionDigest()
        XCTAssertEqual(digestA, digestB)
        let countA = try await a.ledger.eventCount()
        let countB = try await b.ledger.eventCount()
        XCTAssertEqual(countA, countB, "古いイベントも ledger_events には残る")

        // 届く順を入れ替えても同じ。created_at が同じなら origin_device_id の大きい方。
        let all = try await events(a.ledger)
        var tie = all.last!
        tie.originDeviceID = "zzzz-device"; tie.originSeq = 1
        tie.payload = LedgerEvent.upsert("thread.renamed", { var t = thread; t.title = "同時刻・大きい端末"; return t }()).payload.canonicalText
        let forward = try Ledger.inMemory(), backward = try Ledger.inMemory()
        try await forward.ingest(all + [tie], build: "1")
        for record in (all + [tie]).reversed() { try await backward.ingest([record], build: "1") }
        let f = try await forward.projectionDigest()
        let r = try await backward.projectionDigest()
        XCTAssertEqual(f, r)
        let winner = try await backward.read { db in try ThreadRecord.fetchOne(db, key: thread.id)?.title }
        XCTAssertEqual(winner, "同時刻・大きい端末")
        try await backward.rebuild()
        let rebuilt = try await backward.projectionDigest()
        XCTAssertEqual(rebuilt, r, "rebuild も同じ順で勝ち負けを決める")
    }

    func testMemoryFilesTakeTheLaterVersion() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        try write("v0", to: "memory/tutor_desk/plans/current.yaml", in: a, modified: Date(timeIntervalSince1970: 1_800_000_000))
        try await a.engine.sync()
        try await b.engine.sync()
        XCTAssertEqual(read("memory/tutor_desk/plans/current.yaml", in: b), "v0")

        try write("A の版", to: "memory/tutor_desk/plans/current.yaml", in: a, modified: Date(timeIntervalSince1970: 1_800_000_100))
        try write("B の後の版", to: "memory/tutor_desk/plans/current.yaml", in: b, modified: Date(timeIntervalSince1970: 1_800_000_200))
        try await a.engine.sync()
        try await b.engine.sync()
        try await a.engine.sync()
        XCTAssertEqual(read("memory/tutor_desk/plans/current.yaml", in: a), "B の後の版")
        XCTAssertEqual(read("memory/tutor_desk/plans/current.yaml", in: b), "B の後の版")
    }

    // MARK: - 4. 単元の削除が、もう片方でも範囲のイベント・射影・ファイルを消す

    func testUnitDeletionErasesTheRangeOnTheOtherDeviceAndLateEventsStayOut() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        let (unitID, subunitID) = try await seedGradedUnit(a.ledger)
        try write("jpeg", to: "captures/cap-sync.jpg", in: a)
        try await a.engine.sync()
        try await b.engine.sync()
        XCTAssertEqual(read("captures/cap-sync.jpg", in: b), "jpeg")
        let subunit = try await b.ledger.read { db in try WorkbookSubunitRecord.fetchOne(db, key: subunitID) }
        let late = try XCTUnwrap(subunit)

        let fact = try await a.ledger.deleteUnit(id: unitID)
        try await a.engine.sync()
        let cloudNames = await cloud.recordNames
        let erased = try await b.ledger.events().filter { fact.scope.contains(LedgerEntity(rawValue: $0.entity)!, $0.entityId) && $0.kind != "unit.deleted" && !$0.kind.hasPrefix("unit.") }
        XCTAssertFalse(erased.isEmpty)
        XCTAssertTrue(erased.allSatisfy { !cloudNames.contains($0.recordName!) }, "消した範囲のイベントは CloudKit からも消える")
        XCTAssertFalse(cloudNames.contains(SyncNames.file("captures/cap-sync.jpg")), "消したファイルも CloudKit から消える")

        try await b.engine.sync()
        let units = try await b.ledger.read { db in try WorkbookUnitRecord.fetchAll(db).map(\.id) }
        XCTAssertFalse(units.contains(unitID))
        let subunits = try await b.ledger.read { db in try WorkbookSubunitRecord.fetchOne(db, key: subunitID) }
        XCTAssertNil(subunits)
        XCTAssertNil(read("captures/cap-sync.jpg", in: b), "答案の写真もこの端末から消える")
        let remaining = try await b.ledger.events()
        XCTAssertFalse(remaining.contains { $0.payload.contains("y=x^2-2x+1 の頂点") }, "範囲のイベントが残っている")
        XCTAssertEqual(remaining.filter { $0.kind == "unit.deleted" }.count, 1)
        // B が自分の側で消した結果(進行の無効化など)も A に届き、両方が同じ射影になる。
        try await a.engine.sync()
        try await b.engine.sync()
        let digestA = try await a.ledger.projectionDigest()
        let digestB = try await b.ledger.projectionDigest()
        XCTAssertEqual(digestA, digestB)

        // 削除の前に別の端末で書かれた古いイベントが、後から届いても戻らない。
        var stale = late; stale.title = "遅れて届いた小単元"
        let record = SyncEventRecord(originDeviceID: "third-device", originSeq: 9, kind: "subunit.updated", entity: "workbook_subunits",
                                     entityID: subunitID, payload: LedgerEvent.upsert("subunit.updated", stale).payload.canonicalText,
                                     createdAt: LedgerClock.iso(Date(timeIntervalSinceNow: -60)))
        let result = try await b.ledger.ingest([record], build: "1 (1)")
        XCTAssertEqual(result.dropped, 1)
        let back = try await b.ledger.read { db in try WorkbookSubunitRecord.fetchOne(db, key: subunitID) }
        XCTAssertNil(back)
    }

    // MARK: - 5. 知らない entity のイベントは保留に入り、台帳は止まらない

    func testUnknownEntityIsKeptPendingAndTheLedgerKeepsWorking() async throws {
        let ledger = try Ledger.inMemory()
        let future = SyncEventRecord(originDeviceID: "newer-app", originSeq: 1, kind: "timeline.created", entity: "timeline_future_entries",
                                     entityID: "t1", payload: #"{"id":"t1"}"#, createdAt: LedgerClock.now())
        let broken = SyncEventRecord(originDeviceID: "newer-app", originSeq: 2, kind: "thread.created", entity: "threads",
                                     entityID: "t2", payload: #"{"id":"t2"}"#, createdAt: LedgerClock.now())
        let result = try await ledger.ingest([future, broken], build: "1 (1)")
        XCTAssertEqual(result.pending, 2, "知らない表と、デコードできない行")
        let counts = try await ledger.syncCounts()
        XCTAssertEqual(counts.pending, 2)
        let stored = try await ledger.eventCount()
        XCTAssertEqual(stored, 0)
        // 同じ記録がまた届いても二重に保留しない。
        _ = try await ledger.ingest([future], build: "1 (1)")
        let again = try await ledger.syncCounts()
        XCTAssertEqual(again.pending, 2)

        // 台帳はそのまま書ける。
        let (_, event) = ChatRepository.createThread(title: "保留があっても書ける")
        try await ledger.append([event])
        let count = try await ledger.eventCount()
        XCTAssertEqual(count, 1)

        // 版が上がったら保留を適用し直す(読めるようになった行は反映、読めないものは残る)。
        let (thread, readable) = ChatRepository.createThread(title: "前の版では読めなかった")
        let kept = SyncEventRecord(originDeviceID: "newer-app", originSeq: 3, kind: readable.kind, entity: readable.entity.rawValue,
                                   entityID: readable.entityID, payload: readable.payload.canonicalText, createdAt: LedgerClock.now())
        try await ledger.queue.write { db in try Ledger.park(kept, reason: "unknown entity", build: "1 (1)", db) }
        let sameBuild = try await ledger.retryPendingSync(build: "1 (1)") { _ in nil }
        XCTAssertEqual(sameBuild, Ledger.IngestResult(), "同じ版では適用し直さない")
        let retried = try await ledger.retryPendingSync(build: "2 (5)") { _ in nil }
        XCTAssertEqual(retried.applied, 1)
        XCTAssertEqual(retried.pending, 2)
        let title = try await ledger.read { db in try ThreadRecord.fetchOne(db, key: thread.id)?.title }
        XCTAssertEqual(title, "前の版では読めなかった")
        let after = try await ledger.syncCounts()
        XCTAssertEqual(after.pending, 2)
    }

    // MARK: - 6. 上げ直し: もう片方の台帳が、ZIP を残したうえでクラウドの内容に置き換わる

    func testUploadAgainReplacesTheOtherLedgerAfterKeepingOneZip() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        _ = try await seedGradedUnit(a.ledger)
        try write("jpeg", to: "captures/cap-sync.jpg", in: a)
        try await a.engine.sync()
        try await b.engine.sync()
        // B だけにある記録(まだ送っていない)とファイル。
        let (onlyB, onlyBEvent) = ChatRepository.createThread(title: "B だけの会話")
        try await b.ledger.append([onlyBEvent])
        try write("B だけ", to: "attachments/only-b.txt", in: b)

        let outcome = try await a.engine.uploadAgain()
        XCTAssertTrue(outcome.uploadedAgain)
        let replaced = try await b.engine.sync()
        let backup = try XCTUnwrap(replaced.backup)

        let digestA = try await a.ledger.projectionDigest()
        let digestB = try await b.ledger.projectionDigest()
        XCTAssertEqual(digestA, digestB)
        let gone = try await b.ledger.read { db in try ThreadRecord.fetchOne(db, key: onlyB.id) }
        XCTAssertNil(gone)
        XCTAssertNil(read("attachments/only-b.txt", in: b))
        XCTAssertEqual(read("captures/cap-sync.jpg", in: b), "jpeg")
        // 置き換える前の内容は backups/ の ZIP に1つだけ。
        let backups = b.root.appendingPathComponent("backups")
        let zips = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).filter { $0.pathExtension == "zip" }
        XCTAssertEqual(zips.map(\.lastPathComponent), [backup.lastPathComponent])
        let restored = try Ledger.inMemory()
        try await LedgerArchive.importArchive(from: backup, into: restored, root: restored.deletionRoot)
        let kept = try await restored.read { db in try ThreadRecord.fetchOne(db, key: onlyB.id)?.title }
        XCTAssertEqual(kept, "B だけの会話")

        // もう一度上げ直されても ZIP は1つ。
        try await a.engine.uploadAgain()
        try await b.engine.sync()
        let zipsAfter = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).filter { $0.pathExtension == "zip" }
        XCTAssertEqual(zipsAfter.count, 1)
        let digestAfter = try await b.ledger.projectionDigest()
        XCTAssertEqual(digestAfter, digestA)
    }

    func testDataDeletedFromICloudSettingsKeepsTheLedgerAndStops() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud)
        _ = try await seedGradedUnit(a.ledger)
        try await a.engine.sync()
        let digest = try await a.ledger.projectionDigest()
        await cloud.purge()
        let outcome = try await a.engine.sync()
        XCTAssertTrue(outcome.deletedByLearner)
        let after = try await a.ledger.projectionDigest()
        XCTAssertEqual(after, digest, "手元は消さない")
    }

    func testKeychainResetRecreatesTheZoneAndUploadsAgain() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        _ = try await seedGradedUnit(a.ledger)
        try await a.engine.sync()
        await cloud.resetEncryptionKey()
        let outcome = try await a.engine.sync()
        XCTAssertTrue(outcome.uploadedAgain)
        try await b.engine.sync()
        let digestA = try await a.ledger.projectionDigest()
        let digestB = try await b.ledger.projectionDigest()
        XCTAssertEqual(digestA, digestB)
    }

    // MARK: - 13. 初回: 両方にデータがあれば合わせる

    func testFirstSyncMergesBothLedgers() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        _ = try await seedGradedUnit(a.ledger)
        let (thread, event) = ChatRepository.createThread(title: "B の会話")
        try await b.ledger.append([event])
        try await a.engine.sync()
        try await b.engine.sync()
        try await a.engine.sync()
        let digestA = try await a.ledger.projectionDigest()
        let digestB = try await b.ledger.projectionDigest()
        XCTAssertEqual(digestA, digestB)
        let title = try await a.ledger.read { db in try ThreadRecord.fetchOne(db, key: thread.id)?.title }
        XCTAssertEqual(title, "B の会話")
    }

    // MARK: - 8. codex_account は送らない

    func testCodexAccountIsNeverSent() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        let account = CodexAccountRecord(id: "device", status: "connected", authMode: "chatgpt", planType: "plus", email: "learner@example.com",
                                         rateLimits: .object([:]), resetsAt: nil, syncedAt: LedgerClock.now(), error: nil)
        let (_, thread) = ChatRepository.createThread(title: "会話")
        try await a.ledger.append([.upsert("codex_account.synced", account), thread])
        let outbox = try await a.ledger.syncOutbox(limit: 100)
        XCTAssertEqual(outbox.events.map(\.entity), ["threads"])
        try await a.engine.sync()
        let sent = await cloud.events
        XCTAssertFalse(sent.contains { $0.entity == "codex_account" })
        XCTAssertFalse(sent.contains { $0.payload.contains("learner@example.com") })
        let counts = try await a.ledger.syncCounts()
        XCTAssertEqual(counts.unsent, 0)
        try await b.engine.sync()
        let accounts = try await b.ledger.read { db in try CodexAccountRecord.fetchCount(db) }
        XCTAssertEqual(accounts, 0)
    }

    // MARK: - 7. 別の端末で作られた会話に続けて送ると、rollout の欠落から回復する

    @MainActor func testContinuingAConversationFromAnotherDeviceRecoversTheMissingRollout() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        let (thread, threadEvent) = ChatRepository.createThread(title: "iPhone で始めた会話")
        let (_, question) = ChatRepository.createMessage(threadID: thread.id, role: "user", status: "completed", plainText: "放物線の頂点は？",
                                                         blocks: .emptyArray, metadata: .object([:]))
        let (_, answer) = ChatRepository.createMessage(threadID: thread.id, role: "assistant", status: "completed", plainText: "平方完成で求めます",
                                                       blocks: .emptyArray, metadata: .object([:]))
        let mapping = CodexThreadRecord(threadId: thread.id, codexThreadId: "codex-thread-on-iphone", lastTurnId: "turn-1",
                                        lastCompletedAt: LedgerClock.now(), createdAt: LedgerClock.now())
        try await a.ledger.append([threadEvent, question, answer, .upsert("codex_thread.mapped", mapping)])
        try await a.engine.sync()
        try await b.engine.sync()

        let server = FakeAppServer { _, method, _ in method == "thread/resume" ? .missingRollout : .default }
        let session = CodexAppServerSession(clientVersion: "sync-test", launcher: server.launcher, abandonGrace: .milliseconds(300))
        let runner = CodexTurnRunner(session: session, assets: AssetCache(root: FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)"), lenient: true),
                                     timeouts: CodexTurnRunner.Timeouts(configure: .milliseconds(400), inject: .milliseconds(400), turnStart: .seconds(2),
                                                                         interrupt: .milliseconds(400), rateLimits: .milliseconds(400), minimumTurnS: 5))
        let turns = TurnCoordinator(ledger: b.ledger, assets: AssetCache(lenient: true), runner: runner)
        _ = try await turns.sendChat(TurnCoordinator.ChatSend(threadID: thread.id, text: "続きを教えて", attachments: [], workbookView: nil))
        for _ in 0..<400 {
            let last = try await b.ledger.read { db in try ChatRepository.messages(db, threadID: thread.id) }.last
            if last?.status != "pending" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let resumed = server.params("thread/resume")
        XCTAssertEqual(resumed.first?["threadId"] as? String, "codex-thread-on-iphone", "iPhone の Codex スレッドを続けようとする")
        let started = server.params("thread/start")
        XCTAssertEqual(started.count, 1, "rollout が無いので新しいスレッドで続ける")
        XCTAssertNil(started.first?["threadId"])
        XCTAssertTrue((started.first?["developerInstructions"] as? String)?.contains("recent_thread_history.md") == true)
        let reply = try await b.ledger.read { db in try ChatRepository.messages(db, threadID: thread.id) }.last
        XCTAssertNotEqual(reply?.status, "pending")
        await session.close()
    }
}

// MARK: - Fake cloud

/// The zone `Ledger` in memory: records by name, a change log per generation (a new generation is the
/// zone recreated), and stored copies of file contents.
actor FakeCloud {
    private var records: [String: SyncRecord] = [:]
    private var log: [(serial: Int, name: String)] = []
    private var serial = 0
    private(set) var generation = 0
    private var deletion: ZoneDeletion?
    private var keyReset = false
    private let files = FileManager.default.temporaryDirectory.appendingPathComponent("fake-cloud-\(UUID().uuidString)", isDirectory: true)

    var recordNames: Set<String> { Set(records.keys) }
    var events: [SyncEventRecord] {
        records.values.compactMap { if case .event(let event) = $0 { event } else { nil } }
    }

    func save(_ batch: SyncBatch) throws -> SyncSendResult {
        var result = SyncSendResult()
        if keyReset || deletion == .purged {
            result.encryptedDataReset = keyReset
            for record in batch.records { result.failures[record.recordName] = .retry("zone") }
            return result
        }
        for record in batch.records {
            let name = record.recordName
            switch record {
            case .event:
                if records[name] == nil { touch(name, record) }
                result.saved[name] = .some(nil)
            case .file(var file):
                if case .file(let current)? = records[name], current.systemFields != file.systemFields {
                    result.failures[name] = .conflict(current)
                    continue
                }
                try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
                let copy = files.appendingPathComponent(UUID().uuidString)
                try FileManager.default.copyItem(at: file.fileURL, to: copy)
                file.fileURL = copy
                file.systemFields = Data("tag-\(serial + 1)".utf8)
                touch(name, .file(file))
                result.saved[name] = file.systemFields
            }
        }
        for name in batch.deletions {
            if records[name] != nil {
                records[name] = nil
                serial += 1
                log.append((serial, name))
            }
            result.deleted.insert(name)
        }
        return result
    }

    private func touch(_ name: String, _ record: SyncRecord) {
        serial += 1
        records[name] = record
        log.append((serial, name))
    }

    /// Changes after `cursor`, as CloudKit reports them: the latest state of each changed record.
    func changes(since cursor: (generation: Int, serial: Int)) -> (SyncFetch, (Int, Int)) {
        var fetch = SyncFetch()
        if let deletion, deletion != .deleted {
            fetch.zoneDeletion = deletion
            return (fetch, cursor)
        }
        var after = cursor.serial
        if cursor.generation != generation {
            fetch.zoneDeletion = .deleted
            after = 0
        }
        var latest: [String: Int] = [:]
        for entry in log where entry.serial > after { latest[entry.name] = entry.serial }
        for name in latest.keys.sorted(by: { latest[$0]! < latest[$1]! }) {
            if let record = records[name] { fetch.records.append(record) } else if fetch.zoneDeletion == nil { fetch.deletions.append(name) }
        }
        return (fetch, (generation, serial))
    }

    func reset() {
        records = [:]
        log = []
        generation += 1
        deletion = nil
        keyReset = false
    }

    /// Every record arrives again on the next fetch (CloudKit may deliver a change twice).
    func redeliverEverything() {
        for name in records.keys.sorted() {
            serial += 1
            log.append((serial, name))
        }
    }

    func purge() {
        records = [:]
        log = []
        deletion = .purged
    }

    func resetEncryptionKey() {
        records = [:]
        log = []
        deletion = .encryptedDataReset
        keyReset = true
    }
}

/// `FakeCloud` につないだ engine。他のテストファイルからはこれを使う(`FakeTransport` を他のファイルから直接書くと、
/// Xcode 27 のコンパイラが `nonisolated protocol` に従う actor に nonisolated を付けようとしてビルドが止まる。Issue #57)。
func fakeSyncEngine(ledger: Ledger, cloud: FakeCloud, build: String, eventBatch: Int = 300, fileBatch: Int = 20) -> LedgerSyncEngine {
    LedgerSyncEngine(ledger: ledger, transport: FakeTransport(cloud: cloud), build: build, eventBatch: eventBatch, fileBatch: fileBatch)
}

actor FakeTransport: SyncTransport {
    let cloud: FakeCloud
    private var cursor: (generation: Int, serial: Int) = (0, 0)

    init(cloud: FakeCloud) { self.cloud = cloud }

    func fetchChanges() async throws -> SyncFetch {
        let (fetch, next) = await cloud.changes(since: cursor)
        cursor = next
        return fetch
    }

    func send(_ batch: SyncBatch) async throws -> SyncSendResult {
        try await cloud.save(batch)
    }

    func resetZone() async throws {
        await cloud.reset()
        // A fresh state here: this device does not see its own deletion.
        cursor = (await cloud.generation, 0)
    }
}
