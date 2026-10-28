import Foundation
import GRDB
import OSLog

nonisolated private let recoveryLog = Logger(subsystem: "com.digiloglab.strius", category: "chat-recovery")

extension ChatTurns {
    /// A reply whose turn was cut off by the app being closed (E2E H3). Shown with 「送り直す」.
    nonisolated static let abandonedText = "止まりました。"
}

/// 止まった質問ターンの後始末と「送り直す」(E2E H1・H3, 修正指示書 §1.3 / §2.3)。
extension TurnCoordinator {
    // MARK: - Launch recovery

    /// Chat turns left `queued`/`running` by a previous process have no task to finish them:
    /// mark them `interrupted` and fail their pending reply with 「止まりました。」 so the screen
    /// shows 「送り直す」 instead of a reply that loads forever. Pending replies whose turn row
    /// was never written (the app died inside `sendChat`) are failed the same way.
    func recoverAbandonedChats(_ turns: [TurnRecord]) async {
        // 返事ごとに見る(同じ会話で新しく送った・送り直した返事があっても、前のプロセスが残した返事は後始末する)。
        // ここで読んだ返事だけを対象にする: 読んだ後にこのプロセスが作った・送り直した返事には触れない。
        let deviceID = ledger.deviceID
        let pendingIDs = (try? await ledger.read { db in
            try MessageRecord.filter(Column("role") == "assistant").filter(Column("status") == "pending").fetchAll(db).map(\.id)
                .filter { try Ledger.isLocal(.messages, $0, deviceID: deviceID, db) }
        }) ?? []
        let abandonedReplies = Set(pendingIDs.filter { !isChatReplyLive($0) })
        let abandonedTurnIDs = Set(turns.map(\.id))
        let text = ChatTurns.abandonedText
        do {
            let (recovered, resumable): (Int, [String]) = try await ledger.commit { db in
                var events: [LedgerEvent] = []
                let now = LedgerClock.now()
                for id in abandonedTurnIDs {
                    guard var turn = try TurnRecord.fetchOne(db, key: id), turn.status == "queued" || turn.status == "running" else { continue }
                    turn.status = "interrupted"
                    turn.error = text
                    turn.completedAt = now
                    events.append(.upsert("turn.interrupted", turn))
                }
                var failed = 0
                var resumable: [String] = []
                for id in abandonedReplies {
                    guard var row = try MessageRecord.fetchOne(db, key: id), row.status == "pending" else { continue }
                    let origin = try Self.replyOrigin(db, reply: row)
                    let resumes = origin != .learner && row.metadata["auto_resumed"]?.boolValue != true
                    // A subunit kickoff is recovered by the subunit's one 「もう一度始める」; no 「送り直す」 beside it.
                    row.metadata = WorkbookMachine.merge(row.metadata, [
                        "retryable": .bool(origin != .kickoff), "stopped_by": .string("relaunch"),
                    ])
                    events.append(ChatRepository.failMessage(row, error: text))
                    failed += 1
                    if resumes { resumable.append(row.id) }
                }
                return (events, (failed, resumable))
            }
            if recovered > 0 || !abandonedTurnIDs.isEmpty {
                recoveryLog.info("recovered \(abandonedTurnIDs.count, privacy: .public) chat turns, \(recovered, privacy: .public) pending replies")
            }
            // A step the model starts itself (要点・例題の起動, 単元づくりの生成) resumes once on its own after a
            // relaunch (P4-4, D3). If that run is cut off too, the learner gets the recovery action.
            for replyID in resumable {
                Task {
                    do {
                        _ = try await self.retryChat(assistantMessageID: replyID, automatic: true)
                        recoveryLog.info("resumed model-started reply \(replyID, privacy: .public) after relaunch")
                    } catch {
                        recoveryLog.error("automatic resume failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        } catch {
            recoveryLog.error("chat recovery failed: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated enum ReplyOrigin: Sendable, Equatable {
        /// The learner's own message.
        case learner
        /// A hidden kickoff of a subunit stage (要点・例題の起動).
        case kickoff
        /// The unit-creation request built from the learner's answers (単元づくりの生成).
        case unitCreation
    }

    /// What started the reply: the learner, or a step Struis asked the model to begin.
    nonisolated static func replyOrigin(_ db: Database, reply: MessageRecord) throws -> ReplyOrigin {
        let thread = try ChatRepository.messages(db, threadID: reply.threadId)
        guard let index = thread.firstIndex(where: { $0.id == reply.id }),
              let user = thread[..<index].last(where: { $0.role == "user" }) else { return .learner }
        if user.metadata["hidden"]?.boolValue == true, user.metadata["source"]?.stringValue == "struis_kickoff" { return .kickoff }
        if user.metadata["model_text"]?.stringValue != nil { return .unitCreation }
        return .learner
    }

    // MARK: - 送り直す

    /// Re-run the learner message behind a failed reply (「停止しました」「止まりました」 or an
    /// error). When the failed reply is the last message of its thread it is re-run in place: the
    /// same bubble goes back to loading and then shows the new answer. Otherwise the learner
    /// message is sent again at the end of the thread.
    /// `isCurrent` は台帳を書き換える直前に確かめる(待っている間にサインアウトされたら、何も書かずに終わる)。
    /// `automatic`: the one resume after a relaunch (P4-4). It is marked so it never repeats on its own.
    func retryChat(assistantMessageID: String, isCurrent: (@Sendable () async -> Bool)? = nil, automatic: Bool = false) async throws -> ChatSendResult {
        struct Source {
            var assistant: MessageRecord
            var user: MessageRecord
            var previousTurn: TurnRecord?
            var isLatest: Bool
        }
        let source: Source = try await ledger.read { db in
            guard let assistant = try MessageRecord.fetchOne(db, key: assistantMessageID), assistant.role == "assistant" else {
                throw LedgerError.notFound("message")
            }
            // 起動のやり直しで置き換えた返事は送り直さない(同じ説明・例題が二重になる)。
            guard assistant.status == "failed", assistant.metadata["superseded_by_restart"]?.boolValue != true else {
                throw LedgerError.rejected(code: "retry_not_available", message: "この返事は送り直せません")
            }
            let previousTurn = try TurnRecord.filter(Column("kind") == TurnPlan.Kind.chat.rawValue)
                .filter(Column("target_id") == assistantMessageID).fetchAll(db)
                .max { $0.createdAt < $1.createdAt }
            let thread = try ChatRepository.messages(db, threadID: assistant.threadId)
            var user: MessageRecord?
            if let id = previousTurn?.plan["chat"]?["user_message_id"]?.stringValue {
                user = try MessageRecord.fetchOne(db, key: id)
            }
            if user == nil, let index = thread.firstIndex(where: { $0.id == assistant.id }) {
                user = thread[..<index].last { $0.role == "user" }
            }
            guard let user else { throw LedgerError.rejected(code: "retry_not_available", message: "この返事は送り直せません") }
            return Source(assistant: assistant, user: user, previousTurn: previousTurn, isLatest: thread.last?.id == assistant.id)
        }
        let threadID = source.assistant.threadId
        if isChatRunning(threadID: threadID) {
            throw LedgerError.rejected(code: "codex_turn_in_progress", message: "前の返信を待っています")
        }
        markChatReplyLive(assistantMessageID)
        // ここから台帳に書いてターンを登録するまでの間の「停止」も受け取る(小単元の読み出しの間も)。
        beginComposingChat(threadID: threadID)
        var composing = true
        defer { if composing { _ = endComposingChat(threadID: threadID) } }
        let text = source.user.plainText ?? ""
        // 単元づくりの最初の問いへの答え(§3.3)は、モデルに渡した本文(問いと答えのまとめ)で送り直す。
        let modelText = source.user.metadata["model_text"]?.stringValue
        let attachments = (source.user.metadata["attachments"]?.arrayValue ?? []).compactMap(ChatTurns.Attachment.init(json:))
        let modelAttachments = (source.user.metadata["model_attachments"]?.arrayValue ?? []).compactMap(ChatTurns.Attachment.init(json:))
        let workbookView = source.previousTurn?.plan["chat"]?["workbook_view"].flatMap { $0 == .null ? nil : $0 }
        // 起動メッセージ(学習者に見せない)への返事なら、見せないまま・同じ小単元の文脈で起こし直す。
        let hidden = source.user.metadata["hidden"]?.boolValue == true
        let subunit = try await ledger.read { db -> (id: String, expectsExample: Bool)? in
            let machine = try WorkbookMachine(loading: db)
            guard let row = machine.subunits.values.first(where: { $0.metadata["thread_id"]?.stringValue == threadID }) else { return nil }
            return (row.id, hidden && row.stage == 2 && (try? machine.subunitSummary(id: row.id))?.exampleProblem == nil)
        }
        guard source.isLatest else {
            // 読み出しの間に止められた: 送り直さない(失敗した返事はそのまま残る)。
            let current = await isCurrent?() ?? true
            composing = false
            if endComposingChat(threadID: threadID) || !current { throw CancellationError() }
            var send = ChatSend(
                threadID: threadID, text: text, attachments: attachments, workbookView: workbookView,
                hidden: hidden, subunitID: subunit?.id, expectsExample: subunit?.expectsExample ?? false
            )
            send.modelText = modelText
            send.modelAttachments = modelAttachments
            if let modelText {
                send.userMetadata = ["model_text": .string(modelText)]
                if let key = source.user.metadata["answers_question"] { send.userMetadata["answers_question"] = key }
            }
            let sent = try await sendChat(send)
            // 送っている間にサインアウトされた: 始まったターンを止める。
            if let isCurrent, !(await isCurrent()) {
                await interruptChat(threadID: threadID)
                throw CancellationError()
            }
            return sent
        }

        if let isCurrent, !(await isCurrent()) { throw CancellationError() }
        let turnID = LedgerID.make()
        let userMessageID = source.user.id
        let (progressBefore, codexThreadID, learnerID) = try await ledger.commit { db -> ([LedgerEvent], (ProgressState, String?, String)) in
            guard var row = try MessageRecord.fetchOne(db, key: assistantMessageID), row.status == "failed" else {
                throw LedgerError.rejected(code: "retry_not_available", message: "この返事は送り直せません")
            }
            row.status = "pending"
            row.plainText = nil
            row.blocks = .emptyArray
            row.completedAt = nil
            row.metadata = .object([
                "handled_as": .string("codex_app_server"),
                "retry_of_turn_id": source.previousTurn.map { .string($0.id) } ?? .null,
                // Once resumed on its own, a later relaunch leaves the recovery to the learner.
                "auto_resumed": .bool(automatic || row.metadata["auto_resumed"]?.boolValue == true),
            ])
            var events: [LedgerEvent] = [.upsert("message.retried", row)]
            if let thread = try ThreadRecord.fetchOne(db, key: threadID) {
                events.append(ChatRepository.touchThread(thread, preview: hidden ? nil : source.user.plainText))
            }
            let progress = try ChatRepository.progressState(db)
            let mapping = try CodexThreadRecord.fetchOne(db, key: threadID)
            return (events, (progress, mapping?.codexThreadId, self.ledger.deviceID))
        }
        let state = ChatTurns.State(
            turnID: turnID, threadID: threadID, userMessageID: userMessageID, assistantMessageID: assistantMessageID,
            learnerID: learnerID, text: modelText ?? text, attachments: attachments + modelAttachments, workbookView: workbookView,
            codexThreadID: codexThreadID, progressBefore: progressBefore, progressAfter: progressBefore,
            subunitID: subunit?.id, expectsExample: subunit?.expectsExample ?? false
        )
        var chat: [String: LedgerJSON] = [
            "thread_id": .string(threadID), "user_message_id": .string(userMessageID), "assistant_message_id": .string(assistantMessageID),
        ]
        if let workbookView { chat["workbook_view"] = workbookView }
        if let previous = source.previousTurn { chat["retry_of_turn_id"] = .string(previous.id) }
        let record = TurnRecord(
            id: turnID, kind: TurnPlan.Kind.chat.rawValue, targetId: assistantMessageID, threadId: threadID, status: "queued", round: 1,
            plan: .object(["chat": .object(chat)]),
            outcome: nil, codexThreadId: state.codexThreadID, codexTurnId: nil, executions: .emptyArray, error: nil,
            createdAt: LedgerClock.now(), startedAt: nil, completedAt: nil
        )
        do {
            try await ledger.append([.upsert("turn.queued", record)])
        } catch {
            await ChatTurns.fail(ledger: ledger, state: state, error: ChatTurns.startFailedText)
            throw error
        }
        composing = false
        // 分岐の作成やターンの記録を待っている間にサインアウトされたら、走らせずに「停止しました」で終わらせる。
        let stillCurrent = await isCurrent?() ?? true
        if endComposingChat(threadID: threadID) || !stillCurrent { markStoppedBeforeStart(turnID: turnID) }
        launchChat(state: state)
        return ChatSendResult(userMessageID: userMessageID, assistantMessageID: assistantMessageID, turnID: turnID)
    }

    // MARK: - 判定し直す

    /// Grade a capture again after its grading failed or was stopped.
    @discardableResult
    func retryGrading(captureID: String) async -> Bool {
        let reopened = (try? await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let reopened = machine.reopenFailedCapture(id: captureID)
            return (machine.events, reopened)
        }) ?? false
        guard reopened else { return false }
        await startGrading(captureID: captureID)
        return true
    }
}

extension WorkbookMachine {
    /// failed → identifying, so the capture can be graded again (「判定し直す」).
    nonisolated mutating func reopenFailedCapture(id: String) -> Bool {
        guard var row = captures[id], row.status == "failed" else { return false }
        row.status = "identifying"
        row.error = nil
        row.updatedAt = LedgerClock.now()
        put("capture.retried", row)
        return true
    }
}

extension ChatMessage {
    /// A failed reply that 「送り直す」 can re-run (`ChatStore.retry(assistantMessageID:)`).
    var isRetryable: Bool {
        guard role == .assistant, status == .failed else { return false }
        if case .bool(true)? = metadata?.value["retryable"] { return true }
        return false
    }
}
