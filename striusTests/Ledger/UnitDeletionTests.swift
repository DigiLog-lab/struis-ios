import GRDB
import XCTest
import UIKit
@testable import strius

final class UnitDeletionTests: XCTestCase {
    private func seed(_ ledger: Ledger) async throws -> (String, String, String) {
        try await ledger.commit { db in
            var m = try WorkbookMachine(loading: db)
            let first = m.createUnit(title: "同名", outcome: "exclusive-original-92831", source: "manual", subunits: [.init(title: "専有小単元", n: 2)], firstStage: 3)
            let other = m.createUnit(title: "同名", outcome: "shared-survivor", source: "manual", subunits: [.init(title: "残す小単元", n: 2)], firstStage: 3)
            let subunit = m.orderedSubunits(unitID: first)[0].id
            _ = m.addProblems(subunitID: subunit, problems: [.init(prompt: "exclusive-problem-92831")], source: "generated")
            return (m.events, (first, other, subunit))
        }
    }

    func testDeletionErasesOriginalsAndPreservesSameNameAndRebuild() async throws {
        let ledger = try Ledger.inMemory()
        let (first, other, subunit) = try await seed(ledger)
        let old = try await ledger.read { try WorkbookUnitRecord.fetchOne($0, key: first)! }
        let fact = try await ledger.deleteUnit(id: first)
        XCTAssertEqual(fact.unitID, first)
        XCTAssertEqual(fact.actor, "user")
        let ids = try await ledger.read { try WorkbookUnitRecord.fetchAll($0).map(\.id) }
        XCTAssertEqual(ids, [other])
        let children = try await ledger.read { try WorkbookSubunitRecord.fetchOne($0, key: subunit) }
        XCTAssertNil(children)
        let events = try await ledger.events()
        XCTAssertFalse(events.map(\.payload).joined().contains("exclusive-original-92831"))
        XCTAssertFalse(events.map(\.payload).joined().contains("exclusive-problem-92831"))
        let before = try await ledger.projectionDigest()
        try await ledger.rebuild()
        let after = try await ledger.projectionDigest()
        XCTAssertEqual(before, after)
        let again = try await ledger.deleteUnit(id: first)
        XCTAssertEqual(again.operationID, fact.operationID)
        let facts = try await ledger.events().filter { $0.kind == "unit.deleted" }
        XCTAssertEqual(facts.count, 1)
        do { try await ledger.append([.upsert("unit.late", old)]); XCTFail("古い結果を拒否しない") } catch {}
        let dbData = try Data(contentsOf: ledger.deletionRoot.appendingPathComponent("ledger.sqlite"))
        XCTAssertNil(dbData.range(of: Data("exclusive-original-92831".utf8)))
        XCTAssertNil(dbData.range(of: Data("exclusive-problem-92831".utf8)))
    }

    func testDedicatedMemoryRemovedSharedClaimRetainedAndFactInjected() async throws {
        let ledger = try Ledger.inMemory()
        let (first, _, subunit) = try await seed(ledger)
        let desk = ledger.deletionRoot.appendingPathComponent("memory/tutor_desk")
        try FileManager.default.createDirectory(at: desk.appendingPathComponent("skills"), withIntermediateDirectories: true)
        let path = desk.appendingPathComponent("skills/inferences.yaml")
        let targetEvidence: LedgerJSON = .object(["type": .string("attempt"), "id": .string(subunit)])
        let otherEvidence: LedgerJSON = .object(["type": .string("attempt"), "id": .string("unrelated")])
        let exclusive: LedgerJSON = .object(["id": .string("exclusive"), "claim": .string("exclusive-memory-92831"), "evidence_refs": .array([targetEvidence])])
        let shared: LedgerJSON = .object(["id": .string("shared"), "claim": .string("keep-this-shared-ability"), "evidence_refs": .array([targetEvidence, otherEvidence])])
        let memory: LedgerJSON = .object(["claims": .array([exclusive, shared])])
        try JSONEncoder().encode(memory).write(to: path)
        let before = try TutorMemory.modelMemoryManifest(workspace: ledger.deletionRoot.appendingPathComponent("memory"))
        _ = try await ledger.deleteUnit(id: first)
        let raw = try String(contentsOf: path, encoding: .utf8)
        XCTAssertFalse(raw.contains("exclusive-memory-92831"))
        XCTAssertTrue(raw.contains("keep-this-shared-ability"))
        XCTAssertFalse(raw.contains(subunit))
        let context = try TutorMemory.renderTutorMemoryContext(workspace: ledger.deletionRoot.appendingPathComponent("memory"))
        XCTAssertTrue(context.contains(first))
        XCTAssertTrue(context.contains("current/deletions.yaml"))
        let after = try TutorMemory.modelMemoryManifest(workspace: ledger.deletionRoot.appendingPathComponent("memory"))
        XCTAssertNotEqual(before.digest, after.digest)
    }

