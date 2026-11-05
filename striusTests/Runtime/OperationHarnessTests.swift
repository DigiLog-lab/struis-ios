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
}
