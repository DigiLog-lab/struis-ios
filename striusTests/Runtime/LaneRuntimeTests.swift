import GRDB
import XCTest
@testable import strius

/// 信頼性計画 P1・P4(3〜6)のランタイム: 会話ごとの cwd、読み込み済みスレッドへの resume の省略、
/// 期限の時計と記録、接続が切れた後の入り直し、利用枠の読み取りの切り離し、終わったスレッドの unsubscribe。
final class LaneRuntimeTests: XCTestCase {
    private static let timeouts = CodexTurnRunner.Timeouts(
        configure: .milliseconds(600), inject: .milliseconds(600), turnStart: .seconds(2),
        interrupt: .milliseconds(400), rateLimits: .milliseconds(300), minimumTurnS: 5
    )

    private static func assets() -> AssetCache {
        AssetCache(root: FileManager.default.temporaryDirectory.appendingPathComponent("lane-a-\(UUID().uuidString)"), lenient: true)
    }

    private static func chatPlan(threadID: String?, limit: Int = 5, inject: Bool = true) -> TurnPlan {
        let id = LedgerID.make()
        return TurnPlan(
            id: id, kind: .chat, round: 1,
            thread: TurnPlan.ThreadSpec(
                codexThreadID: threadID, mode: threadID == nil ? .start : .resume, cwd: "",
                model: "gpt-test", effort: "low", ephemeral: false,
                baseInstructions: TurnPlan.AssetRef(asset: "prompt:base", sha256: "unavailable"), developerInstructions: nil,
                developerText: "developer", injectDeveloperOnResume: inject && threadID != nil, config: .object([:]), lastTurnID: nil
            ),
            turn: TurnPlan.TurnSpec(text: "質問", images: [], outputSchema: nil, sandboxPolicy: "dangerFullAccess"),
            workspace: TurnPlan.WorkspaceSpec(files: [TurnPlan.FileSpec(path: "AGENTS.md", inline: "rules")], dirs: []), delegation: nil, collect: [],
            limits: TurnPlan.Limits(collectMaxFiles: 0, collectMaxBytes: 0, turnTimeoutS: limit), items: nil,
            workspaceKey: threadID.flatMap { TurnPlan.threadWorkspaceKey(codexThreadID: $0) }
        )
    }

    private static func structuredPlan() -> TurnPlan {
        var plan = chatPlan(threadID: nil)
        plan.kind = .workbookSet
        plan.workspaceKey = nil
        return plan
    }

    // MARK: - P1-1 / P1-2

