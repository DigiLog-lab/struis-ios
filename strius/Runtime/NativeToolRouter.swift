import Foundation

actor NativeToolRouter {
    struct Context {
        let registration: UUID
        let planID: String
        let cwd: String
        let delegate: (@Sendable (JSONObject) async throws -> JSONObject)?
        var turnID: String?
    }
    private var contexts: [String: Context] = [:]
    private var cancelled: Set<String> = []

    nonisolated static let instructions = "Call struis.exec_command and struis.struis_delegate directly. The code-mode exec host is unavailable on iOS. Use POSIX dash commands or embedded Python; Python cannot launch OS subprocesses. Use struis.struis_delegate for private lookups, never a shell command that waits for a child."
    nonisolated static let lookupInstructions = "Read and search the supplied files with struis.exec_command directly. The code-mode host is unavailable. Use POSIX shell commands, rg or embedded Python. Perform this lookup yourself; do not delegate again."

    nonisolated static var lookupDefinitions: [JSONObject] {
        var namespace = definitions[0]
        namespace["tools"] = (namespace["tools"] as? [JSONObject])?.filter { ["exec_command", DocumentTool.name].contains($0["name"] as? String) }
        return [namespace]
    }

    nonisolated static func configuration(_ original: JSONObject) -> JSONObject {
        var config = original
        config["features.code_mode"] = ["enabled": false, "direct_only_tool_namespaces": ["struis"]]
        // Codex 同梱の Skills(画像生成・Skill のインストールなど)は学習に関係なく、一覧が毎スレッド入るだけなので外す。
        // Struis の Skill は作業フォルダの `.agents/skills` に置く(配信Skillの説明)。
        config["skills.bundled.enabled"] = false
        // ChatGPT の Apps(コネクタ)と Plugins は Struis では使わない。Apps は既定で有効で、ChatGPT にサインインしていると
        // Codex が `codex_apps` MCP サーバーをつなぎ、アカウントの全コネクタの tool 定義を毎要求に入れる。
        // Claude のモデルは Codex に未知で `supports_search_tool` が false のため、定義が遅延(名前だけ)されず
        // 全文が送られ、1 要求あたり約 19 万トークン(2026-10-16 の実機の台帳: 要約の要求 5 万に対し通常の要求 25 万)になった。
        config["features.apps"] = false
        config["features.plugins"] = false
        config["features.tool_suggest"] = false
        return config
    }

    nonisolated static var definitions: [JSONObject] {
        [["type": "namespace", "name": "struis", "description": "Native workspace commands and private material lookup.", "tools": [
            ["type": "function", "name": "exec_command", "description": "Run a POSIX shell command in this turn's workspace. Python 3 is embedded. Use struis_delegate for private lookups; never wait for a child in a shell command.",
             "inputSchema": ["type": "object", "properties": ["cmd": ["type": "string"], "workdir": ["type": "string"]], "required": ["cmd"], "additionalProperties": false]],
            ["type": "function", "name": "struis_delegate", "description": "Request a bounded private material lookup. Waits asynchronously without occupying the shell.",
             "inputSchema": ["type": "object", "properties": ["task_type": ["type": "string"], "purpose": ["type": "string"], "sources": ["type": "array", "items": ["type": "string"]], "search_scope": ["type": "string"], "conditions": ["type": "string"], "count": ["type": "integer"], "return_information": ["type": "string"]], "required": ["task_type", "purpose", "sources", "search_scope", "conditions", "count", "return_information"], "additionalProperties": false]],
            DocumentTool.definition,
        ]]]
    }
    /// ターンの種類ごとの native tool。タイムラインのターンだけ、台帳に問い合わせる `timeline_query` を足す
    /// (出題と採点で同じ定義にして、キャッシュの先頭を揃える)。
    nonisolated static func definitions(for kind: TurnPlan.Kind) -> [JSONObject] {
        guard TimelineTurns.isTimeline(kind) else { return definitions }
        var namespace = definitions[0]
        namespace["tools"] = (namespace["tools"] as? [JSONObject] ?? []) + [TimelineGraph.toolDefinition]
        return [namespace]
    }

    func register(threadID: String, planID: String, cwd: String, delegate: (@Sendable (JSONObject) async throws -> JSONObject)?) -> UUID {
        let registration = UUID()
        contexts[threadID] = Context(registration: registration, planID: planID, cwd: cwd, delegate: delegate)
        cancelled.remove(planID)
        return registration
    }
    func setTurn(threadID: String, turnID: String, registration: UUID) {
        guard contexts[threadID]?.registration == registration else { return }
        contexts[threadID]?.turnID = turnID
    }
    func unregister(threadID: String, registration: UUID) {
        guard contexts[threadID]?.registration == registration else { return }
        contexts[threadID] = nil
    }
    func cancel(planID: String) async {
        let owners = contexts.values.filter { $0.planID == planID || $0.planID.hasPrefix(planID + ":") }
        for context in owners {
            cancelled.insert(context.planID)
            _ = try? await NativeRuntimeHost.shared.send(NativeRuntimeRequest(operation: .interrupt, owner: context.registration.uuidString))
        }
    }
    func handle(_ params: JSONObject) async throws -> (JSONObject, JSONObject?) {
        guard let threadID = params["threadId"] as? String else { throw CodexAppServerError.interrupted }
        guard let registration = contexts[threadID]?.registration else { throw CodexAppServerError.interrupted }
        // Notifications can be delivered before the awaiting runner processes turn/start.
        // Wait for that exact registration instead of accepting an unbound turn ID.
        for _ in 0..<500 {
            guard contexts[threadID]?.registration == registration else { throw CodexAppServerError.interrupted }
            if contexts[threadID]?.turnID != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let turnID = params["turnId"] as? String,
              let context = contexts[threadID], !cancelled.contains(context.planID),
              context.turnID == turnID,
              let name = params["tool"] as? String, let arguments = params["arguments"] as? JSONObject
        else { throw CodexAppServerError.interrupted }
        let result: JSONObject
        var execution: JSONObject?
        if name == "struis_delegate", let delegate = context.delegate {
            result = try await delegate(arguments)
        } else if name == "exec_command", let command = arguments["cmd"] as? String {
            let root = URL(fileURLWithPath: context.cwd).resolvingSymlinksInPath()
            let cwd = arguments["workdir"] as? String ?? context.cwd
            let resolved = URL(fileURLWithPath: cwd, relativeTo: root).resolvingSymlinksInPath()
            guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
                return denied(params, message: "This operation is not permitted: the working directory is outside this turn's workspace. Use a directory inside the supplied workspace. Use struis_delegate for private material lookups.")
            }
            // Reject the obsolete blocking delegation entry point rather than deadlock the child.
            guard !command.contains("struis_delegate.py") else { throw CodexAppServerError.malformed("Use the struis_delegate tool") }
            let start = Date()
            let reply = try await NativeRuntimeHost.shared.send(NativeRuntimeRequest(operation: .command, command: command, cwd: resolved.path, owner: context.registration.uuidString))
            guard !cancelled.contains(context.planID), contexts[threadID]?.registration == context.registration else { throw CodexAppServerError.interrupted }
            result = ["output": reply.output, "exit_code": reply.exitCode, "cwd": resolved.path, "truncated": reply.truncated]
            execution = ["threadId": threadID, "turnId": turnID, "item": ["type": "commandExecution", "id": params["callId"] ?? UUID().uuidString, "command": command, "cwd": resolved.path, "exitCode": reply.exitCode, "durationMs": Int(Date().timeIntervalSince(start) * 1000), "aggregatedOutput": reply.output, "truncated": reply.truncated, "status": "completed"]]
        } else if name == "timeline_query" {
            // 学習者の知識グラフと解答の台帳(ホスト側。前提は WITH RECURSIVE でたどり、結果だけを文にして返す)。
            let text = await TimelineQueryHost.handle(arguments)
            guard !cancelled.contains(context.planID), contexts[threadID]?.registration == context.registration else { throw CodexAppServerError.interrupted }
            return (["success": true, "contentItems": [["type": "inputText", "text": text]]], nil)
        } else if name == DocumentTool.name {
            // 添付の PDF・画像を読む(ホスト側。主スレッドの外で、一度に 1 つ)。
            let reply = await DocumentTool.handle(arguments, root: context.cwd)
            guard !cancelled.contains(context.planID), contexts[threadID]?.registration == context.registration else { throw CodexAppServerError.interrupted }
            return (["success": reply.success, "contentItems": reply.items], nil)
        } else { throw CodexAppServerError.malformed("unsupported native tool") }
        guard !cancelled.contains(context.planID), contexts[threadID]?.registration == context.registration else { throw CodexAppServerError.interrupted }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        return (["success": true, "contentItems": [["type": "inputText", "text": text]]], execution)
    }

    /// Policy failures are tool results, so the real AppServer can let the model
    /// choose an allowed next operation. No attempted path or command is echoed.
    /// This cwd rejection does not mediate file operations inside a command.
    private func denied(_ params: JSONObject, message: String) -> (JSONObject, JSONObject?) {
        let error: JSONObject = ["error": ["code": "operation_not_permitted", "operation": "exec_command", "message": message]]
        let text = String(decoding: (try? JSONSerialization.data(withJSONObject: error)) ?? Data(), as: UTF8.self)
        let execution: JSONObject = ["threadId": params["threadId"] ?? NSNull(), "turnId": params["turnId"] ?? NSNull(), "item": [
            "type": "commandExecution", "id": params["callId"] ?? UUID().uuidString,
            "command": "exec_command (rejected before execution)", "cwd": NSNull(),
            "exitCode": NSNull(), "durationMs": 0, "aggregatedOutput": text,
            "truncated": false, "status": "failed",
        ]]
        return (["success": false, "contentItems": [["type": "inputText", "text": text]]], execution)
    }
}
