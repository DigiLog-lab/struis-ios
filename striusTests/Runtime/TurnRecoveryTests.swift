import GRDB
import XCTest
@testable import strius

/// 止まっても戻れる (修正指示書 §2.3 / E2E H1・H3)。偽の app-server で、停止の後・要求の時間切れの後に
/// アプリを再起動せずに次の送信が通ること、起動時に置き去りの質問ターンが「止まりました」になることを確かめる。
final class TurnRecoveryTests: XCTestCase {
    func testTransportDiagnosticExcludesErrorSecrets() {
        let secret = "Bearer secret-token /private/learner-document.pdf"
        for domain in [NSURLErrorDomain, secret] {
            let error = NSError(domain: domain, code: -1103, userInfo: [NSLocalizedDescriptionKey: secret, NSUnderlyingErrorKey: NSError(domain: secret, code: 1)])
            let diagnostic = NativeRuntimeExit.failureDiagnostic(stage: "receive", error: error, closeCode: 1009, lastReceivedBytes: 23, receiveLimit: 1_048_576)
            XCTAssertTrue(diagnostic.contains("code=-1103"))
            XCTAssertTrue(diagnostic.contains("close_code=1009"))
            XCTAssertFalse(diagnostic.contains(secret))
            XCTAssertFalse(diagnostic.contains("secret-token"))
            XCTAssertFalse(diagnostic.contains("learner-document"))
        }
    }

