import Foundation
import ExtensionFoundation
import XPC
import Darwin

#if STRUIS_CODEX_WORKER && STRUIS_EXEC_WORKER
#error("A worker must have exactly one role")
#elseif !STRUIS_CODEX_WORKER && !STRUIS_EXEC_WORKER
#error("A worker role must be configured")
#endif

final class RuntimeService: @unchecked Sendable {
    static let shared = RuntimeService()
    private let workerID = UUID().uuidString
    private let startLock = NSLock()
    private let commandLock = NSLock()
    private let ownerLock = NSLock()
    private var owner: String?
    private var cancelledOwners: Set<String> = []
    private var endpoint: NativeRuntimeReply?
    #if DEBUG && targetEnvironment(simulator)
    private let preparationGate = NSCondition()
    private var pendingPreparationJob: NativeVirtualPythonJob?
    private var preArmDiscoverySeen = false
    #endif

    func handle(_ request: NativeRuntimeRequest) -> NativeRuntimeReply {
        var reply = handleRequest(request)
        if reply.error == nil && (request.operation == .start || request.operation == .health) {
            let memory = StruisMemorySnapshot()
            reply.memoryFootprintBytes = memory["footprint"]?.uint64Value
            reply.availableMemoryBytes = memory["available"]?.uint64Value
            reply.workerID = workerID
            #if STRUIS_CODEX_WORKER
            let role = NativeMemoryObservation.Role.codex
            #else
            let role = NativeMemoryObservation.Role.exec
            #endif
            reply.memoryObservation = NativeMemoryObservation(snapshot: memory, identity: workerID, role: role)
        }
        return reply
    }