    /// The turns of one conversation share one cwd, and a thread loaded on this connection is not
    /// resumed again (its instructions are not re-sent). The developer message enters once.
    @MainActor func testConversationKeepsOneCwdAndResumesOnlyOncePerConnection() async throws {
        let server = FakeAppServer { _, _, _ in .default }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, abandonGrace: .milliseconds(300))
        let store = ThreadContextStore(url: nil)
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts, contextStore: store)

        let first = try await runner.run(Self.chatPlan(threadID: nil)) { _ in }
        XCTAssertEqual(first.status, .completed, first.error ?? "")
        let thread = try XCTUnwrap(first.codexThreadID)
        for _ in 0..<3 {
            let next = try await runner.run(Self.chatPlan(threadID: thread)) { _ in }
            XCTAssertEqual(next.status, .completed, next.error ?? "")
        }
        XCTAssertEqual(server.count("thread/start"), 1)
        XCTAssertEqual(server.count("thread/resume"), 0, "loaded on this connection: no resume")
        XCTAssertEqual(server.count("thread/inject_items"), 0, "the thread already holds this developer message")
        let cwds = Set(server.params("turn/start").compactMap { $0["cwd"] as? String })
        XCTAssertEqual(cwds.count, 1, "one cwd for the whole conversation: \(cwds)")
        XCTAssertTrue(cwds.first?.hasSuffix("/thread-\(thread)") == true)

        // After a reconnect the thread is resumed once again (to subscribe), still without re-sending the developer message.
        await session.restart()
        let afterReconnect = try await runner.run(Self.chatPlan(threadID: thread)) { _ in }
        XCTAssertEqual(afterReconnect.status, .completed, afterReconnect.error ?? "")
        let again = try await runner.run(Self.chatPlan(threadID: thread)) { _ in }
        XCTAssertEqual(again.status, .completed, again.error ?? "")
        XCTAssertEqual(server.count("thread/resume"), 1)
        // The thread is resumed in the (trusted) workspace root; its turns keep their own directory.
        XCTAssertEqual(server.params("thread/resume").first?["cwd"] as? String, HyotanBoot.workspaceRoot.path)
        XCTAssertEqual(Set(server.params("turn/start").compactMap { $0["cwd"] as? String }), cwds)
        XCTAssertEqual(server.count("thread/inject_items"), 0)
        await session.close()
    }

    /// A thread whose developer message is unknown (made before this version) or outdated gets the
    /// current one once, not on every turn.
    @MainActor func testOutdatedDeveloperMessageIsInjectedOnce() async throws {
        let server = FakeAppServer { _, _, _ in .default }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, abandonGrace: .milliseconds(300))
        let store = ThreadContextStore(url: nil)
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts, contextStore: store)
        for _ in 0..<3 {
            let outcome = try await runner.run(Self.chatPlan(threadID: "thr-old")) { _ in }
            XCTAssertEqual(outcome.status, .completed, outcome.error ?? "")
        }
        XCTAssertEqual(server.count("thread/resume"), 1)
        XCTAssertEqual(server.count("thread/inject_items"), 1)
        await session.close()
    }

    // MARK: - P4-3

    /// The deadline ends the turn, records that Struis (not the learner) stopped it, and tells the
    /// model on the next turn of the thread.
    @MainActor func testDeadlineIsRecordedAsStruisStopAndToldToTheModel() async throws {
        let server = FakeAppServer { _, method, params in
            if method == "turn/start", FakeAppServer.text(params) == "質問", params["threadId"] as? String == "thr-slow" {
                return .answerTurnStart(completes: false)
            }
            return .default
        }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, abandonGrace: .milliseconds(300))
        let store = ThreadContextStore(url: nil)
        var timeouts = Self.timeouts
        timeouts.minimumTurnS = 1
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: timeouts, contextStore: store)
        let began = Date()
        let outcome = try await runner.run(Self.chatPlan(threadID: "thr-slow", limit: 1)) { _ in }
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertLessThan(Date().timeIntervalSince(began), 4)
        let audit = try XCTUnwrap(outcome.executions.last)
        XCTAssertEqual(audit["status"]?.stringValue, "timed_out")
        XCTAssertEqual(audit["stopped_by"]?.stringValue, "deadline")
        XCTAssertEqual(store.entry("thr-slow")?.notices?.count, 1)

        var next = Self.chatPlan(threadID: "thr-slow", inject: false)
        next.turn?.text = "次"
        let after = try await runner.run(next) { _ in }
        XCTAssertEqual(after.status, .completed, after.error ?? "")
        let injected = server.params("thread/inject_items").compactMap { ($0["items"] as? [JSONObject])?.first?["content"] as? [JSONObject] }
        XCTAssertTrue(injected.contains { $0.contains { ($0["text"] as? String)?.contains("The learner did not interrupt it") == true } })
        XCTAssertNil(store.entry("thr-slow")?.notices)
        await session.close()
    }

    /// Time the app spent in the background (where iOS may suspend it) does not count; a slow
    /// foreground (heavy load) still counts in full, so the deadline always ends a stalled turn.
    func testActiveClockSkipsBackgroundTimeOnly() {
        let fake = FakeUptime()
        let clock = ActiveClock(uptime: { fake.value })
        let start = clock.now
        fake.value += 120  // a slow foreground: counted
        XCTAssertEqual(clock.now - start, 120, accuracy: 0.001)
        clock.pause()
        fake.value += 600  // ten minutes in the background
        XCTAssertEqual(clock.now - start, 120, accuracy: 0.001)
        clock.resume()
        fake.value += 5
        XCTAssertEqual(clock.now - start, 125, accuracy: 0.001)
        XCTAssertEqual(clock.skippedSeconds, 600, accuracy: 0.001)
    }

    // MARK: - P4-5

    /// H1: the connection closes while the in-app server keeps running the turn. The runner subscribes
    /// again and takes the turn's result; the turn is neither interrupted nor started a second time.
    /// 開始と終了が近接して届いても、全部終わった後にバックグラウンド実行を持ちっぱなしにしない。
    @MainActor func testBackgroundActivityCountsBeginAndEndInCallOrder() async {
        let activity = BackgroundTurnActivity.shared
        let before = activity.runningCount
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    BackgroundTurnActivity.begin()
                    BackgroundTurnActivity.end()
                }
            }
        }
        XCTAssertEqual(activity.runningCount, before)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(activity.runningCount, before)
    }

    @MainActor func testTurnIsReenteredAfterTheConnectionCloses() async throws {
        let server = FakeAppServer { generation, method, params in
            if generation == 1, method == "turn/start" { return .answerTurnStartThenDisconnect }
            if method == "thread/turns/list" {
                return .result(["data": [["id": "turn-1-1", "status": "completed", "items": [["type": "agentMessage", "text": "こたえ"]]]]])
            }
            return .default
        }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, serverOutlivesConnection: true, abandonGrace: .milliseconds(300))
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts, contextStore: ThreadContextStore(url: nil))
        let outcome = try await runner.run(Self.chatPlan(threadID: "thr-live")) { _ in }
        XCTAssertEqual(outcome.status, .completed, outcome.error ?? "")
        XCTAssertEqual(outcome.finalText, "こたえ")
        XCTAssertEqual(outcome.codexTurnID, "turn-1-1")
        XCTAssertEqual(server.count("turn/start"), 1, "the same input is not sent again")
        XCTAssertEqual(server.count("turn/interrupt"), 0, "the running turn is not stopped")
        XCTAssertEqual(outcome.executions.last?["reattached"]?.intValue, 1)
        await session.close()
    }

    /// H4/M3: a slow rate-limit read neither delays the result nor rebuilds the connection.
    @MainActor func testSlowRateLimitReadKeepsTheConnection() async throws {
        let server = FakeAppServer { _, method, _ in method == "account/rateLimits/read" ? .ignore : .default }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, abandonGrace: .milliseconds(300))
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts, contextStore: ThreadContextStore(url: nil))
        let began = Date()
        let first = try await runner.run(Self.chatPlan(threadID: nil)) { _ in }
        XCTAssertEqual(first.status, .completed, first.error ?? "")
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.3, "the result does not wait for the rate limits")
        try await Task.sleep(for: .milliseconds(500))
        let healthy = await session.isHealthy
        XCTAssertTrue(healthy)
        let second = try await runner.run(Self.chatPlan(threadID: first.codexThreadID)) { _ in }
        XCTAssertEqual(second.status, .completed, second.error ?? "")
        XCTAssertEqual(server.launches, 1)
        await session.close()
    }

    /// H4: a stop followed at once by a new send waits for the stopped turn to end instead of
    /// rebuilding the connection under a structured turn running in parallel.
    @MainActor func testSendRightAfterStopDoesNotTearDownParallelTurns() async throws {
        let server = FakeAppServer { _, method, params in
            if method == "turn/start", FakeAppServer.text(params) == "止める" { return .answerTurnStart(completes: false) }
            if method == "turn/interrupt" { return .answerInterruptThenCompleteLater(0.15) }
            return .default
        }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, serverOutlivesConnection: true, abandonGrace: .seconds(3))
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts, contextStore: ThreadContextStore(url: nil))
        var stopped = Self.chatPlan(threadID: "thr-a")
        stopped.turn?.text = "止める"
        let running = Task { try await runner.run(stopped) { _ in } }
        try await server.waitFor("turn/start", generation: 1)
        await runner.interrupt(planID: stopped.id)
        let interrupted = try await running.value
        XCTAssertEqual(interrupted.status, .interrupted)
        let next = try await runner.run(Self.chatPlan(threadID: "thr-a")) { _ in }
        XCTAssertEqual(next.status, .completed, next.error ?? "")
        XCTAssertEqual(server.launches, 1, "no rebuild: the stopped turn reported its end within the grace")
        await session.close()
    }

    // MARK: - P4-6

    @MainActor func testFinishedStructuredThreadIsUnsubscribed() async throws {
        let server = FakeAppServer { _, _, _ in .default }
        let session = CodexAppServerSession(clientVersion: "test", launcher: server.launcher, abandonGrace: .milliseconds(300))
        let runner = CodexTurnRunner(session: session, assets: Self.assets(), timeouts: Self.timeouts, contextStore: ThreadContextStore(url: nil))
        let outcome = try await runner.run(Self.structuredPlan()) { _ in }
        XCTAssertEqual(outcome.status, .completed, outcome.error ?? "")
        try await server.waitFor("thread/unsubscribe", generation: 1)
        XCTAssertEqual(server.params("thread/unsubscribe").first?["threadId"] as? String, outcome.codexThreadID)
        let chat = try await runner.run(Self.chatPlan(threadID: nil)) { _ in }
        XCTAssertEqual(chat.status, .completed)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(server.count("thread/unsubscribe"), 1, "a conversation thread stays subscribed")
        await session.close()
    }

    // MARK: - Workspace

    /// The conversation directory stays after a turn (it is the thread's cwd); only the turn's files go.
    func testThreadWorkspaceCleanupKeepsTheDirectory() throws {
        var plan = Self.chatPlan(threadID: "thr-clean")
        plan.workspace.files.append(TurnPlan.FileSpec(path: "struis_context/recent_thread_history.md", inline: "history"))
        try WorkspaceStager.prepare(plan: plan, assets: Self.assets())
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.hostWorkspace.appendingPathComponent("AGENTS.md").path))
        WorkspaceStager.cleanup(plan: plan)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.hostWorkspace.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: plan.hostWorkspace.path), [])
        try FileManager.default.removeItem(at: plan.hostWorkspace)
        XCTAssertNil(TurnPlan.threadWorkspaceKey(codexThreadID: "../x"))
    }

    // MARK: - P1-4 差し戻し

    func testInvalidEscapesInProgressJSONAreRepaired() throws {
        let reply = #"答え<struis_progress_update>{"reply_quotes": ["\(x^2\) を展開"], "note": "a\\b \n ok あ"}</struis_progress_update>"#
        let (visible, raw) = try LearningProgress.extractUpdate(reply)
        XCTAssertEqual(visible, "答え")
        XCTAssertEqual((raw["reply_quotes"] as? [String])?.first, #"\(x^2\) を展開"#)
        XCTAssertEqual(raw["note"] as? String, "a\\b \n ok あ")
        XCTAssertThrowsError(try LearningProgress.extractUpdate("<struis_progress_update>{\"a\": }</struis_progress_update>"))
    }

    func testQuoteMatchingToleratesSpacingWidthAndMathMarks() throws {
        let body = "傾きは **2**、切片は $3$ です。\n次に x＝4 を代入しよう。"
        XCTAssertNoThrow(try LearningProgress.requireQuote("傾きは 2、切片は 3 です。", in: body, field: "reply"))
        XCTAssertNoThrow(try LearningProgress.requireQuote("次に x=4 を代入しよう", in: body, field: "reply"))
        XCTAssertThrowsError(try LearningProgress.requireQuote("傾きは 5 です", in: body, field: "reply"))
    }

    func testRepairRoundKeepsTheWrittenReply() {
        XCTAssertEqual(ChatTurns.visibleReply(of: "いいね！次は x=4。\n<struis_progress_update>{bad</struis_progress_update>\n<struis_memory_update>NO_UPDATE</struis_memory_update>"),
                       "いいね！次は x=4。")
        XCTAssertEqual(ChatTurns.visibleReply(of: "<struis_progress_update>{}</struis_progress_update>"), "")
    }
}

