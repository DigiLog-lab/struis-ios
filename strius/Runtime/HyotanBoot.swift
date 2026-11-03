import Foundation
import OSLog

private let bootLog = Logger(subsystem: "com.digiloglab.strius", category: "hyotan")

/// Prepares runtime data. The workspace stays in the app group for the Exec worker (Python, shell, rg).
/// The data of the retired in-app Codex runtime (ChatGPT credentials, rollouts, state databases) is
/// removed once: the app no longer reads it.
@Observable @MainActor final class HyotanBoot {
    enum State: Equatable {
        case idle, installing(Double), booting, ready, failed(String)
        var isReady: Bool { self == .ready }
    }
    private(set) var state: State = .idle
    private(set) var manifest: RootfsManifest?
    private(set) var installDuration: TimeInterval?
    private(set) var bootDuration: TimeInterval?
    let hyotanVersion = "native-2"
    private var startTask: Task<Void, Never>?
    nonisolated static let legacyRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("hyotan", isDirectory: true)
    nonisolated static var root: URL { NativeRuntimePaths.sharedRoot ?? legacyRoot.appendingPathComponent("native-unavailable") }
    nonisolated static var workspaceRoot: URL { root.appendingPathComponent("workspace", isDirectory: true) }
    /// The retired Codex home in the app's container and its former app-group location (`removeRetiredCodexData`).
    nonisolated static var retiredCodexHomes: [URL] {
        [FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StruisRuntime/codex", isDirectory: true),
         root.appendingPathComponent("codex", isDirectory: true)]
    }
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
                for directory in [Self.root, Self.workspaceRoot, Self.root.appendingPathComponent("home")] {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                }
                var root = Self.root
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try root.setResourceValues(values)
                try Self.migrateLegacyData(from: [Self.legacyRoot, Self.legacyRoot.deletingLastPathComponent().appendingPathComponent("agentcase")], to: Self.root)
                Self.removeRetiredCodexData(Self.retiredCodexHomes)
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
        let workspaceRoot = root.appendingPathComponent("workspace")
        let marker = root.appendingPathComponent("migration-v1-complete")
        guard !fm.fileExists(atPath: marker.path) else { return }
        for old in roots where fm.fileExists(atPath: old.path) {
            let workspaces = old.appendingPathComponent("workspace")
            if fm.fileExists(atPath: workspaces.path) { try copyMissing(from: workspaces, to: workspaceRoot) }
        }
        try Data("1".utf8).write(to: marker, options: .atomic)
    }

    /// The in-app Codex runtime was removed (2026-11-03): its home (ChatGPT credentials, conversation rollouts,
    /// state databases) is never read again. Conversations continue from the Ledger (`recent_thread_history.md`).
    nonisolated static func removeRetiredCodexData(_ homes: [URL]) {
        let fm: FileManager = FileManager.default
        for home in homes where fm.fileExists(atPath: home.path) {
            do {
                try fm.removeItem(at: home)
            } catch {
                bootLog.error("retired Codex data not removed: \(String(describing: error), privacy: .public)")
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
