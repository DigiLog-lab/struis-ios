import XCTest
@testable import strius

final class NativeMigrationTests: XCTestCase {
    func testInterruptedCopyRetriesPreservingOriginalsAndNewFiles() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let old = base.appendingPathComponent("agentcase")
        let home = old.appendingPathComponent("rootfs-v2/data/root/.codex")
        let target = base.appendingPathComponent("native")
        try fm.createDirectory(at: home.appendingPathComponent("sessions/2026"), withIntermediateDirectories: true)
        try fm.createDirectory(at: target.appendingPathComponent("codex"), withIntermediateDirectories: true)
        let original = Data("migration-test-auth".utf8)
        try original.write(to: home.appendingPathComponent("auth.json"))
        try Data("original-session".utf8).write(to: home.appendingPathComponent("sessions/2026/test.jsonl"))
        try Data("existing-native-setting".utf8).write(to: target.appendingPathComponent("codex/config.toml"))
        try Data("older-setting".utf8).write(to: home.appendingPathComponent("config.toml"))
        // An unsafe existing destination stops the migration without writing its completion marker.
        try fm.createSymbolicLink(at: target.appendingPathComponent("codex/sessions"), withDestinationURL: home.appendingPathComponent("sessions"))
        XCTAssertThrowsError(try HyotanBoot.migrateLegacyData(from: [old], to: target))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("migration-v1-complete").path))
        try fm.removeItem(at: target.appendingPathComponent("codex/sessions"))
        try HyotanBoot.migrateLegacyData(from: [old], to: target)
        try HyotanBoot.migrateLegacyData(from: [old], to: target)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), original)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("codex/auth.json")), original)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("codex/config.toml"), encoding: .utf8), "existing-native-setting")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("codex/sessions/2026/test.jsonl"), encoding: .utf8), "original-session")
        let permissions = try fm.attributesOfItem(atPath: target.appendingPathComponent("codex/auth.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("migration-v1-complete").path))
        print("NATIVE_MIGRATION retry=ok originals=retained auth_mode=0600 existing_native=retained")
    }

    func testCodexHomeMovesIntoAppAndLeavesNoCredentialsInAppGroup() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let shared = base.appendingPathComponent("group/codex")
        let home = base.appendingPathComponent("private/codex")
        try fm.createDirectory(at: shared.appendingPathComponent("sessions/2026"), withIntermediateDirectories: true)
        let auth = Data("migration-test-auth".utf8)
        try auth.write(to: shared.appendingPathComponent("auth.json"))
        try Data("token".utf8).write(to: shared.appendingPathComponent("transport-token"))
        try Data("rollout".utf8).write(to: shared.appendingPathComponent("sessions/2026/test.jsonl"))
        try Data("db".utf8).write(to: shared.appendingPathComponent("state_5.sqlite"))
        try Data("db-wal".utf8).write(to: shared.appendingPathComponent("state_5.sqlite-wal"))
        // Writable by model-directed commands in the app group: never trusted by the in-app Codex.
        try Data("experimental_compact_prompt_file = \"auth.json\"".utf8).write(to: shared.appendingPathComponent("config.toml"))
        try Data("instructions".utf8).write(to: shared.appendingPathComponent("AGENTS.md"))
        try fm.createDirectory(at: shared.appendingPathComponent("skills/x"), withIntermediateDirectories: true)
        // A copy that does not match stops before the app-group credentials are removed.
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("different".utf8).write(to: home.appendingPathComponent("auth.json"))
        XCTAssertThrowsError(try HyotanBoot.moveCodexHomeIntoApp(from: shared, to: home))
        XCTAssertTrue(fm.fileExists(atPath: shared.appendingPathComponent("auth.json").path))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".moved-from-app-group").path))
        try fm.removeItem(at: home.appendingPathComponent("auth.json"))
        try HyotanBoot.moveCodexHomeIntoApp(from: shared, to: home)
        try HyotanBoot.moveCodexHomeIntoApp(from: shared, to: home)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), auth)
        let permissions = try fm.attributesOfItem(atPath: home.appendingPathComponent("auth.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertFalse(fm.fileExists(atPath: shared.appendingPathComponent("auth.json").path))
        XCTAssertFalse(fm.fileExists(atPath: shared.appendingPathComponent("transport-token").path))
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("sessions/2026/test.jsonl"), encoding: .utf8), "rollout")
        XCTAssertTrue(fm.fileExists(atPath: shared.appendingPathComponent("state_5.sqlite").path), "Other originals stay")
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("state_5.sqlite").path))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("state_5.sqlite-wal").path))
        for name in ["config.toml", "AGENTS.md", "skills"] {
            XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(name).path), name)
        }
        // Later app-group credentials (a rollback build, or a model-directed command) are removed,
        // never imported, and no app-group journal reaches the private databases.
        try Data("planted-login".utf8).write(to: shared.appendingPathComponent("auth.json"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: shared.appendingPathComponent("auth.json").path)
        try Data("token".utf8).write(to: shared.appendingPathComponent("transport-token"))
        try fm.removeItem(at: home.appendingPathComponent("state_5.sqlite-wal"))
        try Data("rollback-rollout".utf8).write(to: shared.appendingPathComponent("sessions/2026/new.jsonl"))
        try HyotanBoot.moveCodexHomeIntoApp(from: shared, to: home)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), auth, "never replaced from the app group")
        XCTAssertFalse(fm.fileExists(atPath: shared.appendingPathComponent("auth.json").path))
        XCTAssertFalse(fm.fileExists(atPath: shared.appendingPathComponent("transport-token").path))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("state_5.sqlite-wal").path), "no journal applied to a moved database")
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("sessions/2026/new.jsonl").path))
        print("NATIVE_CODEX_HOME_MOVE copied=true config_instructions_skills_excluded=true shared_auth_removed=true shared_token_removed=true originals_retained=true later_credentials_removed_not_imported=true")
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