    func testRestoredPlanIDsStayDirectWorkspaceChildren() {
        XCTAssertTrue(TurnPlan.isSafeWorkspaceID(LedgerID.make()))
        XCTAssertTrue(TurnPlan.isSafeWorkspaceID("plan_01-A"))
        for id in ["", "..", ".", "../codex", "a/b", "a\\b", "a b", "日本", String(repeating: "a", count: 129), "a\u{0}"] {
            XCTAssertFalse(TurnPlan.isSafeWorkspaceID(id), id)
        }
        // An escaping ID must not empty or remove anything outside its workspace.
        let sibling = HyotanBoot.workspaceRoot.deletingLastPathComponent().appendingPathComponent("plan-id-canary-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        var escaping = Self.plan(threadID: nil)
        escaping.id = "../" + sibling.lastPathComponent
        WorkspaceStager.cleanup(plan: escaping)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertThrowsError(try WorkspaceStager.prepare(plan: escaping, assets: Self.assets()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testPanicSiteKeepsOnlySanitizedSourceLocation() {
        XCTAssertEqual(NativeRuntimeHost.safePanicSite("/Users/builder/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/tokio-1.47.1/src/runtime/task/mod.rs:120"), "tokio-1.47.1/src/runtime/task/mod.rs:120")
        XCTAssertEqual(NativeRuntimeHost.safePanicSite("core/src/context_manager/history.rs:88"), "core/src/context_manager/history.rs:88")
        XCTAssertEqual(NativeRuntimeHost.safePanicSite("/Users/builder/x.rs:7"), "x.rs:7", "srcの無いpathはファイル名だけにし、ホーム名を出さない")
        XCTAssertEqual(NativeRuntimeHost.safePanicSite("lib.rs:7"), "lib.rs:7")
        XCTAssertNil(NativeRuntimeHost.safePanicSite("/private/learner document.pdf:3"))
        XCTAssertNil(NativeRuntimeHost.safePanicSite("src/a.rs:12:5"))
        XCTAssertNil(NativeRuntimeHost.safePanicSite("src/a.rs"))
        XCTAssertNil(NativeRuntimeHost.safePanicSite("a/../src/b.rs:1"))
        XCTAssertNil(NativeRuntimeHost.safePanicSite("Bearer secret-token"))
    }

    func testFailureProbeSummaryUsesOnlyKnownServerStates() {
        var reply = NativeRuntimeReply(pid: 4, error: "Codex server panicked")
        reply.panicCount = 2
        reply.panicSite = "/build/codex-rs/core/src/codex.rs:900"
        XCTAssertEqual(NativeRuntimeHost.failureProbeSummary(reply), " probe=worker_alive server=panicked panics=2 panic_site=core/src/codex.rs:900")
        reply = NativeRuntimeReply(pid: 4, error: "Bearer secret-token /private/learner-document.pdf")
        reply.panicSite = "/private/learner document.pdf:3"
        let summary = NativeRuntimeHost.failureProbeSummary(reply)
        XCTAssertEqual(summary, " probe=worker_alive server=failed")
        reply = NativeRuntimeReply(pid: 4)
        reply.memoryFootprintBytes = 30
        reply.availableMemoryBytes = 5
        reply.panicCount = 0
        XCTAssertEqual(NativeRuntimeHost.failureProbeSummary(reply), " probe=worker_alive server=running panics=0 probe_footprint_bytes=30 probe_available_bytes=5")
    }

    func testTransportFailureWaitsForProbeAndReportsLastSample() {
        let exited = expectation(description: "one exit callback")
        exited.assertForOverFulfill = true
        let exit = NativeRuntimeExit { _ in exited.fulfill() }
        let release = DispatchSemaphore(value: 0)
        exit.prepare(probe: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { release.wait(); continuation.resume() }
            }
            return " probe=worker_unreachable"
        })
        exit.record(NativeMemoryObservation(snapshot: ["pid": 4, "footprint": 31_000_000, "available": 1_200_000, "lifetimePeak": 36_000_000], identity: "w", role: .codex))
        exit.finish(stage: "receive", error: NSError(domain: NSPOSIXErrorDomain, code: 57))
        XCTAssertNil(exit.detail, "probe結果が揃う前にexitを公開しない")
        XCTAssertFalse(exit.isOpen)
        exit.finish(stage: "worker_interruption")
        release.signal()
        wait(for: [exited], timeout: 3)
        let detail = exit.detail ?? ""
        XCTAssertTrue(detail.hasPrefix("native stage=receive domain=NSPOSIXErrorDomain code=57"), detail)
        XCTAssertTrue(detail.contains(" last_footprint_bytes=31000000 last_available_bytes=1200000 lifetime_peak_bytes=36000000 last_sample_age_ms="), detail)
        XCTAssertTrue(detail.hasSuffix(" probe=worker_unreachable interrupted_while_probing=1"), detail)
    }

    func testLocalCloseDoesNotProbe() {
        let exit = NativeRuntimeExit { _ in }
        exit.prepare(probe: { XCTFail("local close must not probe"); return "" })
        exit.finish(stage: "local_close")
        XCTAssertEqual(exit.detail, "native stage=local_close domain=none code=0 close_code=0 last_received_bytes=0 receive_limit=0")
    }

    func testWorkerInterruptionKeepsFirstExitReason() {
        let exited = expectation(description: "one exit callback")
        exited.assertForOverFulfill = true
        let exit = NativeRuntimeExit { _ in exited.fulfill() }
        exit.finish(stage: "worker_interruption")
        exit.finish(stage: "receive", error: NSError(domain: NSURLErrorDomain, code: -1005))
        XCTAssertTrue(exit.detail?.contains("stage=worker_interruption") == true)
        XCTAssertFalse(exit.detail?.contains("code=-1005") == true)
        wait(for: [exited], timeout: 1)
    }

    func testImmediateTransportFailureKeepsSocketMetadataAndCleansUp() {
        let exited = expectation(description: "exit")
        let cleaned = expectation(description: "late cleanup registration")
        let exit = NativeRuntimeExit { _ in exited.fulfill() }
        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:1")!)
        socket.maximumMessageSize = 123_456
        exit.prepare(socket: socket)
        // A task may fail before its cleanup closure has been attached.
        exit.finish(stage: "receive", error: NSError(domain: NSURLErrorDomain, code: -1005))
        exit.attach { socket.cancel(with: .goingAway, reason: nil); cleaned.fulfill() }
        XCTAssertTrue(exit.detail?.contains("receive_limit=123456") == true)
        XCTAssertTrue(exit.detail?.contains("stage=receive") == true)
        wait(for: [exited, cleaned], timeout: 1)
    }

    @MainActor func testStartupDisconnectionSurvivesAutomaticRetryAudit() async throws {
        let server = FakeAppServer { _, _, _ in .default }
        let session = CodexAppServerSession(clientVersion: "audit-test", launcher: server.launcher, abandonGrace: .milliseconds(300))
        let diagnostic = "native stage=worker_interruption domain=none code=0"
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts, ensureRuntime: {
            throw CodexAppServerError.closed(diagnostic)
        })
        let outcome = try await runner.run(Self.plan(threadID: nil)) { _ in }
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.executions.count, 2, "両方の起動失敗を台帳へ残す")
        for entry in outcome.executions {
            XCTAssertEqual(entry["type"]?.stringValue, "runtime_connection_failure")
            XCTAssertEqual(entry["diagnostic"]?.stringValue, diagnostic)
        }
        await session.close()
    }

    @MainActor func testTransportDiagnosticSurvivesSessionExit() async throws {
        let diagnostic = "websocket stage=receive domain=NSURLErrorDomain code=-1103 close_code=1009"
        let session = CodexAppServerSession(clientVersion: "diagnostic-test", launcher: { onLine, onExit in
            GuestProcessHandle(pid: 123, writeLine: { line in
                guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSONObject,
                      let id = message["id"] else { return }
                if message["method"] as? String == "account/read" {
                    onExit(-1)
                } else {
                    onLine(FakeAppServer.encode(["id": id, "result": [:]]), false)
                }
            }, exitDiagnostic: { diagnostic })
        })
        try await session.start()
        do {
            _ = try await session.request("account/read", params: [:])
            XCTFail("切断した要求は失敗する")
        } catch let error as CodexAppServerError {
            guard case .closed(let value) = error else { return XCTFail("切断のエラーを保つ") }
            XCTAssertEqual(value, diagnostic + " rpc_stage=account/read")
            XCTAssertEqual(error.localizedDescription, "AI が途中で止まりました。もう一度送ってください。")
        }
        await session.close()
    }

