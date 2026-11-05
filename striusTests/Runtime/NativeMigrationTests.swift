import XCTest
@testable import strius

final class NativeMigrationTests: XCTestCase {
    func testInterruptedCopyRetriesPreservingOriginalsAndNewFiles() throws {
        let fm: FileManager = FileManager.default
        let base: URL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let old: URL = base.appendingPathComponent("agentcase")
        let workspace: URL = old.appendingPathComponent("workspace")
        // 以前の Linux 環境の Codex のデータ。端末内の Codex を外した後は写さない(2026-11-03)。
        let home: URL = old.appendingPathComponent("rootfs-v2/data/root/.codex")
        let target: URL = base.appendingPathComponent("native")
        try fm.createDirectory(at: workspace.appendingPathComponent("thread-a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: workspace.appendingPathComponent("thread-b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: target.appendingPathComponent("workspace/thread-b"), withIntermediateDirectories: true)
        try Data("migration-test-auth".utf8).write(to: home.appendingPathComponent("auth.json"))
        let original: Data = Data("original-notes".utf8)
        try original.write(to: workspace.appendingPathComponent("thread-a/notes.md"))
        try Data("older-notes".utf8).write(to: workspace.appendingPathComponent("thread-b/notes.md"))
        try Data("existing-native-notes".utf8).write(to: target.appendingPathComponent("workspace/thread-b/notes.md"))
        // 書き先に既にあるリンクは移行を止め、完了の印を書かない。
        try fm.createSymbolicLink(at: target.appendingPathComponent("workspace/thread-a"), withDestinationURL: base)
        XCTAssertThrowsError(try HyotanBoot.migrateLegacyData(from: [old], to: target))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("migration-v1-complete").path))
        try fm.removeItem(at: target.appendingPathComponent("workspace/thread-a"))
        try HyotanBoot.migrateLegacyData(from: [old], to: target)
        try HyotanBoot.migrateLegacyData(from: [old], to: target)
        XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("thread-a/notes.md")), original, "元のファイルは残す")
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("workspace/thread-a/notes.md")), original)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("workspace/thread-b/notes.md"), encoding: .utf8), "existing-native-notes",
                       "移した後のファイルは上書きしない")
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("codex").path), "Codex のデータは写さない")
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("migration-v1-complete").path))
        print("NATIVE_MIGRATION retry=ok originals=retained existing_native=retained codex_copied=false")
    }

    /// 端末内の Codex を外した(2026-11-03)後は、その home(ChatGPT の認証・会話の rollout・状態の DB)を消す。
    /// 無い場所は飛ばし、ほかの場所は消し続ける。
    func testRetiredCodexDataIsRemovedAndMissingHomesAreSkipped() throws {
        let fm: FileManager = FileManager.default
        let base: URL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let missing: URL = base.appendingPathComponent("missing/codex")
        let shared: URL = base.appendingPathComponent("group/codex")
        let home: URL = base.appendingPathComponent("private/codex")
        for directory in [shared, home] {
            try fm.createDirectory(at: directory.appendingPathComponent("sessions/2026"), withIntermediateDirectories: true)
            try Data("migration-test-auth".utf8).write(to: directory.appendingPathComponent("auth.json"))
            try Data("rollout".utf8).write(to: directory.appendingPathComponent("sessions/2026/test.jsonl"))
        }
        let sibling: URL = base.appendingPathComponent("group/workspace/keep.md")
        try fm.createDirectory(at: sibling.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: sibling)
        HyotanBoot.removeRetiredData([missing, shared, home])
        XCTAssertFalse(fm.fileExists(atPath: shared.path))
        XCTAssertFalse(fm.fileExists(atPath: home.path))
        XCTAssertFalse(fm.fileExists(atPath: missing.path))
        XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "keep", "Codex の home の外は消さない")
        // 2 回目(次の起動)は何も無いので何もしない。
        HyotanBoot.removeRetiredData([missing, shared, home])
        XCTAssertTrue(fm.fileExists(atPath: sibling.path))
        XCTAssertEqual(HyotanBoot.retiredCodexHomes.map(\.lastPathComponent), ["codex", "codex"])
        print("NATIVE_RETIRED_CODEX_DATA removed=true missing_skipped=true siblings_kept=true")
    }

    func testPersistentSimulatorLedgerArchiveRoundTrip() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1", "Simulatorの実操作後に実行")
        let source = try Ledger(path: StruisPaths.ledger)
        let count = try await source.eventCount()
        XCTAssertGreaterThan(count, 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try await LedgerArchive.export(ledger: source, to: directory)
        let target = try Ledger.inMemory()
        let root = directory.appendingPathComponent("imported")
        let manifest = try await LedgerArchive.importArchive(from: archive, into: target, root: root)
        XCTAssertEqual(manifest.eventCount, count)
        let before = try await source.projectionDigest()
        let after = try await target.projectionDigest()
        XCTAssertEqual(before, after)
        let entries = try ZipReader.entries(of: Data(contentsOf: archive))
        var retained = 0
        for (path, data) in entries where LedgerArchive.fileRoots.contains(where: { path.hasPrefix($0 + "/") }) {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), data)
            retained += 1
        }
        XCTAssertGreaterThan(retained, 0, "写真・memory等の実ファイルが無い")
        print("NATIVE_LEDGER_ZIP events=\(count) projection_equal=true retained_files=\(retained)")
    }

    func testSavedPlanPathsResolveAgainstCurrentContainer() throws {
        let old = "/old-container/Library/Application Support/Struis/"
        XCTAssertEqual(try TurnPlan.storedHostURL(old + "captures/paper.jpg"), StruisPaths.captures.appendingPathComponent("paper.jpg"))
        XCTAssertEqual(try TurnPlan.storedHostURL(old + "memory/learner/dossier.yaml"), StruisPaths.memory.appendingPathComponent("learner/dossier.yaml"))
        XCTAssertThrowsError(try TurnPlan.storedHostURL(old + "../../secret"))
        // Only attachments, captures and the tutor desk may be staged where the model can read them.
        XCTAssertEqual(try TurnPlan.stageableHostURL(old + "captures/paper.jpg"), StruisPaths.captures.appendingPathComponent("paper.jpg"))
        XCTAssertNoThrow(try TurnPlan.stageableHostURL(old + "memory/tutor_desk"))
        XCTAssertNoThrow(try TurnPlan.stageableHostURL(old + "attachments/batch/1-page.jpg"))
        for path in [old + "ledger.sqlite", old + "memory/learner/dossier.yaml", old + "attachments/../ledger.sqlite", "/etc/passwd"] {
            XCTAssertThrowsError(try TurnPlan.stageableHostURL(path), path)
        }
        print("NATIVE_PLAN_PATHS captures=current_container memory=current_container traversal=rejected")
    }
}
