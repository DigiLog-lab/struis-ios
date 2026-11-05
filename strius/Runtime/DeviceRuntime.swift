import Foundation
import OSLog

private let runtimeLog = Logger(subsystem: "com.digiloglab.strius", category: "device-runtime")

/// The on-device execution stack: the workspace and the command helper (Python, shell, rg in the Exec
/// extension). Created once in `striusApp`. The model itself is called over the network
/// (`ClaudeTurnRunner`), so nothing else runs on the device.
@Observable
@MainActor
final class DeviceRuntime {
    let boot: HyotanBoot

    /// The runtime boots at launch unless the process opts out (UI tests that never run a turn pass
    /// `STRUIS_DEVICE_RUNTIME=0`).
    nonisolated static var isEnabledAtLaunch: Bool {
        ProcessInfo.processInfo.environment["STRUIS_DEVICE_RUNTIME"] != "0"
    }

    init() {
        boot = HyotanBoot()
        // Start following the app lifecycle now, before any turn can be sent to the background (P4-3).
        _ = ActiveClock.shared
    }

    /// Prepare the workspace and register the command helper. Idempotent; the helper process itself
    /// starts with the first command.
    func start() async {
        await boot.start()
        guard boot.state.isReady else {
            if case .failed(let message) = boot.state { runtimeLog.error("runtime preparation failed: \(message, privacy: .public)") }
            return
        }
        await NativeRuntimeHost.shared.prepareForCommands()
    }

    var isReady: Bool { boot.state.isReady }
}