    func testRPCStageRejectsUnrecognizedOrPrivateLabels() {
        XCTAssertEqual(CodexAppServerSession.diagnosticMethod("thread/resume"), "thread/resume")
        XCTAssertEqual(CodexAppServerSession.diagnosticMethod(nil), "none")
        XCTAssertEqual(CodexAppServerSession.diagnosticMethod("Bearer secret /private/learner.pdf"), "other")
    }

    @MainActor func testSessionPreservesNotificationBurstOrder() async throws {
        let session = CodexAppServerSession(clientVersion: "ordered-input-test", launcher: { onLine, _ in
            GuestProcessHandle(pid: 123, writeLine: { line in
                guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSONObject,
                      let id = message["id"] else { return }
                if message["method"] as? String == "thread/read" {
                    for index in 0..<256 {
                        onLine(FakeAppServer.encode(["method": "test/ordered", "params": ["index": index]]), false)
                    }
                }
                onLine(FakeAppServer.encode(["id": id, "result": [:]]), false)
            })
        })
        _ = try await session.request("thread/read", params: [:])
        for index in 0..<256 {
            let event = try await session.waitForNotification(methods: ["test/ordered"], timeout: .seconds(5))
            XCTAssertEqual(event.params["index"] as? Int, index, "Transport order must survive the actor handoff")
        }
        await session.close()
    }

