import Foundation
import ExtensionFoundation
import XPC

extension AppExtensionPoint {
    @Definition static var struisRuntime: AppExtensionPoint {
        Name("Runtime")
        // Not EnhancedSecurity(): that sandbox denies the worker the app group it shares with the host
        // (open() returns EPERM on a device). The ordinary extension sandbox still keeps the host's
        // private container (Ledger, memory) out of reach; `start` verifies that on every device launch.
    }
}

@MainActor final class NativeRuntimeHost {
    static let shared = NativeRuntimeHost()
    private var process: AppExtensionProcess?
    private var workerID: String?
    private let hostMemoryIdentity = UUID().uuidString
    private var codexObservationLifetime: NativeMemoryProcessLifetime?
    private var keepAlive: XPCSession?
    private var keepAliveExit: NativeReplyWaiter?
    private var monitor: AppExtensionPoint.Monitor?
    private var epoch = UUID()
    private var inProcessEndpoint: (port: UInt16, token: String)?
    /// Set once per process; a start that failed afterwards (for example a port bind) retries
    /// without installing it again.
    private var workspaceCapabilityInstalled = false
    /// Owners stopped while no live command worker existed (for example during its launch).
    private var interruptedBeforeLaunch: Set<String> = []
    private var interruption: (@Sendable (Int32) -> Void)?
    private var retirement: Task<Void, Never>?
    private var execRetirement: Task<Void, Never>?
    /// The command worker runs Python and shell separately from Codex, with role-specific dependencies.
    /// Launched on the first command. Its physical footprint and available memory must be measured
    /// independently; separation does not remove the operating system's process memory limit.
    private var exec: (id: UUID, process: AppExtensionProcess, workerID: String, keepAlive: XPCSession, exit: NativeReplyWaiter, requests: NativeWorkerRequests)?
    private var execLaunch: (id: UUID, requests: NativeWorkerRequests, task: Task<(process: AppExtensionProcess, workerID: String, requests: NativeWorkerRequests?), Error>)?
    private var retiredExecWorkerID: String?
    private enum CommandLaunchError: Error, Equatable { case retiredWorker }
    /// Workers are embedded under the host identifier, which differs for Ad Hoc prototypes.
    nonisolated static let hostBundleID = Bundle.main.bundleIdentifier ?? "com.digiloglab.strius"
    nonisolated static let codexBundleID = "\(hostBundleID).runtime"
    nonisolated static let execBundleID = "\(hostBundleID).exec"
    #if DEBUG && targetEnvironment(simulator)
    struct VirtualPythonCommandHandle: Sendable {
        let job: NativeVirtualPythonJob
        let workerID: String
        fileprivate let id: UUID
    }
    private final class VirtualPythonJobState {
        let handle: VirtualPythonCommandHandle
        let process: AppExtensionProcess
        let requests: NativeWorkerRequests?
        var command: Task<NativeRuntimeReply, Error>?
        var watchdog: Task<Void, Never>?
        var done = false
        var commandAcknowledged = false
        var acknowledgedReply: NativeRuntimeReply?
        var cancelled = false
        var inFlight = false
        var armed = false
        var startupDeniedReads = 0
        init(handle: VirtualPythonCommandHandle, process: AppExtensionProcess, requests: NativeWorkerRequests?) {
            self.handle = handle; self.process = process; self.requests = requests
        }
    }
    private var virtualPythonJobs: [UUID: VirtualPythonJobState] = [:]
    private var virtualPythonGeneration: UInt64 = 0
    private var compoundDashRetirement: (process: AppExtensionProcess, requests: NativeWorkerRequests)?
    private struct VirtualPythonControlFault {
        let token: UUID
        let handleID: UUID
        let invocationID: UInt64
        let sequence: UInt64
        let requests: NativeWorkerRequests
        var dropped = false
        var released = false
    }
    private var virtualPythonControlFault: VirtualPythonControlFault?

    /// Trusted XCTest fault only: neither native messages nor guests can arm it.
    func armVirtualPythonControlAcknowledgementDropForTest(_ handle: VirtualPythonCommandHandle,
        invocationID: UInt64, sequence: UInt64) throws -> UUID {
        guard ProcessInfo.processInfo.environment["STRUIS_COMPOUND_DASH_PREPARATION"] == "1",
              virtualPythonControlFault == nil, invocationID != 0, sequence != 0,
              let state = virtualPythonJobs[handle.id], state.handle.job == handle.job,
              state.handle.workerID == handle.workerID, state.armed, !state.inFlight,
              !state.done, !state.cancelled, let requests = state.requests,
              let exec, exec.workerID == handle.workerID, exec.requests === requests,
              !requests.isTerminated, requests.holdProcessExitObservationForTest() else {
            throw CodexAppServerError.closed("provider fault fixture unavailable")
        }
        let token = UUID()
        virtualPythonControlFault = .init(token: token, handleID: handle.id,
            invocationID: invocationID, sequence: sequence, requests: requests)
        return token
    }

    func virtualPythonControlAcknowledgementWasDroppedForTest(_ token: UUID) -> Bool {
        guard let fault = virtualPythonControlFault, fault.token == token else { return false }
        return fault.dropped
    }

    func virtualPythonControlFaultJobRemovedForTest(_ token: UUID) -> Bool {
        guard let fault = virtualPythonControlFault, fault.token == token else { return false }
        return virtualPythonJobs[fault.handleID] == nil
    }

    func releaseVirtualPythonControlFaultObservationForTest(_ token: UUID) {
        guard var fault = virtualPythonControlFault, fault.token == token, !fault.released else { return }
        fault.requests.releaseProcessExitObservationForTest()
        fault.released = true
        virtualPythonControlFault = fault
    }