/// P4-4: model-started steps resume once on their own after a relaunch; interrupted replies fold.
final class LaneRecoveryTests: XCTestCase {
    private struct Seeded {
        var threadID: String
        var userID: String
        var assistantID: String
    }

    /// A reply the previous process left pending, behind a user message with `userMetadata`.
    private static func seed(_ ledger: Ledger, userMetadata: [String: LedgerJSON], replyMetadata: [String: LedgerJSON] = [:]) async throws -> Seeded {
        let (thread, threadEvent) = ChatRepository.createThread(title: "小単元")
        let (user, userEvent) = ChatRepository.createMessage(
            threadID: thread.id, role: "user", status: "completed", plainText: "起動",
            blocks: .array([.object(["kind": .string("text"), "payload": .object(["text": .string("起動")])])]),
            metadata: .object(["attachments": .emptyArray].merging(userMetadata) { $1 })
        )
        let (assistant, assistantEvent) = ChatRepository.createMessage(
            threadID: thread.id, role: "assistant", status: "pending", plainText: nil, blocks: .emptyArray,
            metadata: .object(["handled_as": .string("codex_app_server")].merging(replyMetadata) { $1 })
        )
        let turn = TurnRecord(
            id: LedgerID.make(), kind: "chat", targetId: assistant.id, threadId: thread.id, status: "running", round: 1,
            plan: .object(["chat": .object(["thread_id": .string(thread.id), "user_message_id": .string(user.id), "assistant_message_id": .string(assistant.id)])]),
            outcome: nil, codexThreadId: nil, codexTurnId: nil, executions: .emptyArray, error: nil,
            createdAt: LedgerClock.now(), startedAt: LedgerClock.now(), completedAt: nil
        )
        try await ledger.append([threadEvent, userEvent, assistantEvent, .upsert("turn.running", turn)])
        return Seeded(threadID: thread.id, userID: user.id, assistantID: assistant.id)
    }

