import XCTest
import Foundation
import Darwin
@testable import strius

#if DEBUG && targetEnvironment(simulator)
/// Transport preparation with an explicitly named binary relay. No Python
/// evaluator is mocked: real dash invokes its registered native Python entry,
/// whose trusted test job selects C shuttles and exchanges bytes over real XPC.
final class VirtualPythonProviderTransportTests: XCTestCase {
    private enum Failure: Error { case deadline, protocolFailure }

    @MainActor private func begin(_ host: NativeRuntimeHost, command: String, cwd: String, owner: String, requirePreArmDiscovery: Bool = false) async throws -> NativeRuntimeHost.VirtualPythonCommandHandle {
        do { return try await host.beginVirtualPythonTransportCommand(command: command, cwd: cwd, owner: owner, requirePreArmDiscovery: requirePreArmDiscovery) }
        catch { printVirtualPythonProviderDiagnostics(); throw error }
    }

    @MainActor private func discover(_ host: NativeRuntimeHost,
        _ handle: NativeRuntimeHost.VirtualPythonCommandHandle,
        excluding previous: UInt64 = 0) async throws -> NativeVirtualPythonReply {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < end {
            let reply = try await host.virtualPythonControl(.init(action: .discover, job: handle.job), for: handle)
            if reply.errorCode == 0, reply.invocationID != previous { return reply }
            guard reply.errorCode == EAGAIN || (reply.errorCode == 0 && reply.invocationID == previous) else {
                print("NATIVE_PROVIDER_DISCOVER errno=\(reply.errorCode)")
                throw Failure.protocolFailure
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.deadline
    }

    @MainActor private func relay(_ host: NativeRuntimeHost,
        _ handle: NativeRuntimeHost.VirtualPythonCommandHandle, invocation: UInt64,
        expected: Data) async throws {
        var sequence: UInt64 = 1
        var output = Data(), errors = Data()
        var inputEOF = false
        var seen = 0
        let end = ContinuousClock.now.advanced(by: .seconds(10))
        while !inputEOF || !output.isEmpty || !errors.isEmpty {
            guard ContinuousClock.now < end else { throw Failure.deadline }
            let pull = output.isEmpty && errors.isEmpty && !inputEOF
            let reply = try await host.virtualPythonControl(.init(action: .exchange,
                job: handle.job, invocationID: invocation, sequence: sequence,
                stdout: output, stderr: errors, stdinCapacity: pull ? 16384 : 0), for: handle)
            sequence += 1
            guard reply.errorCode == 0, reply.stdoutAccepted <= output.count,
                reply.stderrAccepted <= errors.count, reply.stdin.count <= 16384 else { throw Failure.protocolFailure }
            output.removeFirst(reply.stdoutAccepted)
            errors.removeFirst(reply.stderrAccepted)
            if !reply.stdin.isEmpty {
                guard pull, seen + reply.stdin.count <= expected.count else { throw Failure.protocolFailure }
                XCTAssertEqual(reply.stdin, expected.subdata(in: seen..<(seen + reply.stdin.count)))
                seen += reply.stdin.count
                output = Data(reply.stdin.map { $0 ^ 0x55 })
                errors = Data(reply.stdin.map { $0 ^ 0xaa })
            }
            inputEOF = inputEOF || reply.stdinEOF
            if reply.stdin.isEmpty && reply.stdoutAccepted == 0 && reply.stderrAccepted == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        XCTAssertEqual(seen, expected.count)
        let finished = try await host.virtualPythonControl(.init(action: .finish,
            job: handle.job, invocationID: invocation, sequence: sequence, exitCode: 0), for: handle)
        XCTAssertEqual(finished.errorCode, 0)
        let terminal = try await host.awaitVirtualPythonInvocationCompletion(invocation, for: handle)
        XCTAssertEqual(terminal, 0)
    }

    @MainActor private func startFixture() async throws -> (NativeRuntimeHost, URL) {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1", "native Simulator integration is opt-in")
        let boot = HyotanBoot()
        await boot.start()
        XCTAssertTrue(boot.state.isReady)
        let host = NativeRuntimeHost.shared
        if let root = NativeRuntimePaths.sharedRoot {
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent().appendingPathComponent("Library"), withIntermediateDirectories: true)
        }
        _ = try await host.start { _ in }
        let workspace = HyotanBoot.workspaceRoot.appendingPathComponent("provider-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (host, workspace)
    }

    @MainActor func testRealDashBinaryRelayStreamsBeforeEOFAndPreservesArgvExitAndNextInvocation() async throws {
        let (host, workspace) = try await startFixture()
        defer { host.stop(); try? FileManager.default.removeItem(at: workspace) }
        let count = 65536 * 5 + 237
        let bytes = Data((0..<count).map { UInt8(($0 * 37) % 251) })
        try bytes.write(to: workspace.appendingPathComponent("input.bin"))
        // Native producer cannot write the rest until the native consumer sees
        // output. This proves real pipeline output precedes full input/EOF.
        // Native commands share process-wide BSD getopt state. The flags keep
        // option parsing in the two stages from overlapping: the consumer's
        // head starts after the producer's head, and tee creates early.flag
        // only after parsing, before the producer starts tail.
        let command = """
        printf x >>execution-count.bin
        { printf group-a; printf group-b; } >group.bin
        printf after >>group.bin
        { head -c 1024 input.bin; : >producer.head; i=0; while [ ! -f early.flag ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done; [ -f early.flag ] || exit 91; tail -c +1025 input.bin; : >producer.done; } | python3 -c 'binary-relay-transport-only' '日本語' 2>errors.bin | { i=0; while [ ! -f producer.head ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done; head -c 1024 >first.bin; if [ -f producer.done ]; then printf late >timing.txt; else printf early >timing.txt; fi; tee early.flag >rest.bin; }
        cat first.bin rest.bin >combined.bin
        python3 -c 'exit-transport-only' '日本語'
        """
        let handle = try await begin(host, command: command, cwd: workspace.path, owner: UUID().uuidString, requirePreArmDiscovery: true)
        do {
            XCTAssertGreaterThan(host.virtualPythonStartupDeniedReadCount(handle), 0, "Forced pre-arm discover must be denied before the handshake succeeds")
            let first = try await discover(host, handle)
            XCTAssertEqual(first.function, 1)
            XCTAssertEqual(first.argv.map { String(decoding: $0, as: UTF8.self) }, ["python3", "-c", "binary-relay-transport-only", "日本語"])
            var foreign = handle.job
            foreign = NativeVirtualPythonJob(id: foreign.id, owner: "foreign-owner", generation: foreign.generation)
            do {
                _ = try await host.virtualPythonControl(.init(action: .exchange, job: foreign, invocationID: first.invocationID, sequence: 1), for: handle)
                XCTFail("foreign owner accepted")
            } catch { /* Rejected by the trusted pinned host binding. */ }
            let oldGeneration = NativeVirtualPythonJob(id: handle.job.id, owner: handle.job.owner, generation: handle.job.generation + 1)
            do {
                _ = try await host.virtualPythonControl(.init(action: .discover, job: oldGeneration), for: handle)
                XCTFail("wrong generation accepted")
            } catch { }
            try await relay(host, handle, invocation: first.invocationID, expected: bytes)
            let second = try await discover(host, handle, excluding: first.invocationID)
            XCTAssertNotEqual(second.invocationID, first.invocationID)
            XCTAssertEqual(second.argv.map { String(decoding: $0, as: UTF8.self) }, ["python3", "-c", "exit-transport-only", "日本語"])
            let stale = try await host.virtualPythonControl(.init(action: .exchange, job: handle.job,
                invocationID: first.invocationID, sequence: 1, stdout: Data("stale".utf8), stdinCapacity: 0), for: handle)
            XCTAssertEqual(stale.errorCode, EACCES)
            XCTAssertEqual(stale.stdoutAccepted, 0)
            let marker = Data("relay-stderr-marker\n".utf8)
            let exchange = NativeVirtualPythonControl(action: .exchange, job: handle.job,
                invocationID: second.invocationID, sequence: 1, stderr: marker)
            let accepted = try await host.virtualPythonControl(exchange, for: handle)
            XCTAssertEqual(accepted.errorCode, 0)
            XCTAssertEqual(accepted.stderrAccepted, marker.count)
            let duplicate = try await host.virtualPythonControl(exchange, for: handle)
            XCTAssertEqual(duplicate.errorCode, EALREADY)
            XCTAssertEqual(duplicate.stderrAccepted, 0)
            let finish = try await host.virtualPythonControl(.init(action: .finish, job: handle.job,
                invocationID: second.invocationID, sequence: 2, exitCode: 42), for: handle)
            XCTAssertEqual(finish.errorCode, 0)
            let secondExit = try await host.awaitVirtualPythonInvocationCompletion(second.invocationID, for: handle)
            XCTAssertEqual(secondExit, 42)
            let commandReply = try await host.finishVirtualPythonTransportCommand(handle)
            XCTAssertEqual(commandReply.exitCode, 42)
            XCTAssertTrue(commandReply.output.contains("relay-stderr-marker"))
            XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("combined.bin")), Data(bytes.map { $0 ^ 0x55 }))
            XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("errors.bin")), Data(bytes.map { $0 ^ 0xaa }))
            XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("timing.txt"), encoding: .utf8), "early")
            do {
                _ = try await host.virtualPythonControl(exchange, for: handle)
                XCTFail("completed job accepted")
            } catch { }
            XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("execution-count.bin")), Data("x".utf8))
            if ProcessInfo.processInfo.environment["STRUIS_COMPOUND_DASH_PREPARATION"] == "1" {
                // The prepared Dash stage keeps a group redirection active for
                // every command and restores it before the following command.
                // The default Dash build does not include this repair yet.
                XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("group.bin")), Data("group-agroup-bafter".utf8))
                XCTAssertEqual(commandReply.compoundDashWorkerSpent, true,
                    "Dedicated SDK preparation must execute the signed stage path")
            }
            if commandReply.compoundDashWorkerSpent == true {
                XCTAssertEqual(commandReply.workerID, handle.workerID)
                do {
                    _ = try await host.commandWorkerHealth()
                    XCTFail("Consumed signed stage images remained available")
                } catch { }
                var previousWorker = handle.workerID
                // Each real pipeline consumes its signed stage images. These
                // jobs must use actual new process generations, with no replay
                // of the earlier side effect while replacing a spent pool.
                for index in 1...2 {
                    let payload = Data("FRESH_SIGNED_POOL_\(index)".utf8)
                    let next = try await begin(host,
                        command: "printf x >>execution-count.bin; printf FRESH_SIGNED_POOL_\(index) | python3 -c 'binary-relay-transport-only' >pool-\(index).bin 2>pool-\(index).err",
                        cwd: workspace.path, owner: UUID().uuidString)
                    XCTAssertNotEqual(next.workerID, previousWorker)
                    let invocation = try await discover(host, next)
                    XCTAssertEqual(invocation.function, 1)
                    try await relay(host, next, invocation: invocation.invocationID, expected: payload)
                    let nextReply = try await host.finishVirtualPythonTransportCommand(next)
                    XCTAssertEqual(nextReply.exitCode, 0)
                    XCTAssertEqual(nextReply.workerID, next.workerID)
                    XCTAssertEqual(nextReply.compoundDashWorkerSpent, true)
                    XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("pool-\(index).bin")), Data(payload.map { $0 ^ 0x55 }))
                    XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("pool-\(index).err")), Data(payload.map { $0 ^ 0xaa }))
                    XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("execution-count.bin")), Data(repeating: 0x78, count: index + 1))
                    previousWorker = next.workerID
                }
                print("NATIVE_COMPOUND_DASH_RETIREMENT fresh_generations=2 replay=false")
            } else {
                let health = try await host.commandWorkerHealth()
                XCTAssertEqual(health.pid, commandReply.pid)
            }
            print("NATIVE_PROVIDER_TRANSPORT expected_bytes=\(count) actual_exit=\(commandReply.exitCode)")
        } catch {
            printVirtualPythonProviderDiagnostics()
            await host.cancelVirtualPythonTransportCommand(handle)
            _ = try? await host.finishVirtualPythonTransportCommand(handle)
            throw error
        }
    }

    @MainActor func testLostRealProviderAcknowledgementKeepsReplacementSealedUntilActualCapturedExit() async throws {
        let (host, workspace) = try await startFixture()
        // This dedicated SDK scheme must run the regression, never certify
        // its absence as a passing ordinary-provider fallback.
        var fault: UUID?
        defer {
            if let fault { host.endVirtualPythonControlFaultForTest(fault) }
            host.stop(); try? FileManager.default.removeItem(at: workspace)
        }
        guard ProcessInfo.processInfo.environment["STRUIS_COMPOUND_DASH_PREPARATION"] == "1" else {
            XCTFail("Dedicated SDK regression requires signed compound preparation")
            throw Failure.protocolFailure
        }
        let failed = try await begin(host,
            command: "printf x >>execution-count.bin; { printf LOST_ACK_PAYLOAD; } | python3 -c 'binary-relay-transport-only' | { cat >failed-output.bin; }",
            cwd: workspace.path, owner: UUID().uuidString)
        do {
            let invocation = try await discover(host, failed)
            let token = try host.armVirtualPythonControlAcknowledgementDropForTest(failed,
                invocationID: invocation.invocationID, sequence: 1)
            fault = token
            var controlFailed = false
            do {
                _ = try await host.virtualPythonControl(.init(action: .exchange, job: failed.job,
                    invocationID: invocation.invocationID, sequence: 1, stdinCapacity: 16384), for: failed)
            } catch { controlFailed = true }
            XCTAssertTrue(controlFailed, "The real accepted control's dropped ACK must throw")
            XCTAssertTrue(host.virtualPythonControlAcknowledgementWasDroppedForTest(token),
                "A real successful provider reply must reach the fault, without retry")
            var finishFailed = false
            do { _ = try await host.finishVirtualPythonTransportCommand(failed) }
            catch { finishFailed = true }
            XCTAssertTrue(finishFailed, "Unknown ACK retirement must fail the command waiter")
            XCTAssertTrue(host.virtualPythonControlFaultJobRemovedForTest(token),
                "The physical-exit gate must outlive removal of the provider job")
            XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("execution-count.bin")), Data("x".utf8))
            var replacementDenied = false
            do {
                _ = try await host.send(.init(operation: .command,
                    command: "printf forbidden >>forbidden-replacement.bin",
                    cwd: workspace.path, owner: UUID().uuidString))
            } catch { replacementDenied = true }
            XCTAssertTrue(replacementDenied, "Held actual exit publication must deny replacement before send")
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("forbidden-replacement.bin").path))
            XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("execution-count.bin")), Data("x".utf8))
            host.releaseVirtualPythonControlFaultObservationForTest(token)
            let actualExit = await host.awaitVirtualPythonControlFaultExitForTest(token)
            guard actualExit else {
                XCTFail("No actual captured AppExtensionProcess interruption was observed")
                throw Failure.deadline
            }
            // Exactly one begin after actual exit; retrying begin could replay
            // a shell prefix if the command had already reached the worker.
            let payload = Data("AFTER_LOST_ACK".utf8)
            let next = try await begin(host,
                command: "printf x >>execution-count.bin; { printf AFTER_LOST_ACK; } | python3 -c 'binary-relay-transport-only' 2>next.err | { cat >next.bin; }",
                cwd: workspace.path, owner: UUID().uuidString)
            XCTAssertNotEqual(next.workerID, failed.workerID)
            do {
                _ = try await host.virtualPythonControl(.init(action: .discover, job: failed.job), for: failed)
                XCTFail("Old captured control accepted by a successor")
            } catch { }
            let nextInvocation = try await discover(host, next)
            try await relay(host, next, invocation: nextInvocation.invocationID, expected: payload)
            let reply = try await host.finishVirtualPythonTransportCommand(next)
            XCTAssertEqual(reply.exitCode, 0)
            XCTAssertEqual(reply.workerID, next.workerID)
            XCTAssertEqual(reply.compoundDashWorkerSpent, true)
            XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("next.bin")), Data(payload.map { $0 ^ 0x55 }))
            XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("next.err")), Data(payload.map { $0 ^ 0xaa }))
            XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("execution-count.bin")), Data("xx".utf8))
            print("NATIVE_COMPOUND_DASH_LOST_ACK real_ack=true job_removed=true held_exit_denies_replacement=true actual_exit=true new_worker=true replay=false")
        } catch {
            printVirtualPythonProviderDiagnostics()
            throw error
        }
    }

    @MainActor func testRealDashBlockedProviderCancellationRetiresOnlyCapturedJobAndRunsNextNativeCommand() async throws {
        let (host, workspace) = try await startFixture()
        defer { host.stop(); try? FileManager.default.removeItem(at: workspace) }
        for blockedOutput in [false, true] {
            let command = blockedOutput ? "python3 -c 'blocked-output-transport-only' | sleep 15" : "sleep 15 | python3 -c 'blocked-input-transport-only'"
            let handle = try await begin(host, command: command, cwd: workspace.path, owner: UUID().uuidString)
            do {
                let discovered = try await discover(host, handle)
                let before = try await host.commandWorkerHealth()
                if blockedOutput {
                    let frame = Data(repeating: 0x75, count: 16384)
                    var sequence: UInt64 = 1
                    var full = false
                    let end = ContinuousClock.now.advanced(by: .seconds(5))
                    while !full && ContinuousClock.now < end {
                        let reply = try await host.virtualPythonControl(.init(action: .exchange, job: handle.job,
                            invocationID: discovered.invocationID, sequence: sequence, stdout: frame, stdinCapacity: 0), for: handle)
                        sequence += 1
                        guard reply.errorCode == 0 else { throw Failure.protocolFailure }
                        full = reply.stdoutAccepted == 0 && reply.stdoutCredit == 0
                    }
                    XCTAssertTrue(full, "Native downstream must exert actual backpressure")
                }
                let began = ContinuousClock.now
                let cleanupConfirmed = await host.cancelVirtualPythonTransportCommand(handle)
                XCTAssertTrue(cleanupConfirmed, "Cancel acknowledgement alone is not native cleanup")
                var retired = false
                do {
                    let stopped = try await host.finishVirtualPythonTransportCommand(handle)
                    XCTAssertEqual(stopped.exitCode, 130)
                } catch {
                    retired = true
                    // A native sleep stage can keep dash waiting after provider
                    // cleanup. Defined recovery then retires the captured worker.
                    print("NATIVE_PROVIDER_TRANSPORT cancellation=worker_retired")
                }
                XCTAssertLessThan(began.duration(to: .now), .seconds(8))
                do {
                    _ = try await host.virtualPythonControl(.init(action: .discover, job: handle.job), for: handle)
                    XCTFail("cancelled old job accepted")
                } catch { }
                let next = try await host.send(.init(operation: .command,
                    command: "python3 -c 'print(\"NATIVE_PROVIDER_DEFAULT_UNCHANGED\")'", cwd: workspace.path, owner: UUID().uuidString))
                XCTAssertEqual(next.exitCode, 0)
                if retired { XCTAssertNotEqual(next.pid, before.pid, "Recovery must actually replace the captured worker") }
                XCTAssertTrue(next.output.contains("NATIVE_PROVIDER_DEFAULT_UNCHANGED"))
                print("NATIVE_PROVIDER_TRANSPORT blocked_output=\(blockedOutput) next_native_python=true old_job_denied=true")
            } catch {
                printVirtualPythonProviderDiagnostics()
                await host.cancelVirtualPythonTransportCommand(handle)
                _ = try? await host.finishVirtualPythonTransportCommand(handle)
                throw error
            }
        }
    }
}
#endif