    func awaitVirtualPythonControlFaultExitForTest(_ token: UUID) async -> Bool {
        guard let fault = virtualPythonControlFault, fault.token == token, fault.released else { return false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !fault.requests.processExitObserved && ContinuousClock.now < deadline {
            await Self.providerCleanupPause()
        }
        return fault.requests.processExitObserved
    }

    func endVirtualPythonControlFaultForTest(_ token: UUID) {
        guard let fault = virtualPythonControlFault, fault.token == token else { return }
        fault.requests.releaseProcessExitObservationForTest()
        virtualPythonControlFault = nil
    }

    /// Trusted transport preparation only. No model or JS arguments select this path.
    func beginVirtualPythonTransportCommand(command: String, cwd: String, owner: String, requirePreArmDiscovery: Bool = false) async throws -> VirtualPythonCommandHandle {
        guard workerID != nil, virtualPythonJobs.isEmpty, virtualPythonGeneration < UInt64.max else {
            throw CodexAppServerError.closed("provider command unavailable")
        }
        let worker = try await commandWorker()
        guard virtualPythonJobs.isEmpty, exec?.workerID == worker.workerID,
              !(worker.requests?.isTerminated ?? true), !owner.isEmpty,
              owner.utf8.count < 256, !owner.utf8.contains(0) else {
            throw CodexAppServerError.closed("provider command busy or invalid")
        }
        virtualPythonGeneration += 1
        let job = NativeVirtualPythonJob(id: UUID(), owner: owner, generation: virtualPythonGeneration,
            requirePreArmDiscovery: requirePreArmDiscovery)
        let handle = VirtualPythonCommandHandle(job: job, workerID: worker.workerID, id: UUID())
        let state = VirtualPythonJobState(handle: handle, process: worker.process, requests: worker.requests)
        virtualPythonJobs[handle.id] = state
        var request = NativeRuntimeRequest(operation: .command, command: command, cwd: cwd, owner: owner,
            workerID: worker.workerID, sharedRoot: NativeRuntimePaths.sharedRoot?.path)
        request.virtualPythonJob = job
        let commandRequest = request
        state.command = Task { @MainActor in
            defer { state.done = true; state.watchdog?.cancel() }
            let reply = try await Self.send(commandRequest, to: state.process, requests: state.requests, validateReplyError: false)
            state.commandAcknowledged = true
            state.acknowledgedReply = reply
            if let error = reply.error { throw CodexAppServerError.closed(error) }
            return reply
        }
        state.watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !state.done else { return }
            await self.cancelVirtualPythonTransportCommand(handle)
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                if state.done {
                    // A known busy/error/finished command never armed this job.
                    // Its ACK is safe to surface without cancelling another owner.
                    if let command = state.command { _ = try await command.value }
                    throw CodexAppServerError.closed("provider command ended before startup")
                }
                let result = try await performVirtualPythonControl(.init(action: .discover,
                    job: job, stdinCapacity: 0), for: handle, startupReadOnly: true)
                print("NATIVE_PROVIDER_STARTUP errno=\(result.errorCode)")
                guard ContinuousClock.now < deadline else { throw CodexAppServerError.closed("provider startup timed out") }
                if result.errorCode == 0 || result.errorCode == EAGAIN {
                    state.armed = true
                    return handle // Positive ACK proved this exact job's identity.
                }
                guard result.errorCode == EACCES else {
                    throw CodexAppServerError.closed("provider startup rejected")
                }
                state.startupDeniedReads += 1
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CodexAppServerError.closed("provider startup timed out")
        } catch {
            if let reply = state.acknowledgedReply {
                // A known early/error ACK may still carry a consumed image
                // receipt. Preserve it even when the command task throws.
                defer { state.watchdog?.cancel(); state.command = nil; virtualPythonJobs[handle.id] = nil }
                try await retireSpentCompoundDashWorker(reply, workerID: handle.workerID,
                    requests: state.requests)
                throw error
            }
            if !(state.done && state.commandAcknowledged) {
                let cleanupConfirmed = await cancelVirtualPythonTransportCommand(handle)
                guard cleanupConfirmed else {
                    // Retain the sealed pending job; no replacement job may
                    // start until trusted stop/recovery confirms retirement.
                    throw CodexAppServerError.closed("provider startup cleanup unconfirmed")
                }
            }
            state.watchdog?.cancel(); state.command = nil; virtualPythonJobs[handle.id] = nil
            throw error
        }
    }

    func virtualPythonStartupDeniedReadCount(_ handle: VirtualPythonCommandHandle) -> Int {
        virtualPythonJobs[handle.id]?.startupDeniedReads ?? 0
    }

    /// Never launches/replaces Exec or rewrites a captured worker's identity.
    func virtualPythonControl(_ control: NativeVirtualPythonControl, for handle: VirtualPythonCommandHandle) async throws -> NativeVirtualPythonReply {
        try await performVirtualPythonControl(control, for: handle, startupReadOnly: false)
    }