    func testArchiveRoundTripAfterDeletion() async throws {
        let ledger = try Ledger.inMemory()
        let (first, _, _) = try await seed(ledger)
        _ = try await ledger.deleteUnit(id: first)
        let archive = try await LedgerArchive.export(ledger: ledger, root: ledger.deletionRoot, to: ledger.deletionRoot)
        let target = try Ledger.inMemory()
        _ = try await LedgerArchive.importArchive(from: archive, into: target, root: target.deletionRoot)
        let original = try await ledger.projectionDigest()
        let imported = try await target.projectionDigest()
        XCTAssertEqual(original, imported)
        let facts = try await target.events().filter { $0.kind == "unit.deleted" }
        XCTAssertEqual(facts.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.deletionRoot.appendingPathComponent("memory/tutor_desk/current/deletions.yaml").path))
    }

    func testCrashBeforeCommitRestoresMemoryBeforeReads() async throws {
        let ledger = try Ledger.inMemory()
        let (first, _, _) = try await seed(ledger)
        let root = ledger.deletionRoot
        let journal = try await ledger.queue.read { try UnitDeletion.prepare(db: $0, root: root, unitID: first, extraCodexIDs: [], runtimeRoots: []) }
        try JSONEncoder().encode(journal).write(to: UnitDeletion.journalURL(root))
        for change in journal.changes { try UnitDeletion.write(change) }
        do { _ = try await LedgerArchive.export(ledger: ledger, root: root, to: root); XCTFail("途中の書き出しを許可した") } catch {}
        let reopened = try Ledger(path: root.appendingPathComponent("ledger.sqlite"))
        let unit = try await reopened.read { try WorkbookUnitRecord.fetchOne($0, key: first) }
        XCTAssertNotNil(unit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: UnitDeletion.journalURL(root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("memory/tutor_desk/current/deletions.yaml").path))
    }

    func testCrashAfterCommitFinishesErasureAndKeepsOneFact() async throws {
        let ledger = try Ledger.inMemory()
        let (first, _, _) = try await seed(ledger)
        let root = ledger.deletionRoot
        let privateFile = root.appendingPathComponent("exclusive.jsonl")
        try Data("exclusive-rollout-92831".utf8).write(to: privateFile)
        var journal = try await ledger.queue.read { try UnitDeletion.prepare(db: $0, root: root, unitID: first, extraCodexIDs: [], runtimeRoots: []) }
        journal.files.append(privateFile.path)
        try JSONEncoder().encode(journal).write(to: UnitDeletion.journalURL(root))
        try await ledger.queue.write { db in
            for event in journal.events { try db.execute(sql: "DELETE FROM ledger_events WHERE entity=? AND entity_id=?", arguments: [event.entity.rawValue, event.entityID]) }
            try Ledger.append(journal.events, deviceID: ledger.deviceID, to: db)
        }
        let reopened = try Ledger(path: root.appendingPathComponent("ledger.sqlite"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateFile.path))
        let unit = try await reopened.read { try WorkbookUnitRecord.fetchOne($0, key: first) }
        XCTAssertNil(unit)
        let facts = try await reopened.events().filter { $0.kind == "unit.deleted" }
        XCTAssertEqual(facts.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: UnitDeletion.journalURL(root).path))
    }
    func testSharedAndUnclassifiedCapturesKeepOriginalImageAndOtherAttempt() async throws {
        let ledger = try Ledger.inMemory()
        let (first, other, subunit) = try await seed(ledger)
        let otherSubunit = try await ledger.read { db in try WorkbookSubunitRecord.filter(Column("unit_id") == other).fetchOne(db)!.id }
        let root = ledger.deletionRoot
        try FileManager.default.createDirectory(at: root.appendingPathComponent("captures"), withIntermediateDirectories: true)
        let image = Data("shared-photo-content".utf8)
        try image.write(to: root.appendingPathComponent("captures/shared.jpg"))
        let now = LedgerClock.now()
        let firstAttempt = WorkbookAttemptRecord(id: "first-attempt", subunitId: subunit, problemId: "first-problem", captureId: "shared-cap", setId: nil, sequence: 1, verdict: "correct", score: 1, assisted: false, errorTag: "", note: "exclusive-grade", createdAt: now)
        let otherAttempt = WorkbookAttemptRecord(id: "other-attempt", subunitId: otherSubunit, problemId: "other-problem", captureId: "shared-cap", setId: nil, sequence: 1, verdict: "incorrect", score: 0, assisted: false, errorTag: "", note: "keep-other-grade", createdAt: now)
        let shared = WorkbookCaptureRecord(id: "shared-cap", status: "graded", imagePath: "shared.jpg", contentType: "image/jpeg", sha256: "0", byteCount: image.count, context: .object(["stages": .object([subunit: .number(3), otherSubunit: .number(3)])]), subunitId: subunit, setId: nil, verdicts: .array([.object(["problem_id": .string("first-problem"), "note": .string("exclusive-grade")]), .object(["problem_id": .string("other-problem"), "note": .string("keep-other-grade")])]), summary: .emptyObject, candidates: .emptyArray, error: nil, createdAt: now, updatedAt: now, gradedAt: now)
        var free = shared; free.id = "unknown-cap"; free.status = "identifying"; free.subunitId = nil; free.verdicts = .emptyArray
        try await ledger.append([.upsert("capture.created", shared), .upsert("capture.created", free), .upsert("attempt.recorded", firstAttempt), .upsert("attempt.recorded", otherAttempt)])
        _ = try await ledger.deleteUnit(id: first)
        let kept = try await ledger.read { try WorkbookCaptureRecord.fetchOne($0, key: "shared-cap")! }
        XCTAssertEqual(kept.subunitId, otherSubunit)
        XCTAssertFalse(kept.verdicts.canonicalText.contains("exclusive-grade"))
        XCTAssertTrue(kept.verdicts.canonicalText.contains("keep-other-grade"))
        XCTAssertEqual(kept.summary["result"]?["total"]?.intValue, 1)
        XCTAssertEqual(kept.summary["result"]?["correct"]?.intValue, 0)
        let survived = try await ledger.read { try WorkbookAttemptRecord.fetchOne($0, key: "other-attempt") }
        XCTAssertEqual(survived, otherAttempt)
        let freeCapture = try await ledger.read { try WorkbookCaptureRecord.fetchOne($0, key: "unknown-cap") }
        XCTAssertNotNil(freeCapture)
        XCTAssertEqual(freeCapture?.summary, .emptyObject)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("captures/shared.jpg")), image)
    }

    func testDatabaseFailureRestoresMemoryAndUnitAndRetryCommitsOnce() async throws {
        let ledger = try Ledger.inMemory()
        let (first, _, _) = try await seed(ledger)
        try await ledger.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_deletion BEFORE INSERT ON ledger_events WHEN NEW.kind='unit.deleted' BEGIN SELECT RAISE(ABORT, 'injected-save-failure'); END")
        }
        do { _ = try await ledger.deleteUnit(id: first); XCTFail("失敗注入が効いていない") } catch { XCTAssertTrue(String(describing: error).contains("injected-save-failure")) }
        let unit = try await ledger.read { try WorkbookUnitRecord.fetchOne($0, key: first) }
        XCTAssertNotNil(unit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: UnitDeletion.journalURL(ledger.deletionRoot).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.deletionRoot.appendingPathComponent("memory/tutor_desk/current/deletions.yaml").path))
        try await ledger.queue.write { try $0.execute(sql: "DROP TRIGGER reject_deletion") }
        _ = try await ledger.deleteUnit(id: first)
        let facts = try await ledger.events().filter { $0.kind == "unit.deleted" }
        XCTAssertEqual(facts.count, 1)
    }

    func testIncompleteCommittedRecoveryBlocksAIAndExportUntilRetry() async throws {
        let ledger = try Ledger.inMemory()
        let (first, _, _) = try await seed(ledger)
        let root = ledger.deletionRoot
        let journal = try await ledger.queue.read { try UnitDeletion.prepare(db: $0, root: root, unitID: first, extraCodexIDs: [], runtimeRoots: []) }
        try JSONEncoder().encode(journal).write(to: UnitDeletion.journalURL(root))
        try await ledger.queue.write { db in
            for event in journal.events { try db.execute(sql: "DELETE FROM ledger_events WHERE entity=? AND entity_id=?", arguments: [event.entity.rawValue, event.entityID]) }
            try Ledger.append(journal.events, deviceID: ledger.deviceID, to: db)
        }
        let blocked = root.appendingPathComponent("memory/tutor_desk/current/deletions.yaml")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let reopened = try Ledger(path: root.appendingPathComponent("ledger.sqlite"))
        let pending = await reopened.pendingDeletion()
        XCTAssertEqual(pending?.unitID, first)
        do { _ = try await reopened.withMemory { _ in "must-not-run" }; XCTFail("不完全な記憶でAI入力を許可した") } catch {}
        do { _ = try await LedgerArchive.export(ledger: reopened, root: root, to: root); XCTFail("不完全な状態を書き出した") } catch {}
        try FileManager.default.removeItem(at: blocked)
        let fact = try await reopened.deleteUnit(id: first)
        XCTAssertEqual(fact.operationID, journal.fact.operationID)
        let facts = try await reopened.events().filter { $0.kind == "unit.deleted" }
        XCTAssertEqual(facts.count, 1)
    }

    func testTitlesAndProseThatEqualAnIDAreNeverOwnershipEvidence() {
        let raw: LedgerJSON = .object(["title": .string("deleted-id"), "plain_text": .string("deleted-id"), "subunit_id": .string("deleted-id")])
        let scrubbed = UnitDeletion.scrub(raw, ids: ["deleted-id"])
        XCTAssertEqual(scrubbed["title"]?.stringValue, "deleted-id")
        XCTAssertEqual(scrubbed["plain_text"]?.stringValue, "deleted-id")
        XCTAssertTrue(scrubbed["subunit_id"]?.isNull == true)
        XCTAssertTrue(UnitDeletion.references(.object(["title": .string("deleted-id")])).isEmpty)
    }

    func testDedicatedAttachmentsAndPDFDerivativeErasedSharedAttachmentRetained() async throws {
        let ledger = try Ledger.inMemory()
        let (first, _, subunit) = try await seed(ledger)
        let hash = String(repeating: "a", count: 64)
        let root = ledger.deletionRoot.appendingPathComponent("attachments")
        let paths = ["only.jpg", "model.pdf", "shared.jpg", "runtime-page-images-v1/" + hash + ".jpg", "runtime-page-images-v1/" + hash + ".jpg.sha256"]
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("private-file-original".utf8).write(to: url)
        }
        let (_, thread) = ChatRepository.createThread(id: "dedicated-thread", title: "専有")
        let (_, otherThread) = ChatRepository.createThread(id: "shared-thread", title: "共有")
        func attachment(_ path: String, kind: String = "image", sha: String = "") -> LedgerJSON {
            ChatTurns.Attachment(filename: path, contentType: "image/jpeg", bytes: 1, relativePath: path, sha256: sha, kind: kind).json
        }
        let (_, message) = ChatRepository.createMessage(id: "dedicated-message", threadID: "dedicated-thread", role: "user", status: "completed", plainText: "専有", blocks: .emptyArray, metadata: .object([
            "attachments": .array([attachment("only.jpg", kind: "page_image", sha: hash), attachment("shared.jpg")]),
            "model_attachments": .array([attachment("model.pdf", kind: "document")])
        ]))
        let (_, otherMessage) = ChatRepository.createMessage(id: "shared-message", threadID: "shared-thread", role: "user", status: "completed", plainText: "共有", blocks: .emptyArray, metadata: .object(["model_attachments": .array([attachment("shared.jpg")])]))
        try await ledger.commit { db in
            var row = try WorkbookSubunitRecord.fetchOne(db, key: subunit)!
            row.metadata = .object(["thread_id": .string("dedicated-thread")])
            return ([.upsert("subunit.thread", row), thread, otherThread, message, otherMessage], ())
        }
        _ = try await ledger.deleteUnit(id: first)
        for path in paths where path != "shared.jpg" { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("shared.jpg").path))
    }

    func testCodexIndexAndHistoryEraseOnlyDedicatedSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deletion-index-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: root.appendingPathComponent("state_5.sqlite").path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT); CREATE TABLE logs(thread_id TEXT, message TEXT)")
            try db.execute(sql: "INSERT INTO threads VALUES ('target-session','erase-original'),('shared-session','keep-original')")
            try db.execute(sql: "INSERT INTO logs VALUES ('target-session','erase-original'),('shared-session','keep-original')")
        }
        let history = root.appendingPathComponent("history.jsonl")
        try Data("{\"session_id\":\"target-session\",\"text\":\"erase-original\"}\n{\"session_id\":\"shared-session\",\"text\":\"keep-original\"}\n".utf8).write(to: history)
        try UnitDeletion.eraseIndexes(root, ids: ["target-session"])
        let kept = try queue.read { db in try String.fetchAll(db, sql: "SELECT id FROM threads") }
        XCTAssertEqual(kept, ["shared-session"])
        let logs = try queue.read { db in try String.fetchAll(db, sql: "SELECT thread_id FROM logs") }
        XCTAssertEqual(logs, ["shared-session"])
        XCTAssertFalse(try String(contentsOf: history, encoding: .utf8).contains("erase-original"))
        XCTAssertTrue(try String(contentsOf: history, encoding: .utf8).contains("keep-original"))
        XCTAssertNil(try Data(contentsOf: root.appendingPathComponent("state_5.sqlite")).range(of: Data("erase-original".utf8)))
    }

    func testSharedAndUnknownChildGoalsSurviveDeletedParent() async throws {
        let ledger = try Ledger.inMemory()
        let (first, _, subunit) = try await seed(ledger)
        let state: LedgerJSON = .object(["revision": .number(1), "goals": .object([
            "parent": .object(["id": .string("parent"), "evidence": .array([.object(["message_id": .string(subunit)])])]),
            "shared-child": .object(["id": .string("shared-child"), "parent_id": .string("parent"), "evidence": .array([.object(["message_id": .string("other-message")])])]),
            "unknown-child": .object(["id": .string("unknown-child"), "parent_id": .string("parent"), "evidence": .emptyArray])
        ])])
        try await ledger.append([.upsert("progress.saved", ProgressRevisionRecord(revision: 1, state: state, messageId: nil, turnId: nil, savedAt: LedgerClock.now()))])
        _ = try await ledger.deleteUnit(id: first)
        let progress = try await ledger.read { try ChatRepository.latestProgress($0)!.state }
        XCTAssertNil(progress["goals"]?["parent"])
        XCTAssertNotNil(progress["goals"]?["shared-child"])
        XCTAssertNotNil(progress["goals"]?["unknown-child"])
        XCTAssertTrue(progress["goals"]?["shared-child"]?["parent_id"]?.isNull == true)
    }

}

