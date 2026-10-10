import XCTest
@testable import strius

/// Contract fixtures; Apple execution is separate from Linux source checks.
final class NativeMemoryObservationTests: XCTestCase {
    func testOldReplyDecodesWithoutStructuredObservation() throws {
        let data = Data(#"{"pid":42,"workerID":"old-worker","port":0,"token":"","output":"","exitCode":0,"truncated":false,"memoryFootprintBytes":123,"availableMemoryBytes":0}"#.utf8)
        let reply = try JSONDecoder().decode(NativeRuntimeReply.self, from: data)
        XCTAssertNil(reply.memoryObservation)
        XCTAssertEqual(reply.memoryFootprintBytes, 123)
        XCTAssertEqual(reply.availableMemoryBytes, 0)
    }

    func testUnavailableIsDistinctFromZeroAndSignedPeakCannotWrap() throws {
        let missing = NativeMemoryObservation(snapshot: ["pid": 42, "queryStatus": 5], identity: "fixture", role: .exec)
        XCTAssertNil(missing.footprintBytes)
        XCTAssertNil(missing.availableBytes)
        XCTAssertNil(missing.monotonicNanoseconds)
        let zero = NativeMemoryObservation(snapshot: ["pid": 42, "available": 0, "lifetimePeak": -1], identity: "fixture", role: .exec)
        XCTAssertEqual(zero.availableBytes, 0)
        XCTAssertNil(zero.lifetimePeakFootprintBytes)
        let decoded = try JSONDecoder().decode(NativeMemoryObservation.self, from: JSONEncoder().encode(zero))
        XCTAssertEqual(decoded, zero)
    }

    func testCapturedIdentityRejectsPIDReuseRoleMismatchAndFailure() {
        let sample = NativeMemoryObservation(snapshot: ["pid": 42, "footprint": 7, "lifetimePeak": 11], identity: "old-fixture", role: .codex)
        var reply = NativeRuntimeReply(pid: 42, workerID: "old-fixture")
        reply.memoryObservation = sample
        XCTAssertTrue(sample.matches(reply: reply, identity: "old-fixture", role: .codex))
        XCTAssertFalse(sample.matches(reply: reply, identity: "new-fixture", role: .codex))
        XCTAssertFalse(sample.matches(reply: reply, identity: "old-fixture", role: .exec))
        reply.workerID = "new-fixture"
        XCTAssertFalse(sample.matches(reply: reply, identity: "old-fixture", role: .codex))
        reply.workerID = "old-fixture"
        reply.pid = 43
        XCTAssertFalse(sample.matches(reply: reply, identity: "old-fixture", role: .codex))
        reply.pid = 42
        reply.error = "fixture failure"
        XCTAssertFalse(sample.matches(reply: reply, identity: "old-fixture", role: .codex))
    }

    @MainActor
    func testCompletedReplyThenTerminalPublicationRejectsOnResume() async {
        for processExit in [true, false] {
            let lifetime = NativeMemoryProcessLifetime()
            let identity = UUID().uuidString
            var completedReply = NativeRuntimeReply(pid: 42, workerID: identity)
            completedReply.memoryObservation = NativeMemoryObservation(snapshot: ["pid": 42], identity: identity, role: .codex)
            let registered = expectation(description: "captured health await suspended")
            let gate = MemoryReplyOrderingFixture()
            let observation = Task { @MainActor in
                let reply = await gate.value(onSuspended: { registered.fulfill() })
                return lifetime.accepts(reply, identity: identity, role: .codex)
            }
            await fulfillment(of: [registered], timeout: 2)
            // The success callback queues the MainActor continuation. Publish the
            // actual terminal callback receipt before yielding that actor to it.
            gate.complete(completedReply)
            if processExit { lifetime.observeProcessInterruption() }
            else { lifetime.observeKeepAliveCancellation() }
            let accepted = await observation.value
            XCTAssertFalse(accepted)
            XCTAssertEqual(lifetime.observedProcessInterruption, processExit)
            XCTAssertEqual(lifetime.observedKeepAliveCancellation, !processExit)
            XCTAssertFalse(lifetime.allowsSampling)
            let fresh = NativeMemoryProcessLifetime()
            let freshIdentity = UUID().uuidString
            var freshReply = NativeRuntimeReply(pid: 43, workerID: freshIdentity)
            freshReply.memoryObservation = NativeMemoryObservation(snapshot: ["pid": 43], identity: freshIdentity, role: .codex)
            XCTAssertTrue(fresh.allowsSampling)
            XCTAssertFalse(fresh.accepts(completedReply, identity: freshIdentity, role: .codex))
            XCTAssertTrue(fresh.accepts(freshReply, identity: freshIdentity, role: .codex))
            // Late callbacks on the old captured instance cannot seal the fresh one.
            lifetime.observeProcessInterruption()
            lifetime.observeKeepAliveCancellation()
            XCTAssertTrue(fresh.allowsSampling)
        }
    }

    func testRetirementRequestDoesNotManufactureTerminalReceipt() {
        let lifetime = NativeMemoryProcessLifetime()
        XCTAssertTrue(lifetime.allowsSampling)
        lifetime.requestRetirement()
        XCTAssertFalse(lifetime.allowsSampling)
        XCTAssertFalse(lifetime.observedProcessInterruption)
        XCTAssertFalse(lifetime.observedKeepAliveCancellation)
        lifetime.observeKeepAliveCancellation()
        XCTAssertFalse(lifetime.observedProcessInterruption, "transport cancellation is not a process-exit receipt")
        XCTAssertTrue(lifetime.observedKeepAliveCancellation)
    }

}


/// Synthetic callback ordering only; this does not manufacture an actual XPC or
/// process-exit event. It executes the same production seal acceptance predicate.
nonisolated private final class MemoryReplyOrderingFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NativeRuntimeReply, Never>?

    func value(onSuspended: @Sendable () -> Void) async -> NativeRuntimeReply {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            onSuspended()
        }
    }
    func complete(_ reply: NativeRuntimeReply) {
        let continuation = lock.withLock {
            let captured = self.continuation
            self.continuation = nil
            return captured
        }
        precondition(continuation != nil)
        continuation?.resume(returning: reply)
    }
}