    private func performVirtualPythonControl(_ control: NativeVirtualPythonControl, for handle: VirtualPythonCommandHandle, startupReadOnly: Bool) async throws -> NativeVirtualPythonReply {
        guard let state = virtualPythonJobs[handle.id], state.handle.job == handle.job,
              state.handle.workerID == handle.workerID, control.job == handle.job,
              let exec, exec.workerID == handle.workerID, !exec.requests.isTerminated,
              !state.cancelled, (!state.done || control.action == .completion), !state.inFlight,
              (state.armed || (startupReadOnly && control.action == .discover && control.sequence == 0 &&
                control.invocationID == 0 && control.stdout.isEmpty && control.stderr.isEmpty && control.stdinCapacity == 0)),
              control.stdout.count <= 16384, control.stderr.count <= 16384,
              control.stdinCapacity >= 0, control.stdinCapacity <= 16384 else {
            throw CodexAppServerError.closed("stale or invalid provider control")
        }
        state.inFlight = true
        defer { state.inFlight = false }
        var request = NativeRuntimeRequest(operation: .virtualPythonControl, workerID: handle.workerID,
            sharedRoot: NativeRuntimePaths.sharedRoot?.path)
        request.virtualPythonControl = control
        do {
            let reply = try await Self.send(request, to: state.process, requests: state.requests, controlTimeout: 2)
            guard self.exec?.workerID == handle.workerID,
                  let result = reply.virtualPython, result.sequence == control.sequence else {
                throw CodexAppServerError.closed("provider acknowledgement invalid")
            }
            guard !state.cancelled else { throw CodexAppServerError.interrupted }
            if var fault = virtualPythonControlFault, !fault.dropped, !fault.released,
               fault.handleID == handle.id, fault.requests === state.requests,
               control.action == .exchange, control.invocationID == fault.invocationID,
               control.sequence == fault.sequence, result.errorCode == 0 {
                // Self.send actually returned the real provider's ACK. Drop
                // exactly this result through the production unknown-ACK catch;
                // do not retry a control whose bytes may already be consumed.
                fault.dropped = true
                virtualPythonControlFault = fault
                throw CodexAppServerError.closed("provider acknowledgement unavailable")
            }
            if control.action == .cancel, result.errorCode == 0 {
                state.cancelled = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, !state.done, self.exec?.workerID == handle.workerID else { return }
                    self.retireCommandWorker()
                }
            }
            return result
        } catch {
            if state.cancelled { throw error } // The cancelling path owns cleanup/retirement.
            // Unknown acknowledgement is never retried: bytes might already
            // have been removed/accepted. Retire only the captured worker.
            state.cancelled = true
            if self.exec?.workerID == handle.workerID { retireCommandWorker() }
            throw error
        }
    }

    /// Final native exit is available only after this exact invocation's
    /// Await + Destroy, independently of later commands in the same dash job.
    func awaitVirtualPythonInvocationCompletion(_ invocationID: UInt64, for handle: VirtualPythonCommandHandle) async throws -> Int32 {
        guard invocationID != 0 else { throw CodexAppServerError.closed("invalid provider invocation") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let result = try await virtualPythonControl(.init(action: .completion, job: handle.job,
                invocationID: invocationID, stdinCapacity: 0), for: handle)
            if result.errorCode == 0, result.completed, result.invocationID == invocationID { return result.exitCode }
            guard result.errorCode == EAGAIN else { throw CodexAppServerError.closed("provider cleanup unconfirmed") }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = await cancelVirtualPythonTransportCommand(handle)
        throw CodexAppServerError.closed("provider cleanup timed out")
    }

    func finishVirtualPythonTransportCommand(_ handle: VirtualPythonCommandHandle) async throws -> NativeRuntimeReply {
        guard let state = virtualPythonJobs[handle.id], state.handle.job == handle.job,
              let command = state.command else { throw CodexAppServerError.closed("stale provider job") }
        defer { state.watchdog?.cancel(); state.watchdog = nil; state.command = nil; virtualPythonJobs[handle.id] = nil }
        let reply: NativeRuntimeReply
        do { reply = try await command.value }
        catch {
            if let acknowledged = state.acknowledgedReply {
                try await retireSpentCompoundDashWorker(acknowledged, workerID: handle.workerID,
                    requests: state.requests)
            } else if exec?.workerID == handle.workerID { retireCommandWorker() }
            throw error
        }
        try await retireSpentCompoundDashWorker(reply, workerID: handle.workerID,
            requests: state.requests)
        return reply
    }

    // A caller cancellation must not turn cleanup polling into a busy loop.
    private nonisolated static func providerCleanupPause() async {
        await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
    }

    /// Called after the command ACK and all provider invocation controls have
    /// been consumed. The command is never replayed, even if retirement fails.
    private func retireSpentCompoundDashWorker(_ reply: NativeRuntimeReply,
        workerID: String, requests: NativeWorkerRequests?) async throws {
        guard reply.compoundDashWorkerSpent == true else { return }
        guard reply.workerID == workerID, let requests else {
            throw CodexAppServerError.closed("compound command retirement identity mismatch")
        }
        if requests.processExitObserved {
            if compoundDashRetirement?.requests === requests { compoundDashRetirement = nil }
            return
        }
        guard let captured = exec, captured.workerID == workerID,
              captured.requests === requests,
              compoundDashRetirement.map({ $0.requests === requests }) ?? true else {
            throw CodexAppServerError.closed("compound command retirement identity mismatch")
        }
        // Keep the physical process alive as an observable object even after
        // the shutdown task releases its capture. A late interruption callback
        // must remain available to open this exact generation's gate.
        compoundDashRetirement = (captured.process, requests)
        retireCommandWorker()
        await execRetirement?.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !requests.processExitObserved && ContinuousClock.now < deadline {
            await Self.providerCleanupPause()
        }
        guard requests.processExitObserved else {
            // Keep the captured gate: scheduling invalidation or cancelling an
            // XPC session alone does not permit another process generation.
            throw CodexAppServerError.closed("compound command process exit unconfirmed")
        }
        if compoundDashRetirement?.requests === requests { compoundDashRetirement = nil }
    }

    /// The in-process Codex starts at once, so a command can follow a spent worker's retirement
    /// before its exit callback arrives (the extension launch used to take that long). Wait for
    /// the actual exit briefly; without it, no replacement starts.
    private func awaitObservedCommandRetirement() async throws {
        if let captured = compoundDashRetirement {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !captured.requests.processExitObserved && ContinuousClock.now < deadline {
                await Self.providerCleanupPause()
            }
        }
        try requireObservedCommandRetirement()
    }

    private func requireObservedCommandRetirement() throws {
        if let captured = compoundDashRetirement {
            guard captured.requests.processExitObserved else {
                throw CodexAppServerError.closed("compound command process exit unconfirmed")
            }
            compoundDashRetirement = nil
        }
    }

    /// True means a native command ACK after cleanup, or the captured process's
    /// actual interruption callback. Scheduling retirement alone is not proof.
    @discardableResult
    func cancelVirtualPythonTransportCommand(_ handle: VirtualPythonCommandHandle) async -> Bool {
        guard let state = virtualPythonJobs[handle.id], state.handle.job == handle.job,
              state.handle.workerID == handle.workerID else { return false }
        state.cancelled = true
        if state.done && state.commandAcknowledged { return true }
        if exec?.workerID == handle.workerID {
            var request = NativeRuntimeRequest(operation: .interrupt, owner: handle.job.owner,
                workerID: handle.workerID, sharedRoot: NativeRuntimePaths.sharedRoot?.path)
            request.virtualPythonJob = handle.job
            do { _ = try await Self.send(request, to: state.process, requests: state.requests, controlTimeout: 2) }
            catch {
                if !state.commandAcknowledged, exec?.workerID == handle.workerID { retireCommandWorker() }
            }
        }
        // The worker first cancels C shuttles and has its own 3s owner watchdog.
        // Host fallback never targets a subsequently launched replacement.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(state.done && state.commandAcknowledged) && state.requests?.processExitObserved != true && ContinuousClock.now < deadline {
            await Self.providerCleanupPause()
        }
        if state.done && state.commandAcknowledged || state.requests?.processExitObserved == true { return true }
        if exec?.workerID == handle.workerID { retireCommandWorker() }
        let retirementDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while state.requests?.processExitObserved != true && ContinuousClock.now < retirementDeadline {
            await Self.providerCleanupPause()
        }
        return state.requests?.processExitObserved == true
    }
    #endif

    /// Codex runs in this process. In the extension its ~37 MB limit ended PDF turns, and its
    /// app-group CODEX_HOME got the suspended extension killed (0xDEAD10CC). Model file tools reach
    /// files only through the workspace capability installed before the server starts; Python and
    /// shell commands stay in the Exec worker. The server starts once per app process: "starting"
    /// again opens a new connection to it, and a stopped server needs an app relaunch.
    func start(onExit: @escaping @Sendable (Int32) -> Void) async throws -> (NativeRuntimeReply, UUID) {
        stop()
        await retirement?.value
        await execRetirement?.value
        if inProcessEndpoint == nil {
            // Rows are rewritten only before the server opens the database.
            try await Task.detached {
                try FileManager.default.createDirectory(at: HyotanBoot.codexHome, withIntermediateDirectories: true)
                try HyotanBoot.rebaseCodexState()
            }.value
        }
        let epoch = UUID()
        self.epoch = epoch
        codexObservationLifetime = NativeMemoryProcessLifetime()
        interruption = onExit
        do {
            let endpoint = try startInProcessCodex()
            let workerID = UUID().uuidString
            self.workerID = workerID
            var reply = inProcessHealth(workerID: workerID)
            // A recorded failure means the server stopped; it cannot start again in this process.
            if reply.error != nil { throw CodexAppServerError.closed(CodexAppServerError.inProcessStoppedDetail) }
            reply.port = endpoint.port
            reply.token = endpoint.token
            return (reply, epoch)
        } catch {
            stop(ifEpoch: epoch)
            throw error
        }
    }

    private func startInProcessCodex() throws -> (port: UInt16, token: String) {
        if let endpoint = inProcessEndpoint {
            guard Self.inProcessFailure() == nil else {
                throw CodexAppServerError.closed(CodexAppServerError.inProcessStoppedDetail)
            }
            return endpoint
        }
        let fm = FileManager.default
        let home = HyotanBoot.codexHome
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        guard let certificate = Bundle.main.url(forResource: "cacert", withExtension: "pem") else {
            throw CodexAppServerError.closed("cacert.pem missing from the app bundle")
        }
        // Read by Codex (find_codex_home, rustls) only; set once before its threads start.
        setenv("CODEX_HOME", home.path, 1)
        setenv("SSL_CERT_FILE", certificate.path, 1)
        let token = UUID().uuidString + UUID().uuidString
        let tokenFile = home.appendingPathComponent("transport-token")
        try Data(token.utf8).write(to: tokenFile, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        // The same spelling the turns use as cwd: the capability compares paths lexically.
        if !workspaceCapabilityInstalled {
            let workspace = HyotanBoot.workspaceRoot
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
            let descriptor = open(workspace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw CodexAppServerError.closed("workspace root unavailable") }
            defer { close(descriptor) }
            let installed = workspace.path.withCString { path in
                hostMemoryIdentity.withCString { owner in hyotan_codex_install_operation_harness(descriptor, path, owner, 1) }
            }
            guard installed == 0 else { throw CodexAppServerError.closed("workspace capability installation failed \(installed)") }
            workspaceCapabilityInstalled = true
        }
        let status = tokenFile.path.withCString { hyotan_codex_start(0, $0) }
        // 114: already started once in this process; 11: its thread could not be created.
        if status == 114 || status == 11 { throw CodexAppServerError.closed(CodexAppServerError.inProcessStoppedDetail) }
        guard status == 0 else { throw CodexAppServerError.closed("native start \(status)") }
        let port = hyotan_codex_port()
        guard port != 0 else { throw CodexAppServerError.closed("native listener port missing") }
        inProcessEndpoint = (port, token)
        return (port, token)
    }

    /// Moves the running server to a new loopback listener and returns its port. iOS reclaims
    /// a suspended app's listening socket; the server keeps running but refuses connections.
    func rebindInProcessListener() -> UInt16? {
        guard let endpoint = inProcessEndpoint, Self.inProcessFailure() == nil else { return nil }
        let port = hyotan_codex_rebind()
        guard port != 0 else { return nil }
        inProcessEndpoint = (port, endpoint.token)
        return port
    }

    /// The Codex server's recorded stop or startup failure, if any.
    private nonisolated static func inProcessFailure() -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        return hyotan_codex_error(&buffer, buffer.count) == 0 ? nil : String(cString: buffer)
    }

    /// The same reply the Codex worker's health request used to return, measured in this process.
    private func inProcessHealth(workerID: String) -> NativeRuntimeReply {
        var reply = NativeRuntimeReply(pid: getpid(), workerID: workerID, error: Self.inProcessFailure())
        var site = [CChar](repeating: 0, count: 512)
        if hyotan_codex_panic_site(&site, site.count) > 0 { reply.panicSite = String(cString: site) }
        reply.panicCount = hyotan_codex_panic_count()
        if reply.error == nil {
            let memory = StruisMemorySnapshot()
            reply.memoryFootprintBytes = memory["footprint"]?.uint64Value
            reply.availableMemoryBytes = memory["available"]?.uint64Value
            reply.memoryObservation = NativeMemoryObservation(snapshot: memory, identity: workerID, role: .codex)
        }
        return reply
    }

    func send(_ request: NativeRuntimeRequest) async throws -> NativeRuntimeReply {
        #if DEBUG && targetEnvironment(simulator)
        guard request.operation != .virtualPythonControl, request.virtualPythonJob == nil else {
            throw CodexAppServerError.closed("provider requests require a pinned trusted job")
        }
        #endif
        guard let workerID else { throw CodexAppServerError.notRunning }
        if request.operation.usesCommandWorker {
            if request.operation == .interrupt, exec == nil || exec?.requests.isTerminated == true {
                // A command may be waiting for the worker launch; it must not run afterwards.
                if let owner = request.owner { interruptedBeforeLaunch.insert(owner) }
                return NativeRuntimeReply(pid: 0)
            }
            let worker = try await commandWorker()
            if request.operation == .command, let owner = request.owner,
               interruptedBeforeLaunch.remove(owner) != nil {
                throw CodexAppServerError.interrupted
            }
            var request = request
            request.workerID = worker.workerID
            request.sharedRoot = NativeRuntimePaths.sharedRoot?.path
            #if DEBUG && targetEnvironment(simulator)
            let reply: NativeRuntimeReply
            do {
                reply = try await Self.send(request, to: worker.process, requests: worker.requests,
                    validateReplyError: false)
            } catch {
                if let captured = exec, captured.workerID == worker.workerID,
                   captured.requests === worker.requests { retireCommandWorker() }
                throw error
            }
            if request.operation == .command {
                try await retireSpentCompoundDashWorker(reply, workerID: worker.workerID,
                    requests: worker.requests)
            }
            if let error = reply.error { throw CodexAppServerError.closed(error) }
            #else
            let reply = try await Self.send(request, to: worker.process, requests: worker.requests)
            #endif
            return reply
        }
        guard request.workerID == nil || request.workerID == workerID else {
            throw CodexAppServerError.closed("stale worker request")
        }
        switch request.operation {
        case .health:
            let reply = inProcessHealth(workerID: workerID)
            if let error = reply.error { throw CodexAppServerError.closed(error) }
            return reply
        case .shutdown:
            throw CodexAppServerError.closed("in-process Codex is not shut down by request")
        default:
            throw CodexAppServerError.closed("unsupported Codex request")
        }
    }

    /// Whether a launcher's connection still belongs to the current start.
    func isCurrent(epoch expected: UUID) -> Bool { epoch == expected }

    /// Host self-measurement; this imports only the OS diagnostics helper.
    func hostMemoryObservation() -> NativeMemoryObservation {
        NativeMemoryObservation(snapshot: StruisMemorySnapshot(), identity: hostMemoryIdentity, role: .host)
    }

    /// Capture an existing Codex process. A delayed response cannot belong to its replacement.
    func codexWorkerHealth() async throws -> NativeRuntimeReply {
        guard let workerID, let lifetime = codexObservationLifetime,
              lifetime.allowsSampling else { throw CodexAppServerError.notRunning }
        let reply = inProcessHealth(workerID: workerID)
        guard lifetime.accepts(reply, identity: workerID, role: .codex) else {
            throw CodexAppServerError.closed("stale or unidentified Codex memory observation")
        }
        return reply
    }

    /// After the Codex WebSocket fails: does the captured worker still answer, and did its
    /// server stop or panic? Allowlisted labels, numbers and a sanitized source location only.
    func codexFailureProbe(epoch expected: UUID) async -> String {
        guard epoch == expected, let workerID else { return " probe=no_worker" }
        return Self.failureProbeSummary(inProcessHealth(workerID: workerID)) + " in_process=1"
    }

    nonisolated static func failureProbeSummary(_ reply: NativeRuntimeReply) -> String {
        let server = switch reply.error {
        case nil: "running"
        case .some("Codex server panicked"): "panicked"
        case .some("Codex server stopped"): "stopped"
        default: "failed"
        }
        var summary = " probe=worker_alive server=\(server)"
        if let count = reply.panicCount { summary += " panics=\(count)" }
        if let site = reply.panicSite.flatMap(safePanicSite) { summary += " panic_site=\(site)" }
        if let bytes = reply.memoryFootprintBytes { summary += " probe_footprint_bytes=\(bytes)" }
        if let bytes = reply.availableMemoryBytes { summary += " probe_available_bytes=\(bytes)" }
        return summary
    }

    /// A Rust source location reduced to `crate/src/…/file.rs:line` (the components from the
    /// directory containing the last `src`), or the file name alone. Build-machine directories
    /// such as a home or registry path are dropped. Nil unless every kept part is plain ASCII.
    nonisolated static func safePanicSite(_ site: String) -> String? {
        let parts = site.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let line = UInt32(parts[1]) else { return nil }
        let components = Array(parts[0].split(separator: "/"))
        var kept = components.suffix(1)
        if let source = components.lastIndex(of: "src"), source > 0 { kept = components[(source - 1)...] }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard !kept.isEmpty, kept.count <= 6,
              kept.allSatisfy({ $0.count <= 64 && $0.allSatisfy(allowed.contains) && $0 != ".." && $0 != "." })
        else { return nil }
        return kept.joined(separator: "/") + ":\(line)"
    }

    /// Observe the captured command worker without launching or replacing it.
    func commandWorkerHealth() async throws -> NativeRuntimeReply {
        guard let exec, !exec.requests.isTerminated else { throw CodexAppServerError.notRunning }
        let reply = try await Self.send(NativeRuntimeRequest(operation: .health, workerID: exec.workerID,
            sharedRoot: NativeRuntimePaths.sharedRoot?.path), to: exec.process, requests: exec.requests)
        guard self.exec?.id == exec.id, !exec.requests.isTerminated,
              reply.memoryObservation?.matches(reply: reply, identity: exec.workerID, role: .exec) == true else {
            throw CodexAppServerError.closed("stale or unidentified Exec memory observation")
        }
        return reply
    }

    /// The command worker, launched on first use. Commands require the separate Exec extension.
    private func commandWorker() async throws -> (process: AppExtensionProcess, workerID: String, requests: NativeWorkerRequests?) {
        let requestedEpoch = epoch
        await execRetirement?.value
        try Task.checkCancellation()
        guard epoch == requestedEpoch else { throw CodexAppServerError.notRunning }
        #if DEBUG && targetEnvironment(simulator)
        try await awaitObservedCommandRetirement()
        #endif
        if let exec {
            if !exec.requests.isTerminated { return (exec.process, exec.workerID, exec.requests) }
            retireCommandWorker()
            await execRetirement?.value
            try Task.checkCancellation()
            guard epoch == requestedEpoch else { throw CodexAppServerError.notRunning }
            #if DEBUG && targetEnvironment(simulator)
            try await awaitObservedCommandRetirement()
            #endif
        }
        if let execLaunch { return try await execLaunch.task.value }
        let launchID = UUID()
        let launchEpoch = epoch
        let initialRequests = NativeWorkerRequests()
        let launch = Task { @MainActor [weak self] () throws -> (process: AppExtensionProcess, workerID: String, requests: NativeWorkerRequests?) in
            guard let self else { throw CodexAppServerError.notRunning }
            let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .struisRuntime)
            try Task.checkCancellation()
            guard self.epoch == launchEpoch else { throw CodexAppServerError.notRunning }
            guard let identity = monitor.identities.first(where: { $0.bundleIdentifier == Self.execBundleID }) else {
                throw CodexAppServerError.closed("Exec runtime extension missing")
            }
            for attempt in 0..<5 {
                let requests = attempt == 0 ? initialRequests : NativeWorkerRequests()
                if let context = self.execLaunch, context.id == launchID {
                    self.execLaunch = (context.id, requests, context.task)
                }
                try Task.checkCancellation()
                guard self.epoch == launchEpoch else { throw CodexAppServerError.notRunning }
                do {
                    let id = UUID()
                    let exit = NativeReplyWaiter()
                    let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity, onInterruption: { [weak self] in
                        #if DEBUG && targetEnvironment(simulator)
                        requests.markProcessExitObserved()
                        #endif
                        exit.finish(.success(NativeRuntimeReply(pid: 0)))
                        // A terminated process may never invoke a per-request XPC callback. Release
                        // its waiters directly, including a request registered after this notification.
                        requests.finishAll(CodexAppServerError.closed("command worker interrupted"), processInterrupted: true)
                        // A command worker that exits (for example after a stuck command is stopped) is
                        // replaced on the next command; Codex keeps running.
                        Task { @MainActor in
                            guard let self, let stopped = self.exec, stopped.id == id else { return }
                            // Publication may be held by the trusted regression;
                            // use the same sealing path before dropping ownership.
                            self.retireCommandWorker()
                        }
                    }))
                    var installed = false
                    var launchSession: XPCSession?
                    defer {
                        if !installed {
                            requests.finishAll(CodexAppServerError.closed("command worker launch failed"))
                            launchSession?.cancel(reason: "Command worker launch failed")
                            process.invalidate()
                        }
                    }
                    try Task.checkCancellation()
                    guard self.epoch == launchEpoch else { throw CodexAppServerError.notRunning }
                    let keepAlive = try process.makeXPCSession()
                    launchSession = keepAlive
                    keepAlive.setCancellationHandler { error in
                        requests.finishAll(error, processInterrupted: true)
                        exit.finish(.failure(error))
                    }
                    try keepAlive.activate()
                    let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                        .appendingPathComponent("Struis", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let canary = directory.appendingPathComponent(".runtime-boundary-" + UUID().uuidString)
                    try Data(UUID().uuidString.utf8).write(to: canary, options: .atomic)
                    defer { try? FileManager.default.removeItem(at: canary) }
                    var start = NativeRuntimeRequest(operation: .start)
                    start.privateBoundaryCanary = canary.resolvingSymlinksInPath().path
                    start.sharedRoot = NativeRuntimePaths.sharedRoot?.path
                    start.startsCodex = false
                    let reply: NativeRuntimeReply
                    reply = try await Self.send(start, to: process, requests: requests)
                    try Task.checkCancellation()
                    guard self.epoch == launchEpoch, !requests.isTerminated else { throw CodexAppServerError.notRunning }
                    guard reply.workerID != self.retiredExecWorkerID else { throw CommandLaunchError.retiredWorker }
                    self.exec = (id, process, reply.workerID, keepAlive, exit, requests)
                    installed = true
                    print("NATIVE_COMMAND_WORKER_READY attempt=\(attempt + 1) pid=\(reply.pid)")
                    return (process, reply.workerID, requests)
                } catch {
                    try Task.checkCancellation()
                    let reusedRetiredWorker = (error as? CommandLaunchError) == .retiredWorker
                    guard self.epoch == launchEpoch, requests.wasProcessInterrupted || reusedRetiredWorker, attempt < 4 else { throw error }
                    // ExtensionKit can briefly return the endpoint of the just-terminated
                    // process. Retry its startup only, before a learner command is sent.
                    print("NATIVE_COMMAND_LAUNCH_RETRY attempt=\(attempt + 1)")
                    try await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
                }
            }
            throw CodexAppServerError.notRunning
        }
        execLaunch = (launchID, initialRequests, launch)
        defer { if execLaunch?.id == launchID { execLaunch = nil } }
        return try await launch.value
    }

    private func retireCommandWorker() {
        guard let exec else { return }
        #if DEBUG && targetEnvironment(simulator)
        // Seal before failing command waiters: a lost ACK may hide the spent
        // receipt and its finish path may remove the provider job immediately.
        // Retain the captured process independently of those job lifetimes.
        if !exec.requests.processExitObserved {
            compoundDashRetirement = (exec.process, exec.requests)
        }
        for state in virtualPythonJobs.values where state.handle.workerID == exec.workerID {
            state.cancelled = true
        }
        #endif
        retiredExecWorkerID = exec.workerID
        self.exec = nil
        let old = exec
        old.requests.finishAll(CodexAppServerError.closed("command worker stopped"))
        execRetirement = Task {
            do {
                try old.keepAlive.send(NativeRuntimeRequest(operation: .shutdown, workerID: old.workerID)) { (result: Result<NativeRuntimeReply, Error>) in old.exit.finish(result) }
            } catch { old.exit.finish(.failure(error)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                old.exit.finish(.failure(CodexAppServerError.timeout("native command shutdown")))
            }
            _ = try? await old.exit.value()
            old.keepAlive.cancel(reason: "Runtime stopped")
            old.process.invalidate()
            print("NATIVE_COMMAND_WORKER_RETIRED")
        }
    }

    private static func send(_ request: NativeRuntimeRequest, to process: AppExtensionProcess, requests: NativeWorkerRequests? = nil, controlTimeout: Double? = nil, validateReplyError: Bool = true) async throws -> NativeRuntimeReply {
        // Each command and control operation gets its own queue and cancellation callback.
        let pending = NativeReplyWaiter()
        let requestID = UUID()
        if let requests, !requests.register(pending, id: requestID) {
            return try await pending.value()
        }
        defer { requests?.remove(id: requestID) }
        let connection: XPCSession
        do { connection = try process.makeXPCSession() }
        catch {
            requests?.finishAll(error, processInterrupted: true)
            throw error
        }
        let complete: @Sendable (Result<NativeRuntimeReply, Error>) -> Void = { result in
            if case .failure(let error) = result, error is XPCRichError {
                pending.finish(result, beforeCompletion: {
                    if requests != nil { print("NATIVE_COMMAND_XPC_FAILURE") }
                    requests?.finishAll(error, processInterrupted: true)
                })
            } else { pending.finish(result) }
        }
        connection.setCancellationHandler { error in complete(.failure(error)) }
        defer { connection.cancel(reason: "Request complete") }
        do { try connection.activate() }
        catch {
            pending.finish(.failure(error), beforeCompletion: {
                requests?.finishAll(error, processInterrupted: true)
            })
            return try await pending.value()
        }
        if request.operation != .command {
            let delay: Double = controlTimeout ?? (request.operation == .shutdown ? 3 : 20)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                pending.finish(.failure(CodexAppServerError.timeout("native control")))
            }
        }
        do {
            try connection.send(request) { (result: Result<NativeRuntimeReply, Error>) in complete(result) }
        } catch { complete(.failure(error)) }
        let reply = try await pending.value()
        if validateReplyError, let error = reply.error { throw CodexAppServerError.closed(error) }
        return reply
    }

    func stop(ifEpoch expected: UUID? = nil) {
        if let expected, expected != epoch { return }
        // Requested retirement invalidates sampling, but is not a process-exit receipt.
        codexObservationLifetime?.requestRetirement()
        codexObservationLifetime = nil
        epoch = UUID()
        #if DEBUG && targetEnvironment(simulator)
        for state in virtualPythonJobs.values { state.cancelled = true; state.watchdog?.cancel() }
        virtualPythonJobs.removeAll()
        #endif
        interruption = nil
        interruptedBeforeLaunch.removeAll()
        if let launch = execLaunch {
            execLaunch = nil
            launch.requests.finishAll(CodexAppServerError.closed("command worker stopped during launch"))
            launch.task.cancel()
        }
        retireCommandWorker()
        let oldProcess = process
        let oldWorkerID = workerID
        workerID = nil
        let oldKeepAlive = keepAlive
        let oldExit = keepAliveExit
        keepAlive = nil
        keepAliveExit = nil
        process = nil
        monitor = nil
        guard let oldProcess else { oldKeepAlive?.cancel(reason: "Runtime stopped"); return }
        retirement = Task {
            // Never open a new session to retire an old process: ExtensionKit can
            // reconnect that session to a replacement and deliver stale shutdown there.
            if let oldKeepAlive, let oldExit, let oldWorkerID {
                do {
                    try oldKeepAlive.send(NativeRuntimeRequest(operation: .shutdown, workerID: oldWorkerID)) { (result: Result<NativeRuntimeReply, Error>) in oldExit.finish(result) }
                } catch { oldExit.finish(.failure(error)) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    oldExit.finish(.failure(CodexAppServerError.timeout("native shutdown")))
                }
                _ = try? await oldExit.value()
            }
            oldKeepAlive?.cancel(reason: "Runtime stopped")
            oldProcess.invalidate()
        }
    }

    func waitForRetirement() async {
        await retirement?.value
        await execRetirement?.value
    }
}