    private static func waitIdle(_ turns: TurnCoordinator, threadID: String, runner: CountingRunner, runs: Int) async throws {
        for _ in 0..<300 {
            let running = await turns.isChatRunning(threadID: threadID)
            if runner.runs >= runs, !running { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor func testKickoffResumesOnceAfterRelaunch() async throws {
        let ledger = try Ledger.inMemory()
        let seeded = try await Self.seed(ledger, userMetadata: ["hidden": .bool(true), "source": .string("struis_kickoff")])
        let runner = CountingRunner()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: runner)
        await turns.resumeUnfinished()
        try await Self.waitIdle(turns, threadID: seeded.threadID, runner: runner, runs: 1)
        XCTAssertEqual(runner.runs, 1, "resumed without the learner")
        let reply = try await ledger.read { db in try MessageRecord.fetchOne(db, key: seeded.assistantID) }
        XCTAssertEqual(reply?.metadata["auto_resumed"]?.boolValue, true)
        XCTAssertEqual(reply?.status, "failed", "the stub fails: the learner now gets the recovery")
        XCTAssertEqual(reply?.metadata["retryable"]?.boolValue, false, "a kickoff has one recovery action: the subunit's restart")
    }

    /// 3.5: 失敗した返事には学習者向けの一文と別に、理由(診断の文)が `error_detail` に残り、画面で読める。
    @MainActor func testFailedReplyKeepsTheDiagnosticDetail() async throws {
        let ledger = try Ledger.inMemory()
        let seeded = try await Self.seed(ledger, userMetadata: ["hidden": .bool(true), "source": .string("struis_kickoff")])
        let runner = CountingRunner()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: runner)
        await turns.resumeUnfinished()
        try await Self.waitIdle(turns, threadID: seeded.threadID, runner: runner, runs: 1)
        let reply = try await ledger.read { db in try MessageRecord.fetchOne(db, key: seeded.assistantID) }
        XCTAssertEqual(reply?.status, "failed")
        XCTAssertEqual(reply?.plainText, CodexAppServerError.closed("stub").localizedDescription, "学習者向けの一文はそのまま")
        XCTAssertEqual(reply?.metadata["error_detail"]?.stringValue, "closed stub", "理由が残っていない")
        let message = ChatRepository.chatMessage(try XCTUnwrap(reply))
        XCTAssertEqual(message.errorDetail, "closed stub")
    }

    @MainActor func testResumedStepDoesNotResumeAgain() async throws {
        let ledger = try Ledger.inMemory()
        let seeded = try await Self.seed(ledger, userMetadata: ["model_text": .string("単元づくりの依頼")], replyMetadata: ["auto_resumed": .bool(true)])
        let runner = CountingRunner()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: runner)
        await turns.resumeUnfinished()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(runner.runs, 0)
        let reply = try await ledger.read { db in try MessageRecord.fetchOne(db, key: seeded.assistantID) }
        XCTAssertEqual(reply?.metadata["retryable"]?.boolValue, true, "unit creation keeps 「送り直す」")
    }

