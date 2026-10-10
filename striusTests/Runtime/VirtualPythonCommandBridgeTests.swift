import XCTest
import Foundation
import Darwin
@testable import strius

#if DEBUG && targetEnvironment(simulator)
final class VirtualPythonCommandBridgeTests: XCTestCase {
    @MainActor
    func testExecRealPipesSupportDuplexCancellationAndNextInvocation() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1", "native Simulator integration is opt-in")
        let boot = HyotanBoot()
        await boot.start()
        XCTAssertTrue(boot.state.isReady)
        let host = NativeRuntimeHost.shared
        // Worker startup's existing freopen needs this trusted shared directory.
        // Make it before either test worker starts so fd2 records survive exit.
        if let root = NativeRuntimePaths.sharedRoot {
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent()
                .appendingPathComponent("Library"), withIntermediateDirectories: true)
        }
        let (codex, _) = try await host.start { _ in }
        defer { host.stop() }
        let result: NativeRuntimeReply
        do { result = try await host.send(.init(operation: .virtualPythonBridgeProbe)) }
        catch {
            reportNumericProbeDiagnostics()
            throw error // The failing probe stays a failing test.
        }
        XCTAssertNil(result.error)
        XCTAssertEqual(result.exitCode, 0, result.output)
        // C sets each bit only after actual pipe/thread assertions succeed.
        XCTAssertEqual(result.output, "63", "Expected transfer/EOF/read-cancel/write-cancel/EPIPE/next-context")
        XCTAssertNotEqual(result.pid, codex.pid, "The probe must run in the real Exec worker")
        let health = try await host.commandWorkerHealth()
        XCTAssertEqual(health.pid, result.pid)
        XCTAssertNil(health.error)
        print("NATIVE_DUPLEX_APPLE mask=\(result.output) exit=\(result.exitCode) same_exec_health=\(health.pid == result.pid && health.error == nil)")
    }

    /// Bounded trusted diagnostic read. Never echo other worker stderr, paths,
    /// commands or auth; normalize only the fixed numeric probe record grammar.
    @MainActor private func reportNumericProbeDiagnostics() {
        guard let root = NativeRuntimePaths.sharedRoot else { return }
        let file = root.deletingLastPathComponent().appendingPathComponent("Library/worker-stderr.log")
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { print("NATIVE_DUPLEX_DIAGNOSTICS unavailable"); return }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              UInt32(metadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) else {
            close(descriptor)
            print("NATIVE_DUPLEX_DIAGNOSTICS unavailable")
            return
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end > 16384 ? end - 16384 : 0)
            guard let bytes = try handle.read(upToCount: 16384) else { return }
            let text = String(decoding: bytes, as: UTF8.self)
            let expression = try NSRegularExpression(pattern: "^STRUIS_VP_PROBE stage=([0-9]{1,3}) line=([0-9]{1,10}) errno=(-?[0-9]{1,10})$")
            let stages: Set<Int> = [1, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
                20, 21, 22, 23, 24, 25, 26, 30, 31, 32, 33, 34, 35, 36, 37,
                40, 41, 42, 43, 44, 45, 50, 60, 61, 62, 63]
            for record in text.split(separator: "\n").suffix(64) {
                let line = String(record)
                let source = line as NSString
                guard let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: source.length)),
                      let stage = Int(source.substring(with: match.range(at: 1))), stages.contains(stage),
                      let location = Int(source.substring(with: match.range(at: 2))),
                      let error = Int(source.substring(with: match.range(at: 3))) else { continue }
                if stage == 62 || stage == 63 {
                    // Synthetic FD flag before/after, never paths or payload.
                    guard location <= Int(Int32.max), error >= -1, error <= Int(Int32.max) else { continue }
                } else { guard location <= 10000, error >= -4096, error <= 4096 else { continue } }
                print("STRUIS_VP_PROBE stage=\(stage) line=\(location) errno=\(error)")
            }
        } catch { print("NATIVE_DUPLEX_DIAGNOSTICS unavailable") }
    }
}
#endif