extension UnitDeletionTests {
    func testArchiveFailureRestoresFilesAndLeavesEmptyLedger() async throws {
        let source = try Ledger.inMemory()
        let (first, _, _) = try await seed(source)
        _ = try await source.deleteUnit(id: first)
        let archive = try await LedgerArchive.export(ledger: source, root: source.deletionRoot, to: source.deletionRoot)
        let target = try Ledger.inMemory()
        let memory = target.deletionRoot.appendingPathComponent("memory/tutor_desk/current/deletions.yaml")
        try FileManager.default.createDirectory(at: memory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("before-import".utf8).write(to: memory)
        try await target.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_import BEFORE INSERT ON ledger_meta WHEN NEW.key='archive_import_id' BEGIN SELECT RAISE(ABORT,'import commit failure'); END")
        }
        do {
            _ = try await LedgerArchive.importArchive(from: archive, into: target, root: target.deletionRoot)
            XCTFail("途中の取り込みを成功にした")
        } catch {}
        let count = try await target.eventCount()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try String(contentsOf: memory, encoding: .utf8), "before-import")
        XCTAssertFalse(FileManager.default.fileExists(atPath: LedgerArchive.importJournalURL(target.deletionRoot).path))
        try await target.queue.write { try $0.execute(sql: "DROP TRIGGER fail_import") }
        _ = try await LedgerArchive.importArchive(from: archive, into: target, root: target.deletionRoot)
        let imported = try await target.eventCount()
        XCTAssertGreaterThan(imported, 0)
        XCTAssertTrue(try String(contentsOf: memory, encoding: .utf8).contains(first))
    }

    func testImportCrashBeforeCommitRestoresFilesBeforeAIReads() async throws {
        let ledger = try Ledger.inMemory()
        let root = ledger.deletionRoot
        let existing = root.appendingPathComponent("memory/shared.txt")
        let new = root.appendingPathComponent("captures/imported.jpg")
        let changes = [UnitDeletion.Change(path: existing.path, before: Data("old".utf8), after: Data("new".utf8)), UnitDeletion.Change(path: new.path, before: nil, after: Data("image".utf8))]
        let journal = LedgerArchive.ImportJournal(id: "pre-commit", changes: changes)
        try JSONEncoder().encode(journal).write(to: LedgerArchive.importJournalURL(root))
        for change in changes { try UnitDeletion.write(change) }
        do { _ = try await ledger.read { _ in 0 }; XCTFail("途中の記憶を渡した") } catch {}
        let reopened = try Ledger(path: root.appendingPathComponent("ledger.sqlite"))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
        let count = try await reopened.eventCount()
        XCTAssertEqual(count, 0)
    }

    func testImportCrashAfterCommitFinishesFilesBeforeReads() async throws {
        let ledger = try Ledger.inMemory()
        let root = ledger.deletionRoot
        let path = root.appendingPathComponent("memory/shared.txt")
        let journal = LedgerArchive.ImportJournal(id: "post-commit", changes: [.init(path: path.path, before: nil, after: Data("committed-memory".utf8))])
        try JSONEncoder().encode(journal).write(to: LedgerArchive.importJournalURL(root))
        try await ledger.queue.write { db in try db.execute(sql: "INSERT INTO ledger_meta (key,value) VALUES ('archive_import_id',?)", arguments: [journal.id]) }
        let reopened = try Ledger(path: root.appendingPathComponent("ledger.sqlite"))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "committed-memory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: LedgerArchive.importJournalURL(root).path))
        _ = try await reopened.read { _ in 0 }
    }
}