    @MainActor func testLearnerMessageIsNotResumedAutomatically() async throws {
        let ledger = try Ledger.inMemory()
        _ = try await Self.seed(ledger, userMetadata: [:])
        let runner = CountingRunner()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: runner)
        await turns.resumeUnfinished()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(runner.runs, 0)
    }

    @MainActor func testInterruptedRepliesFoldWhenALaterReplyCompletes() async throws {
        let ledger = try Ledger.inMemory()
        let (thread, threadEvent) = ChatRepository.createThread(title: "質問")
        var events = [threadEvent]
        var stoppedIDs: [String] = []
        for text in ["1", "2"] {
            let (_, user) = ChatRepository.createMessage(threadID: thread.id, role: "user", status: "completed", plainText: text, blocks: .emptyArray, metadata: .emptyObject)
            let (stopped, created) = ChatRepository.createMessage(threadID: thread.id, role: "assistant", status: "pending", plainText: nil, blocks: .emptyArray, metadata: .emptyObject)
            events += [user, created, ChatRepository.failMessage(stopped, error: ChatTurns.interruptedText)]
            stoppedIDs.append(stopped.id)
        }
        let (_, user) = ChatRepository.createMessage(threadID: thread.id, role: "user", status: "completed", plainText: "3", blocks: .emptyArray, metadata: .emptyObject)
        let (reply, created) = ChatRepository.createMessage(threadID: thread.id, role: "assistant", status: "pending", plainText: nil, blocks: .emptyArray, metadata: .emptyObject)
        try await ledger.append(events + [user, created])
        let folded = try await ledger.read { db in try ChatTurns.foldInterruptedReplies(db, threadID: thread.id, before: reply.id) }
        XCTAssertEqual(folded.count, 2)
        try await ledger.append(folded)
        for id in stoppedIDs {
            let row = try await ledger.read { db in try MessageRecord.fetchOne(db, key: id) }
            XCTAssertEqual(row?.metadata["folded"]?.boolValue, true)
            XCTAssertEqual(row?.metadata["retryable"]?.boolValue, false)
        }
    }
}

/// Counts chat runs and fails each one, so a resumed turn ends without a model.
nonisolated final class CountingRunner: TurnRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var runs: Int { lock.withLock { count } }

    func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome {
        lock.withLock { count += 1 }
        return TurnOutcome(
            planID: plan.id, round: plan.round, status: .failed, codexThreadID: nil, codexTurnID: nil, finalText: "",
            executions: [], rateLimits: nil, files: [], error: CodexAppServerError.closed("stub").localizedDescription, elapsedMs: 1,
            errorDetail: CodexAppServerError.closed("stub").detail
        )
    }

    func interrupt(planID: String) async {}
}

nonisolated final class FakeUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval = 100
    var value: TimeInterval {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

nonisolated final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
