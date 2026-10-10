import XCTest
@testable import strius

/// 実機のワーカーは containermanagerd を引けないので、ホストが渡す App Group のパスを使う。
/// 渡されたパスは、この App Group の `Runtime` だけを受け入れる。
final class WorkerRootTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("worker-root-\(UUID().uuidString)/Shared/AppGroup")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func container(group: String?) throws -> URL {
        let root = base.appendingPathComponent(UUID().uuidString).appendingPathComponent("Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let group {
            let plist = try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": group], format: .xml, options: 0)
            try plist.write(to: root.deletingLastPathComponent().appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist"))
        }
        return root
    }

    func testAcceptsThisAppGroupsRuntime() throws {
        let root = try container(group: NativeRuntimePaths.group)
        let real = try XCTUnwrap(realpath(root.path, nil)); defer { free(real) } // the same real path F_GETPATH reports
        XCTAssertEqual(NativeRuntimePaths.workerRoot(hostPath: root.path)?.path, String(cString: real))
    }

    func testRejectsAnotherAppGroup() throws {
        let root = try container(group: "group.example.other")
        XCTAssertNil(NativeRuntimePaths.workerRoot(hostPath: root.path))
    }

    func testRejectsPathsOutsideAnAppGroupRuntime() throws {
        let root = try container(group: NativeRuntimePaths.group)
        XCTAssertNil(NativeRuntimePaths.workerRoot(hostPath: root.deletingLastPathComponent().path))
        XCTAssertNil(NativeRuntimePaths.workerRoot(hostPath: root.appendingPathComponent("../Library/Runtime").path))
        XCTAssertNil(NativeRuntimePaths.workerRoot(hostPath: FileManager.default.temporaryDirectory.appendingPathComponent("Runtime").path))
    }

    func testRejectsASymlinkedRuntimeThatLeadsOutside() throws {
        let root = try container(group: NativeRuntimePaths.group)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("worker-root-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        XCTAssertNil(NativeRuntimePaths.workerRoot(hostPath: root.path))
    }

    /// Without readable metadata the Simulator never guesses; the device accepts only the system store.
    func testRejectsAnAppGroupShapedPathWithoutMetadata() throws {
        let root = try container(group: nil)
        XCTAssertNil(NativeRuntimePaths.workerRoot(hostPath: root.path))
    }

    func testFallsBackToTheLookupWithoutAHostPath() {
        XCTAssertEqual(NativeRuntimePaths.workerRoot(hostPath: nil), NativeRuntimePaths.sharedRoot)
    }
}
