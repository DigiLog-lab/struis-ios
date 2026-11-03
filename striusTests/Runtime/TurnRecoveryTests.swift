import GRDB
import XCTest
@testable import strius

/// 止まっても戻れる (修正指示書 §2.3 / E2E H1・H3)。起動時に置き去りの質問ターンが「止まりました」になり、
/// その場で送り直せること、学習者に見せる失敗の文に内部の名前が出ないことを確かめる。
final class TurnRecoveryTests: XCTestCase {
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

    /// Learner-facing errors never carry method names (E2E M4).
    func testTimeoutErrorTextHasNoMethodNames() {
        let errors: [TurnRuntimeError] = [
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
        XCTAssertTrue(TurnRuntimeError.unanswered("thread/resume").detail.contains("thread/resume"))
        // 3.5: 理由(診断の文)は別に取り出せる。Claude の準備の失敗は一文に理由が入っているのでそのまま。
        XCTAssertEqual(ClaudeTurnRunner.describe(TurnRuntimeError.rpc(code: 400, message: "invalid_request")), "rpc 400: invalid_request")
        XCTAssertEqual(ClaudeTurnRunner.describe(AppAttestClient.Failure.requestFailed(endpoint: "register", status: 401)),
                       "Claude を使う準備に失敗しました(register HTTP 401)。")
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
            limits: TurnPlan.Limits(collectMaxFiles: 0, collectMaxBytes: 0, turnTimeoutS: 5)
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
            metadata: .object(["handled_as": .string("claude_messages")])
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
            executions: [], rateLimits: nil, files: [], error: TurnRuntimeError.closed("stub").localizedDescription, elapsedMs: 1
        )
    }

    func interrupt(planID: String) async {}
}
