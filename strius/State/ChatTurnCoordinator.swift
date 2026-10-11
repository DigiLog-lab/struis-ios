import CryptoKit
import Foundation
import GRDB
import OSLog

private let chatCoordinatorLog = Logger(subsystem: "com.digiloglab.strius", category: "chat-coordinator")

/// 質問ターンの起動と修復ループ (design §6.3)。`post_message` → `run_codex_turn_background` の端末版。
extension TurnCoordinator {
    nonisolated struct ChatSend: Sendable {
        var threadID: String
        var text: String
        var attachments: [ChatTurns.Attachment]
        var workbookView: LedgerJSON?
        /// モデルに話しかけさせる起動メッセージ(学習者には見せない。§13.13 / §13.12)。
        var hidden = false
        /// 段階 1・2 の起動: この段のキーを小単元に記録する(記録済みなら `kickoff_exists` で何もしない)。
        var kickoff: (subunitID: String, key: String)? = nil
        /// 小単元の会話なら、その小単元(例題の block を保存する先)。
        var subunitID: String? = nil
        /// 段階 2 の例題を `<struis_workbook_example>` で出させる。
        var expectsExample = false
        /// モデルに渡す本文(学習者の吹き出しは `text`)。単元づくりの最初の問いへの答えをまとめて渡す時(§3.3)。
        var modelText: String? = nil
        /// 学習者のメッセージの metadata に足すもの。
        var userMetadata: [String: LedgerJSON] = [:]
        /// モデルにだけ渡す添付(吹き出しには出さない。単元づくりの前の答えの写真・教材)。
        var modelAttachments: [ChatTurns.Attachment] = []
        /// 同じ会話の返事がまだ動いていたら、止めずにその後ろに並べる(見える返事を書き終えて、記録だけを
        /// 書いている間の送信)。並べた返事は、前の返事が台帳に書き終わってから始まる。
        var queuesBehindReply = false

        init(threadID: String, text: String, attachments: [ChatTurns.Attachment], workbookView: LedgerJSON?,
             hidden: Bool = false, kickoff: (subunitID: String, key: String)? = nil, subunitID: String? = nil, expectsExample: Bool = false) {
            self.threadID = threadID
            self.text = text
            self.attachments = attachments
            self.workbookView = workbookView
            self.hidden = hidden
            self.kickoff = kickoff
            self.subunitID = subunitID
            self.expectsExample = expectsExample
        }
    }

    nonisolated struct ChatSendResult: Sendable {
        var userMessageID: String
        var assistantMessageID: String
        var turnID: String
    }

