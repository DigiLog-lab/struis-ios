import Foundation

/// Only runtime data crosses XPC. Ledger and canonical memory stay in the host container.
nonisolated struct NativeRuntimeRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case start, command, interrupt, health, shutdown
        #if DEBUG && targetEnvironment(simulator)
        /// Trusted transport test only; never a model tool or production provider.
        case virtualPythonBridgeProbe
        case virtualPythonControl
        #endif
        var usesCommandWorker: Bool {
            switch self {
            case .command, .interrupt: return true
            #if DEBUG && targetEnvironment(simulator)
            case .virtualPythonBridgeProbe: return true
            case .virtualPythonControl: return true
            #endif
            default: return false
            }
        }
    }
    var operation: Operation
    var command: String? = nil
    var cwd: String? = nil
    var owner: String? = nil
    var workerID: String? = nil
    var privateBoundaryCanary: String? = nil
    /// The host's shared runtime directory. The Enhanced Security sandbox denies the worker
    /// `containermanagerd`, so the worker cannot look the app group up itself on a device.
    var sharedRoot: String? = nil
    /// `start` only: false for the command worker, which never runs Codex.
    var startsCodex: Bool? = nil
    #if DEBUG && targetEnvironment(simulator)
    /// Trusted test bootstrap only. Never supplied by model tool arguments.
    var operationHarnessTestRoot: String? = nil
    var virtualPythonJob: NativeVirtualPythonJob? = nil
    var virtualPythonControl: NativeVirtualPythonControl? = nil
    #endif
}
nonisolated struct NativeRuntimeReply: Codable, Sendable {
    var pid: Int32
    var workerID: String = ""
    var port: UInt16 = 0
    var token: String = ""
    var output: String = ""
    var exitCode: Int = 0
    var truncated: Bool = false
    var error: String? = nil
    /// Physical footprint and additional memory reported by this worker's OS.
    /// Missing measurements are not a zero-memory reading or an inferred limit.
    var memoryFootprintBytes: UInt64? = nil
    var availableMemoryBytes: UInt64? = nil
    /// Optional for compatibility with older replies. Numeric diagnostics only.
    var memoryObservation: NativeMemoryObservation? = nil
    /// Codex health only: latest panic source location (`file:line`) and panic count.
    var panicSite: String? = nil
    var panicCount: UInt32? = nil
    #if DEBUG && targetEnvironment(simulator)
    var virtualPython: NativeVirtualPythonReply? = nil
    /// Trusted native receipt: consumed one-shot signed Dash images require
    /// actual captured Exec process retirement before another command starts.
    var compoundDashWorkerSpent: Bool? = nil
    #endif
}
/// A self-measurement. identity is issued by the trusted process, not a model path.
nonisolated struct NativeMemoryObservation: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable { case host, codex, exec }
    let pid: Int32
    let identity: String
    let role: Role
    let monotonicNanoseconds: UInt64?
    let clockStatus: Int32
    let queryStatus: Int32
    let queryCount: UInt32
    let footprintBytes: UInt64?
    /// Genuine OS high-water across the process lifetime, including earlier phases.
    let lifetimePeakFootprintBytes: UInt64?
    let availableBytes: UInt64?

    init(snapshot: [String: NSNumber], identity: String, role: Role) {
        pid = snapshot["pid"]?.int32Value ?? 0
        self.identity = identity
        self.role = role
        monotonicNanoseconds = snapshot["monotonicNanoseconds"]?.uint64Value
        clockStatus = snapshot["clockStatus"]?.int32Value ?? -1
        queryStatus = snapshot["queryStatus"]?.int32Value ?? -1
        queryCount = snapshot["queryCount"]?.uint32Value ?? 0
        footprintBytes = snapshot["footprint"]?.uint64Value
        // Signed native ledger values must never wrap into a huge unsigned reading.
        lifetimePeakFootprintBytes = snapshot["lifetimePeak"].flatMap { $0.int64Value >= 0 ? $0.uint64Value : nil }
        availableBytes = snapshot["available"]?.uint64Value
    }

    func matches(reply: NativeRuntimeReply, identity: String, role: Role) -> Bool {
        reply.error == nil && pid > 0 && pid == reply.pid && self.identity == identity
            && reply.workerID == identity && self.role == role
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Trusted host correlation only; neither JS nor tool arguments create authority.
nonisolated struct NativeVirtualPythonJob: Codable, Sendable, Equatable {
    let id: UUID
    let owner: String
    let generation: UInt64
    // Trusted Debug Simulator test-only scheduler gate; never a model/JS field.
    var requirePreArmDiscovery: Bool = false
}
nonisolated struct NativeVirtualPythonControl: Codable, Sendable {
    enum Action: String, Codable, Sendable { case discover, exchange, finish, cancel, completion }
    var action: Action
    var job: NativeVirtualPythonJob
    var invocationID: UInt64 = 0
    var sequence: UInt64 = 0
    var stdout = Data()
    var stderr = Data()
    var stdinCapacity: Int = 16384
    var exitCode: Int32 = 0
}
nonisolated struct NativeVirtualPythonReply: Codable, Sendable {
    var invocationID: UInt64 = 0
    var sequence: UInt64 = 0
    var function: UInt32 = 0
    var argv: [Data] = []
    var stdin = Data()
    var stdinEOF = false
    var completed = false
    var exitCode: Int32 = 0
    var stdoutAccepted = 0
    var stderrAccepted = 0
    var stdoutCredit = 0
    var stderrCredit = 0
    var errorCode: Int32 = 0
}
#endif
nonisolated enum NativeRuntimePaths {
    static let group = "group.com.digiloglab.struis.runtime"
    static var sharedRoot: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Runtime", isDirectory: true)
    }

    /// Worker side: the root the host sent, only if it is this app group's `Runtime` directory.
    /// Without a host path it falls back to the lookup, which only works outside the device sandbox.
    static func workerRoot(hostPath: String?) -> URL? { try? resolveWorkerRoot(hostPath: hostPath) }

    /// Like `workerRoot`, but says which check failed (the reason reaches the host's error log).
    static func resolveWorkerRoot(hostPath: String?) throws -> URL {
        guard let hostPath else {
            guard let sharedRoot else { throw NativeRuntimeStartError("app group lookup unavailable and no host path") }
            return sharedRoot
        }
        // Resolve the real path from the opened directory itself. realpath walks every ancestor, and the
        // device sandbox does not let the worker look at /private/var/mobile/Containers/... O_NOFOLLOW
        // rejects a `Runtime` symlink that would lead elsewhere; F_GETPATH keeps `/private`.
        let fd = open(hostPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw NativeRuntimeStartError("cannot open host root \(hostPath) (errno \(errno))") }
        defer { close(fd) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { throw NativeRuntimeStartError("cannot resolve host root \(hostPath) (errno \(errno))") }
        let url = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
        let parts = url.pathComponents
        guard parts.count >= 5, parts.suffix(4).first == "Shared", parts.suffix(3).first == "AppGroup", parts.last == "Runtime"
        else { throw NativeRuntimeStartError("host root \(url.path) is not an app group Runtime directory") }
        let metadata = url.deletingLastPathComponent().appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        if let data = try? Data(contentsOf: metadata),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            guard plist["MCMMetadataIdentifier"] as? String == group else { throw NativeRuntimeStartError("host root belongs to another app group") }
            return url
        }
        // The device sandbox may hide the container metadata. Then accept only a container in the
        // system's own app group store, which no app can create directories in; the sandbox lets the
        // worker write only to the app groups in its entitlements (this one), so a writable one is ours.
        #if targetEnvironment(simulator)
        throw NativeRuntimeStartError("app group metadata unreadable")
        #else
        let store = "/private/var/mobile/Containers/Shared/AppGroup/"
        let container = url.deletingLastPathComponent()
        guard url.path.hasPrefix(store), container.deletingLastPathComponent().path + "/" == store,
              UUID(uuidString: container.lastPathComponent) != nil
        else { throw NativeRuntimeStartError("host root \(url.path) is outside the system app group store") }
        let probe = url.appendingPathComponent(".worker-root-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else { throw NativeRuntimeStartError("host root \(url.path) is not writable (errno \(errno))") }
        try? FileManager.default.removeItem(at: probe)
        return url
        #endif
    }
}

nonisolated struct NativeRuntimeStartError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
