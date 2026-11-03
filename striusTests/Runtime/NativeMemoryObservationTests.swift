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
        let sample = NativeMemoryObservation(snapshot: ["pid": 42, "footprint": 7, "lifetimePeak": 11], identity: "old-fixture", role: .exec)
        var reply = NativeRuntimeReply(pid: 42, workerID: "old-fixture")
        reply.memoryObservation = sample
        XCTAssertTrue(sample.matches(reply: reply, identity: "old-fixture", role: .exec))
        XCTAssertFalse(sample.matches(reply: reply, identity: "new-fixture", role: .exec))
        XCTAssertFalse(sample.matches(reply: reply, identity: "old-fixture", role: .host))
        reply.workerID = "new-fixture"
        XCTAssertFalse(sample.matches(reply: reply, identity: "old-fixture", role: .exec))
        reply.workerID = "old-fixture"
        reply.pid = 43
        XCTAssertFalse(sample.matches(reply: reply, identity: "old-fixture", role: .exec))
        reply.pid = 42
        reply.error = "fixture failure"
        XCTAssertFalse(sample.matches(reply: reply, identity: "old-fixture", role: .exec))
    }
}