    /// Persist the learner message and the pending reply, then run the turn in the background.
    func sendChat(_ send: ChatSend) async throws -> ChatSendResult {
        let userMessageID = LedgerID.make()
        let assistantMessageID = LedgerID.make()
        let turnID = LedgerID.make()
        var predecessor: String?
        if await isChatRunning(threadID: send.threadID) {
            guard send.queuesBehindReply, let running = queueableChat(threadID: send.threadID) else {
                throw LedgerError.rejected(code: "codex_turn_in_progress", message: "前の返信を待っています")
            }
            predecessor = running
        }
        // この会話が進むので、分岐の時点で作っていた先回りの例題は使えない(§3.1)。
        discardExamplePrefetch(threadID: send.threadID)
        // 台帳に書いてターンを登録するまでの間の「停止」も受け取る。
        beginComposingChat(threadID: send.threadID)
        defer { _ = endComposingChat(threadID: send.threadID) }
        markChatReplyLive(assistantMessageID)
        let (progressBefore, codexThreadID, learnerID) = try await ledger.commit { db -> ([LedgerEvent], (ProgressState, String?, String)) in
            guard let thread = try ThreadRecord.fetchOne(db, key: send.threadID) else { throw LedgerError.notFound("thread") }
            var blocks: [LedgerJSON] = []
            if !send.text.isEmpty { blocks.append(.object(["kind": .string("text"), "payload": .object(["text": .string(send.text)])])) }
            // PDF のページの画像はモデルにだけ渡す(吹き出しには元の PDF だけ)。送り直し用に metadata には全部残す。
            for attachment in send.attachments where attachment.kind != ChatTurns.Attachment.pageImageKind {
                blocks.append(.object(["kind": .string(attachment.kind == "image" ? "image" : "file"), "payload": attachment.json]))
            }
            let (user, userEvent) = ChatRepository.createMessage(
                id: userMessageID, threadID: send.threadID, role: "user", status: "completed",
                plainText: send.text.isEmpty ? nil : send.text, blocks: .array(blocks),
                metadata: WorkbookMachine.merge(.object([
                    "handled_as": .string("codex_app_server"), "source": .string(send.hidden ? "struis_kickoff" : "thread_message"),
                    "attachments": .array(send.attachments.map(\.json)), "hidden": .bool(send.hidden),
                    "model_attachments": .array(send.modelAttachments.map(\.json)),
                    "workbook_view": send.workbookView ?? .null,
                ]), send.userMetadata)
            )
            var kickoffEvents: [LedgerEvent] = []
            if let kickoff = send.kickoff {
                var machine = try WorkbookMachine(loading: db)
                guard machine.recordKickoff(subunitID: kickoff.subunitID, key: kickoff.key, messageID: userMessageID) else {
                    throw LedgerError.rejected(code: "kickoff_exists", message: "already started")
                }
                kickoffEvents = machine.events
            }
            let (_, assistantEvent) = ChatRepository.createMessage(
                id: assistantMessageID, threadID: send.threadID, role: "assistant", status: "pending", plainText: nil, blocks: .emptyArray,
                metadata: .object(["handled_as": .string("codex_app_server")])
            )
            let progress = try ChatRepository.progressState(db)
            let mapping = try CodexThreadRecord.fetchOne(db, key: send.threadID)
            let events = kickoffEvents + [userEvent, assistantEvent, ChatRepository.touchThread(thread, preview: send.hidden ? nil : user.plainText)]
            return (events, (progress, mapping?.codexThreadId, self.ledger.deviceID))
        }
        let state = ChatTurns.State(
            turnID: turnID, threadID: send.threadID, userMessageID: userMessageID, assistantMessageID: assistantMessageID,
            learnerID: learnerID, text: send.modelText ?? send.text, attachments: send.attachments + send.modelAttachments, workbookView: send.workbookView,
            codexThreadID: codexThreadID, progressBefore: progressBefore, progressAfter: progressBefore,
            subunitID: send.subunitID, expectsExample: send.expectsExample
        )
        // ここから先で失敗すると、返事待ちの吹き出しだけが残って動かない。失敗にして「送り直す」を出す。
        do {
        let record = TurnRecord(
            id: turnID, kind: TurnPlan.Kind.chat.rawValue, targetId: assistantMessageID, threadId: send.threadID, status: "queued", round: 1,
            plan: .object(["chat": .object(["thread_id": .string(send.threadID), "user_message_id": .string(userMessageID), "assistant_message_id": .string(assistantMessageID), "workbook_view": send.workbookView ?? .null])]),
            outcome: nil, codexThreadId: codexThreadID, codexTurnId: nil, executions: .emptyArray, error: nil,
            createdAt: LedgerClock.now(), startedAt: nil, completedAt: nil
        )
        try await ledger.append([.upsert("turn.queued", record)])
        } catch {
            await ChatTurns.fail(ledger: ledger, state: state, error: ChatTurns.startFailedText)
            throw error
        }
        if endComposingChat(threadID: send.threadID) { markStoppedBeforeStart(turnID: turnID) }
        launchChat(state: state, after: predecessor)
        return ChatSendResult(userMessageID: userMessageID, assistantMessageID: assistantMessageID, turnID: turnID)
    }

