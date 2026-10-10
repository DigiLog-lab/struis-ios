import Foundation
import GRDB
import OSLog

private let bootLog = Logger(subsystem: "com.digiloglab.strius", category: "hyotan")

/// Prepares runtime data. The workspace stays in the app group for the Exec worker; Codex's home
/// (auth, transport token, config, rollouts, state) lives in the app's own container, outside the
/// Exec worker's reach and outside the Ledger directory.
@Observable @MainActor final class HyotanBoot {
    enum State: Equatable {
        case idle, installing(Double), booting, ready, failed(String)
        var isReady: Bool { self == .ready }
    }
    private(set) var state: State = .idle
    private(set) var manifest: RootfsManifest?
    private(set) var installDuration: TimeInterval?
    private(set) var bootDuration: TimeInterval?
    let hyotanVersion = "native-0.153.4"
    private var startTask: Task<Void, Never>?
    nonisolated static let legacyRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("hyotan", isDirectory: true)
    nonisolated static var root: URL { NativeRuntimePaths.sharedRoot ?? legacyRoot.appendingPathComponent("native-unavailable") }
    nonisolated static var workspaceRoot: URL { root.appendingPathComponent("workspace", isDirectory: true) }
    nonisolated static var codexHome: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StruisRuntime/codex", isDirectory: true)
    }
    /// Former app-group location, read once by `moveCodexHomeIntoApp`.
    nonisolated static var sharedCodexHome: URL { root.appendingPathComponent("codex", isDirectory: true) }
    // Retained for legacy archive tests and migration inspection; no Linux runtime boots.
    nonisolated static func rootfsDirectory(version: Int) -> URL { legacyRoot.appendingPathComponent("rootfs-v\(version)") }

    func start() async {
        if state.isReady { return }
        if let startTask { await startTask.value; return }
        let task = Task { await prepare() }
        startTask = task
        await task.value
        startTask = nil
    }
    private func prepare() async {
        state = .booting
        let began = Date()
        do {
            guard NativeRuntimePaths.sharedRoot != nil else { throw CocoaError(.fileReadNoPermission) }
            try await Task.detached {
                let fm = FileManager.default
                for directory in [Self.root, Self.workspaceRoot, Self.codexHome, Self.root.appendingPathComponent("home")] {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                }
                var root = Self.root
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try root.setResourceValues(values)
                try Self.migrateLegacyData(from: [Self.legacyRoot, Self.legacyRoot.deletingLastPathComponent().appendingPathComponent("agentcase")], to: Self.root)
                try Self.moveCodexHomeIntoApp(from: Self.sharedCodexHome, to: Self.codexHome)
                var home = Self.codexHome
                try home.setResourceValues(values)
            }.value
            installDuration = Date().timeIntervalSince(began)
            state = .ready
        } catch {
            bootLog.error("native runtime preparation failed: \(String(describing: error), privacy: .public)")
            state = .failed("実行環境を準備できませんでした。")
        }
    }
    nonisolated static func migrateLegacyData(from roots: [URL], to root: URL) throws {
        let fm = FileManager.default
        let codexHome = root.appendingPathComponent("codex")
        let workspaceRoot = root.appendingPathComponent("workspace")
        let marker = root.appendingPathComponent("migration-v1-complete")
        guard !fm.fileExists(atPath: marker.path) else { return }
        for old in roots where fm.fileExists(atPath: old.path) {
            let versions = try fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("rootfs-v") && !$0.lastPathComponent.hasSuffix(".installing") }
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            for version in versions {
                let source = version.appendingPathComponent("data/root/.codex")
                if fm.fileExists(atPath: source.path) { try copyMissing(from: source, to: codexHome) }
            }
            let workspaces = old.appendingPathComponent("workspace")
            if fm.fileExists(atPath: workspaces.path) { try copyMissing(from: workspaces, to: workspaceRoot) }
        }
        let auth = codexHome.appendingPathComponent("auth.json")
        if fm.fileExists(atPath: auth.path) { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path) }
        try Data("1".utf8).write(to: marker, options: .atomic)
    }

    /// Copies the former app-group Codex home's data once, then removes the credentials there: the
    /// Exec worker shares the app group and must not read auth or the transport token. Other files
    /// stay as the original until a later cleanup decision. Only data is copied: config,
    /// instructions, skills and the like were writable by model-directed commands there, and Codex
    /// in the app process would trust them (a config path setting is read outside the workspace
    /// capability). After the move nothing more is imported: a credential that appears in the app
    /// group later (a rollback build, or a model-directed command) is removed, never trusted, and a
    /// stray SQLite journal is never applied to the private databases.
    nonisolated static func moveCodexHomeIntoApp(from shared: URL, to home: URL) throws {
        let fm = FileManager.default
        let marker = home.appendingPathComponent(".moved-from-app-group")
        let sharedAuth = shared.appendingPathComponent("auth.json")
        let sharedToken = shared.appendingPathComponent("transport-token")
        if fm.fileExists(atPath: marker.path) {
            for credential in [sharedAuth, sharedToken] where fm.fileExists(atPath: credential.path) {
                try fm.removeItem(at: credential)
            }
            return
        }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let entries = fm.fileExists(atPath: shared.path) ? try fm.contentsOfDirectory(atPath: shared.path) : []
        for name in entries where isCodexHomeData(name) {
            try copyMissing(from: shared.appendingPathComponent(name), to: home.appendingPathComponent(name))
        }
        let auth = home.appendingPathComponent("auth.json")
        if fm.fileExists(atPath: auth.path) { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path) }
        if fm.fileExists(atPath: sharedAuth.path) {
            // A copy that does not match stops before the app-group credential is removed.
            guard try Data(contentsOf: auth) == Data(contentsOf: sharedAuth) else { throw CocoaError(.fileWriteUnknown) }
            try fm.removeItem(at: sharedAuth)
        }
        if fm.fileExists(atPath: sharedToken.path) { try fm.removeItem(at: sharedToken) }
        try Data("1".utf8).write(to: marker, options: .atomic)
    }

    /// Credentials, conversation rollouts, state databases and prompt history.
    nonisolated static func isCodexHomeData(_ name: String) -> Bool {
        if ["auth.json", "sessions", "archived_sessions", "history.jsonl"].contains(name) { return true }
        return name.range(of: #"^(state|logs|goals|memories|queue|thread_history)_[0-9]+\.sqlite(-wal|-shm|-journal)?$"#,
                          options: .regularExpression) != nil
    }

    /// Codex's SQLite index stores absolute rollout paths, including Linux /root/.codex.
    /// Run before the in-process server first opens the database, so an iOS container relocation
    /// is handled too.
    nonisolated static func rebaseCodexState() throws {
        let fm = FileManager.default
        let databases = try fm.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: [.isSymbolicLinkKey])
        for database in databases where database.lastPathComponent.hasPrefix("state_") && database.pathExtension == "sqlite" {
            guard try database.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
            let queue = try DatabaseQueue(path: database.path)
            try queue.write { db in
                guard try db.tableExists("threads") else { return }
                let columns = Set(try db.columns(in: "threads").map(\.name))
                guard columns.isSuperset(of: ["id", "rollout_path", "cwd"]) else { return }
                for row in try Row.fetchAll(db, sql: "SELECT id, rollout_path, cwd FROM threads") {
                    let id: String = row["id"]
                    let oldPath: String = row["rollout_path"]
                    var newPath = oldPath
                    for folder in ["sessions", "archived_sessions"] {
                        if let range = oldPath.range(of: "/" + folder + "/", options: .backwards) {
                            let relative = folder + "/" + oldPath[range.upperBound...]
                            guard !relative.split(separator: "/").contains("..") else { continue }
                            let candidate = codexHome.appendingPathComponent(relative).resolvingSymlinksInPath()
                            if candidate.path.hasPrefix(codexHome.resolvingSymlinksInPath().path + "/"), fm.fileExists(atPath: candidate.path) { newPath = candidate.path }
                        }
                    }
                    // The databases were copied from a folder model-directed commands could write.
                    // Never leave Codex a rollout path outside its home: point it at a missing file
                    // inside instead, and Codex falls back to finding the rollout by thread ID.
                    let home = codexHome.resolvingSymlinksInPath().path + "/"
                    if newPath.split(separator: "/").contains("..")
                        || !URL(fileURLWithPath: newPath).resolvingSymlinksInPath().path.hasPrefix(home) {
                        newPath = codexHome.appendingPathComponent("sessions/unavailable-\(UUID().uuidString).jsonl").path
                    }
                    let oldCwd: String = row["cwd"]
                    var newCwd = oldCwd
                    if let range = oldCwd.range(of: "/workspace/", options: .backwards) {
                        let relative = String(oldCwd[range.upperBound...])
                        if !relative.split(separator: "/").contains("..") { newCwd = workspaceRoot.appendingPathComponent(relative).path }
                    }
                    if newPath != oldPath || newCwd != oldCwd {
                        try db.execute(sql: "UPDATE threads SET rollout_path = ?, cwd = ? WHERE id = ?", arguments: [newPath, newCwd, id])
                    }
                }
            }
        }
    }
    /// Preserve the source and already migrated files; refuse links into private host data.
    nonisolated private static func copyMissing(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else { return }
        if let existing = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]), existing.isSymbolicLink == true {
            throw CocoaError(.fileWriteNoPermission)
        }
        if values.isDirectory == true {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
                try copyMissing(from: file, to: destination.appendingPathComponent(file.lastPathComponent))
            }
        } else if !fm.fileExists(atPath: destination.path) {
            // Atomic writes make an interrupted migration safe to repeat.
            try Data(contentsOf: source).write(to: destination, options: .atomic)
        }
    }
}
nonisolated enum HyotanBootError: Error, LocalizedError {
    case bootFailed(String)
    var errorDescription: String? { "実行環境を起動できませんでした。" }
}