/// 実ランナーの結果だけを保持し、削除との競合を再現する。モデル出力は生成しない。
@MainActor private final class HeldNativeDeletionRunner: TurnRunning {
    let native: CodexTurnRunner
    var held: TurnOutcome?
    var releaseContinuation: CheckedContinuation<Void, Never>?
    var interrupted = false
    init(_ native: CodexTurnRunner) { self.native = native }
    func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome {
        let outcome = try await native.run(plan, progress: progress)
        if held == nil {
            held = outcome
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        return outcome
    }
    func interrupt(planID: String) async { interrupted = true; await native.interrupt(planID: planID) }
    func forgetThreads(_ ids: Set<String>) async throws { try await native.forgetThreads(ids) }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

extension UnitDeletionTests {
    @MainActor
    func testNativeLateGradingGenerationChatAndPrefetchNeverRestoreDeletedUnit() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_UNIT_DELETION_LIVE"] == "1", "実Codex検証は明示的に起動する")
        try StruisPaths.prepare()
        let runtime = DeviceRuntime()
        try await runtime.ensureRunning()
        let assets = AssetCache()
        let source = try XCTUnwrap(LocalDirectoryAssetSource.fromEnvironment)
        _ = try await assets.refresh(from: source)
        let ledger = try Ledger(path: StruisPaths.ledger)
        for mode in ["grading", "generation", "chat", "prefetch"] {
            let native = CodexTurnRunner(runtime: runtime, assets: assets)
            let held = HeldNativeDeletionRunner(native)
            let coordinator = TurnCoordinator(ledger: ledger, assets: assets, runner: held)
            let captureID = LedgerID.make()
            let imageName = "unit-deletion-live-\(captureID).jpg"
            let imageURL = StruisPaths.captures.appendingPathComponent(imageName)
            let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 500)).jpegData(withCompressionQuality: 0.9) { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
                "問題: x + 1 = 2\n答案: x = 1".draw(in: CGRect(x: 40, y: 80, width: 720, height: 350), withAttributes: [.font: UIFont.systemFont(ofSize: 40), .foregroundColor: UIColor.black])
            }
            try image.write(to: imageURL)
            defer { try? FileManager.default.removeItem(at: imageURL) }
            let (unitID, subunitID, setID, threadID) = try await ledger.commit { db in
                var m = try WorkbookMachine(loading: db)
                let unitID = m.createUnit(title: "遅延検証 \(mode)", outcome: "一次方程式を解く", source: "manual", subunits: [.init(title: "一次方程式", outcome: "x + 1 = 2 を解く", n: 1)], firstStage: 3)
                let sub = m.orderedSubunits(unitID: unitID)[0].id
                _ = m.addProblems(subunitID: sub, problems: [.init(prompt: "x + 1 = 2 を解きなさい。")], source: "manual")
                let setID = mode == "prefetch" ? m.insertPrefetchedSet(subunitID: sub, stage: 4)! : m.insertGeneratingSet(subunitID: sub, spec: try m.nextSetSpec(subunitID: sub))
                _ = try m.createCapture(id: captureID, imagePath: imageName, contentType: "image/jpeg", sha256: "test-owned", byteCount: image.count, subunitID: sub, setID: nil)
                let thread = try m.ensureThread(subunitID: sub)
                return (m.events + thread.events, (unitID, sub, setID, thread.threadID))
            }
            switch mode {
            case "grading": await coordinator.startGrading(captureID: captureID)
            case "generation": await coordinator.startSetGeneration(setID: setID)
            case "prefetch": await coordinator.startPrefetchedSet(setID: setID)
            default: _ = try await coordinator.sendChat(.init(threadID: threadID, text: "x + 1 = 2 の解き方を一言で教えてください。", attachments: [], workbookView: .object(["unit_id": .string(unitID), "subunit_id": .string(subunitID)]), subunitID: subunitID))
            }
            let deadline = Date().addingTimeInterval(300)
            while await held.held == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
            let received = await held.held
            let outcome = try XCTUnwrap(received, "実ランナーの結果が届かない: \(mode)")
            guard outcome.status == .completed else {
                await held.release()
                XCTFail("実ランナー \(mode) status=\(outcome.status) error=\(outcome.error ?? "")")
                continue
            }
            XCTAssertNotNil(outcome.codexThreadID)
            print("UNIT_DELETION_NATIVE held mode=\(mode) status=\(outcome.status.rawValue) codex_thread=\(outcome.codexThreadID ?? "")")
            let deletion = Task { try await coordinator.deleteUnit(id: unitID) }
            let stopDeadline = Date().addingTimeInterval(15)
            while !(await held.interrupted) && Date() < stopDeadline { try await Task.sleep(for: .milliseconds(100)) }
            let stopped = await held.interrupted
            XCTAssertTrue(stopped)
            let during = try await ledger.read { try WorkbookUnitRecord.fetchOne($0, key: unitID) }
            XCTAssertNotNil(during, "実結果を保持している間に完了扱いにした")
            await held.release()
            _ = try await deletion.value
            let reopened = try Ledger(path: StruisPaths.ledger)
            await TurnCoordinator(ledger: reopened, assets: assets, runner: native).resumeUnfinished()
            let restored = try await reopened.read { db in
                try WorkbookUnitRecord.fetchOne(db, key: unitID) != nil || WorkbookSubunitRecord.fetchOne(db, key: subunitID) != nil || WorkbookSetRecord.fetchOne(db, key: setID) != nil || ThreadRecord.fetchOne(db, key: threadID) != nil
            }
            XCTAssertFalse(restored)
            let facts = try await reopened.events().filter { $0.kind == "unit.deleted" && $0.entityId == unitID }
            XCTAssertEqual(facts.count, 1)
            print("UNIT_DELETION_NATIVE deleted mode=\(mode) restored=\(restored) facts=\(facts.count)")
        }
    }
}
