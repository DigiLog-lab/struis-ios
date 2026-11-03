import GRDB
import XCTest
@testable import strius

/// 信頼性計画 P1・P4 のランタイムのうち、ランナーに依らない部分: 期限の時計(バックグラウンドの時間を数えない)、
/// バックグラウンド実行の数え方、会話の作業フォルダの後始末、進行の記録の JSON の修復と差し戻し。
/// 期限で止めた記録と次のターンへの注記は `ClaudeTurnRunnerTests` が確かめる。
final class LaneRuntimeTests: XCTestCase {
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
            limits: TurnPlan.Limits(collectMaxFiles: 0, collectMaxBytes: 0, turnTimeoutS: limit),
            workspaceKey: threadID.flatMap { TurnPlan.threadWorkspaceKey(codexThreadID: $0) }
        )
    }

    // MARK: - P4-3

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
            metadata: .object(["handled_as": .string("claude_messages")].merging(replyMetadata) { $1 })
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
        XCTAssertEqual(reply?.plainText, TurnRuntimeError.closed("stub").localizedDescription, "学習者向けの一文はそのまま")
        XCTAssertEqual(reply?.metadata["error_detail"]?.stringValue, "closed stub", "理由が残っていない")
        let message = ChatRepository.chatMessage(try XCTUnwrap(reply))
        XCTAssertEqual(message.errorDetail, "closed stub")
    }

    /// 3.6: 検証の差し戻しは 1 ターンに 1 回まで。2 回目も通らなければ、送り直し続けずに失敗にする(ラウンド ≤ 3)。
    @MainActor func testValidationRepairIsSentOnceThenTheTurnFails() async throws {
        let ledger = try Ledger.inMemory()
        let seeded = try await Self.seed(ledger, userMetadata: [:])
        var state = ChatTurns.State(
            turnID: LedgerID.make(), threadID: seeded.threadID, userMessageID: seeded.userID, assistantMessageID: seeded.assistantID,
            learnerID: "fixture-learner", text: "質問", attachments: [], workbookView: nil,
            codexThreadID: nil, progressBefore: ProgressState(), progressAfter: ProgressState()
        )
        // 読めない進行の記録(検証で必ず差し戻される返事)。
        let broken = "返事です。\n<struis_progress_update>{not json</struis_progress_update>"
        func outcome() -> TurnOutcome {
            TurnOutcome(planID: "p", round: state.round + 1, status: .completed, codexThreadID: nil, codexTurnID: nil, finalText: broken,
                        executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: 1)
        }
        let first = await ChatTurns.applyRound(ledger: ledger, state: &state, outcome: outcome())
        guard case .again = first else { return XCTFail("1 回目の差し戻しが無い: \(first)") }
        let second = await ChatTurns.applyRound(ledger: ledger, state: &state, outcome: outcome())
        guard case .failed(let message, let detail) = second else { return XCTFail("2 回目で失敗にならない: \(second)") }
        XCTAssertEqual(message, ChatTurns.learnerFacingFailure)
        XCTAssertEqual(detail?.hasPrefix("validation repair limit (1) reached"), true, detail ?? "-")
        XCTAssertEqual(state.checks.filter { $0["accepted"]?.boolValue == false }.count, 2)
        XCTAssertTrue(ChatTurns.repairsExhausted(state.checks))
        XCTAssertFalse(ChatTurns.repairsExhausted([.object(["accepted": .bool(false)])]), "1 回目の差し戻しは送る")
    }

    /// 3.6: 続き(`disposition: continue`)もラウンドに数える。3 ラウンド目で続きを求められても、届いている分で返事を終える。
    @MainActor func testContinuationStopsAtTheRoundLimitAndDeliversWhatWasWritten() async throws {
        XCTAssertEqual(ChatTurns.roundLimit, 3, "最初 + 差し戻し 1 + 続き 1")
        let ledger = try Ledger.inMemory()
        let seeded = try await Self.seed(ledger, userMetadata: [:])
        var state = ChatTurns.State(
            turnID: LedgerID.make(), threadID: seeded.threadID, userMessageID: seeded.userID, assistantMessageID: seeded.assistantID,
            learnerID: "fixture-learner", text: "質問", attachments: [], workbookView: nil,
            codexThreadID: nil, progressBefore: ProgressState(), progressAfter: ProgressState()
        )
        // 1 ラウンド目で目標を作り、以後は同じ目標を指したまま「続き」を求め続ける返事。
        let goal = #"{"id": "practice", "parent_id": null, "title": "practice", "outcome": "自力で説明できる", "learner_action": "解答する", "model_action": "説明して評価する", "completion_condition": "必要な解答の証拠を確認する", "kind": "learner", "status": "active", "next_action": "解答する", "child_order": [], "loop": {"enabled": true, "unit": "出題から評価まで", "repeat_when": "未達", "exit_when": "達成または上限", "after_exit": "親で見直す", "stagnation_attempts": 3, "max_attempts": 2}, "evaluation": null}"#
        func outcome(part: String) -> TurnOutcome {
            let goals = state.round == 0 ? goal : ""
            let update = #"{"schema_version": 1, "base_revision": \#(state.progressAfter.revision), "goals": [\#(goals)], "problems": [], "attempts": [], "current_goal_id": "practice", "disposition": "continue", "next_action": "説明を続ける", "reply_quotes": ["\#(part)"]}"#
            return TurnOutcome(planID: "p", round: state.round + 1, status: .completed, codexThreadID: nil, codexTurnID: nil,
                               finalText: "\(part)\n<struis_progress_update>\(update)</struis_progress_update>",
                               executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: 1)
        }
        let first = await ChatTurns.applyRound(ledger: ledger, state: &state, outcome: outcome(part: "一つ目"))
        guard case .again(let prompt) = first else { return XCTFail("1 ラウンド目の続きが無い: \(first)") }
        XCTAssertEqual(prompt, ChatTurns.continuation)
        let second = await ChatTurns.applyRound(ledger: ledger, state: &state, outcome: outcome(part: "二つ目"))
        guard case .again = second else { return XCTFail("2 ラウンド目の続きが無い: \(second)") }
        let third = await ChatTurns.applyRound(ledger: ledger, state: &state, outcome: outcome(part: "三つ目"))
        guard case .done = third else { return XCTFail("3 ラウンド目で終わらない: \(third)") }
        XCTAssertEqual(state.round, ChatTurns.roundLimit)
        XCTAssertEqual(state.visibleText, "一つ目\n\n二つ目\n\n三つ目", "届いている分は全部返す")
        XCTAssertEqual(state.checks.count, 3)
        XCTAssertTrue(state.checks.allSatisfy { $0["accepted"]?.boolValue == true }, "続きの打ち切りは失敗ではない")
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
            executions: [], rateLimits: nil, files: [], error: TurnRuntimeError.closed("stub").localizedDescription, elapsedMs: 1,
            errorDetail: TurnRuntimeError.closed("stub").detail
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