/// One monotonic observation seal per captured Codex instance. Callback publication
/// is synchronous and independent of MainActor continuation scheduling. A requested
/// shutdown/cancel is not evidence that the process has actually exited.
nonisolated final class NativeMemoryProcessLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var retirementRequested = false
    private var processInterrupted = false
    private var keepAliveCancelled = false

    var allowsSampling: Bool {
        lock.withLock { !retirementRequested && !processInterrupted && !keepAliveCancelled }
    }
    var observedProcessInterruption: Bool { lock.withLock { processInterrupted } }
    var observedKeepAliveCancellation: Bool { lock.withLock { keepAliveCancelled } }

    func requestRetirement() { lock.withLock { retirementRequested = true } }
    func observeProcessInterruption() { lock.withLock { processInterrupted = true } }
    func observeKeepAliveCancellation() { lock.withLock { keepAliveCancelled = true } }

    /// Acceptance linearizes under the same lock as terminal publication.
    func accepts(_ reply: NativeRuntimeReply, identity: String, role: NativeMemoryObservation.Role) -> Bool {
        lock.withLock {
            !retirementRequested && !processInterrupted && !keepAliveCancelled
                && reply.memoryObservation?.matches(reply: reply, identity: identity, role: role) == true
        }
    }
}

/// Waiters belong to one process generation, never to its replacement. Late replies and
/// interruption race through NativeReplyWaiter's single-completion gate.
nonisolated private final class NativeWorkerRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: NativeReplyWaiter] = [:]
    private var terminalError: Error?
    private var processInterrupted = false
    #if DEBUG && targetEnvironment(simulator)
    private var observedProcessExit = false
    private var holdProcessExitObservation = false
    private var actualProcessExitDeferred = false
    var processExitObserved: Bool {
        lock.lock(); defer { lock.unlock() }; return observedProcessExit
    }
    func markProcessExitObserved() {
        lock.lock(); defer { lock.unlock() }
        // Only the captured AppExtensionProcess interruption callback calls
        // this function. Holding publication never manufactures an exit.
        if holdProcessExitObservation { actualProcessExitDeferred = true }
        else { observedProcessExit = true }
    }
    func holdProcessExitObservationForTest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !holdProcessExitObservation, !observedProcessExit else { return false }
        holdProcessExitObservation = true
        return true
    }
    func releaseProcessExitObservationForTest() {
        lock.lock(); defer { lock.unlock() }
        guard holdProcessExitObservation else { return }
        holdProcessExitObservation = false
        if actualProcessExitDeferred {
            observedProcessExit = true
            actualProcessExitDeferred = false
        }
    }
    #endif

    var isTerminated: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminalError != nil
    }

    var wasProcessInterrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return processInterrupted
    }

    func register(_ waiter: NativeReplyWaiter, id: UUID) -> Bool {
        lock.lock()
        if let terminalError {
            lock.unlock()
            waiter.finish(.failure(terminalError))
            return false
        } else {
            pending[id] = waiter
            lock.unlock()
            return true
        }
    }

    func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        pending.removeValue(forKey: id)
    }

    func finishAll(_ error: Error, processInterrupted: Bool = false) {
        lock.lock()
        if terminalError == nil {
            terminalError = error
            self.processInterrupted = processInterrupted
        }
        let waiters = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.finish(.failure(error)) }
    }
}