    private func handleRequest(_ request: NativeRuntimeRequest) -> NativeRuntimeReply {
        do {
            #if DEBUG
            NSLog("Native runtime request %@ pid=%d matching_worker=%d", request.operation.rawValue, getpid(), request.workerID == workerID ? 1 : 0)
            #endif
            let root = try NativeRuntimePaths.resolveWorkerRoot(hostPath: request.sharedRoot)
            if request.operation != .start && request.workerID != workerID {
                return NativeRuntimeReply(pid: getpid(), error: "stale worker request")
            }
            switch request.operation {
            case .shutdown:
                // Invalidation alone permits ExtensionKit to reuse the still-live process.
                // Native Codex's OnceLock and Python state require an actual process exit.
                StruisTerminateWorker(0)
                return NativeRuntimeReply(pid: getpid(), error: "worker termination failed")
            case .start:
                startLock.lock(); defer { startLock.unlock() }
                #if STRUIS_CODEX_WORKER
                guard request.startsCodex != false else {
                    return NativeRuntimeReply(pid: getpid(), error: "Codex worker role mismatch")
                }
                #else
                guard request.startsCodex == false else {
                    return NativeRuntimeReply(pid: getpid(), error: "Exec worker role mismatch")
                }
                #endif
                if let endpoint { return endpoint }
                guard let canary = request.privateBoundaryCanary else {
                    return NativeRuntimeReply(pid: getpid(), error: "private boundary canary missing")
                }
                let accessDenied = StruisPrivateFileAccessDenied(canary)
                #if DEBUG && targetEnvironment(simulator)
                // Simulator does not enforce the device sandbox. This exception is
                // excluded from every device configuration, including Debug.
                NSLog("Native boundary simulator=true access_denied=%d", accessDenied ? 1 : 0)
                #else
                guard accessDenied else {
                    return NativeRuntimeReply(pid: getpid(), error: "private container isolation unavailable")
                }
                #endif
                #if DEBUG
                // Device diagnostics: the worker's stderr (Python and Codex fatal messages) in the shared root.
                if freopen(root.deletingLastPathComponent().appendingPathComponent("Library/worker-stderr.log").path, "a", stderr) != nil { setvbuf(stderr, nil, _IONBF, 0) }
                #endif
                guard let certificate = Bundle.main.url(forResource: "cacert", withExtension: "pem") else { throw NativeRuntimeStartError("cacert.pem missing from the worker bundle") }
                setenv("SSL_CERT_FILE", certificate.path, 1)
                setenv("REQUESTS_CA_BUNDLE", certificate.path, 1)
                #if STRUIS_EXEC_WORKER
                let result = NativeRuntimeReply(pid: getpid(), workerID: workerID)
                endpoint = result
                return result
                #else
                let home = root.appendingPathComponent("codex", isDirectory: true)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                setenv("CODEX_HOME", home.path, 1)
                let token = UUID().uuidString + UUID().uuidString
                let tokenFile = home.appendingPathComponent("transport-token")
                try Data(token.utf8).write(to: tokenFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
                #if DEBUG && targetEnvironment(simulator)
                if let testRoot = request.operationHarnessTestRoot {
                    let workspace = root.appendingPathComponent("workspace", isDirectory: true).resolvingSymlinksInPath()
                    let directory = URL(fileURLWithPath: testRoot, isDirectory: true).resolvingSymlinksInPath()
                    guard directory.path.hasPrefix(workspace.path + "/") else { throw NativeRuntimeStartError("invalid operation harness test root") }
                    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard descriptor >= 0 else { throw NativeRuntimeStartError("operation harness test root unavailable") }
                    defer { close(descriptor) }
                    let installed = directory.path.withCString { path in
                        workerID.withCString { owner in hyotan_codex_install_operation_harness(descriptor, path, owner, 1) }
                    }
                    guard installed == 0 else { throw NativeRuntimeStartError("operation harness installation failed") }
                }
                #endif
                let status = tokenFile.path.withCString { hyotan_codex_start(0, $0) }
                guard status == 0 else { return NativeRuntimeReply(pid: getpid(), error: "native start \(status)") }
                let port = hyotan_codex_port()
                guard port != 0 else { return NativeRuntimeReply(pid: getpid(), error: "native listener port missing") }
                let result = NativeRuntimeReply(pid: getpid(), workerID: workerID, port: port, token: token)
                endpoint = result
                return result
                #endif
            case .health:
                #if STRUIS_CODEX_WORKER
                var buffer = [CChar](repeating: 0, count: 4096)
                let length = hyotan_codex_error(&buffer, buffer.count)
                var reply = NativeRuntimeReply(pid: getpid(), error: length == 0 ? nil : String(cString: buffer))
                var site = [CChar](repeating: 0, count: 512)
                if hyotan_codex_panic_site(&site, site.count) > 0 { reply.panicSite = String(cString: site) }
                reply.panicCount = hyotan_codex_panic_count()
                return reply
                #else
                return NativeRuntimeReply(pid: getpid())
                #endif
            #if DEBUG && targetEnvironment(simulator)
            case .virtualPythonControl:
                #if STRUIS_EXEC_WORKER
                guard let control = request.virtualPythonControl,
                      control.stdinCapacity >= 0, control.stdinCapacity <= 16384,
                      control.stdout.count <= 16384, control.stderr.count <= 16384 else {
                    return NativeRuntimeReply(pid: getpid(), error: "invalid provider frame")
                }
                let data = StruisVPControl(workerID, control.job.owner, control.job.id.uuidString,
                    control.job.generation, control.invocationID, control.sequence,
                    control.action.rawValue, control.stdout, control.stderr,
                    UInt32(control.stdinCapacity), control.exitCode)
                var result = NativeVirtualPythonReply()
                result.invocationID = (data["invocationID"] as? NSNumber)?.uint64Value ?? 0
                result.sequence = (data["sequence"] as? NSNumber)?.uint64Value ?? 0
                result.function = (data["function"] as? NSNumber)?.uint32Value ?? 0
                result.argv = data["argv"] as? [Data] ?? []
                result.stdin = data["stdin"] as? Data ?? Data()
                result.stdinEOF = (data["stdinEOF"] as? NSNumber)?.boolValue ?? false
                result.completed = (data["completed"] as? NSNumber)?.boolValue ?? false
                result.exitCode = (data["exitCode"] as? NSNumber)?.int32Value ?? 0
                result.stdoutAccepted = (data["stdoutAccepted"] as? NSNumber)?.intValue ?? 0
                result.stderrAccepted = (data["stderrAccepted"] as? NSNumber)?.intValue ?? 0
                result.stdoutCredit = (data["stdoutCredit"] as? NSNumber)?.intValue ?? 0
                result.stderrCredit = (data["stderrCredit"] as? NSNumber)?.intValue ?? 0
                result.errorCode = (data["errorCode"] as? NSNumber)?.int32Value ?? EIO
                if control.action == .discover, result.errorCode == EACCES {
                    preparationGate.lock()
                    if pendingPreparationJob == control.job {
                        preArmDiscoverySeen = true; preparationGate.broadcast()
                    }
                    preparationGate.unlock()
                }
                if control.action == .cancel, result.errorCode == 0 {
                    ownerLock.lock(); cancelledOwners.insert(control.job.owner); ownerLock.unlock()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
                        ownerLock.lock(); let sameOwner = owner == control.job.owner; ownerLock.unlock()
                        if sameOwner && StruisVPIsJobCurrent(control.job.id.uuidString, control.job.generation) {
                            StruisTerminateWorker(130)
                        }
                    }
                }
                return NativeRuntimeReply(pid: getpid(), workerID: workerID, virtualPython: result)
                #else
                return NativeRuntimeReply(pid: getpid(), error: "Codex worker cannot control a provider")
                #endif
            case .virtualPythonBridgeProbe:
                #if STRUIS_EXEC_WORKER
                // Synthetic owned pipes only. C retires this entire test
                // worker if a real transfer assertion or cleanup fails.
                let result = StruisVPAppleProbe()
                return NativeRuntimeReply(pid: getpid(), output: String(result), exitCode: result == STRUIS_VP_APPLE_PROBE_ALL ? 0 : 125)
                #else
                return NativeRuntimeReply(pid: getpid(), error: "Codex worker cannot run a command bridge probe")
                #endif
            #endif
            case .interrupt:
                #if STRUIS_EXEC_WORKER
                #if DEBUG && targetEnvironment(simulator)
                if let job = request.virtualPythonJob {
                    guard job.owner == request.owner,
                          StruisVPCancelJob(workerID, job.owner, job.id.uuidString, job.generation) else {
                        return NativeRuntimeReply(pid: getpid(), error: "stale provider cancellation")
                    }
                }
                #endif
                ownerLock.lock(); defer { ownerLock.unlock() }
                if let requestedOwner = request.owner { cancelledOwners.insert(requestedOwner) }
                if owner == request.owner, let requestedOwner = request.owner {
                    #if DEBUG && targetEnvironment(simulator)
                    if !StruisVPCancelOwner(requestedOwner) { StruisInterruptCommand() }
                    #else
                    StruisInterruptCommand()
                    #endif
                    // A native C extension may never return to Python to receive KeyboardInterrupt.
                    // Retire this worker if the cancelled command is still running after the grace period.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
                        ownerLock.lock()
                        var stillRunning = owner == requestedOwner
                        #if DEBUG && targetEnvironment(simulator)
                        if let job = request.virtualPythonJob {
                            stillRunning = stillRunning && StruisVPIsJobCurrent(job.id.uuidString, job.generation)
                        }
                        #endif
                        ownerLock.unlock()
                        if stillRunning { StruisTerminateWorker(130) }
                    }
                }
                return NativeRuntimeReply(pid: getpid())
                #else
                return NativeRuntimeReply(pid: getpid(), error: "Codex worker cannot interrupt commands")
                #endif
            case .command:
                #if STRUIS_EXEC_WORKER
                #if DEBUG && targetEnvironment(simulator)
                if request.virtualPythonJob != nil {
                    guard commandLock.try() else { return NativeRuntimeReply(pid: getpid(), error: "command worker busy") }
                } else { commandLock.lock() }
                #else
                commandLock.lock()
                #endif
                defer { commandLock.unlock() }
                guard let command = request.command, let cwd = request.cwd, let requestedOwner = request.owner else { throw CocoaError(.coderValueNotFound) }
                let directory = URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
                let workspaces = root.appendingPathComponent("workspace").resolvingSymlinksInPath()
                guard directory.path.hasPrefix(workspaces.path + "/") else { throw CocoaError(.fileReadNoPermission) }
                ownerLock.lock()
                guard !cancelledOwners.contains(requestedOwner) else {
                    ownerLock.unlock()
                    return NativeRuntimeReply(pid: getpid(), error: "command interrupted before execution")
                }
                owner = requestedOwner
                ownerLock.unlock()
                defer { ownerLock.lock(); owner = nil; ownerLock.unlock() }
                #if DEBUG && targetEnvironment(simulator)
                if let job = request.virtualPythonJob {
                    if job.requirePreArmDiscovery {
                        // Deterministic real-XPC ordering canary. The independent
                        // control must observe this exact job denied before arm.
                        preparationGate.lock()
                        pendingPreparationJob = job; preArmDiscoverySeen = false
                        let deadline = Date(timeIntervalSinceNow: 2)
                        while !preArmDiscoverySeen && preparationGate.wait(until: deadline) {}
                        let observed = preArmDiscoverySeen
                        pendingPreparationJob = nil; preArmDiscoverySeen = false
                        preparationGate.unlock()
                        guard observed else { return NativeRuntimeReply(pid: getpid(), error: "provider startup gate timed out") }
                    }
                    guard job.owner == requestedOwner,
                          StruisVPPrepareJob(workerID, requestedOwner, job.id.uuidString, job.generation) == 0 else {
                        return NativeRuntimeReply(pid: getpid(), error: "invalid provider job")
                    }
                    if job.requirePreArmDiscovery {
                        let empty = Data()
                        func probe(_ owner: String, _ generation: UInt64) -> Int32 {
                            let result = StruisVPControl(workerID, owner, job.id.uuidString, generation,
                                0, 0, "discover", empty, empty, 0, 0)
                            return (result["errorCode"] as? NSNumber)?.int32Value ?? EIO
                        }
                        guard probe(requestedOwner, job.generation) == EAGAIN,
                              probe(requestedOwner + "-foreign", job.generation) == EACCES,
                              probe(requestedOwner, job.generation - 1) == EACCES else {
                            StruisVPEndJob(job.id.uuidString)
                            return NativeRuntimeReply(pid: getpid(), error: "provider startup identity proof failed")
                        }
                    }
                }
                defer { if let job = request.virtualPythonJob { StruisVPEndJob(job.id.uuidString) } }
                #endif
                let result = StruisRunCommand(command, directory.path, root.appendingPathComponent("home").path)
                var reply = NativeRuntimeReply(pid: getpid(), output: result["output"] as? String ?? "", exitCode: result["exit"] as? Int ?? 125, truncated: result["truncated"] as? Bool ?? false)
                #if DEBUG && targetEnvironment(simulator)
                if (result["compoundDashWorkerSpent"] as? NSNumber)?.boolValue == true {
                    reply.workerID = workerID
                    reply.compoundDashWorkerSpent = true
                }
                #endif
                return reply
                #else
                return NativeRuntimeReply(pid: getpid(), error: "Codex worker cannot execute commands")
                #endif
            }
        } catch { return NativeRuntimeReply(pid: getpid(), error: String(describing: error)) }
    }
}
struct RuntimeHandler: XPCPeerHandler {
    func handleIncomingRequest(_ request: NativeRuntimeRequest) -> (any Encodable)? { RuntimeService.shared.handle(request) }
}
@main struct RuntimeWorker: AppExtension {
    @AppExtensionPoint.Bind var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "com.digiloglab.strius", name: "Runtime")
    }
    var configuration: some AppExtensionConfiguration {
        ConnectionHandler(onSessionRequest: { request in
            request.accept { session in
                session.setTargetQueue(DispatchQueue(label: "com.digiloglab.strius.runtime.xpc.\(UUID().uuidString)", qos: .userInitiated))
                return RuntimeHandler()
            }
        })
    }
}
