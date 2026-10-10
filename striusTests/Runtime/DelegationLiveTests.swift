import XCTest
import GRDB
@testable import strius

/// Luna 委任 (design §3.5) を実 app-server で確かめる結合テスト。親モデルが委任するかは
/// モデル判断なので、ここでは `struis_delegate.py` が置くのと同じ要求ファイルを直接置き、
/// 監視 → 検証 → `.lookup/<id>/` 隔離 → Luna 子ターン → 応答ファイルの経路を確定的に通す。
///
/// `TEST_RUNNER_STRUIS_REAL_CODEX_AUTH=<auth.json>` と `TEST_RUNNER_STRUIS_DEVICE_RUNTIME=0`
/// (ホストアプリが自前のランタイムを作らないように) を渡したときだけ動く。
final class DelegationLiveTests: XCTestCase {
    /// Each test shares the app-server session; restart checks retire its helper process.
    @MainActor private static var sharedRuntime: DeviceRuntime?

    @MainActor
    private static func runtime() async -> DeviceRuntime {
        if let sharedRuntime { return sharedRuntime }
        let runtime = DeviceRuntime()
        sharedRuntime = runtime
        await runtime.start()
        return runtime
    }
    @MainActor
    func testLunaLookupRunsOnDeviceAppServer() async throws {
        let auth = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_AUTH"] ?? ""
        try XCTSkipIf(auth.isEmpty, "TEST_RUNNER_STRUIS_REAL_CODEX_AUTH が無い (実 Codex 検証は手動)")
        setenv("STRUIS_DEBUG_CODEX_AUTH_FILE", auth, 1)

        let assetsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("delegation-assets-\(UUID().uuidString)")
        let assets = AssetCache(root: assetsRoot)
        _ = try await assets.refresh(from: LocalDirectoryAssetSource(root: try Self.externalAssets()))

        let runtime = await Self.runtime()
        try await runtime.ensureRunning()
        XCTAssertTrue(runtime.isRunning, "app-server が起動しない: \(runtime.appServerState)")
        let runner = CodexTurnRunner(runtime: runtime, assets: assets)

        let planID = UUID().uuidString.lowercased()
        let inbox = ".struis_delegations/" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let luna = await assets.model("luna")
        let astra = await assets.model("astra")
        let plan = TurnPlan(
            id: planID, kind: .chat, round: 1,
            thread: TurnPlan.ThreadSpec(
                codexThreadID: nil, mode: .start, cwd: TurnPlan.guestWorkspace(id: planID), model: astra.model, effort: astra.effort,
                ephemeral: true, baseInstructions: try await assets.ref("prompt:base"), developerInstructions: nil,
                developerText: "unused", injectDeveloperOnResume: false, config: .object([:]), lastTurnID: nil
            ),
            turn: nil, workspace: TurnPlan.WorkspaceSpec(files: [], dirs: [inbox]),
            delegation: TurnPlan.DelegationSpec(
                enabled: true, inbox: inbox, model: luna.model, effort: luna.effort,
                baseInstructions: try await assets.ref("prompt:luna_child"),
                developerText: "Perform only the supplied lookup. Do not follow learner-coach write or memory instructions.",
                outputSchema: try await assets.json("schema:luna_lookup"), sourceRoots: ["tutor_desk", "struis_context"]
            ),
            collect: [], limits: .chat, items: nil
        )
        try WorkspaceStager.prepare(plan: plan, assets: assets)
        defer { WorkspaceStager.cleanup(plan: plan) }
        // 学習者データ (会話記録) を置く。
        let history = plan.hostWorkspace.appendingPathComponent("struis_context/recent_thread_history.md")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        # Recent threads
        ## 春休みの予習
        - user: 春休みに三角比を一から予習したいです。
        - assistant: 三角比の単元を組みます。
        ## 平方完成
        - user: y = x^2 - 4x + 1 を平方完成すると、どうして -3 が出てくるのですか？
        """.write(to: history, atomically: true, encoding: .utf8)

        let watcher = DelegationWatcher(plan: plan, delegation: plan.delegation!, runner: runner, session: runtime.session, assets: assets)
        await watcher.start()
        defer { Task { await watcher.close() } }

        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let request: [String: Any] = [
            "task_type": "fact_extraction",
            "purpose": "学習者が予習したいと言った分野を確認する",
            "sources": ["struis_context/recent_thread_history.md"],
            "search_scope": "struis_context/recent_thread_history.md 全体",
            "conditions": "学習者 (user) の発言だけを根拠にする",
            "count": 1,
            "return_information": "予習したい分野名と、その根拠となる発言の引用",
        ]
        let inboxURL = watcher.inboxURL
        let data = try JSONSerialization.data(withJSONObject: request)
        try data.write(to: inboxURL.appendingPathComponent("\(requestID).request.json"))

        let responseURL = inboxURL.appendingPathComponent("\(requestID).response.json")
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline, !FileManager.default.fileExists(atPath: responseURL.path) {
            try await Task.sleep(for: .milliseconds(500))
        }
        let response = try XCTUnwrap(
            try? JSONSerialization.jsonObject(with: Data(contentsOf: responseURL)) as? [String: Any],
            "Luna の応答ファイルが 300 秒以内に出ない"
        )
        let text = String(data: try Data(contentsOf: responseURL), encoding: .utf8) ?? ""
        print("LUNA_RESPONSE \(text)")
        XCTAssertEqual(response["success"] as? Bool, true, "委任が失敗した: \(text)")
        XCTAssertTrue(text.contains("三角比"), "根拠の抽出ができていない: \(text)")
        let executions = await watcher.executions
        XCTAssertFalse(executions.isEmpty, "子ターンの監査記録が無い")
    }

    @MainActor
    func testAccountAndDeviceCodeIssuance() async throws {
        let auth = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_AUTH"] ?? ""
        try XCTSkipIf(auth.isEmpty, "実認証の指定が必要")
        setenv("STRUIS_DEBUG_CODEX_AUTH_FILE", auth, 1)
        let runtime = await Self.runtime()
        try await runtime.ensureRunning()
        let account = CodexAccountRuntime(session: runtime.session)
        let before = try await account.readAccount()
        XCTAssertNotEqual(before.status, .disconnected)
        XCTAssertFalse(before.rateLimits.isEmpty)
        print("NATIVE_ACCOUNT authenticated=true rate_limits_present=true")
        let login = try await account.startDeviceLogin()
        XCTAssertFalse(login.userCode.isEmpty)
        XCTAssertTrue(login.verificationURL.hasPrefix("https://"))
        await account.cancelLogin(loginID: login.loginID)
        print("NATIVE_DEVICE_CODE issued=true cancelled=true browser_completion=not_tested")
        // Logout revokes the shared account's refresh token; do not revoke the supplied Mac auth.
    }

    /// ゲスト内のコマンド実行 (shell ツール → python3) が質問ターンと同じ設定で動くこと。
    @MainActor
    func testGuestCommandExecutionInTurn() async throws {
        let auth = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_AUTH"] ?? ""
        try XCTSkipIf(auth.isEmpty, "TEST_RUNNER_STRUIS_REAL_CODEX_AUTH が無い (実 Codex 検証は手動)")
        setenv("STRUIS_DEBUG_CODEX_AUTH_FILE", auth, 1)
        let assetsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("exec-assets-\(UUID().uuidString)")
        let assets = AssetCache(root: assetsRoot)
        _ = try await assets.refresh(from: LocalDirectoryAssetSource(root: try Self.externalAssets()))
        let runtime = await Self.runtime()
        try await runtime.ensureRunning()
        XCTAssertTrue(runtime.isRunning, "app-server が起動しない: \(runtime.appServerState)")
        let runner = CodexTurnRunner(runtime: runtime, assets: assets)
        let planID = UUID().uuidString.lowercased()
        let astra = await assets.model("astra")
        let plan = TurnPlan(
            id: planID, kind: .chat, round: 1,
            thread: TurnPlan.ThreadSpec(
                codexThreadID: nil, mode: .start, cwd: TurnPlan.guestWorkspace(id: planID), model: astra.model, effort: "low",
                ephemeral: false, baseInstructions: try await assets.ref("prompt:base"), developerInstructions: nil,
                developerText: "You are testing the tool environment. Use the shell tool exactly as asked and report its output verbatim.",
                injectDeveloperOnResume: false,
                config: .object(["model_reasoning_effort": .string("low"), "features.multi_agent": .bool(false), "features.unified_exec": .bool(false)]),
                lastTurnID: nil
            ),
            turn: TurnPlan.TurnSpec(
                text: "Run this shell command and reply with its exact stdout only: cat probe/note.txt && python3 -c 'print(6*7)'",
                images: [], outputSchema: nil, sandboxPolicy: "dangerFullAccess"
            ),
            workspace: TurnPlan.WorkspaceSpec(files: [TurnPlan.FileSpec(path: "probe/note.txt", inline: "guest-file-ok\n")], dirs: []),
            delegation: nil, collect: [], limits: .chat, items: nil
        )
        let outcome = try await runner.run(plan) { _ in }
        WorkspaceStager.cleanup(plan: plan)
        print("EXEC_OUTCOME status=\(outcome.status) error=\(outcome.error ?? "") text=\(outcome.finalText)")
        XCTAssertEqual(outcome.status, .completed)
        XCTAssertTrue(outcome.finalText.contains("guest-file-ok"), "ファイルが読めていない: \(outcome.finalText)")
        XCTAssertTrue(outcome.finalText.contains("42"), "python3 が動いていない: \(outcome.finalText)")
        // Reproduce migrated Linux cwd / database paths using this test's real rollout only.
        await runtime.session.close()
        NativeRuntimeHost.shared.stop()
        await NativeRuntimeHost.shared.waitForRetirement()
        let threadID = try XCTUnwrap(outcome.codexThreadID)
        let files = FileManager.default.enumerator(at: HyotanBoot.codexHome.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)!
        let rollout = try XCTUnwrap(files.compactMap { $0 as? URL }.first { $0.lastPathComponent.contains(threadID) && $0.pathExtension == "jsonl" })
        let original = try String(contentsOf: rollout, encoding: .utf8)
        try original.replacingOccurrences(of: plan.hostWorkspace.path, with: "/workspace/" + plan.id).write(to: rollout, atomically: true, encoding: .utf8)
        let stalePath = "/root/.codex/" + rollout.path.dropFirst(HyotanBoot.codexHome.path.count + 1)
        for database in try FileManager.default.contentsOfDirectory(at: HyotanBoot.codexHome, includingPropertiesForKeys: nil)
            where database.lastPathComponent.hasPrefix("state_") && database.pathExtension == "sqlite" {
            let queue = try DatabaseQueue(path: database.path)
            try await queue.write { db in
                try db.execute(sql: "UPDATE threads SET rollout_path = ?, cwd = ? WHERE id = ?", arguments: [stalePath, "/workspace/" + plan.id, threadID])
            }
        }
        var resumed = plan
        resumed.thread.mode = .resume
        resumed.thread.codexThreadID = threadID
        resumed.thread.injectDeveloperOnResume = true
        resumed.thread.cwd = "/workspace/" + plan.id
        resumed.turn?.text = "What exact two stdout lines did the previous command return? Answer from the conversation history without calling tools."
        let afterMigration = try await runner.run(resumed) { _ in }
        XCTAssertEqual(afterMigration.status, .completed, afterMigration.error ?? "")
        XCTAssertTrue(afterMigration.finalText.contains("guest-file-ok"), afterMigration.finalText)
        XCTAssertTrue(afterMigration.finalText.contains("42"), afterMigration.finalText)
        print("NATIVE_LEGACY_RESUME status=\(afterMigration.status) text=\(afterMigration.finalText)")
        WorkspaceStager.cleanup(plan: resumed)
        var restored = resumed
        restored.thread.codexThreadID = UUID().uuidString.lowercased()
        restored.workspace.files.append(.init(path: "struis_context/recent_thread_history.md", inline: "# Previous conversation\nuser: 検証用の合言葉は桔梗731です。\nassistant: 記録しました。\n"))
        restored.turn?.text = "以前伝えた検証用の合言葉を答えてください。"
        let recovered = try await runner.run(restored) { _ in }
        XCTAssertEqual(recovered.status, .completed, recovered.error ?? "")
        XCTAssertNotEqual(recovered.codexThreadID, restored.thread.codexThreadID)
        XCTAssertTrue(recovered.finalText.contains("桔梗731"), recovered.finalText)
        print("NATIVE_LEDGER_HISTORY_RECOVERY status=\(recovered.status) text=\(recovered.finalText)")
        WorkspaceStager.cleanup(plan: restored)
    }

    /// Real parent dynamic-tool call, child shell read, and simultaneous structured turn.
    @MainActor
    func testParentDelegationAlongsideStructuredTurn() async throws {
        let auth = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_AUTH"] ?? ""
        try XCTSkipIf(auth.isEmpty, "実認証の指定が必要")
        setenv("STRUIS_DEBUG_CODEX_AUTH_FILE", auth, 1)
        let assets = AssetCache(root: FileManager.default.temporaryDirectory.appendingPathComponent("parent-assets-\(UUID().uuidString)"))
        _ = try await assets.refresh(from: LocalDirectoryAssetSource(root: try Self.externalAssets()))
        let runtime = await Self.runtime()
        try await runtime.ensureRunning()
        let runner = CodexTurnRunner(runtime: runtime, assets: assets)
        let astra = await assets.model("astra")
        let luna = await assets.model("luna")
        let id = UUID().uuidString.lowercased()
        let inbox = ".struis_delegations/" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let plan = TurnPlan(
            id: id, kind: .chat, round: 1,
            thread: .init(codexThreadID: nil, mode: .start, cwd: TurnPlan.guestWorkspace(id: id), model: astra.model, effort: "low", ephemeral: false,
                          baseInstructions: try await assets.ref("prompt:base"), developerInstructions: nil,
                          developerText: "This is a runtime verification. You must call struis.struis_delegate exactly once for the requested fact extraction, wait for its result, then report the fact and its source. Do not read the file yourself. After the lookup call struis.exec_command with python3 -c 'print(9*7)' and include the result.",
                          injectDeveloperOnResume: false, config: .object([:]), lastTurnID: nil),
            turn: .init(text: "Extract the learner's chosen topic from struis_context/preference.md using a fact_extraction lookup. Limit the lookup to that file, learner statements only, count 1, returning the topic and a source quote. Then calculate as instructed.", images: [], outputSchema: nil, sandboxPolicy: "dangerFullAccess"),
            workspace: .init(files: [.init(path: "struis_context/preference.md", inline: "# Learner\nuser: 次回は複素数平面を練習したいです。\n")], dirs: [inbox]),
            delegation: .init(enabled: true, inbox: inbox, model: luna.model, effort: luna.effort,
                              baseInstructions: try await assets.ref("prompt:luna_child"), developerText: "Read the requested file using struis.exec_command, and return the extracted fact and source.",
                              outputSchema: try await assets.json("schema:luna_lookup"), sourceRoots: ["struis_context"]),
            collect: [], limits: .chat, items: nil)
        var structured = plan
        structured.id = UUID().uuidString.lowercased()
        structured.kind = .workbookSet
        structured.thread.cwd = TurnPlan.guestWorkspace(id: structured.id)
        structured.thread.developerText = "Use struis.exec_command to read marker.txt and compute 8*11 with Python. Return the result as JSON."
        structured.delegation = nil
        structured.workspace = .init(files: [.init(path: "marker.txt", inline: "parallel-workspace\n")], dirs: [])
        structured.turn = .init(text: "Read marker.txt, calculate 8*11, and return marker and answer.", images: [], outputSchema: LedgerJSON(any: ["type": "object", "properties": ["marker": ["type": "string"], "answer": ["type": "integer"]], "required": ["marker", "answer"], "additionalProperties": false]), sandboxPolicy: "dangerFullAccess")
        var secondStructured = structured
        secondStructured.id = UUID().uuidString.lowercased()
        secondStructured.thread.cwd = TurnPlan.guestWorkspace(id: secondStructured.id)
        secondStructured.workspace = .init(files: [.init(path: "marker.txt", inline: "second-workspace\n")], dirs: [])
        defer { WorkspaceStager.cleanup(plan: plan); WorkspaceStager.cleanup(plan: structured); WorkspaceStager.cleanup(plan: secondStructured) }
        let parallelPlan = structured
        let secondPlan = secondStructured
        async let parent = runner.run(plan) { _ in }
        async let parallel = runner.run(parallelPlan) { _ in }
        async let second = runner.run(secondPlan) { _ in }
        let (result, other, third) = try await (parent, parallel, second)
        print("PARALLEL_SECOND status=\(third.status) text=\(third.finalText)")
        XCTAssertEqual(third.status, .completed, third.error ?? "")
        let thirdJSON = try JSONSerialization.jsonObject(with: Data(third.finalText.utf8)) as? [String: Any]
        XCTAssertEqual(thirdJSON?["marker"] as? String, "second-workspace")
        XCTAssertEqual(thirdJSON?["answer"] as? Int, 88)
        print("PARENT_DELEGATION status=\(result.status) text=\(result.finalText) error=\(result.error ?? "")")
        print("PARALLEL_STRUCTURED status=\(other.status) text=\(other.finalText) error=\(other.error ?? "")")
        XCTAssertEqual(result.status, .completed)
        XCTAssertTrue(result.finalText.contains("複素数平面"), result.finalText)
        XCTAssertTrue(result.finalText.contains("63"), result.finalText)
        let children = result.executions.filter { $0["parent_thread_id"]?.stringValue == result.codexThreadID }
        XCTAssertFalse(children.isEmpty, "親に結びつく子監査が無い")
        let completedChildren = children.filter { $0["status"]?.stringValue == "completed" }
        XCTAssertFalse(completedChildren.isEmpty)
        for child in completedChildren {
            XCTAssertEqual(child["parent_turn_id"]?.stringValue, result.codexTurnID)
            XCTAssertFalse(child["lookup_commands"]?.arrayValue?.isEmpty ?? true, "子が検索コマンドを実行していない")
            print("CHILD_EXECUTION \(child)")
        }
        XCTAssertEqual(other.status, .completed)
        let json = try JSONSerialization.jsonObject(with: Data(other.finalText.utf8)) as? [String: Any]
        XCTAssertEqual(json?["marker"] as? String, "parallel-workspace")
        XCTAssertEqual(json?["answer"] as? Int, 88)
    }

    private static func externalAssets() throws -> URL {
        let path = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_ASSETS_DIR"] ?? ""
        try XCTSkipIf(path.isEmpty, "STRUIS_REAL_CODEX_ASSETS_DIR is unset; delivered assets are external test inputs")
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