/// XPC can cancel a session without invoking its outstanding reply callback.
/// Whichever arrives first completes the waiter; late callbacks cannot resume it twice.
nonisolated private final class NativeReplyWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<NativeRuntimeReply, Error>?
    private var finished = false
    private var continuation: CheckedContinuation<NativeRuntimeReply, Error>?

    func finish(_ result: Result<NativeRuntimeReply, Error>, beforeCompletion: (@Sendable () -> Void)? = nil) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        // Seal the captured generation before either an existing or a late waiter
        // can observe this result. Run outside the lock: sealing also finishes
        // sibling requests, including this already-claimed waiter.
        beforeCompletion?()
        lock.lock()
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func value() async throws -> NativeRuntimeReply {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { self.continuation = continuation; lock.unlock() }
        }
    }
}

/// One exit owner for both extension interruption and WebSocket failure. It exists
/// before the worker starts, so startup failures participate in the same arbitration.
nonisolated final class NativeRuntimeExit: @unchecked Sendable {
    private let lock = NSLock()
    private var diagnostic: String?
    private var socket: URLSessionWebSocketTask?
    private var lastReceivedBytes = 0
    private var cleanup: (@Sendable () -> Void)?
    private let onExit: @Sendable (Int32) -> Void
    private var probe: (@Sendable () async -> String)?
    private var probing = false
    private var interruptedWhileProbing = false
    private var sample: (observation: NativeMemoryObservation, uptime: UInt64)?

    init(onExit: @escaping @Sendable (Int32) -> Void) { self.onExit = onExit }
    var detail: String? { lock.withLock { diagnostic } }
    var isOpen: Bool { lock.withLock { diagnostic == nil && !probing } }
    func prepare(socket: URLSessionWebSocketTask) { lock.withLock { self.socket = socket } }
    /// Asked once, before the exit is published, when the WebSocket itself fails.
    func prepare(probe: @escaping @Sendable () async -> String) { lock.withLock { self.probe = probe } }
    /// Latest periodic worker measurement; the exit reports it with its age.
    func record(_ observation: NativeMemoryObservation?) {
        guard let observation else { return }
        lock.withLock { if diagnostic == nil { sample = (observation, DispatchTime.now().uptimeNanoseconds) } }
    }
    func attach(cleanup: @escaping @Sendable () -> Void) {
        let alreadyClosed = lock.withLock {
            if diagnostic != nil { return true }
            self.cleanup = cleanup
            return false
        }
        if alreadyClosed { cleanup() }
    }
    func received(bytes: Int) { lock.withLock { lastReceivedBytes = bytes } }
    func finish(stage: String, error: Error? = nil) {
        lock.lock()
        guard diagnostic == nil else { lock.unlock(); return }
        if probing {
            if stage == "worker_interruption" { interruptedWhileProbing = true }
            lock.unlock(); return
        }
        let base = Self.failureDiagnostic(stage: stage, error: error, closeCode: socket?.closeCode.rawValue ?? 0, lastReceivedBytes: lastReceivedBytes, receiveLimit: socket?.maximumMessageSize ?? 0)
        if ["send", "receive"].contains(stage), let probe {
            probing = true
            self.probe = nil
            lock.unlock()
            Task { self.completeProbe(base: base, found: await probe()) }
            return
        }
        publish(base + sampleSummary())
    }
    private func completeProbe(base: String, found: String) {
        lock.lock()
        probing = false
        let interrupted = interruptedWhileProbing ? " interrupted_while_probing=1" : ""
        publish(base + sampleSummary() + found + interrupted)
    }
    /// Called with the lock held; releases it.
    private func publish(_ text: String) {
        diagnostic = text
        let cleanup = self.cleanup
        self.cleanup = nil
        lock.unlock()
        cleanup?()
        onExit(-1)
    }
    private func sampleSummary() -> String {
        guard let sample else { return "" }
        var text = ""
        if let bytes = sample.observation.footprintBytes { text += " last_footprint_bytes=\(bytes)" }
        if let bytes = sample.observation.availableBytes { text += " last_available_bytes=\(bytes)" }
        if let bytes = sample.observation.lifetimePeakFootprintBytes { text += " lifetime_peak_bytes=\(bytes)" }
        let now = DispatchTime.now().uptimeNanoseconds
        text += " last_sample_age_ms=\(now >= sample.uptime ? (now - sample.uptime) / 1_000_000 : 0)"
        return text
    }
    /// Only allowlisted labels and numeric values enter the execution audit.
    static func failureDiagnostic(stage: String, error: Error?, closeCode: Int, lastReceivedBytes: Int, receiveLimit: Int) -> String {
        let nsError = error.map { $0 as NSError }
        let domain = nsError.map { [NSURLErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain].contains($0.domain) ? $0.domain : "other" } ?? "none"
        let safeStage = ["send", "receive", "local_close", "worker_interruption"].contains(stage) ? stage : "other"
        return "native stage=\(safeStage) domain=\(domain) code=\(nsError?.code ?? 0) close_code=\(closeCode) last_received_bytes=\(lastReceivedBytes) receive_limit=\(receiveLimit)"
    }
}