    /// `thread/fork` だけ(台帳の会話には結ばない。先回りの例題は、使う時に結ぶ)。
    func forkCodexThread(from fork: (codexThreadID: String, lastTurnID: String)) async throws -> String {
        let planID = LedgerID.make()
        let astra = await assets.model("astra")
        let plan = TurnPlan(
            id: planID, kind: .threadFork, round: 1,
            thread: TurnPlan.ThreadSpec(
                codexThreadID: fork.codexThreadID, mode: .fork, cwd: TurnPlan.guestWorkspace(id: planID), model: astra.model, effort: astra.effort,
                ephemeral: false, baseInstructions: try await assets.ref("prompt:base"),
                developerInstructions: try await ChatTurns.developerRef(assets: assets),
                developerText: nil, injectDeveloperOnResume: false,
                config: .object(["model_reasoning_effort": .string(astra.effort), "features.multi_agent": .bool(false), "features.unified_exec": .bool(false)]),
                lastTurnID: fork.lastTurnID, provider: astra.provider
            ),
            turn: nil, workspace: TurnPlan.WorkspaceSpec(files: [], dirs: []), delegation: nil, collect: [], limits: .structured, items: nil
        )
        let outcome = try await runner.run(plan) { _ in }
        WorkspaceStager.cleanup(plan: plan)
        guard outcome.status == .completed, let forked = outcome.codexThreadID else {
            throw LedgerError.rejected(code: "codex_app_server_error", message: outcome.error ?? "AI の会話を準備できませんでした。もう一度送ってください。")
        }
        return forked
    }

    /// `predecessor`: 同じ会話で先に動いている返事。その返事が終わってから始める(止めない)。
    func launchChat(state: ChatTurns.State, after predecessor: String? = nil) {
        registerChat(turnID: state.turnID, threadID: state.threadID)
        let task = Task { [weak self] in
            guard let self else { return }
            let status = await self.runChat(state: state, after: predecessor)
            await self.finishChatAndNotify(state: state, status: status)
            // 段階 1 の会話が止まった: 「先に進む」の後の例題を先回りで作る(§3.1)。
            await self.prefetchExampleIfSubunitThread(threadID: state.threadID)
        }
        registerChatTask(turnID: state.turnID, task: task)
    }

    private func finishChatAndNotify(state: ChatTurns.State, status: String) {
        finishedChat(turnID: state.turnID, threadID: state.threadID)
        // One actor operation releases the reservation before publishing terminal state.
        notifyChat(state: state, status: status)
    }

