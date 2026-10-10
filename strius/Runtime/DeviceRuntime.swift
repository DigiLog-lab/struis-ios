import Foundation
import OSLog

private let runtimeLog = Logger(subsystem: "com.digiloglab.strius", category: "device-runtime")

/// The on-device execution stack: native helper startup, the resident `codex app-server`
/// session, and the account runtime (design §2 "Runtime"). Created once in
/// `striusApp`; screens read its state to show the connection surface.
@Observable
@MainActor
final class DeviceRuntime {
    enum AppServerState: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    let boot: HyotanBoot
    let session: CodexAppServerSession
    let account: CodexAccountRuntime
    private(set) var appServerState: AppServerState = .stopped
    private(set) var initializeDuration: TimeInterval?
    private var startTask: Task<Void, Never>?

    /// The runtime boots at launch unless the process opts out (UI tests that never
    /// touch Codex pass `STRUIS_DEVICE_RUNTIME=0`).
    nonisolated static var isEnabledAtLaunch: Bool {
        ProcessInfo.processInfo.environment["STRUIS_DEVICE_RUNTIME"] != "0"
    }

    init() {
        let boot = HyotanBoot()
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
            + "+" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0")
        let session = CodexAppServerSession(clientVersion: version, launcher: CodexAppServerSession.nativeLauncher(boot: boot),
                                            serverOutlivesConnection: true)
        self.boot = boot
        self.session = session
        // Start following the app lifecycle now, before any turn can be sent to the background (P4-3).
        _ = ActiveClock.shared
        self.account = CodexAccountRuntime(session: session)
    }

    /// Boot the helper and start the app-server. Idempotent; later callers await the same work.
    func start() async {
        if appServerState == .running, await session.isRunning { return }
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { await performStart() }
        startTask = task
        await task.value
        startTask = nil
    }

    private func performStart() async {
        await boot.start()
        guard boot.state.isReady else {
            if case .failed(let message) = boot.state { appServerState = .failed(message) }
            return
        }
        #if DEBUG && targetEnvironment(simulator)
        await seedDebugCodexAuth()
        #endif
        appServerState = .starting
        let started = Date()
        do {
            try await session.start()
            initializeDuration = Date().timeIntervalSince(started)
            appServerState = .running
            runtimeLog.info("app-server initialized in \(self.initializeDuration ?? 0, privacy: .public)s")
        } catch {
            runtimeLog.error("app-server start failed: \(String(describing: error), privacy: .public)")
            appServerState = .failed(error.localizedDescription)
        }
    }

    /// Wait for a usable app-server, restarting it if the process has exited.
    func ensureRunning() async throws {
        await start()
        if await session.isRunning {
            appServerState = .running
            return
        }
        appServerState = .starting
        do {
            try await session.start()
            appServerState = .running
        } catch {
            appServerState = .failed(error.localizedDescription)
            throw error
        }
    }

    var isRunning: Bool { appServerState == .running }

    #if DEBUG && targetEnvironment(simulator)
    /// Simulator-only verification aid: `STRUIS_DEBUG_CODEX_AUTH_FILE=<host path>` places an
    /// existing Codex `auth.json` in the app's private Codex home before the app-server
    /// starts, so real turns can run without a browser device-code login. Never compiled for devices.
    private func seedDebugCodexAuth() async {
        guard let path = ProcessInfo.processInfo.environment["STRUIS_DEBUG_CODEX_AUTH_FILE"], !path.isEmpty else { return }
        do {
            let destination = HyotanBoot.codexHome.appendingPathComponent("auth.json")
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            runtimeLog.info("debug auth seeded in native runtime")
        } catch {
            runtimeLog.error("debug auth copy failed")
        }
    }
    #endif
}
