import GRDB
import XCTest
@testable import strius

/// `ClaudeTurnRunner`(Claude の Messages API へ直接送るランナー)。模擬の Anthropic(`StubAnthropic`)に届いた要求で、
/// 要求の形・会話の履歴の保存と再開・分岐・停止の印・画像の保存・古い plan の読み込みを確かめる。
final class ClaudeTurnRunnerTests: XCTestCase {
    private var requests: [[String: Any]] = []
    private var assets: AssetCache!
    private var conversations: ClaudeConversationStore!
    private var context: ThreadContextStore!

    override func setUp() async throws {
        requests = []
        StubAnthropic.handler = nil
        let directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("claude-runner-\(UUID().uuidString)", isDirectory: true)
        let source: URL = directory.appendingPathComponent("source", isDirectory: true)
        // 質問の会話・ワークブックの指示文は短い仮の文に替え、ほかは本物の同梱版を使う。
        let bundled: BundledAssets = .main
        for (name, relative) in BundledAssets.files {
            let url: URL = source.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if name.contains("timeline") || name.contains("onboarding") {
                try XCTUnwrap(bundled.data(name), name).write(to: url)
                continue
            }
            let text: String = switch name {
            case "prompt:base": "BASE"
            case "prompt:developer": "DEVELOPER"
            case "prompt:agents": "AGENTS BODY\n"
            case "skill:struis_document": "---\nname: struis-document\ndescription: Read attachments.\n---\n\nBody\n"
            default: name.hasPrefix("schema:") ? #"{"type":"object","properties":{"answer":{"type":"string","maxLength":10}},"required":["answer"]}"# : name
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let cache: AssetCache = AssetCache(bundled: BundledAssets(root: source))
        assets = cache
        conversations = try ClaudeConversationStore.temporary()
        context = ThreadContextStore(url: nil)
    }

    // MARK: - 道具

    private func runner(_ replies: [String]) -> ClaudeTurnRunner {
        let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAnthropic.self]
        let recorder: RequestRecorder = RequestRecorder()
        self.recorder = recorder
        StubAnthropic.handler = { request in
            let body: [String: Any] = (try? JSONSerialization.jsonObject(with: StubAnthropic.body(of: request))) as? [String: Any] ?? [:]
            let index: Int = recorder.add(body)
            return (200, replies[min(index, replies.count - 1)])
        }
        let upstream: ClaudeUpstream = ClaudeUpstream(baseURL: URL(string: "https://stub.invalid")!, apiKey: { "sk-test" }, session: URLSession(configuration: configuration),
                                                      gate: OpenUsageGate())
        return ClaudeTurnRunner(assets: assets, conversations: conversations, upstream: upstream, contextStore: context, prepareCommands: {})
    }

    private var recorder: RequestRecorder?
    private var sent: [[String: Any]] { recorder?.bodies ?? [] }

    private static func sse(_ events: [String]) -> String { events.map { "event: x\ndata: \($0)\n\n" }.joined() }

    /// thinking(署名付き)と答えの文を返す応答。
    private static func answer(_ text: String, signature: String = "sig-1") -> String {
        let escaped: String = String(decoding: try! JSONSerialization.data(withJSONObject: [text]), as: UTF8.self).dropFirst().dropLast().description
        return sse([
            #"{"type":"message_start","message":{"id":"msg_\#(signature)","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":90,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"考える"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"\#(signature)"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":\#(escaped)}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}"#,
            #"{"type":"message_stop"}"#,
        ])
    }

    /// `view_image` を呼ぶ応答(作業フォルダの外を指すので、失敗の結果が返る)。
    private static let toolCall: String = sse([
        #"{"type":"message_start","message":{"id":"msg_tool","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":1}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-tool"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"view_image","input":{}}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"/etc/hosts\"}"}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":4}}"#,
        #"{"type":"message_stop"}"#,
    ])

    private func chatPlan(id: String = UUID().uuidString.lowercased(), thread: String?, mode: TurnPlan.ThreadSpec.Mode, text: String,
                          images: [TurnPlan.ImageRef] = [], lastTurnID: String? = nil, kind: TurnPlan.Kind = .chat) async throws -> TurnPlan {
        TurnPlan(
            id: id, kind: kind, round: 1,
            thread: TurnPlan.ThreadSpec(
                codexThreadID: thread, mode: mode, cwd: "/", model: "claude-opus-5-5", effort: "medium", ephemeral: false,
                baseInstructions: try await assets.ref("prompt:base"), developerInstructions: try await assets.ref("prompt:developer"),
                developerText: nil, injectDeveloperOnResume: mode == .resume, config: .object([:]), lastTurnID: lastTurnID
            ),
            turn: kind == .threadFork ? nil : TurnPlan.TurnSpec(text: text, images: images, outputSchema: nil, sandboxPolicy: "dangerFullAccess"),
            workspace: TurnPlan.WorkspaceSpec(files: [
                TurnPlan.FileSpec(path: "AGENTS.md", asset: "prompt:agents"),
                TurnPlan.FileSpec(path: ".agents/skills/struis-document/SKILL.md", asset: "skill:struis_document"),
                TurnPlan.FileSpec(path: "struis_context/recent_thread_history.md", inline: "# history"),
            ], dirs: []),
            delegation: nil, collect: [], limits: .chat,
            workspaceKey: thread.flatMap { TurnPlan.threadWorkspaceKey(codexThreadID: $0) }
        )
    }

    private func texts(_ message: [String: Any]?) -> [String] {
        (message?["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    }

    // MARK: - 要求の形

    func testRequestSizeCapSitsBelowAnthropicsLimitAndAboveNormalTurns() {
        XCTAssertLessThan(ClaudeUpstream.maxRequestBytes, 32 * 1024 * 1024)
        XCTAssertGreaterThan(ClaudeUpstream.maxRequestBytes, 4 * 1024 * 1024)
        XCTAssertTrue(ClaudeUpstream.requestTooLarge(ClaudeUpstream.maxRequestBytes + 1))
        XCTAssertFalse(ClaudeUpstream.requestTooLarge(ClaudeUpstream.maxRequestBytes))
    }

    func testStructuredTurnSendsTheSchemaAsOutputFormatAndMovesItIntoTheInstructionsWhenRejected() async throws {
        let rejected: String = #"{"type":"error","error":{"type":"invalid_request_error","message":"output_config.format.schema: grammar is too large"}}"#
        let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAnthropic.self]
        let recorder: RequestRecorder = RequestRecorder()
        self.recorder = recorder
        StubAnthropic.handler = { request in
            let body: [String: Any] = (try? JSONSerialization.jsonObject(with: StubAnthropic.body(of: request))) as? [String: Any] ?? [:]
            return recorder.add(body) == 0 ? (400, rejected) : (200, Self.answer(#"{"answer":"x"}"#))
        }
        let upstream: ClaudeUpstream = ClaudeUpstream(baseURL: URL(string: "https://stub.invalid")!, apiKey: { "sk-test" }, session: URLSession(configuration: configuration),
                                                      gate: OpenUsageGate())
        let runner: ClaudeTurnRunner = ClaudeTurnRunner(assets: assets, conversations: conversations, upstream: upstream, contextStore: context, prepareCommands: {})
        let schema: LedgerJSON = try await assets.json("schema:workbook_set")
        let plan: TurnPlan = TurnPlan(
            id: UUID().uuidString.lowercased(), kind: .workbookSet, round: 1,
            thread: TurnPlan.ThreadSpec(codexThreadID: nil, mode: .start, cwd: "/", model: "claude-opus-5-5", effort: "medium", ephemeral: true,
                                        baseInstructions: try await assets.ref("prompt:set_instructions"), developerInstructions: nil, developerText: "Only JSON.",
                                        injectDeveloperOnResume: false, config: .object([:]), lastTurnID: nil),
            turn: TurnPlan.TurnSpec(text: "{}", images: [], outputSchema: schema, sandboxPolicy: "dangerFullAccess"),
            workspace: TurnPlan.WorkspaceSpec(files: [], dirs: []), delegation: nil, collect: [], limits: .structured
        )
        let outcome: TurnOutcome = try await runner.run(plan) { _ in }
        WorkspaceStager.cleanup(plan: plan)
        XCTAssertEqual(outcome.status, .completed, outcome.errorDetail ?? "")
        XCTAssertEqual(outcome.finalText, #"{"answer":"x"}"#)
        XCTAssertEqual(sent.count, 2)
        let first: [String: Any] = sent[0]
        let format: [String: Any]? = (first["output_config"] as? [String: Any])?["format"] as? [String: Any]
        let answer: [String: Any]? = ((format?["schema"] as? [String: Any])?["properties"] as? [String: Any])?["answer"] as? [String: Any]
        XCTAssertNotNil(answer)
        XCTAssertNil(answer?["maxLength"], "Claude が受け付けない制約は外す")
        let system: [[String: Any]] = first["system"] as? [[String: Any]] ?? []
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(system.first?["text"] as? String, "prompt:set_instructions\n\nOnly JSON.\n\n" + NativeToolRouter.instructions)
        XCTAssertEqual((system.first?["cache_control"] as? [String: Any])?["ttl"] as? String, "1h")
        XCTAssertEqual(first["cache_control"] as? [String: String], ["type": "ephemeral"])
        XCTAssertEqual((first["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String },
                       ["struis__document", "struis__exec_command", "struis__struis_delegate", "view_image"])
        XCTAssertEqual(first["thinking"] as? [String: String], ["type": "adaptive", "display": "summarized"])
        // 文法が大きすぎて拒まれた schema は、指示文で渡して送り直す。
        XCTAssertNil((sent[1]["output_config"] as? [String: Any])?["format"])
        XCTAssertTrue(((sent[1]["system"] as? [[String: Any]])?.first?["text"] as? String ?? "").contains("It must validate against this JSON Schema"))
        let reasons: [String] = (outcome.executions.last?["requests"]?.arrayValue ?? []).compactMap { $0["reason"]?.stringValue }
        XCTAssertEqual(reasons, ["turn_start", "schema_retry"])
    }

    // MARK: - 会話

    func testConversationKeepsSignedThinkingAndSendsAgentsOnlyOnTheFirstTurn() async throws {
        let runner: ClaudeTurnRunner = runner([Self.toolCall, Self.answer("一つ目", signature: "sig-a"), Self.answer("二つ目", signature: "sig-b")])
        let first: TurnOutcome = try await runner.run(try await chatPlan(thread: nil, mode: .start, text: "質問 1")) { _ in }
        XCTAssertEqual(first.status, .completed, first.errorDetail ?? "")
        XCTAssertEqual(first.finalText, "一つ目")
        let thread: String = try XCTUnwrap(first.codexThreadID)
        // 最初の発話は AGENTS.md・今回の文の順。Skill の一覧は developer 指示の後ろに改行 1 つで続く。
        let opening: [String] = texts((sent[0]["messages"] as? [[String: Any]])?.first)
        XCTAssertEqual(opening.count, 2)
        XCTAssertTrue(opening[0].hasPrefix("# AGENTS.md instructions for "))
        XCTAssertTrue(opening[0].hasSuffix("\n\n<INSTRUCTIONS>\nAGENTS BODY\n\n</INSTRUCTIONS>"))
        XCTAssertEqual(opening[1], "質問 1")
        let system: String = (sent[0]["system"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(system.hasPrefix("BASE\n\nDEVELOPER\n\n" + NativeToolRouter.instructions + "\n<skills_instructions>\n## Skills\n"))
        XCTAssertTrue(system.hasSuffix("- struis-document: Read attachments. (file: r0/struis-document/SKILL.md)\n</skills_instructions>"))
        XCTAssertEqual(sent[0]["cache_control"] as? [String: String], ["type": "ephemeral", "ttl": "1h"])
        // 道具の結果は失敗として返り、thinking は署名ごと次の要求に戻る。
        let afterTool: [[String: Any]] = sent[1]["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual((afterTool[1]["content"] as? [[String: Any]])?.first?["signature"] as? String, "sig-tool")
        let result: [String: Any]? = (afterTool[2]["content"] as? [[String: Any]])?.first
        XCTAssertEqual(result?["tool_use_id"] as? String, "toolu_1")
        XCTAssertEqual(result?["is_error"] as? Bool, true)

        // 次のターン(アプリを開き直した後と同じく、新しいランナーで)は、保存した履歴から続ける。
        let second: TurnOutcome = try await self.runner([Self.answer("二つ目", signature: "sig-b")])
            .run(try await chatPlan(thread: thread, mode: .resume, text: "質問 2")) { _ in }
        XCTAssertEqual(second.status, .completed, second.errorDetail ?? "")
        XCTAssertEqual(second.codexThreadID, thread)
        let resumed: [[String: Any]] = sent[0]["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(resumed.map { $0["role"] as? String ?? "" }, ["user", "assistant", "user", "assistant", "user"])
        XCTAssertEqual((resumed[3]["content"] as? [[String: Any]])?.first?["signature"] as? String, "sig-a")
        XCTAssertEqual(texts(resumed[4]), ["質問 2"], "同じ作業フォルダでは AGENTS.md を送り直さない")
        // 1 ターン目の 4 件(質問・道具の呼び出し・その結果・答え)と、2 ターン目の 2 件(質問・答え)。
        XCTAssertEqual(try conversations.messages(thread).count, 6)
    }

    func testForkCopiesTheHistoryUpToTheTurnAndResendsAgentsForItsFolder() async throws {
        let runner: ClaudeTurnRunner = runner([Self.answer("一つ目"), Self.answer("二つ目"), Self.answer("分岐")])
        let first: TurnOutcome = try await runner.run(try await chatPlan(thread: nil, mode: .start, text: "質問 1")) { _ in }
        let thread: String = try XCTUnwrap(first.codexThreadID)
        _ = try await runner.run(try await chatPlan(thread: thread, mode: .resume, text: "質問 2")) { _ in }
        let fork: TurnOutcome = try await runner.run(try await chatPlan(thread: thread, mode: .fork, text: "", lastTurnID: first.codexTurnID, kind: .threadFork)) { _ in }
        XCTAssertEqual(fork.status, .completed)
        let forked: String = try XCTUnwrap(fork.codexThreadID)
        XCTAssertNotEqual(forked, thread)
        XCTAssertEqual(try conversations.messages(forked).count, 2, "最初のターン(質問 1 と答え)までを写す")
        let onFork: TurnOutcome = try await runner.run(try await chatPlan(thread: forked, mode: .resume, text: "分岐の質問")) { _ in }
        XCTAssertEqual(onFork.status, .completed, onFork.errorDetail ?? "")
        let last: [String] = texts((sent[2]["messages"] as? [[String: Any]])?.last)
        XCTAssertTrue(last[0].contains("<INSTRUCTIONS>\nThese AGENTS.md instructions replace all previously provided AGENTS.md instructions.\n\nAGENTS BODY"))
        XCTAssertTrue(last[1].hasPrefix("<developer_instructions>\n<skills_instructions>\n"))
        XCTAssertEqual(last[2], "分岐の質問")
    }

    func testStoppedTurnLeavesTheAbortMarkAndClosesOpenToolCalls() async throws {
        let runner: ClaudeTurnRunner = runner([Self.answer("一つ目")])
        let first: TurnOutcome = try await runner.run(try await chatPlan(thread: nil, mode: .start, text: "質問 1")) { _ in }
        let thread: String = try XCTUnwrap(first.codexThreadID)
        // アプリが道具の途中で落ちた: 結果の無い tool_use が履歴の最後に残っている。
        try conversations.append(threadID: thread, turnID: "t-crash", role: "user", content: [["type": "text", "text": "途中の質問"]])
        try conversations.append(threadID: thread, turnID: "t-crash", role: "assistant", content: [
            ["type": "thinking", "thinking": "", "signature": "sig-x"], ["type": "tool_use", "id": "toolu_open", "name": "view_image", "input": ["path": "a.png"]],
        ])
        let next: TurnOutcome = try await self.runner([Self.answer("続き")]).run(try await chatPlan(thread: thread, mode: .resume, text: "質問 2")) { _ in }
        XCTAssertEqual(next.status, .completed, next.errorDetail ?? "")
        let messages: [[String: Any]] = sent[0]["messages"] as? [[String: Any]] ?? []
        let closing: [[String: Any]] = messages.last?["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(closing.first?["tool_use_id"] as? String, "toolu_open")
        XCTAssertEqual(closing.first?["is_error"] as? Bool, true)
        XCTAssertEqual(closing.last?["text"] as? String, "質問 2")
    }

    func testLearnerStopIsRecordedForTheNextTurn() async throws {
        let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAnthropic.self]
        let recorder: RequestRecorder = RequestRecorder()
        self.recorder = recorder
        StubAnthropic.handler = { request in
            let body: [String: Any] = (try? JSONSerialization.jsonObject(with: StubAnthropic.body(of: request))) as? [String: Any] ?? [:]
            if recorder.add(body) == 1 { Thread.sleep(forTimeInterval: 3) }
            return (200, Self.answer("答え"))
        }
        let upstream: ClaudeUpstream = ClaudeUpstream(baseURL: URL(string: "https://stub.invalid")!, apiKey: { "sk-test" }, session: URLSession(configuration: configuration),
                                                      gate: OpenUsageGate())
        let runner: ClaudeTurnRunner = ClaudeTurnRunner(assets: assets, conversations: conversations, upstream: upstream, contextStore: context, prepareCommands: {})
        let first: TurnOutcome = try await runner.run(try await chatPlan(thread: nil, mode: .start, text: "質問 1")) { _ in }
        let thread: String = try XCTUnwrap(first.codexThreadID)
        let plan: TurnPlan = try await chatPlan(thread: thread, mode: .resume, text: "止める質問")
        let task: Task<TurnOutcome, Error> = Task { try await runner.run(plan) { _ in } }
        try await Task.sleep(for: .milliseconds(800))
        await runner.interrupt(planID: plan.id)
        let stopped: TurnOutcome = try await task.value
        XCTAssertEqual(stopped.status, .interrupted)
        _ = try await runner.run(try await chatPlan(thread: thread, mode: .resume, text: "次の質問")) { _ in }
        let last: [String] = texts((sent.last?["messages"] as? [[String: Any]])?.last)
        XCTAssertEqual(last, ["止める質問", ClaudeTurn.turnAbortedText, "次の質問"])
    }

    /// 配信された developer 指示が、スレッドに渡し済みの版と違う時だけ、次のターンの前に 1 回渡し直す。
    func testOutdatedDeveloperInstructionsAreSentOnceOnResume() async throws {
        let runner: ClaudeTurnRunner = runner([Self.answer("一つ目"), Self.answer("二つ目"), Self.answer("三つ目")])
        let first: TurnOutcome = try await runner.run(try await chatPlan(thread: nil, mode: .start, text: "質問 1")) { _ in }
        let thread: String = try XCTUnwrap(first.codexThreadID)
        // この版より前に始めた(渡した版の記録が古い)スレッド。
        context.update(thread) { $0.developer = "outdated" }
        let second: TurnOutcome = try await runner.run(try await chatPlan(thread: thread, mode: .resume, text: "質問 2")) { _ in }
        XCTAssertEqual(second.status, .completed, second.errorDetail ?? "")
        XCTAssertEqual(texts((sent[1]["messages"] as? [[String: Any]])?.last), ["<developer_instructions>\nDEVELOPER\n</developer_instructions>", "質問 2"])
        let third: TurnOutcome = try await runner.run(try await chatPlan(thread: thread, mode: .resume, text: "質問 3")) { _ in }
        XCTAssertEqual(third.status, .completed, third.errorDetail ?? "")
        XCTAssertEqual(texts((sent[2]["messages"] as? [[String: Any]])?.last), ["質問 3"], "渡した後は送り直さない")
    }

    /// 期限で止めたターンは、学習者ではなく Struis が止めたと記録し、そのスレッドの次のターンでモデルに伝える(P4-3)。
    func testDeadlineIsRecordedAsStruisStopAndToldToTheModel() async throws {
        let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAnthropic.self]
        let recorder: RequestRecorder = RequestRecorder()
        self.recorder = recorder
        StubAnthropic.handler = { request in
            let body: [String: Any] = (try? JSONSerialization.jsonObject(with: StubAnthropic.body(of: request))) as? [String: Any] ?? [:]
            if recorder.add(body) == 1 { Thread.sleep(forTimeInterval: 3) }
            return (200, Self.answer("答え"))
        }
        let upstream: ClaudeUpstream = ClaudeUpstream(baseURL: URL(string: "https://stub.invalid")!, apiKey: { "sk-test" }, session: URLSession(configuration: configuration),
                                                      gate: OpenUsageGate())
        var timeouts: ClaudeTurnRunner.Timeouts = ClaudeTurnRunner.Timeouts()
        timeouts.minimumTurnS = 1
        let runner: ClaudeTurnRunner = ClaudeTurnRunner(assets: assets, conversations: conversations, upstream: upstream, timeouts: timeouts,
                                                        contextStore: context, prepareCommands: {})
        let first: TurnOutcome = try await runner.run(try await chatPlan(thread: nil, mode: .start, text: "質問 1")) { _ in }
        let thread: String = try XCTUnwrap(first.codexThreadID)
        var slow: TurnPlan = try await chatPlan(thread: thread, mode: .resume, text: "質問 2")
        slow.limits = TurnPlan.Limits(collectMaxFiles: 0, collectMaxBytes: 0, turnTimeoutS: 1)
        let stopped: TurnOutcome = try await runner.run(slow) { _ in }
        XCTAssertEqual(stopped.status, .failed)
        XCTAssertEqual(stopped.errorDetail, TurnRuntimeError.timeout(ClaudeTurnRunner.deadlineDetail).detail)
        let audit: LedgerJSON = try XCTUnwrap(stopped.executions.last)
        XCTAssertEqual(audit["status"]?.stringValue, "timed_out")
        XCTAssertEqual(audit["stopped_by"]?.stringValue, "deadline")
        XCTAssertEqual(context.entry(thread)?.notices?.count, 1)

        let next: TurnOutcome = try await runner.run(try await chatPlan(thread: thread, mode: .resume, text: "次")) { _ in }
        XCTAssertEqual(next.status, .completed, next.errorDetail ?? "")
        let last: [String] = texts((sent.last?["messages"] as? [[String: Any]])?.last)
        XCTAssertEqual(last.last, "次")
        XCTAssertTrue(last.contains { $0.hasPrefix("<developer_instructions>\n") && $0.contains("The learner did not interrupt it") }, "\(last)")
        XCTAssertNil(context.entry(thread)?.notices, "伝えた注記は消す")
    }

    func testMissingHistoryContinuesOnANewThreadWithTheHistoryNote() async throws {
        let runner: ClaudeTurnRunner = runner([Self.answer("答え")])
        let outcome: TurnOutcome = try await runner.run(try await chatPlan(thread: "old-codex-thread", mode: .resume, text: "前の続き")) { _ in }
        XCTAssertEqual(outcome.status, .completed, outcome.errorDetail ?? "")
        XCTAssertNotEqual(outcome.codexThreadID, "old-codex-thread")
        let system: String = (sent[0]["system"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(system.contains(ClaudeTurn.missingHistoryNote))
        let resumes: Bool = await runner.resumes(threadID: "old-codex-thread")
        XCTAssertFalse(resumes)
    }

    func testImagesAreStoredAsFilesAndRestoredForTheNextRequest() throws {
        let png: Data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        try conversations.begin(threadID: "t", kind: "chat", model: "m")
        try conversations.append(threadID: "t", turnID: "turn", role: "user", content: [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]],
        ])
        let raw: String = try XCTUnwrap(try conversations.rawContentForTest("t"))
        XCTAssertFalse(raw.contains(png.base64EncodedString()), "台帳には画像の本体を入れない")
        XCTAssertTrue(raw.contains("struis_file"))
        let restored: [String: Any]? = try conversations.messages("t").first?.blocks.first?["source"] as? [String: Any]
        XCTAssertEqual(restored?["data"] as? String, png.base64EncodedString())
    }

    // MARK: - 古い plan

    func testPlansSavedWithAnyProviderRunAsClaude() throws {
        let old: String = #"{"mode":"start","cwd":"/","model":"gpt","effort":"low","ephemeral":true,"base_instructions":{"asset":"a","sha256":"x"},"inject_developer_on_resume":false,"config":{}}"#
        let spec: TurnPlan.ThreadSpec = try JSONDecoder().decode(TurnPlan.ThreadSpec.self, from: Data(old.utf8))
        XCTAssertNil(spec.provider)
        let openai: String = old.replacingOccurrences(of: #""config":{}"#, with: #""config":{},"provider":"openai""#)
        XCTAssertEqual(try JSONDecoder().decode(TurnPlan.ThreadSpec.self, from: Data(openai.utf8)).provider, .anthropic)
    }
}

/// 届いた要求の本文を順に残す。
final class RequestRecorder: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var values: [[String: Any]] = []

    /// 足した要求の番号(0 から)。
    func add(_ body: [String: Any]) -> Int {
        lock.withLock {
            values.append(body)
            return values.count - 1
        }
    }

    var bodies: [[String: Any]] { lock.withLock { values } }
}

/// 利用枠で止めない(テスト用)。
nonisolated struct OpenUsageGate: UsageGate {
    func admit() -> Bool { true }
    func record(_ record: [String: Any], requestBytes: Int) {}
}

/// Anthropic の代わりに決まった SSE を返す。
final class StubAnthropic: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?

    /// 要求の本文(URLSession は本文を `httpBodyStream` で渡す)。
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data: Data = Data()
        var buffer: [UInt8] = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count: Int = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler?(request) ?? (500, "")
        let response: HTTPURLResponse = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