    private func runChat(state initial: ChatTurns.State, after predecessor: String?) async -> String {
        var state = initial
        // 返事の待ち(要点・例題の起動・質問・単元づくり)へ、実際に起きた出来事と書かれた本文を流す(信頼性計画 P2)。
        let activity = TurnActivityBoard.sink(TurnActivityKey.reply(state.assistantMessageID), queuedBehindReply: predecessor != nil)
        defer { activity.finish() }
        // 返事が全体像の提案を書き終えたら、返事の残りを待たずに全体像を組み始める(A12)。
        let collector = ReplyStreamCollector()
        // 返事が準備OKを書いたら、返事の残り(記録・検証)を待たずに「先に進む」を出す(§13.13 の 5)。
        let readyDetector = ExampleReadyStreamDetector()
        let assistantMessageID = state.assistantMessageID
        if let predecessor {
            // 前の返事(記録を書いている)は止めずに、台帳に書き終わるまで待つ。同じ Codex thread で順に答える。
            await waitForChat(predecessor, turnID: state.turnID)
            activity.started()
            // 前の返事が新しい会話の最初のターンだった時、Codex thread はその返事が終わって初めて決まる。
            if let mapped = try? await ledger.read({ db in try CodexThreadRecord.fetchOne(db, key: state.threadID)?.codexThreadId }) {
                state.codexThreadID = mapped
            }
        }
        guard await acquireChatSlot(turnID: state.turnID) else {
            // 枠を待っている間に「停止」された: 走らせずに「停止しました」にする。
            await ChatTurns.fail(ledger: ledger, state: state, error: ChatTurns.interruptedText)
            await markTurn(turnID: state.turnID, status: "interrupted", codexThreadID: state.codexThreadID, error: ChatTurns.interruptedText)
            return "failed"
        }
        // 学習の進行は全会話で 1 本。枠を待つ間に別の会話のターン(小単元の要点の起動など)が進行を
        // 保存していることがあるので、実際に始める時点の版を読み直す(送った時点の版だと確定時に衝突する)。
        if let current = try? await ledger.read({ db in try ChatRepository.progressState(db) }), current.revision != state.progressBefore.revision {
            state.progressBefore = current
            state.progressAfter = current
        }
        await markTurn(turnID: state.turnID, status: "running", codexThreadID: state.codexThreadID)
        notifyChat(state: state, status: "running")
        var roundText: String?
        var plan: TurnPlan?
        var error: String?
        while true {
            do {
                plan = try await ChatTurns.compose(ledger: ledger, assets: assets, state: &state, roundText: roundText)
            } catch let composeError {
                error = composeError.localizedDescription
                break
            }
            guard let current = plan else { break }
            let turnID = state.turnID
            let readyState = state
            let outcome: TurnOutcome
            do {
                outcome = try await runner.run(current) { [weak self] event in
                    activity.send(event)
                    guard let self else { return }
                    if case .replyDelta(let itemID, let text) = event.kind {
                        if let request = collector.append(itemID: itemID, delta: text) {
                            Task { await self.prefetchUnit(messageID: assistantMessageID, request: request) }
                        }
                        if readyDetector.append(itemID: itemID, delta: text) {
                            Task { await self.applyExampleReadyEarly(state: readyState) }
                        }
                    }
                    Task { await self.forwardChatProgress(turnID: turnID, event: event) }
                }
            } catch let runError {
                error = runError.localizedDescription
                break
            }
            chatCoordinatorLog.info("chat round \(state.round, privacy: .public) outcome \(outcome.status.rawValue, privacy: .public) \(outcome.finalText.count, privacy: .public) chars")
            let applied = await ChatTurns.applyRound(ledger: ledger, state: &state, outcome: outcome)
            chatCoordinatorLog.info("chat round applied: \(String(describing: applied), privacy: .public)")
            switch applied {
            case .done:
                break
            case .again(let text):
                roundText = text
                continue
            case .failed(let message):
                error = message
            }
            break
        }
        if error == nil {
            // The thread now holds this memory evidence; the next turn sends it only if it changes (P1-3).
            if let codexThreadID = state.codexThreadID, let memory = state.deliveredMemory {
                ThreadContextStore.shared.update(codexThreadID) { $0.memory = memory }
            }
            do {
                let finished = try await ChatTurns.finish(ledger: ledger, state: state)
                chatCoordinatorLog.info("chat turn \(state.turnID, privacy: .public) finished")
                if let setID = finished.prefetchSetID { await startPrefetchedSet(setID: setID) }
                if finished.proposalRequest != nil {
                    // The proposal row was created inside finish(); start its generation turn.
                    let proposalID = try? await ledger.read { db in
                        try WorkbookProposalRecord.filter(Column("message_id") == state.assistantMessageID).fetchOne(db)?.id
                    }
                    // 返事の途中で先に組み始めた全体像があれば、それを結ぶ(A12)。無ければふつうに組む。
                    if let proposalID {
                        if !(await adoptUnitPrefetch(proposalID: proposalID, messageID: state.assistantMessageID)) {
                            await startUnitGeneration(proposalID: proposalID)
                        }
                    } else {
                        await discardUnitPrefetch(messageID: state.assistantMessageID)
                    }
                } else {
                    await discardUnitPrefetch(messageID: state.assistantMessageID)
                }
            } catch let finishError {
                error = finishError.localizedDescription
            }
        }
        if let error {
            chatCoordinatorLog.error("chat turn \(state.turnID, privacy: .public) failed: \(error, privacy: .public)")
            await ChatTurns.fail(ledger: ledger, state: state, error: error)
            // 返事が失敗・停止した: 先回りの全体像は使わない。
            await discardUnitPrefetch(messageID: state.assistantMessageID)
        }
        if var plan {
            // A new conversation's first turn learns its thread (and directory) only from the outcome.
            plan.workspaceKey = state.codexThreadID.flatMap { TurnPlan.threadWorkspaceKey(codexThreadID: $0) } ?? plan.workspaceKey
            WorkspaceStager.cleanup(plan: plan)
        }
        await markTurn(turnID: state.turnID, status: error == nil ? "completed" : (error == ChatTurns.interruptedText ? "interrupted" : "failed"), codexThreadID: state.codexThreadID, error: error, executions: state.executions, codexTurnID: state.codexTurnID)
        return error == nil ? "completed" : "failed"
    }

