import XCTest
@testable import strius

final class OperationHarnessTests: XCTestCase {
    @MainActor
    func testRejectedToolResultExplainsAllowedAlternativeAndKeepsTurnUsable() async throws {
        let router = NativeToolRouter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = await router.register(threadID: "thread", planID: "plan", cwd: root.path, delegate: { _ in ["result": "permitted lookup"] })
        await router.setTurn(threadID: "thread", turnID: "turn", registration: registration)
        let secretPath = root.deletingLastPathComponent().appendingPathComponent("private-canary").path
        let (reply, execution) = try await router.handle([
            "threadId": "thread", "turnId": "turn", "callId": "denied-call", "tool": "exec_command",
            "arguments": ["cmd": "cat private-canary", "workdir": secretPath],
        ])
        XCTAssertEqual(reply["success"] as? Bool, false)
        let items = try XCTUnwrap(reply["contentItems"] as? [JSONObject])
        let text = try XCTUnwrap(items.first?["text"] as? String)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSONObject)
        let error = try XCTUnwrap(payload["error"] as? JSONObject)
        XCTAssertEqual(error["code"] as? String, "operation_not_permitted")
        XCTAssertTrue(text.contains("struis_delegate"))
        XCTAssertFalse(text.contains(secretPath))
        let item = try XCTUnwrap(execution?["item"] as? JSONObject)
        XCTAssertEqual(item["status"] as? String, "failed")
        XCTAssertTrue(item["exitCode"] is NSNull, "No process ran; do not invent an exit code")
        XCTAssertEqual(item["id"] as? String, "denied-call")
        let (next, _) = try await router.handle([
            "threadId": "thread", "turnId": "turn", "callId": "lookup-call", "tool": "struis_delegate", "arguments": [:],
        ])
        XCTAssertEqual(next["success"] as? Bool, true, "An allowed next tool remains usable in the same turn")
        await router.unregister(threadID: "thread", registration: registration)
        do {
            _ = try await router.handle(["threadId": "thread", "turnId": "turn", "tool": "exec_command", "arguments": ["cmd": "true"]])
            XCTFail("A stale context must not get a policy response or execute")
        } catch {}
        print("NATIVE_TOOL_POLICY_RESULT denied=true audit_failed=true path_disclosed=false same_turn_lookup=true")
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Real pinned AppServer RPC and real descriptor operations against the production workspace
    /// capability: Codex runs in the app process, so the canary sits beside the Ledger directory.
    @MainActor
    func testRealAppServerFilesystemRejectsPrivatePathsAndRemainsResponsive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1", "native Simulator integration is opt-in")
        let boot = HyotanBoot()
        await boot.start()
        let directory = HyotanBoot.workspaceRoot.appendingPathComponent("harness-rpc-" + UUID().uuidString)
        let privateDirectory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Struis", isDirectory: true)
        try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true)
        let outside = privateDirectory.appendingPathComponent("harness-private-" + UUID().uuidString)
        // A synthetic file beside Codex's auth, never the real credential.
        try FileManager.default.createDirectory(at: HyotanBoot.codexHome, withIntermediateDirectories: true)
        let codexCanary = HyotanBoot.codexHome.appendingPathComponent("harness-canary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("private-canary".utf8).write(to: outside)
        try Data("codex-canary".utf8).write(to: codexCanary)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
            try? FileManager.default.removeItem(at: codexCanary)
        }
        let link = directory.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let file = directory.appendingPathComponent("日本語.txt")
        let expected = Data("許可された操作".utf8)
        let session = CodexAppServerSession(clientVersion: "native-harness-rpc", launcher: CodexAppServerSession.nativeLauncher(boot: boot))
        do {
            try await session.start()
            let generation = await session.generation
            _ = try await session.request("fs/writeFile", params: ["path": file.path, "dataBase64": expected.base64EncodedString()])
            let response = try await session.request("fs/readFile", params: ["path": file.path])
            XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(response["dataBase64"] as? String)), expected)
            let parent = directory.appendingPathComponent("..").appendingPathComponent("..").path
            for path in [outside.path, link.path, codexCanary.path, parent] {
                for method in ["fs/readFile", "fs/writeFile", "fs/getMetadata", "fs/remove"] {
                    var params: JSONObject = ["path": path]
                    if method == "fs/writeFile" { params["dataBase64"] = Data("forbidden".utf8).base64EncodedString() }
                    if method == "fs/remove" { params["force"] = false; params["recursive"] = false }
                    do {
                        _ = try await session.request(method, params: params)
                        XCTFail("Forbidden final operation succeeded: \(method)")
                    } catch let error as CodexAppServerError {
                        guard case .rpc(_, let message) = error else { throw error }
                        XCTAssertTrue(message.contains("denied"), "Must explain policy denial: \(message)")
                        XCTAssertFalse(message.contains(outside.path), "Do not disclose a private path in denial")
                    }
                }
            }
            XCTAssertEqual(try Data(contentsOf: outside), Data("private-canary".utf8))
            XCTAssertEqual(try Data(contentsOf: codexCanary), Data("codex-canary".utf8))
            XCTAssertEqual(try Data(contentsOf: file), expected)
            _ = try await session.request("account/read", params: ["refreshToken": false])
            let after = await session.generation
            XCTAssertEqual(after, generation)
            print("NATIVE_APPSERVER_HARNESS_RPC in_process=true allowed_rw=true denied_private_symlink_parent_codex_home=true canary_unchanged=true account_read=true same_generation=true simulator=true")
        } catch {
            await session.close()
            NativeRuntimeHost.shared.stop()
            await NativeRuntimeHost.shared.waitForRetirement()
            throw error
        }
        await session.close()
        NativeRuntimeHost.shared.stop()
        await NativeRuntimeHost.shared.waitForRetirement()
    }
    #endif
}