    @MainActor func testChatCompletionWithoutItemsKeepsEarlierAnswer() async throws {
        let server = FakeAppServer { _, method, _ in
            method == "turn/start" ? .answerTurnStartWithItemOnly : .default
        }
        let session = CodexAppServerSession(clientVersion: "item-only-test", launcher: server.launcher)
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts)
        var plan = Self.plan(threadID: nil)
        plan.kind = .chat
        defer { WorkspaceStager.cleanup(plan: plan) }
        let outcome = try await runner.run(plan) { _ in }
        XCTAssertEqual(outcome.status, .completed, outcome.error ?? "")
        XCTAssertEqual(outcome.finalText, "こたえ")
        XCTAssertEqual(server.count("turn/start"), 1, "Never replay an already completed chat")
        XCTAssertEqual(server.count("thread/turns/list"), 0, "Ordered item/completed already supplied the answer")
        await session.close()
    }

    @MainActor func testChatReadsCompletedAnswerWhenNotificationOmitsItems() async throws {
        let server = FakeAppServer { _, method, _ in
            if method == "turn/start" { return .answerTurnStartCompletionOnly }
            if method == "thread/turns/list" {
                return .result(["data": [["id": "turn-1-1", "status": "completed", "items": [
                    ["type": "agentMessage", "text": "保存されたこたえ"],
                ]]]])
            }
            return .default
        }
        let session = CodexAppServerSession(clientVersion: "completion-only-test", launcher: server.launcher)
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts)
        var plan = Self.plan(threadID: nil)
        plan.kind = .chat
        defer { WorkspaceStager.cleanup(plan: plan) }
        let outcome = try await runner.run(plan) { _ in }
        XCTAssertEqual(outcome.status, .completed, outcome.error ?? "")
        XCTAssertEqual(outcome.finalText, "保存されたこたえ")
        XCTAssertEqual(server.count("turn/start"), 1, "Recovery reads the result without another model call")
        XCTAssertEqual(server.count("thread/turns/list"), 1)
        await session.close()
    }

    @MainActor func testMissingCompletedAnswerStillFailsWithoutReplayingChat() async throws {
        let server = FakeAppServer { _, method, _ in
            method == "turn/start" ? .answerTurnStartCompletionOnly : .default
        }
        let session = CodexAppServerSession(clientVersion: "empty-completion-test", launcher: server.launcher)
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts)
        var plan = Self.plan(threadID: nil)
        plan.kind = .chat
        defer { WorkspaceStager.cleanup(plan: plan) }
        let outcome = try await runner.run(plan) { _ in }
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(server.count("turn/start"), 1)
        XCTAssertEqual(server.count("thread/turns/list"), 1)
        await session.close()
    }

    @MainActor func testResumeOmitsUnusedResponseHistory() async throws {
        let server = FakeAppServer { _, method, params in
            if method == "thread/resume" {
                XCTAssertEqual(params["excludeTurns"] as? Bool, true)
            }
            return .default
        }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, abandonGrace: .milliseconds(300))
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts)
        let outcome = try await runner.run(Self.plan(threadID: "existing-thread")) { _ in }
        XCTAssertEqual(outcome.status, .completed, outcome.error ?? "")
        XCTAssertEqual(server.count("thread/resume"), 1)
        XCTAssertEqual(server.count("turn/start"), 1)
        await session.close()
    }

    @MainActor func testMissingRolloutRecoveryDoesNotPassResumeOnlyFlagToStart() async throws {
        let server = FakeAppServer { _, method, params in
            if method == "thread/resume" {
                XCTAssertEqual(params["excludeTurns"] as? Bool, true)
                return .missingRollout
            }
            if method == "thread/start" {
                XCTAssertNil(params["excludeTurns"])
                XCTAssertNil(params["threadId"])
                XCTAssertTrue((params["developerInstructions"] as? String)?.contains("recent_thread_history.md") == true)
            }
            return .default
        }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, abandonGrace: .milliseconds(300))
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts)
        var plan = Self.plan(threadID: "missing-thread")
        plan.workspace.files.append(.init(path: "struis_context/recent_thread_history.md", inline: "Synthetic previous conversation"))
        defer { try? FileManager.default.removeItem(at: plan.hostWorkspace) }
        let outcome = try await runner.run(plan) { _ in }
        XCTAssertEqual(outcome.status, .completed, outcome.error ?? "")
        XCTAssertEqual(server.count("thread/resume"), 1)
        XCTAssertEqual(server.count("thread/start"), 1)
        await session.close()
    }

    // MARK: - (a) 停止の後の次の送信

    /// E2E H1: `turn/interrupt` is accepted but the guest task never finishes (no `turn/completed`).
    @MainActor func testSendAfterStopSucceedsWhenGuestNeverFinishesTheTurn() async throws {
        let server = FakeAppServer { generation, method, _ in
            // The first app-server wedges once a turn starts; later ones behave.
            if generation == 1, method == "turn/start" { return .answerTurnStart(completes: false) }
            return .default
        }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, abandonGrace: .milliseconds(300))
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts)

        let first = Self.plan(threadID: nil)
        let running = Task { try await runner.run(first) { _ in } }
        try await server.waitFor("turn/start", generation: 1)
        let stopped = Date()
        await runner.interrupt(planID: first.id)
        let interrupted = try await running.value
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 2, "停止は guest を待たずにすぐ終わる")
        let healthyAfterStop = await session.isHealthy
        XCTAssertFalse(healthyAfterStop, "turn/completed が来ていないので立て直しが要る")

        let second = try await runner.run(Self.plan(threadID: interrupted.codexThreadID)) { _ in }
        XCTAssertEqual(second.status, .completed, second.error ?? "")
        XCTAssertEqual(second.finalText, "こたえ")
        XCTAssertEqual(server.launches, 2, "次の送信の前に app-server を立て直す")
        XCTAssertTrue(server.terminated.contains(1))
    }

    /// When the guest reports the interrupted turn, the session stays and is not rebuilt.
    @MainActor func testSendAfterStopReusesHealthySession() async throws {
        let server = FakeAppServer { _, method, params in
            if method == "turn/start" { return .answerTurnStart(completes: FakeAppServer.text(params) != "止める") }
            if method == "turn/interrupt" { return .answerInterruptAndComplete }
            return .default
        }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, abandonGrace: .milliseconds(300))
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts)

        let first = Self.plan(threadID: nil, text: "止める")
        let running = Task { try await runner.run(first) { _ in } }
        try await server.waitFor("turn/start", generation: 1)
        await runner.interrupt(planID: first.id)
        let interrupted = try await running.value
        XCTAssertEqual(interrupted.status, .interrupted)
        try await server.waitFor("turn/interrupt", generation: 1)
        for _ in 0..<100 where !(await session.isHealthy) { try await Task.sleep(for: .milliseconds(20)) }
        let healthy = await session.isHealthy
        XCTAssertTrue(healthy)

        let second = try await runner.run(Self.plan(threadID: interrupted.codexThreadID)) { _ in }
        XCTAssertEqual(second.status, .completed, second.error ?? "")
        XCTAssertEqual(server.launches, 1)
    }

    // MARK: - (b) 要求の時間切れの後の次の送信

    /// E2E H1: after the stall, `thread/resume` was never answered and every resend failed until relaunch.
    @MainActor func testThreadResumeTimeoutRebuildsSessionAndSendSucceeds() async throws {
        let server = FakeAppServer { generation, method, _ in
            if generation == 1, method == "thread/resume" { return .ignore }
            return .default
        }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, abandonGrace: .milliseconds(300))
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts)

        let outcome = try await runner.run(Self.plan(threadID: "thr-existing")) { _ in }
        XCTAssertEqual(outcome.status, .completed, outcome.error ?? "")
        XCTAssertEqual(outcome.finalText, "こたえ")
        XCTAssertEqual(server.launches, 2, "時間切れで app-server を立て直してやり直す")
        XCTAssertEqual(server.count("thread/resume"), 2)

        let next = try await runner.run(Self.plan(threadID: "thr-existing")) { _ in }
        XCTAssertEqual(next.status, .completed, next.error ?? "")
        XCTAssertEqual(server.launches, 2, "立て直した後は同じ app-server を使う")
    }

    /// 2026-09-30: the answer started streaming and then went silent while the websocket stayed open,
    /// so the unit turn waited its whole limit and the learner saw 「全体像を作れませんでした」.
    @MainActor func testStalledStructuredAnswerIsRetriedOnAFreshThread() async throws {
        let server = FakeAppServer { generation, method, _ in
            if generation == 1, method == "turn/start" { return .answerTurnStartThenStall }
            return .default
        }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, abandonGrace: .milliseconds(300))
        var timeouts = Self.timeouts
        timeouts.messageStall = .milliseconds(300)
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: timeouts)

        let began = Date()
        let outcome = try await runner.run(Self.plan(threadID: nil)) { _ in }
        XCTAssertEqual(outcome.status, .completed, outcome.error ?? "")
        XCTAssertEqual(outcome.finalText, "こたえ")
        XCTAssertLessThan(Date().timeIntervalSince(began), 4, "ターン全体の上限(5秒)を待たずに作り直す")
        XCTAssertEqual(server.count("turn/start"), 2)
        XCTAssertEqual(server.count("thread/start"), 2, "作り直しは新しいスレッドで")
    }

    /// Codex in the app process keeps a closed connection's turns running. The next connection
    /// interrupts the stalled turn before anything else, so the retry cannot overlap it.
    @MainActor func testInProcessServerInterruptsTheStalledTurnBeforeRetrying() async throws {
        let seen = MessageLog()
        let server = FakeAppServer { generation, method, params in
            seen.append(generation, method, params)
            if generation == 1, method == "turn/start" { return .answerTurnStartThenStall }
            return .default
        }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, serverOutlivesConnection: true, abandonGrace: .milliseconds(300))
        var timeouts = Self.timeouts
        timeouts.messageStall = .milliseconds(300)
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: timeouts)
        let outcome = try await runner.run(Self.plan(threadID: nil)) { _ in }
        XCTAssertEqual(outcome.status, .completed, outcome.error ?? "")
        let second = seen.entries.filter { $0.generation == 2 }.map(\.method)
        let interrupt = try XCTUnwrap(seen.entries.first { $0.generation == 2 && $0.method == "turn/interrupt" })
        XCTAssertEqual(interrupt.turnID, "turn-1-1", "the stalled turn of the closed connection")
        XCTAssertEqual(Array(second.prefix(2)), ["initialize", "turn/interrupt"], "stopped before any other request")
        await session.close()
    }

    /// M5: a stale turn whose interrupt goes unanswered no longer stops the whole server. Other
    /// threads keep working; only that thread waits, and its next turn retries the stop.
    @MainActor func testUnansweredStaleStopHoldsOnlyItsThread() async throws {
        let answerInterrupts = LockedFlag()
        let server = FakeAppServer { generation, method, _ in
            if generation == 1, method == "turn/start" { return .answerTurnStartThenStall }
            if generation >= 2, method == "turn/interrupt", !answerInterrupts.value { return .ignore }
            return .default
        }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, serverOutlivesConnection: true,
                                            staleTurnStopTimeout: .milliseconds(300), abandonGrace: .milliseconds(300))
        var timeouts = Self.timeouts
        timeouts.messageStall = .milliseconds(300)
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: timeouts, contextStore: ThreadContextStore(url: nil))
        let outcome = try await runner.run(Self.plan(threadID: nil)) { _ in }
        XCTAssertEqual(outcome.status, .completed, "the structured retry runs on a fresh thread: \(outcome.error ?? "")")
        let stuckThread = "thr-1"
        let held = try await runner.run(Self.plan(threadID: stuckThread)) { _ in }
        XCTAssertEqual(held.status, .failed, "the stuck thread still waits for its old turn")
        XCTAssertEqual(held.error, CodexAppServerError.timeout("turn/interrupt").localizedDescription)
        answerInterrupts.value = true
        let released = try await runner.run(Self.plan(threadID: stuckThread)) { _ in }
        XCTAssertEqual(released.status, .completed, released.error ?? "")
        XCTAssertEqual(server.launches, 2, "no relaunch is needed")
        await session.close()
    }

    /// Learner-facing errors never carry method names (E2E M4).
    func testTimeoutErrorTextHasNoMethodNames() {
        let errors: [CodexAppServerError] = [
            .timeout("item/completed,item/started,model/rerouted,thread/tokenUsage/updated,turn/completed"),
            .unanswered("thread/resume"), .closed("exit 139"), .malformed("turn/start returned no turn id"),
            .rpc(code: -32600, message: "thread not found"), .turnFailed("Turn failed"), .notRunning,
        ]
        for error in errors {
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("/"), text)
            for word in ["thread", "turn", "item", "exit", "rpc", "Codex", "("] { XCTAssertFalse(text.contains(word), text) }
            XCTAssertTrue(text.hasSuffix("。"), text)
        }
        XCTAssertTrue(CodexAppServerError.unanswered("thread/resume").detail.contains("thread/resume"))
    }

    // MARK: - (c) 起動時の後始末

    @MainActor func testLaunchRecoveryMarksAbandonedChatTurnInterrupted() async throws {
        let ledger = try Ledger.inMemory()
        let seeded = try await Self.seedAbandonedChat(ledger)
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: StubRunner())

        await turns.resumeUnfinished()

        let (turn, assistant, user) = try await ledger.read { db in
            (try TurnRecord.fetchOne(db, key: seeded.turnID), try MessageRecord.fetchOne(db, key: seeded.assistantID), try MessageRecord.fetchOne(db, key: seeded.userID))
        }
        XCTAssertEqual(turn?.status, "interrupted")
        XCTAssertEqual(assistant?.status, "failed")
        XCTAssertEqual(assistant?.plainText, "止まりました。")
        XCTAssertEqual(assistant?.metadata["retryable"]?.boolValue, true)
        XCTAssertEqual(user?.status, "completed")
        let message = ChatRepository.chatMessage(try XCTUnwrap(assistant))
        XCTAssertTrue(message.isRetryable)
        XCTAssertEqual(message.status, .failed)
    }

    @MainActor func testRetryReRunsAbandonedReplyInPlace() async throws {
        let ledger = try Ledger.inMemory()
        let seeded = try await Self.seedAbandonedChat(ledger)
        let runner = StubRunner()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: runner)
        await turns.resumeUnfinished()

        let result = try await turns.retryChat(assistantMessageID: seeded.assistantID)
        XCTAssertEqual(result.assistantMessageID, seeded.assistantID)
        XCTAssertEqual(result.userMessageID, seeded.userID)
        for _ in 0..<200 {
            let running = await turns.isChatRunning(threadID: seeded.threadID)
            if !running { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let (messages, newTurn) = try await ledger.read { db in
            (try ChatRepository.messages(db, threadID: seeded.threadID), try TurnRecord.fetchOne(db, key: result.turnID))
        }
        XCTAssertEqual(messages.count, 2, "送り直しで吹き出しは増えない")
        XCTAssertEqual(runner.chatRuns, 1)
        XCTAssertEqual(newTurn?.plan["chat"]?["user_message_id"]?.stringValue, seeded.userID)
        XCTAssertNotEqual(newTurn?.status, "queued")
        XCTAssertNotEqual(newTurn?.status, "running")
    }

    // MARK: - Fixtures

    private static let timeouts = CodexTurnRunner.Timeouts(
        configure: .milliseconds(400), inject: .milliseconds(400), turnStart: .seconds(2),
        interrupt: .milliseconds(400), rateLimits: .milliseconds(400), minimumTurnS: 5
    )

    private static func assets() -> AssetCache {
        AssetCache(root: FileManager.default.temporaryDirectory.appendingPathComponent("turn-recovery-\(UUID().uuidString)"), lenient: true)
    }

    private static func plan(threadID: String?, text: String = "問題を作って") -> TurnPlan {
        let id = LedgerID.make()
        return TurnPlan(
            id: id, kind: .workbookSet, round: 1,
            thread: TurnPlan.ThreadSpec(
                codexThreadID: threadID, mode: threadID == nil ? .start : .resume, cwd: TurnPlan.guestWorkspace(id: id),
                model: "gpt-test", effort: "low", ephemeral: false,
                baseInstructions: TurnPlan.AssetRef(asset: "prompt:base", sha256: "unavailable"), developerInstructions: nil,
                developerText: "test", injectDeveloperOnResume: false, config: .object([:]), lastTurnID: nil
            ),
            turn: TurnPlan.TurnSpec(text: text, images: [], outputSchema: nil, sandboxPolicy: "dangerFullAccess"),
            workspace: TurnPlan.WorkspaceSpec(files: [], dirs: []), delegation: nil, collect: [],
            limits: TurnPlan.Limits(collectMaxFiles: 0, collectMaxBytes: 0, turnTimeoutS: 5), items: nil
        )
    }

    private struct Seeded {
        var threadID: String
        var userID: String
        var assistantID: String
        var turnID: String
    }

    /// A chat turn the previous process left `running`, with its pending reply.
    private static func seedAbandonedChat(_ ledger: Ledger) async throws -> Seeded {
        let (thread, threadEvent) = ChatRepository.createThread(title: "質問")
        let (user, userEvent) = ChatRepository.createMessage(
            threadID: thread.id, role: "user", status: "completed", plainText: "一次関数の傾きって何？",
            blocks: .array([.object(["kind": .string("text"), "payload": .object(["text": .string("一次関数の傾きって何？")])])]),
            metadata: .object(["attachments": .emptyArray])
        )
        let (assistant, assistantEvent) = ChatRepository.createMessage(
            threadID: thread.id, role: "assistant", status: "pending", plainText: nil, blocks: .emptyArray,
            metadata: .object(["handled_as": .string("codex_app_server")])
        )
        let turn = TurnRecord(
            id: LedgerID.make(), kind: "chat", targetId: assistant.id, threadId: thread.id, status: "running", round: 1,
            plan: .object(["chat": .object(["thread_id": .string(thread.id), "user_message_id": .string(user.id), "assistant_message_id": .string(assistant.id)])]),
            outcome: nil, codexThreadId: nil, codexTurnId: nil, executions: .emptyArray, error: nil,
            createdAt: LedgerClock.now(), startedAt: LedgerClock.now(), completedAt: nil
        )
        try await ledger.append([threadEvent, userEvent, assistantEvent, .upsert("turn.running", turn)])
        return Seeded(threadID: thread.id, userID: user.id, assistantID: assistant.id, turnID: turn.id)
    }
}

