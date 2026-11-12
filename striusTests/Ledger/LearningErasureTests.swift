import GRDB
import XCTest
@testable import strius

/// 学習記録をまとめて消す(#78): 端末の記録を残さない・途中で止まっても続きから消す・iCloud のゾーンを作り直す・
/// 別の端末も印を受けて消す・消す前の記録が遅れて届いても戻らない・使用額やお試しの数などは消さない。
final class LearningErasureTests: XCTestCase {
    private struct Device {
        let ledger: Ledger
        let engine: LedgerSyncEngine
        var root: URL { ledger.deletionRoot }
    }

    private func device(_ cloud: FakeCloud) throws -> Device {
        let ledger = try Ledger.inMemory()
        return Device(ledger: ledger, engine: fakeSyncEngine(ledger: ledger, cloud: cloud, build: "1 (1)"))
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ path: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    /// 会話 1 つ・Claude との会話の控え・答案と写真と添付と学習メモ・backups の ZIP。
    private func seed(_ ledger: Ledger, title: String = "二次関数の質問") async throws -> String {
        let (thread, event) = ChatRepository.createThread(title: title)
        try await ledger.append([event])
        try await ledger.queue.write { db in
            try db.execute(sql: "INSERT INTO claude_conversations (thread_id, kind, model, created_at, updated_at) VALUES (?, 'chat', 'claude-sonnet-5-5', '', '')",
                           arguments: [thread.id])
        }
        try DrillTemplateStore(queue: ledger.queue).save(skillID: "quad.vertex_form", outcome: .excluded(reasons: ["グラフを読む問題"], declined: true))
        let root = ledger.deletionRoot
        try write("jpeg", to: "captures/cap-1.jpg", in: root)
        try write("png", to: "attachments/page.png", in: root)
        try write("learner_id: learner\n", to: "memory/tutor_desk/learner/profile.yaml", in: root)
        try write("png", to: "conversation-images/abc.png", in: root)
        try write("zip", to: "backups/struis-ledger-old.zip", in: root)
        return thread.id
    }

    private func count(_ table: String, _ ledger: Ledger) async throws -> Int {
        try await ledger.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    // MARK: - この端末

    func testErasingLeavesNoLearningRecordOnTheDeviceAndKeepsItsID() async throws {
        let ledger = try Ledger.inMemory()
        let threadID = try await seed(ledger)
        let deviceID = ledger.deviceID
        let marker = LearningErasure.Marker.new()

        try await ledger.beginErasure(marker, remote: false)
        do {
            _ = try await ledger.read { db in try ThreadRecord.fetchOne(db, key: threadID) }
            XCTFail("消している途中は台帳を読ませない")
        } catch {}
        try await ledger.eraseLearningRecords()

        for table in ["ledger_events", "threads", "claude_conversations", "drill_templates", "sync_pending", "sync_files"] {
            let rows = try await count(table, ledger)
            XCTAssertEqual(rows, 0, "\(table) が残っている")
        }
        let root = ledger.deletionRoot
        for path in ["captures/cap-1.jpg", "attachments/page.png", "memory/tutor_desk/learner/profile.yaml", "conversation-images/abc.png", "backups"] {
            XCTAssertFalse(exists(path, in: root), "\(path) が残っている")
        }
        XCTAssertTrue(exists("captures", in: root), "空のフォルダは作り直す")
        XCTAssertEqual(ledger.deviceID, deviceID, "同期に使う端末の ID は変えない")
        let reopenedID = try await ledger.queue.read { db in try String.fetchOne(db, sql: "SELECT value FROM ledger_meta WHERE key = 'device_id'") }
        XCTAssertEqual(reopenedID, deviceID)
        XCTAssertEqual(ledger.appliedErasure(), marker)
        XCTAssertEqual(ledger.pendingErasure()?.localDone, true, "残りは iCloud")
        // 消し終えた後は、新しい記録を書ける。
        try await ledger.append([ChatRepository.createThread(title: "消した後の質問").1])
        try await ledger.finishErasure()
        XCTAssertNil(ledger.pendingErasure())
    }

    func testAnErasureStoppedHalfwayContinuesAfterARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("erasure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite")
        var ledger: Ledger? = try Ledger(path: path)
        _ = try await seed(ledger!)
        try await ledger!.beginErasure(.new(), remote: false)
        ledger = nil // 消去の記録を置いたところで止まった

        let relaunched = try Ledger(path: path)
        XCTAssertEqual(relaunched.pendingErasure()?.localDone, false, "次の起動でも、消している途中だと分かる")
        do {
            try await relaunched.append([ChatRepository.createThread(title: "x").1])
            XCTFail("消し終えるまで書かせない")
        } catch {}
        try await relaunched.eraseLearningRecords()
        let events = try await count("ledger_events", relaunched)
        XCTAssertEqual(events, 0)
        XCTAssertFalse(exists("captures/cap-1.jpg", in: directory))
        // もう一度呼んでも同じ結果。
        try await relaunched.eraseLearningRecords()
        XCTAssertEqual(relaunched.pendingErasure()?.localDone, true)
    }

    func testDeviceStateKeepsConsentAndAgeButDropsTheAnswers() throws {
        let defaults = UserDefaults(suiteName: "erasure-\(UUID().uuidString)")!
        var profile = OnboardingProfile()
        profile.grade = "中3"
        profile.unit = "二次方程式"
        profile.trial = [TrialRecord(problemID: "p", label: "中3", correct: true, learnerAnswer: "x=2", comment: "")]
        profile.ageBand = .under18
        profile.ageDeclaration = "selfDeclared"
        profile.termsAcceptedAt = "2026-11-06T00:00:00Z"
        profile.photoConsentAt = "2026-11-06T00:00:01Z"
        profile.save(defaults)
        OnboardingProfile.markCompleted(defaults)
        defaults.set("thread-1", forKey: OnboardingProfile.unitCreationThreadKey)
        defaults.set(true, forKey: "workbook.subunitHeaderCollapsed.sub-1")
        defaults.set("頂点", forKey: "reminder.subunit.v1")

        LearningErasure.clearDeviceState(defaults: defaults, temporary: FileManager.default.temporaryDirectory.appendingPathComponent("erasure-none"))

        let kept = try XCTUnwrap(OnboardingProfile.load(defaults))
        XCTAssertNil(kept.grade)
        XCTAssertNil(kept.unit)
        XCTAssertTrue(kept.trial.isEmpty, "オンボーディングの回答は消す")
        XCTAssertEqual(kept.ageBand, .under18, "年齢の判定は消さない")
        XCTAssertEqual(kept.termsAcceptedAt, "2026-11-06T00:00:00Z", "同意の記録は消さない")
        XCTAssertEqual(kept.photoConsentAt, "2026-11-06T00:00:01Z")
        XCTAssertTrue(OnboardingProfile.isCompleted(defaults), "オンボーディングを最初からやり直させない")
        XCTAssertNil(defaults.string(forKey: OnboardingProfile.unitCreationThreadKey))
        XCTAssertNil(defaults.object(forKey: "workbook.subunitHeaderCollapsed.sub-1"))
        XCTAssertNil(defaults.string(forKey: "reminder.subunit.v1"))
    }

    // MARK: - iCloud と別の端末

    func testErasureClearsICloudAndTheOtherDeviceAndOldRecordsNeverComeBack() async throws {
        let cloud = FakeCloud()
        let a = try device(cloud), b = try device(cloud)
        _ = try await seed(a.ledger, title: "A の質問")
        try await a.engine.sync()
        try await b.engine.sync()
        // B だけにある、まだ送っていない記録(消す前に書いた)。
        try await b.ledger.append([ChatRepository.createThread(title: "B の質問").1])
        let beforeErasure = try await b.ledger.events().compactMap(SyncEventRecord.init)

        // A で消す: 端末 → iCloud のゾーン。
        let marker = LearningErasure.Marker.new()
        try await a.ledger.beginErasure(marker, remote: false)
        try await a.ledger.eraseLearningRecords()
        try await a.engine.eraseZone()
        try await a.ledger.finishErasure()
        let left = await cloud.recordNames
        XCTAssertTrue(left.isEmpty, "iCloud に記録が残らない: \(left.count)")

        // B: ゾーンが消えたことを知る(消去の印より先に届いた)。記録はゾーンの内容(空)に置き換わる。
        let outcome = try await b.engine.sync()
        XCTAssertNotNil(outcome.backup, "印が届く前は、置き換える前の記録を ZIP に残す")
        // 消去の印が届いた: B の台帳は印より前に作られているので、ZIP も含めて消す。
        XCTAssertEqual(b.ledger.remoteErasure(for: marker), .erase)
        try await b.ledger.beginErasure(marker, remote: true)
        try await b.ledger.eraseLearningRecords()
        try await b.ledger.finishErasure()
        XCTAssertFalse(exists("backups", in: b.root), "別の端末にも backups の ZIP を残さない")
        let bEvents = try await count("ledger_events", b.ledger)
        XCTAssertEqual(bEvents, 0)
        XCTAssertEqual(b.ledger.remoteErasure(for: marker), .none, "同じ印で 2 回は消さない")

        // 消す前の B の記録が遅れて届いても(古い版の端末・同期の行き違い)、A は受け取らず、iCloud からも消す。
        let result = try await a.ledger.ingest(beforeErasure, build: "1 (1)")
        XCTAssertEqual(result.dropped, beforeErasure.count)
        let aThreads = try await count("threads", a.ledger)
        XCTAssertEqual(aThreads, 0, "消した記録が戻らない")
        let tombstones = try await count("sync_tombstones", a.ledger)
        XCTAssertEqual(tombstones, beforeErasure.count, "iCloud にあれば消す")

        // 消した後に A で書いた記録は、B に届く。
        let (after, afterEvent) = ChatRepository.createThread(title: "消した後の質問")
        try await a.ledger.append([afterEvent])
        try await a.engine.sync()
        try await b.engine.sync()
        let reached = try await b.ledger.read { db in try ThreadRecord.fetchOne(db, key: after.id)?.title }
        XCTAssertEqual(reached, "消した後の質問")
    }

    func testADeviceSetUpAfterTheErasureKeepsItsRecords() async throws {
        let marker = LearningErasure.Marker.new(now: Date().addingTimeInterval(-60))
        let fresh = try Ledger.inMemory()
        XCTAssertEqual(fresh.remoteErasure(for: marker), .acknowledge, "印より後に作った台帳は消さない")
        try await fresh.acknowledgeErasure(marker)
        XCTAssertEqual(fresh.remoteErasure(for: marker), .none)

        // #78 より前に作った台帳(作った時刻が無い)は、印より前とみなす。
        let legacy = try Ledger.inMemory()
        try await legacy.queue.write { db in try db.execute(sql: "DELETE FROM ledger_meta WHERE key = ?", arguments: [LearningErasure.createdMetaKey]) }
        XCTAssertEqual(legacy.remoteErasure(for: marker), .erase)
    }

    func testNewerMarkerIsNotOverwrittenByAnOlderOne() {
        let store = MemoryValueStore()
        let newer = LearningErasure.Marker.new(now: Date())
        let older = LearningErasure.Marker.new(now: Date().addingTimeInterval(-3600))
        LearningErasure.publish(newer, to: store)
        LearningErasure.publish(older, to: store)
        XCTAssertEqual(LearningErasure.cloudMarker(store), newer)
    }

    /// 使用額・お試しの数・年齢・同意の記録(Keychain と iCloud の Key-Value ストア)は、消去の対象の外。
    func testUsageTrialAgeAndConsentAreOutsideTheErasure() async throws {
        let local = MemoryValueStore(), cloud = MemoryValueStore()
        let records = OnboardingRecords(values: MirroredValues(local: local, cloud: cloud))
        records.recordTrialSolved()
        records.acceptTerms()
        records.saveAge(AgeResult(band: .adult, declaration: "selfDeclared", checkedAt: Date()))
        let before = cloud.keys(withPrefix: "")
        let ledger = try Ledger.inMemory()
        _ = try await seed(ledger)
        let marker = LearningErasure.Marker.new()
        LearningErasure.publish(marker, to: cloud)
        try await ledger.beginErasure(marker, remote: false)
        try await ledger.eraseLearningRecords()
        XCTAssertEqual(records.trialUsed, 1, "お試しの枠は戻らない")
        XCTAssertTrue(records.hasAcceptedCurrentTerms)
        XCTAssertNotNil(records.age)
        XCTAssertEqual(Set(cloud.keys(withPrefix: "")), Set(before + [LearningErasure.markerKey]))
    }
}
