import XCTest
import Foundation
import Darwin
@testable import strius

/// Synthetic test-owned files only. Uses the linked C ABI, not a fake broker.
final class WorkspaceOperationBrokerTests: XCTestCase {
    private func withFixture(_ body: (URL, URL, Int32) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = base.appendingPathComponent("workspace")
        let canary = base.appendingPathComponent("private/canary")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: canary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test-private-canary".utf8).write(to: canary)
        defer { try? FileManager.default.removeItem(at: base) }
        let fd = Darwin.open(workspace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(fd) }
        try body(workspace, canary, fd)
        XCTAssertEqual(try Data(contentsOf: canary), Data("test-private-canary".utf8))
    }
    private func denied(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let failure = error as? WorkspaceOperationBroker.Failure else {
                XCTFail("Expected sanitized C errno", file: file, line: line); return
            }
            XCTAssertEqual(failure.code, EACCES, file: file, line: line)
            XCTAssertFalse(failure.localizedDescription.contains("canary"), file: file, line: line)
            XCTAssertTrue(failure.localizedDescription.contains("active workspace"), file: file, line: line)
        }
    }

    func testConfiguredSparseFourGiBPolicyAndLiveRevocationUseActualCAPI() throws {
        try withFixture { workspace, _, fd in
            let extent: UInt64 = 4 * 1024 * 1024 * 1024
            let limits = try WorkspaceOperationBroker.DescriptorLimits(readExtent: extent, writeExtent: extent)
            let broker = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "configured-test", generation: 71, access: .readWrite, descriptorLimits: limits)
            defer { try? broker.destroy() }
            let policy = try broker.descriptorPolicy()
            XCTAssertTrue(policy.configured); XCTAssertEqual(policy.readExtent, extent); XCTAssertEqual(policy.writeExtent, extent)
            let handle = try broker.open("日本語-large.bin", options: [.read, .write, .create, .exclusive])
            try broker.truncate(handle, length: extent)
            XCTAssertEqual(try broker.stat(handle).bytes, extent)
            let binary = Data([0, 255, 42, 65])
            for offset in [UInt64(2 * 1024 * 1024 * 1024 + 3), extent - 4] {
                XCTAssertEqual(try broker.write(handle, offset: offset, data: binary), 4)
                XCTAssertEqual(try broker.read(handle, offset: offset, count: 4), binary)
            }
            XCTAssertEqual(try broker.read(handle, offset: extent - 4, count: 16), binary)
            XCTAssertEqual(try broker.read(handle, offset: extent, count: 16), Data())
            denied { _ = try broker.read(handle, offset: extent + 1, count: 1) }
            denied { _ = try broker.write(handle, offset: extent, data: Data([1])) }
            denied { try broker.truncate(handle, length: extent + 1) }
            var native = Darwin.stat()
            XCTAssertEqual(Darwin.lstat(workspace.appendingPathComponent("日本語-large.bin").path, &native), 0)
            XCTAssertEqual(native.st_size, Int64(extent))
            XCTAssertLessThan(UInt64(native.st_blocks) * 512, 1_048_576)
            let legacy = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "legacy-test", generation: 72, access: .readWrite)
            defer { try? legacy.destroy() }
            let legacyPolicy = try legacy.descriptorPolicy()
            XCTAssertFalse(legacyPolicy.configured); XCTAssertEqual(legacyPolicy.readExtent, 16_777_216); XCTAssertEqual(legacyPolicy.writeExtent, 16_777_216)
            denied { _ = try legacy.open("日本語-large.bin", options: .read) }
            denied { _ = try legacy.read(handle, offset: 0, count: 1) }
            try broker.revoke(); denied { _ = try broker.descriptorPolicy() }; denied { _ = try broker.read(handle, offset: 0, count: 1) }
            let fresh = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "configured-test", generation: 73, access: .readOnly, descriptorLimits: limits)
            defer { try? fresh.destroy() }
            let current = try fresh.open("日本語-large.bin", options: .read)
            XCTAssertEqual(try fresh.read(current, offset: extent - 4, count: 4), binary)
            denied { _ = try fresh.read(handle, offset: 0, count: 1) }
            try broker.destroy(); denied { _ = try broker.descriptorPolicy() }
        }
    }

    func testAsymmetricDescriptorBoundsAndStrictReadonlyPolicyEnvelope() throws {
        XCTAssertThrowsError(try WorkspaceOperationBroker.DescriptorLimits(readExtent: UInt64.max, writeExtent: 1))
        XCTAssertThrowsError(try WorkspaceOperationBroker.DescriptorLimits(readExtent: 1, writeExtent: 0))
        try withFixture { _, _, fd in
            let limits = try WorkspaceOperationBroker.DescriptorLimits(readExtent: 16, writeExtent: 64)
            let broker = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "asymmetric-test", generation: 74, access: .readWrite, descriptorLimits: limits)
            defer { try? broker.destroy() }
            let handle = try broker.open("asym", options: [.read, .write, .create])
            try broker.truncate(handle, length: 64)
            XCTAssertEqual(try broker.write(handle, offset: 63, data: Data([42])), 1)
            XCTAssertEqual(try broker.read(handle, offset: 15, count: 16), Data([0]))
            XCTAssertEqual(try broker.read(handle, offset: 16, count: 16), Data())
            denied { _ = try broker.read(handle, offset: 17, count: 1) }
            denied { _ = try broker.write(handle, offset: 64, data: Data([42])) }
            let dispatcher = VirtualFilesystemDispatcher(broker: broker)
            let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: dispatcher.execute(Data(#"{"sequence":1,"operation":"descriptorPolicy"}"#.utf8))) as? [String: Any])
            let policy = try XCTUnwrap(reply["policy"] as? [String: Any])
            XCTAssertEqual(policy["readExtent"] as? String, "16"); XCTAssertEqual(policy["writeExtent"] as? String, "64"); XCTAssertEqual(policy["configured"] as? Bool, true)
            for envelope in [#"{"sequence":2,"operation":"descriptorPolicy","readExtent":"9999999999"}"#, #"{"sequence":3,"operation":"descriptorPolicy","owner":"guest"}"#, #"{"sequence":4,"operation":"descriptorPolicy","operation":"open"}"#] {
                let denied = try XCTUnwrap(try JSONSerialization.jsonObject(with: dispatcher.execute(Data(envelope.utf8))) as? [String: Any])
                XCTAssertEqual(denied["errno"] as? String, "EINVAL")
            }
            try broker.revoke()
            let revoked = try XCTUnwrap(try JSONSerialization.jsonObject(with: dispatcher.execute(Data(#"{"sequence":5,"operation":"descriptorPolicy"}"#.utf8))) as? [String: Any])
            XCTAssertEqual(revoked["errno"] as? String, "EACCES")
            XCTAssertNil(revoked["policy"])
        }
    }

    func testJapaneseRandomIOCopyListingAndReadonlyUseActualCAPI() throws {
        try withFixture { _, _, fd in
            let broker = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "trusted-test", generation: 7, access: .readWrite)
            defer { try? broker.destroy() }
            try broker.mkdir("資料")
            let handle = try broker.open("資料/答案.bin", options: [.read, .write, .create, .exclusive])
            let binary = Data([0, 255, 10, 0, 42])
            XCTAssertEqual(try broker.write(handle, offset: 4, data: binary), binary.count)
            XCTAssertEqual(try broker.read(handle, offset: 0, count: 9), Data([0, 0, 0, 0]) + binary)
            XCTAssertEqual(try broker.stat(handle).bytes, 9)
            try broker.truncate(handle, length: 6)
            XCTAssertEqual(try broker.read(handle, offset: 4, count: 10), Data([0, 255]))
            try broker.close(handle)
            denied { _ = try broker.read(handle, offset: 0, count: 1) }
            try broker.copy("資料/答案.bin", to: "copy.bin")
            XCTAssertEqual(Set(try broker.list()), Set(["資料", "copy.bin"]))
            XCTAssertTrue(try broker.metadata("資料").isDirectory)
            XCTAssertEqual(try broker.metadata("copy.bin").bytes, 6)
            let readonly = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "trusted-ro", generation: 7, access: .readOnly)
            defer { try? readonly.destroy() }
            let reader = try readonly.open("copy.bin", options: .read)
            XCTAssertEqual(try readonly.read(reader, offset: 4, count: 2), Data([0, 255]))
            denied { _ = try readonly.write(reader, offset: 0, data: Data([1])) }
            denied { _ = try readonly.open("copy.bin", options: .write) }
            denied { try readonly.truncate(reader, length: 0) }
            denied { try readonly.mkdir("later") }
            denied { try readonly.copy("copy.bin", to: "other.bin") }
            denied { try readonly.remove("copy.bin") }
            try readonly.close(reader)
            try broker.remove("copy.bin")
            try broker.remove("資料", recursive: true)
            XCTAssertEqual(try broker.list(), [])
        }
    }

    func testPrivateEscapesForeignHandlesRevokeAndFreshInstance() throws {
        try withFixture { workspace, canary, fd in
            try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("outside"), withDestinationURL: canary.deletingLastPathComponent())
            try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("leaf"), withDestinationURL: canary)
            XCTAssertEqual(Darwin.link(canary.path, workspace.appendingPathComponent("hard").path), 0)
            let broker = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "trusted-a", generation: 8, access: .readWrite)
            defer { try? broker.destroy() }
            for path in [canary.path, "../private/canary", "outside/canary", "leaf", "hard"] {
                denied { _ = try broker.open(path, options: [.read, .write]) }
                denied { _ = try broker.metadata(path) }
                denied { try broker.copy(path, to: "stolen") }
            }
            denied { try broker.remove("../private/canary") }
            denied { try broker.mkdir("outside/new") }
            denied { _ = try broker.list("outside") }
            let handle = try broker.open("owned", options: [.read, .write, .create])
            XCTAssertEqual(try broker.write(handle, offset: 0, data: Data("first".utf8)), 5)
            let fresh = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "trusted-b", generation: 9, access: .readWrite)
            defer { try? fresh.destroy() }
            denied { _ = try fresh.read(handle, offset: 0, count: 1) }
            try broker.revoke()
            denied { _ = try broker.read(handle, offset: 0, count: 1) }
            denied { _ = try broker.open("owned", options: .read) }
            denied { try broker.mkdir("revoked") }
            denied { _ = try broker.metadata() }
            let next = try fresh.open("owned", options: [.read, .write])
            XCTAssertEqual(try fresh.read(next, offset: 0, count: 5), Data("first".utf8))
            XCTAssertEqual(try fresh.write(next, offset: 0, data: Data("next!".utf8)), 5)
            try fresh.close(next)
            try broker.destroy()
            try broker.destroy() // Swift lifecycle shutdown is idempotent.
            denied { _ = try broker.list() }
        }
    }

    func testConcurrentReadAndDestroySerializePointerLifetime() throws {
        try withFixture { _, _, fd in
            let broker = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "trusted-race", generation: 10, access: .readWrite)
            let handle = try broker.open("active", options: [.read, .write, .create])
            XCTAssertEqual(try broker.write(handle, offset: 0, data: Data([42])), 1)
            let started = DispatchSemaphore(value: 0)
            let done = DispatchSemaphore(value: 0)
            let result = RaceResult()
            DispatchQueue.global().async {
                defer { done.signal() }
                do {
                    guard try broker.read(handle, offset: 0, count: 1) == Data([42]) else { result.record(EIO); started.signal(); return }
                    started.signal()
                    for _ in 0..<10_000 { _ = try broker.read(handle, offset: 0, count: 1) }
                } catch let failure as WorkspaceOperationBroker.Failure { result.record(failure.code) }
                catch { result.record(EIO) }
            }
            XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
            try broker.destroy()
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            XCTAssertTrue(result.code == nil || result.code == EACCES)
            denied { _ = try broker.read(handle, offset: 0, count: 1) }
            let fresh = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "trusted-next", generation: 11, access: .readWrite)
            defer { try? fresh.destroy() }
            let next = try fresh.open("active", options: .read)
            XCTAssertEqual(try fresh.read(next, offset: 0, count: 1), Data([42]))
            try fresh.close(next)
        }
    }
}

private final class RaceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var code: Int32? { lock.lock(); defer { lock.unlock() }; return value }
    func record(_ code: Int32) { lock.lock(); defer { lock.unlock() }; value = code }
}