/// Serial WebSocket delivery behind the Session's existing handle contract.
nonisolated final class NativeRuntimeConnection: @unchecked Sendable {
    private let socket: URLSessionWebSocketTask
    private let outgoing: AsyncStream<String>.Continuation
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private let exit: NativeRuntimeExit

    init(socket: URLSessionWebSocketTask, exit: NativeRuntimeExit, onLine: @escaping @Sendable (String, Bool) -> Void) {
        self.socket = socket
        self.exit = exit
        let stream = AsyncStream<String>.makeStream()
        outgoing = stream.continuation
        exit.prepare(socket: socket)
        writer = Task {
            do { for await line in stream.stream { try await socket.send(.string(line)) } }
            catch { exit.finish(stage: "send", error: error) }
        }
        reader = Task {
            do {
                while !Task.isCancelled {
                    switch try await socket.receive() {
                    case .string(let line):
                        exit.received(bytes: line.utf8.count)
                        onLine(line, false)
                    case .data(let data):
                        exit.received(bytes: data.count)
                        onLine(String(decoding: data, as: UTF8.self), false)
                    @unknown default: break
                    }
                }
            } catch { exit.finish(stage: "receive", error: error) }
        }
        exit.attach { [weak self] in self?.cleanup() }
    }
    func write(_ line: String) { outgoing.yield(line) }
    func finish() { exit.finish(stage: "local_close") }
    private func cleanup() {
        outgoing.finish()
        socket.cancel(with: .goingAway, reason: nil)
        reader?.cancel(); writer?.cancel()
    }
}

