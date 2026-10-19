import XCTest
@testable import strius

/// Codex の Responses API ⇄ Claude の Messages API の変換と、端末内プロキシの往復。
final class ClaudeProxyTests: XCTestCase {
    // MARK: - Request

    /// 3.6: 要求本文の上限。Anthropic の上限(32 MB)より手前で、ふつうのターン(数 MB)は通す。
    func testRequestSizeCapSitsBelowAnthropicsLimitAndAboveNormalTurns() {
        XCTAssertLessThan(ClaudeResponsesProxy.maxRequestBytes, 32 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(ClaudeResponsesProxy.maxRequestBytes, 8 * 1024 * 1024, "写真 4 枚の 1 ターンが通らない")
        XCTAssertFalse(ClaudeResponsesProxy.requestTooLarge(ClaudeResponsesProxy.maxRequestBytes))
        XCTAssertTrue(ClaudeResponsesProxy.requestTooLarge(ClaudeResponsesProxy.maxRequestBytes + 1))
        XCTAssertFalse(ClaudeResponsesProxy.requestTooLarge(3 * 1024 * 1024))
        // 大きすぎる要求は 400 で返す: Codex は 413 を一時的な失敗として同じ本文を送り直す(上流の 413 も 400 に直している)。
        XCTAssertEqual(ClaudeUpstream.codexStatus(413), 400)
        XCTAssertEqual(ClaudeResponsesProxy.oversizedStatus, 400)
    }

    /// system は版 1 で文字列、版 2 で breakpoint 付きの text ブロック。
    static func systemText(_ body: [String: Any]) -> String? {
        if let text = body["system"] as? String { return text }
        return (body["system"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
    }

    private func codexRequest(input: [[String: Any]], tools: [[String: Any]] = [], text: [String: Any]? = nil) -> [String: Any] {
        var request: [String: Any] = [
            "model": "claude-opus-5-5", "instructions": "BASE", "input": input, "tool_choice": "auto",
            "parallel_tool_calls": false, "reasoning": ["effort": "medium", "summary": "auto"], "store": false, "stream": true,
            "include": ["reasoning.encrypted_content"],
        ]
        if !tools.isEmpty { request["tools"] = tools }
        if let text { request["text"] = text }
        return request
    }

    private let namespaceTools: [[String: Any]] = [[
        "type": "namespace", "name": "struis", "description": "Native",
        "tools": [
            ["type": "function", "name": "exec_command", "description": "Run", "strict": false,
             "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]], "required": ["cmd"], "additionalProperties": false]],
        ],
    ], [
        "type": "custom", "name": "apply_patch", "description": "Patch",
        "format": ["type": "grammar", "syntax": "lark", "definition": "start: /.+/"],
    ], ["type": "web_search"]]

    func testLeadingDeveloperMessagesBecomeSystemAndLaterOnesStayInTheConversation() throws {
        let request = codexRequest(input: [
            ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "DEV"]]],
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hello"]]],
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "hi"]]],
            ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "NOTICE"]]],
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "next"]]],
        ])
        let body = try ClaudeRequestTranslator.translate(request).body
        XCTAssertEqual(Self.systemText(body), "BASE\n\nDEV")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let last = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertTrue((last.first?["text"] as? String)?.contains("NOTICE") == true)
        XCTAssertEqual(last.last?["text"] as? String, "next")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertEqual((body["thinking"] as? [String: Any])?["display"] as? String, "summarized")
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testToolsAreFlattenedAndCallsRoundTripWithThinking() throws {
        let thinking = try XCTUnwrap(ClaudeReasoningCodec.encode(["type": "thinking", "thinking": "", "signature": "SIG"]))
        let request = codexRequest(input: [
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "list files"]]],
            ["type": "reasoning", "id": "rs_1", "summary": [], "encrypted_content": thinking],
            ["type": "function_call", "name": "exec_command", "namespace": "struis", "arguments": "{\"cmd\":\"ls\"}", "call_id": "toolu_01"],
            ["type": "function_call_output", "call_id": "toolu_01", "output": "a.txt"],
            ["type": "reasoning", "id": "rs_x", "summary": [], "encrypted_content": "gAAAA-openai-opaque"],
        ], tools: namespaceTools)
        let body = try ClaudeRequestTranslator.translate(request).body
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        // 版 2 は tools を名前の順に固定する(版 1 は Codex の順)。
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["apply_patch", "struis__exec_command"])
        let legacy = try ClaudeRequestTranslator.translate(request, options: .init(translation: 1)).body
        XCTAssertEqual((legacy["tools"] as? [[String: Any]])?.map { $0["name"] as? String }, ["struis__exec_command", "apply_patch"])
        XCTAssertEqual((body["tool_choice"] as? [String: Any])?["disable_parallel_tool_use"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let assistant = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistant.map { $0["type"] as? String }, ["thinking", "tool_use"])
        XCTAssertEqual(assistant[0]["signature"] as? String, "SIG")
        XCTAssertEqual(assistant[1]["name"] as? String, "struis__exec_command")
        XCTAssertEqual((assistant[1]["input"] as? [String: Any])?["cmd"] as? String, "ls")
        let result = try XCTUnwrap((messages[2]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["type"] as? String, "tool_result")
        XCTAssertEqual(result["tool_use_id"] as? String, "toolu_01")
        XCTAssertEqual(result["content"] as? String, "a.txt")

        // 署名が合わなかった時の送り直しでは thinking を外す。
        let stripped = try ClaudeRequestTranslator.translate(request, options: .init(stripThinking: true)).body
        let strippedAssistant = try XCTUnwrap((stripped["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]])
        XCTAssertEqual(strippedAssistant.map { $0["type"] as? String }, ["tool_use"])
    }

    func testImagesAndUnansweredToolCalls() throws {
        let png = "data:image/png;base64,iVBORw0KGgo="
        let request = codexRequest(input: [
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "grade"], ["type": "input_image", "image_url": png]]],
            ["type": "function_call", "name": "exec_command", "namespace": "struis", "arguments": "{}", "call_id": "call:1"],
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "stop"]]],
        ], tools: namespaceTools)
        let messages = try XCTUnwrap(try ClaudeRequestTranslator.translate(request).body["messages"] as? [[String: Any]])
        let first = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(first[1]["type"] as? String, "image")
        XCTAssertEqual((first[1]["source"] as? [String: Any])?["media_type"] as? String, "image/png")
        XCTAssertEqual(((messages[1]["content"] as? [[String: Any]])?.first)?["id"] as? String, "call_1")
        // 結果のない tool_use は中断として補い、その後に学習者の発話を続ける。
        let last = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(last.first?["type"] as? String, "tool_result")
        XCTAssertEqual(last.first?["is_error"] as? Bool, true)
        XCTAssertEqual(last.last?["text"] as? String, "stop")
    }

    func testOutputSchemaDropsConstraintsClaudeRejects() throws {
        let schema: [String: Any] = [
            "type": "object", "required": ["items"],
            "properties": ["items": ["type": "array", "minItems": 1, "maxItems": 5,
                                     "items": ["type": "object", "properties": ["score": ["type": "integer", "minimum": 0, "maximum": 10]]]]],
        ]
        let request = codexRequest(input: [["type": "message", "role": "user", "content": [["type": "input_text", "text": "go"]]]],
                                   text: ["format": ["type": "json_schema", "name": "out", "strict": true, "schema": schema]])
        let translation = try ClaudeRequestTranslator.translate(request)
        XCTAssertTrue(translation.structured)
        let format = try XCTUnwrap((translation.body["output_config"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let sanitized = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(sanitized["additionalProperties"] as? Bool, false)
        let items = try XCTUnwrap((sanitized["properties"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertNil(items["minItems"])
        XCTAssertNil(items["maxItems"])
        let element = try XCTUnwrap(items["items"] as? [String: Any])
        XCTAssertEqual(element["additionalProperties"] as? Bool, false)
        let score = try XCTUnwrap((element["properties"] as? [String: Any])?["score"] as? [String: Any])
        XCTAssertNil(score["minimum"])
        XCTAssertEqual(score["type"] as? String, "integer")
    }

    func testOversizedSchemaCanMoveIntoTheInstructions() throws {
        let schema: [String: Any] = ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"]]
        let request = codexRequest(input: [["type": "message", "role": "user", "content": [["type": "input_text", "text": "go"]]]],
                                   text: ["format": ["type": "json_schema", "name": "out", "strict": true, "schema": schema]])
        let translation = try ClaudeRequestTranslator.translate(request, options: .init(schemaInInstructions: true))
        XCTAssertTrue(translation.structured)
        XCTAssertNil((translation.body["output_config"] as? [String: Any])?["format"])
        let system = try XCTUnwrap(Self.systemText(translation.body))
        XCTAssertTrue(system.hasPrefix("BASE"))
        XCTAssertTrue(system.contains("\"ok\""))
    }

    // MARK: - Stream

    private func run(_ events: [[String: Any]], tools: [[String: Any]] = []) -> [[String: Any]] {
        let translator = ClaudeStreamTranslator(tools: ClaudeToolNames(responsesTools: tools), responseID: "resp_test")
        var out = events.flatMap { translator.consume($0) }
        out += translator.streamEnded()
        return out
    }

    private func block(_ index: Int, _ block: [String: Any]) -> [String: Any] { ["type": "content_block_start", "index": index, "content_block": block] }
    private func delta(_ index: Int, _ delta: [String: Any]) -> [String: Any] { ["type": "content_block_delta", "index": index, "delta": delta] }
    private func stop(_ index: Int) -> [String: Any] { ["type": "content_block_stop", "index": index] }

    func testStreamWithThinkingCommentaryToolCallAndUsage() throws {
        let out = run([
            ["type": "message_start", "message": ["id": "msg_1", "model": "claude-opus-5-5", "usage": ["input_tokens": 10, "cache_read_input_tokens": 90, "output_tokens": 1]]],
            block(0, ["type": "thinking", "thinking": "", "signature": ""]),
            delta(0, ["type": "thinking_delta", "thinking": "Checking files"]),
            delta(0, ["type": "signature_delta", "signature": "SIG"]),
            stop(0),
            block(1, ["type": "text", "text": ""]),
            delta(1, ["type": "text_delta", "text": "Let me look."]),
            stop(1),
            block(2, ["type": "tool_use", "id": "toolu_9", "name": "struis__exec_command", "input": [String: Any]()]),
            delta(2, ["type": "input_json_delta", "partial_json": "{\"cmd\":"]),
            delta(2, ["type": "input_json_delta", "partial_json": "\"ls\"}"]),
            stop(2),
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 42]],
            ["type": "message_stop"],
        ], tools: namespaceTools)
        let types = out.map { $0["type"] as? String ?? "" }
        XCTAssertEqual(types.first, "response.created")
        XCTAssertEqual(types.last, "response.completed")
        XCTAssertTrue(types.contains("response.reasoning_summary_text.delta"))
        let done = out.filter { $0["type"] as? String == "response.output_item.done" }.compactMap { $0["item"] as? [String: Any] }
        XCTAssertEqual(done.map { $0["type"] as? String }, ["reasoning", "message", "function_call"])
        let reasoning = done[0]
        let decoded = try XCTUnwrap(ClaudeReasoningCodec.decode(try XCTUnwrap(reasoning["encrypted_content"] as? String)))
        XCTAssertEqual(decoded.first?["signature"] as? String, "SIG")
        XCTAssertEqual(decoded.first?["thinking"] as? String, "Checking files")
        XCTAssertEqual(done[1]["phase"] as? String, "commentary")
        XCTAssertEqual(done[2]["name"] as? String, "exec_command")
        XCTAssertEqual(done[2]["namespace"] as? String, "struis")
        XCTAssertEqual(done[2]["call_id"] as? String, "toolu_9")
        XCTAssertEqual(done[2]["arguments"] as? String, "{\"cmd\":\"ls\"}")
        let usage = try XCTUnwrap(((out.last?["response"] as? [String: Any])?["usage"]) as? [String: Any])
        XCTAssertEqual(usage["input_tokens"] as? Int, 100)
        XCTAssertEqual((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int, 90)
        XCTAssertEqual(usage["output_tokens"] as? Int, 42)
    }

    func testFinalAnswerCustomToolAndFailures() throws {
        let answer = run([
            ["type": "message_start", "message": ["id": "m", "usage": ["input_tokens": 1]]],
            block(0, ["type": "text", "text": ""]),
            delta(0, ["type": "text_delta", "text": "{\"ok\":true}"]),
            stop(0),
            ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 3]],
            ["type": "message_stop"],
        ])
        let message = try XCTUnwrap(answer.first { $0["type"] as? String == "response.output_item.done" }?["item"] as? [String: Any])
        XCTAssertEqual(message["phase"] as? String, "final_answer")
        XCTAssertEqual(((message["content"] as? [[String: Any]])?.first)?["text"] as? String, "{\"ok\":true}")
        XCTAssertEqual(answer.filter { $0["type"] as? String == "response.output_text.delta" }.count, 1)

        let custom = run([
            block(0, ["type": "tool_use", "id": "toolu_p", "name": "apply_patch", "input": [String: Any]()]),
            delta(0, ["type": "input_json_delta", "partial_json": "{\"input\":\"*** Begin Patch\"}"]),
            stop(0),
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"]],
            ["type": "message_stop"],
        ], tools: namespaceTools)
        let call = try XCTUnwrap(custom.first { $0["type"] as? String == "response.output_item.done" }?["item"] as? [String: Any])
        XCTAssertEqual(call["type"] as? String, "custom_tool_call")
        XCTAssertEqual(call["input"] as? String, "*** Begin Patch")

        let overloaded = run([["type": "error", "error": ["type": "overloaded_error", "message": "busy"]]])
        let failure = try XCTUnwrap(overloaded.last)
        XCTAssertEqual(failure["type"] as? String, "response.failed")
        XCTAssertEqual(((failure["response"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "server_is_overloaded")

        let truncated = run([["type": "message_start", "message": ["id": "m"]], block(0, ["type": "text", "text": "partial"])])
        XCTAssertEqual(truncated.last?["type"] as? String, "response.failed")
    }

    // MARK: - Proxy over loopback

    func testProxyRejectsWrongTokenAndRelaysTheStream() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAnthropic.self]
        StubAnthropic.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            let lines = [
                #"{"type":"message_start","message":{"id":"msg","model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":1}}}"#,
                #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"こんにちは"}}"#,
                #"{"type":"content_block_stop","index":0}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}"#,
                #"{"type":"message_stop"}"#,
            ]
            return (200, lines.map { "event: x\ndata: \($0)\n\n" }.joined())
        }
        let upstream = ClaudeUpstream(baseURL: URL(string: "https://stub.invalid")!, apiKey: { "sk-test" }, session: URLSession(configuration: configuration))
        let proxy = ClaudeResponsesProxy(upstream: upstream)
        let endpoint = try await proxy.start()
        defer { Task { await proxy.stop() } }

        var request = URLRequest(url: URL(string: endpoint.baseURL + "/responses")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: codexRequest(input: [["type": "message", "role": "user", "content": [["type": "input_text", "text": "hi"]]]]))
        request.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, rejected) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 401)

        request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("event: response.created"))
        XCTAssertTrue(text.contains("こんにちは"))
        XCTAssertTrue(text.contains("event: response.completed"))
    }

    func testProviderSelectionKeepsAThreadOnTheProviderItStartedWith() async throws {
        let store = ThreadContextStore(url: nil)
        store.update("thread-claude") { $0.provider = .anthropic }
        let assets = AssetCache(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), lenient: true)
        let runner = CodexTurnRunner(session: CodexAppServerSession(clientVersion: "test", launcher: { _, _ in throw CodexAppServerError.closed("test") }),
                                     assets: assets, contextStore: store)
        func plan(thread: String?, mode: TurnPlan.ThreadSpec.Mode, provider: ModelProvider?) -> TurnPlan {
            TurnPlan(
                id: "p", kind: .chat, round: 1,
                thread: TurnPlan.ThreadSpec(codexThreadID: thread, mode: mode, cwd: "/", model: "m", effort: "medium", ephemeral: false,
                                            baseInstructions: .init(asset: "a", sha256: "x"), developerInstructions: nil, developerText: nil,
                                            injectDeveloperOnResume: false, config: .object([:]), lastTurnID: nil, provider: provider),
                turn: nil, workspace: .init(files: [], dirs: []),
                delegation: TurnPlan.DelegationSpec(enabled: true, inbox: "i", model: "l", effort: "low", baseInstructions: .init(asset: "a", sha256: "x"),
                                                    developerText: "", outputSchema: .object([:]), sourceRoots: [], provider: provider),
                collect: [], limits: .chat, items: nil
            )
        }
        // 設定が GPT でも、Claude で始めた会話の続きは Claude で動く。
        let resumedClaude = await runner.resolvingProvider(plan(thread: "thread-claude", mode: .resume, provider: nil))
        XCTAssertEqual(resumedClaude.thread.provider, .anthropic)
        XCTAssertEqual(resumedClaude.thread.model, ClaudeModels.astraModel)
        XCTAssertEqual(resumedClaude.delegation?.model, ClaudeModels.lunaModel)
        XCTAssertEqual(resumedClaude.delegation?.provider, .anthropic)
        // 記録のない(この変更より前の)会話は GPT で続く。
        let resumedOld = await runner.resolvingProvider(plan(thread: "thread-old", mode: .resume, provider: .anthropic))
        XCTAssertNil(resumedOld.thread.provider)
        XCTAssertEqual(resumedOld.thread.model, CodexModels.astraModel)
        // 最初のターンが失敗した(返事の無い)スレッドは、切り替えた設定で送り直せる。
        store.update("thread-unanswered") {
            $0.provider = nil
            $0.answered = false
        }
        let retried = await runner.resolvingProvider(plan(thread: "thread-unanswered", mode: .resume, provider: .anthropic))
        XCTAssertEqual(retried.thread.provider, .anthropic)
        XCTAssertEqual(retried.thread.model, "m")
        // Codex は読み込み済みのスレッドの provider を変えないので、新しいスレッドで始め直す。
        XCTAssertEqual(retried.thread.mode, .start)
        XCTAssertNil(retried.thread.codexThreadID)
        // 同じ実行先なら、そのまま続ける。
        let same = await runner.resolvingProvider(plan(thread: "thread-unanswered", mode: .resume, provider: nil))
        XCTAssertEqual(same.thread.mode, .resume)
        // 新しいスレッドは設定どおり。
        let started = await runner.resolvingProvider(plan(thread: nil, mode: .start, provider: .anthropic))
        XCTAssertEqual(started.thread.provider, .anthropic)
        XCTAssertEqual(started.thread.model, "m")
        // 古いスレッドの記録が溢れても、Claude で始めた実行先は残る。
        for index in 0..<(ThreadContextStore.limit + 5) { store.update("t\(index)") { $0.developer = "d" } }
        XCTAssertEqual(store.entry("thread-claude")?.provider, .anthropic)
    }

    func testPlansSavedBeforeProvidersStillDecode() throws {
        let old = #"{"mode":"start","cwd":"/","model":"gpt","effort":"low","ephemeral":true,"base_instructions":{"asset":"a","sha256":"x"},"inject_developer_on_resume":false,"config":{}}"#
        let spec = try JSONDecoder().decode(TurnPlan.ThreadSpec.self, from: Data(old.utf8))
        XCTAssertNil(spec.provider)
        var claude = spec
        claude.provider = .anthropic
        let reencoded = try JSONDecoder().decode(TurnPlan.ThreadSpec.self, from: JSONEncoder().encode(claude))
        XCTAssertEqual(reencoded.provider, .anthropic)
    }
}

/// Anthropic の代わりに決まった SSE を返す。
final class StubAnthropic: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler?(request) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