    /// 返事の途中で準備OKが書き終わった: 返事の残り(進み具合の記録・記憶・検証の差し戻し)を待たずに、小単元に
    /// 準備OKを記録して「先に進む」を出し、行き先の一枚を先回りで組み始める。返事が終わった時の記録(`finish`)は
    /// 同じことを繰り返さない(記録済みなら何もしない)。例題を出す起動の返事では使わない(例題の保存が先)。
    private func applyExampleReadyEarly(state: ChatTurns.State) async {
        guard !state.expectsExample else { return }
        let prefetchSetID = try? await ledger.commit { db -> ([LedgerEvent], String?) in
            var machine = try WorkbookMachine(loading: db)
            let setID = ChatTurns.markExampleReady(machine: &machine, state: state)
            return (machine.events, setID)
        }
        chatCoordinatorLog.info("example ready applied early for \(state.turnID, privacy: .public)")
        if let setID = prefetchSetID ?? nil { await startPrefetchedSet(setID: setID) }
    }

    private func markTurn(turnID: String, status: String, codexThreadID: String?, error: String? = nil, executions: [LedgerJSON]? = nil, codexTurnID: String? = nil) async {
        try? await ledger.commit { db in
            guard var turn = try TurnRecord.fetchOne(db, key: turnID) else { return ([], ()) }
            turn.status = status
            turn.codexThreadId = codexThreadID ?? turn.codexThreadId
            turn.codexTurnId = codexTurnID ?? turn.codexTurnId
            if let executions { turn.executions = .array(executions) }
            turn.error = error
            if status == "running" { turn.startedAt = LedgerClock.now() } else { turn.completedAt = LedgerClock.now() }
            return ([.upsert("turn.\(status)", turn)], ())
        }
    }

    private func notifyChat(state: ChatTurns.State, status: String) {
        notifyNotice(Notice(turnID: state.turnID, kind: .chat, targetID: state.threadID, status: status))
    }

    /// Interrupt the running chat turn of a thread (design §3.6).
    func interruptChat(threadID: String) async {
        guard let turnID = await chatTurnID(threadID: threadID) else {
            stopComposingChat(threadID: threadID)
            return
        }
        await stopChat(turnID: turnID)
    }
}

/// 返事の本文の差分から、準備OK(`<struis_workbook_example_ready/>`)が書き終わったのを一度だけ見つける。
nonisolated final class ExampleReadyStreamDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var itemID = ""
    private var text = ""
    private var seen = false

    /// 差分を足し、準備OKが初めて書き終わったら true。
    func append(itemID: String, delta: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if itemID != self.itemID {
            self.itemID = itemID
            text = ""
        }
        text += delta
        guard !seen, delta.contains(">"), LearnerText.extractWorkbookExampleReady(text).ready else { return false }
        seen = true
        return true
    }
}