/// Counts chat runs and answers with a canned failure so the retry finishes without a model.
nonisolated private final class StubRunner: TurnRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0
    var chatRuns: Int { lock.withLock { runs } }

    func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome {
        lock.withLock { runs += 1 }
        return TurnOutcome(
            planID: plan.id, round: plan.round, status: .failed, codexThreadID: nil, codexTurnID: nil, finalText: "",
            executions: [], rateLimits: nil, files: [], error: CodexAppServerError.closed("stub").localizedDescription, elapsedMs: 1
        )
    }

    func interrupt(planID: String) async {}
}

/// Requests in arrival order, as the fake server saw them.
nonisolated final class MessageLog: @unchecked Sendable {
    struct Entry { let generation: Int; let method: String; let turnID: String? }
    private let lock = NSLock()
    private var stored: [Entry] = []
    func append(_ generation: Int, _ method: String, _ params: JSONObject) {
        lock.withLock { stored.append(Entry(generation: generation, method: method, turnID: params["turnId"] as? String)) }
    }
    var entries: [Entry] { lock.withLock { stored } }
}

/// A scripted `codex app-server` speaking JSON-RPC lines through a `GuestProcessHandle`.
nonisolated final class FakeAppServer: @unchecked Sendable {
    enum Reply {
        case `default`
        case ignore
        case missingRollout
        case answerTurnStart(completes: Bool)
        case answerTurnStartWithItemOnly
        case answerTurnStartCompletionOnly
        case answerInterruptAndComplete
        /// The answer starts (`item/started` agentMessage) and then nothing more arrives.
        case answerTurnStartThenStall
        /// Answers with this result.
        case result(JSONObject)
        /// The turn starts, then the connection closes (iOS reclaimed the socket); the server keeps it.
        case answerTurnStartThenDisconnect
        /// Answers the interrupt now and reports the interrupted turn after `seconds`.
        case answerInterruptThenCompleteLater(Double)
    }

    /// Params of every request, in arrival order.
    private var paramLog: [(generation: Int, method: String, params: JSONObject)] = []
    func params(_ method: String) -> [JSONObject] { lock.withLock { paramLog.filter { $0.method == method }.map(\.params) } }

    typealias Script = @Sendable (_ generation: Int, _ method: String, _ params: JSONObject) -> Reply

    private let lock = NSLock()
    private let script: Script
    private var launchCount = 0
    private var log: [(generation: Int, method: String)] = []
    private var terminatedGenerations: Set<Int> = []
    private var turnSerial = 0
    /// Turns started but not completed, per generation (thread, turn).
    private var openTurns: [Int: [(String, String)]] = [:]

    init(script: @escaping Script) { self.script = script }

    var launches: Int { lock.withLock { launchCount } }
    var terminated: Set<Int> { lock.withLock { terminatedGenerations } }
    func count(_ method: String) -> Int { lock.withLock { log.filter { $0.method == method }.count } }

    func waitFor(_ method: String, generation: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<250 {
            if lock.withLock({ log.contains { $0.generation == generation && $0.method == method } }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("\(method) never reached generation \(generation)", file: file, line: line)
    }

    static func text(_ params: JSONObject) -> String? {
        (params["input"] as? [JSONObject])?.first?["text"] as? String
    }

    var launcher: CodexAppServerSession.Launcher {
        { [self] onLine, onExit in
            let generation = lock.withLock { () -> Int in
                launchCount += 1
                return launchCount
            }
            return GuestProcessHandle(
                pid: Int32(generation),
                writeLine: { [self] line in handle(line: line, generation: generation, output: onLine, exit: onExit) },
                terminate: { [self] in _ = lock.withLock { terminatedGenerations.insert(generation) } }
            )
        }
    }

    private func handle(line: String, generation: Int, output: @escaping @Sendable (String, Bool) -> Void,
                        exit: @escaping @Sendable (Int32) -> Void = { _ in }) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
              let method = message["method"] as? String, let id = message["id"]
        else { return }
        let params = message["params"] as? JSONObject ?? [:]
        let dead = lock.withLock { () -> Bool in
            log.append((generation, method))
            paramLog.append((generation, method, params))
            return terminatedGenerations.contains(generation)
        }
        if dead { return }
        let threadID = params["threadId"] as? String ?? "thr-\(generation)"
        switch script(generation, method, params) {
        case .ignore:
            return
        case .missingRollout:
            output(Self.encode(["id": id, "error": ["code": -32600, "message": "no rollout found for thread id"]]), false)
        case .answerTurnStart(let completes):
            startTurn(id: id, threadID: threadID, generation: generation, completes: completes, output: output)
        case .answerTurnStartWithItemOnly:
            startTurn(id: id, threadID: threadID, generation: generation, completes: true, includeCompletionText: false, output: output)
        case .answerTurnStartCompletionOnly:
            startTurn(id: id, threadID: threadID, generation: generation, completes: true, includeItem: false, includeCompletionText: false, output: output)
        case .answerTurnStartThenStall:
            startTurn(id: id, threadID: threadID, generation: generation, completes: false, output: output)
            let turn = lock.withLock { openTurns[generation]?.last?.1 ?? "" }
            output(Self.encode(["method": "item/started", "params": ["threadId": threadID, "turnId": turn, "item": ["type": "agentMessage", "id": "msg-stalled", "text": ""]]]), false)
            output(Self.encode(["method": "item/agentMessage/delta", "params": ["threadId": threadID, "turnId": turn, "itemId": "msg-stalled", "delta": "{"]]), false)
        case .result(let result):
            output(Self.encode(["id": id, "result": result]), false)
        case .answerTurnStartThenDisconnect:
            startTurn(id: id, threadID: threadID, generation: generation, completes: false, output: output)
            lock.withLock { _ = terminatedGenerations.insert(generation) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { exit(-1) }
        case .answerInterruptThenCompleteLater(let seconds):
            output(Self.encode(["id": id, "result": [:]]), false)
            let turn = params["turnId"] as? String ?? ""
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                output(Self.turnCompleted(thread: threadID, turn: turn, status: "interrupted", text: nil), false)
            }
        case .answerInterruptAndComplete:
            output(Self.encode(["id": id, "result": [:]]), false)
            let turn = params["turnId"] as? String ?? ""
            _ = lock.withLock { openTurns[generation]?.removeAll { $0.1 == turn } }
            output(Self.turnCompleted(thread: threadID, turn: turn, status: "interrupted", text: nil), false)
        case .default:
            switch method {
            case "thread/start":
                output(Self.encode(["id": id, "result": ["thread": ["id": "thr-\(generation)"]]]), false)
            case "thread/resume":
                output(Self.encode(["id": id, "result": ["thread": ["id": threadID]]]), false)
            case "turn/start":
                startTurn(id: id, threadID: threadID, generation: generation, completes: true, output: output)
            default:
                output(Self.encode(["id": id, "result": [:]]), false)
            }
        }
    }

    private func startTurn(id: Any, threadID: String, generation: Int, completes: Bool,
                           includeItem: Bool = true, includeCompletionText: Bool = true,
                           output: @escaping @Sendable (String, Bool) -> Void) {
        let turn = lock.withLock { () -> String in
            turnSerial += 1
            let turn = "turn-\(generation)-\(turnSerial)"
            if !completes { openTurns[generation, default: []].append((threadID, turn)) }
            return turn
        }
        output(Self.encode(["id": id, "result": ["turn": ["id": turn]]]), false)
        guard completes else { return }
        if includeItem {
            output(Self.encode(["method": "item/completed", "params": ["threadId": threadID, "turnId": turn, "item": ["type": "agentMessage", "text": "こたえ"]]]), false)
        }
        output(Self.turnCompleted(thread: threadID, turn: turn, status: "completed", text: includeCompletionText ? "こたえ" : nil), false)
    }

    static func turnCompleted(thread: String, turn: String, status: String, text: String?) -> String {
        var items: [Any] = []
        if let text { items.append(["type": "agentMessage", "text": text]) }
        return encode(["method": "turn/completed", "params": ["threadId": thread, "turn": ["id": turn, "status": status, "items": items]]])
    }

    static func encode(_ object: JSONObject) -> String {
        (try? CodexAppServerSession.encode(object)) ?? "{}"
    }
}