extension CodexAppServerSession {
    /// Match tungstenite's default message budget. PDF/image histories and file RPCs
    /// can exceed Foundation's 1 MiB default even though each attachment is small.
    nonisolated static let nativeMaximumMessageSize = 64 * 1024 * 1024

    @MainActor static func nativeLauncher(boot: HyotanBoot, maximumMessageSize: Int = CodexAppServerSession.nativeMaximumMessageSize) -> Launcher {
        { onLine, onExit in
            await boot.start()
            guard await boot.state.isReady else { throw CodexAppServerError.notRunning }
            let exit = NativeRuntimeExit(onExit: onExit)
            let (endpoint, epoch) = try await NativeRuntimeHost.shared.start(onExit: { _ in exit.finish(stage: "worker_interruption") })
            do {
            var socket: URLSessionWebSocketTask?
            var port = endpoint.port
            var rebound = false
            // The in-process listener is bound before start returns; a short wait suffices.
            for _ in 0..<20 {
                if let diagnostic = exit.detail { throw CodexAppServerError.closed(diagnostic) }
                try Task.checkCancellation()
                var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)")!)
                request.timeoutInterval = 2
                request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
                let candidate = URLSession.shared.webSocketTask(with: request)
                candidate.maximumMessageSize = maximumMessageSize
                candidate.resume()
                do {
                    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                        candidate.sendPing { error in
                            if let error { c.resume(throwing: error) } else { c.resume() }
                        }
                    }
                    socket = candidate
                    break
                } catch {
                    candidate.cancel(with: .goingAway, reason: nil)
                    if let diagnostic = exit.detail { throw CodexAppServerError.closed(diagnostic) }
                    _ = try await NativeRuntimeHost.shared.send(NativeRuntimeRequest(operation: .health))
                    // A refused connection to a running server means iOS reclaimed the listening
                    // socket while the app was suspended. Listen again once, on a new port.
                    if !rebound, let next = await NativeRuntimeHost.shared.rebindInProcessListener() {
                        rebound = true
                        port = next
                        continue
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            guard let socket else {
                // The server stopped or cannot listen again; only a relaunch recovers it.
                throw CodexAppServerError.closed(CodexAppServerError.inProcessStoppedDetail)
            }
            exit.prepare(probe: { await NativeRuntimeHost.shared.codexFailureProbe(epoch: epoch) })
            let connection = NativeRuntimeConnection(socket: socket, exit: exit, onLine: onLine)
            if let diagnostic = exit.detail { throw CodexAppServerError.closed(diagnostic) }
            // Periodic worker measurement, so a later exit reports memory just before it.
            Task { @MainActor in
                while exit.isOpen, NativeRuntimeHost.shared.isCurrent(epoch: epoch) {
                    if let reply = try? await NativeRuntimeHost.shared.codexWorkerHealth(),
                       NativeRuntimeHost.shared.isCurrent(epoch: epoch) { exit.record(reply.memoryObservation) }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            // These are start-time measurements, not a peak or a measurement at exit.
            var startupMemory = ""
            if let bytes = endpoint.memoryFootprintBytes { startupMemory += " start_footprint_bytes=\(bytes)" }
            if let bytes = endpoint.availableMemoryBytes { startupMemory += " start_available_bytes=\(bytes)" }
            let memoryDiagnostic = startupMemory
            return GuestProcessHandle(pid: endpoint.pid, writeLine: { connection.write($0) }, closeInput: { connection.finish() }, terminate: {
                connection.finish()
                Task { @MainActor in NativeRuntimeHost.shared.stop(ifEpoch: epoch) }
            }, exitDiagnostic: {
                guard let diagnostic = exit.detail else { return nil }
                return diagnostic + memoryDiagnostic
            })
            } catch {
                await NativeRuntimeHost.shared.stop(ifEpoch: epoch)
                throw error
            }
        }
    }
}
