import Foundation
import GRDB

/// Chat rows in the ledger (`threads`, `messages`, `learning_progress`, `codex_threads`),
/// a port of the pieces of `repository.py` / `routes/threads.py` the device needs.
nonisolated enum ChatRepository {
    static let internalSources: Set<String> = ["codex-qa", "internal-auth", "smoke", "web-bypass"]

    // MARK: - Reads

    static func threads(_ db: Database) throws -> [ThreadRecord] {
        try ThreadRecord.fetchAll(db).sorted { ($0.lastMessageAt ?? $0.createdAt) > ($1.lastMessageAt ?? $1.createdAt) }
    }

    static func messages(_ db: Database, threadID: String) throws -> [MessageRecord] {
        try MessageRecord.filter(Column("thread_id") == threadID).fetchAll(db).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    static func latestProgress(_ db: Database) throws -> ProgressRevisionRecord? {
        try ProgressRevisionRecord.order(Column("revision").desc).fetchOne(db)
    }

    static func progressState(_ db: Database) throws -> ProgressState {
        guard let row = try latestProgress(db) else { return LearningProgress.emptyState() }
        return try ProgressState(json: EngineJSON(any: row.state.any))
    }

    /// `source_messages_for_update`: completed messages the learner owns, by id.
    static func sourceMessages(_ db: Database, ids: Set<String>) throws -> [String: LearningProgress.SourceMessage] {
        guard !ids.isEmpty else { return [:] }
        let rows = try MessageRecord.filter(ids.contains(Column("id"))).filter(Column("status") == "completed").fetchAll(db)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, (role: $0.role, plainText: $0.plainText ?? "")) })
    }

    /// Recent-thread context for `recent_thread_history.md` (port of the SQL in `stage_struis_context_pack`).
    static func contextRows(_ db: Database, currentThreadID: String) throws -> (threads: [ThreadRow], messagesByThread: [String: [MessageRow]]) {
        let all = try threads(db).filter { $0.id == currentThreadID || $0.source == "user" }
        let candidates = Array(all.sorted { lhs, rhs in
            if lhs.id == currentThreadID { return true }
            if rhs.id == currentThreadID { return false }
            return (lhs.lastMessageAt ?? "", lhs.updatedAt) > (rhs.lastMessageAt ?? "", rhs.updatedAt)
        }.prefix(48))
        var rows: [ThreadRow] = []
        var messagesByThread: [String: [MessageRow]] = [:]
        for thread in candidates {
            // 学習者に見せない起動メッセージ(`metadata.hidden`)は、ほかの会話の文脈に学習者の発言として混ぜない。
            let completed = try messages(db, threadID: thread.id).filter {
                $0.status == "completed" && !($0.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (thread.id == currentThreadID || $0.metadata["hidden"]?.boolValue != true)
            }
            let recent = completed.suffix(8).reversed().map { message -> String in
                let body = (message.plainText ?? "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                return String((message.role + ": " + body).prefix(LearnerText.recentContextSnippetChars))
            }
            rows.append(ThreadRow(
                id: thread.id, title: thread.title, source: thread.source, latestPreview: thread.latestPreview ?? "",
                lastMessageAt: thread.lastMessageAt.flatMap(LedgerClock.parse), recentContext: recent.joined(separator: "\n")
            ))
            messagesByThread[thread.id] = completed.suffix(12).map { message in
                MessageRow(threadID: thread.id, threadTitle: thread.title, role: message.role, plainText: message.plainText ?? "", createdAt: LedgerClock.parse(message.createdAt) ?? Date())
            }
        }
        return (rows, messagesByThread)
    }

    // MARK: - Writes (events)

    static func createThread(id: String = LedgerID.make(), title: String, source: String = "user", preview: String? = nil) -> (ThreadRecord, LedgerEvent) {
        let now = LedgerClock.now()
        let row = ThreadRecord(id: id, title: title, source: source, latestPreview: preview, lastMessageAt: nil, createdAt: now, updatedAt: now)
        return (row, .upsert("thread.created", row))
    }

    static func createMessage(id: String = LedgerID.make(), threadID: String, role: String, status: String, plainText: String?, blocks: LedgerJSON, metadata: LedgerJSON) -> (MessageRecord, LedgerEvent) {
        let now = LedgerClock.now()
        let row = MessageRecord(
            id: id, threadId: threadID, role: role, status: status, plainText: plainText, blocks: blocks, metadata: metadata,
            createdAt: now, completedAt: status == "completed" ? now : nil
        )
        return (row, .upsert("message.created", row))
    }

    static func completeMessage(_ message: MessageRecord, plainText: String, blocks: LedgerJSON, metadataPatch: [String: LedgerJSON]) -> LedgerEvent {
        var row = message
        row.status = "completed"
        row.plainText = plainText
        row.blocks = blocks
        row.metadata = WorkbookMachine.merge(row.metadata, metadataPatch)
        row.completedAt = LedgerClock.now()
        return .upsert("message.completed", row)
    }

    static func failMessage(_ message: MessageRecord, error: String) -> LedgerEvent {
        var row = message
        row.status = "failed"
        row.plainText = String(error.prefix(2000))
        row.blocks = .array([.object(["kind": .string("text"), "payload": .object(["text": .string(String(error.prefix(2000)))])])])
        row.metadata = WorkbookMachine.merge(row.metadata, ["error": .string(String(error.prefix(2000)))])
        row.completedAt = LedgerClock.now()
        return .upsert("message.failed", row)
    }

    static func touchThread(_ thread: ThreadRecord, preview: String?) -> LedgerEvent {
        var row = thread
        row.latestPreview = preview.map { String($0.prefix(140)) } ?? row.latestPreview
        row.lastMessageAt = LedgerClock.now()
        row.updatedAt = row.lastMessageAt!
        return .upsert("thread.touched", row)
    }

    static func saveProgress(_ state: ProgressState, messageID: String?, turnID: String?) -> LedgerEvent {
        let row = ProgressRevisionRecord(revision: state.revision, state: LedgerJSON(any: state.json.anyValue), messageId: messageID, turnId: turnID, savedAt: LedgerClock.now())
        return .upsert("progress.saved", row)
    }

    static func mapCodexThread(threadID: String, codexThreadID: String, lastTurnID: String?, existing: CodexThreadRecord?) -> LedgerEvent {
        var row = existing ?? CodexThreadRecord(threadId: threadID, codexThreadId: codexThreadID, lastTurnId: nil, lastCompletedAt: nil, createdAt: LedgerClock.now())
        row.codexThreadId = codexThreadID
        if let lastTurnID {
            row.lastTurnId = lastTurnID
            row.lastCompletedAt = LedgerClock.now()
        }
        return .upsert("codex_thread.mapped", row)
    }

    // MARK: - DTO bridges

    static func summary(_ thread: ThreadRecord) -> ThreadSummary {
        ThreadSummary(
            id: UUID(uuidString: thread.id) ?? UUID(), title: thread.title, source: thread.source,
            latestPreview: thread.latestPreview, lastMessageAt: thread.lastMessageAt.flatMap(LedgerClock.parse),
            createdAt: LedgerClock.parse(thread.createdAt)
        )
    }

    /// 会話の行を画面の型にし、返事ごとにターンの時刻を添える(§7: 返事待ちの経過秒数と「N秒考えました」)。
    /// 秒数は台帳の `turns`(送り直しなら最新)の `created_at` → `completed_at` なので、開き直しても同じ値になる。
    static func chatMessages(_ db: Database, rows: [MessageRecord]) throws -> [ChatMessage] {
        let assistantIDs = rows.filter { $0.role == "assistant" }.map(\.id)
        var latestTurn: [String: TurnRecord] = [:]
        if !assistantIDs.isEmpty {
            let turns = try TurnRecord.filter(Column("kind") == TurnPlan.Kind.chat.rawValue)
                .filter(assistantIDs.contains(Column("target_id"))).fetchAll(db)
            for turn in turns {
                guard let target = turn.targetId else { continue }
                if let existing = latestTurn[target], existing.createdAt >= turn.createdAt { continue }
                latestTurn[target] = turn
            }
        }
        var lastUserHidden: Bool?
        return rows.map { row in
            var message = chatMessage(row)
            if row.role == "user" {
                lastUserHidden = row.metadata["hidden"]?.boolValue == true
            } else if row.role == "assistant" {
                message.answersLearner = lastUserHidden == false
                if let turn = latestTurn[row.id], let created = LedgerClock.parse(turn.createdAt) {
                    message.turnCreatedAt = created
                    if row.status == "completed", turn.status == "completed", let done = turn.completedAt.flatMap(LedgerClock.parse) {
                        message.thinkingSeconds = max(1, Int(done.timeIntervalSince(created).rounded()))
                    }
                }
            }
            return message
        }
    }

    static func chatMessage(_ message: MessageRecord) -> ChatMessage {
        ChatMessage(
            id: UUID(uuidString: message.id) ?? UUID(),
            role: MessageRole(rawValue: message.role) ?? .assistant,
            status: MessageStatus(rawValue: message.status) ?? .completed,
            plainText: message.plainText,
            blocks: (message.blocks.arrayValue ?? []).compactMap { block in
                guard let kind = block["kind"]?.stringValue, let payload = block["payload"] else { return nil }
                return MessageBlock(kind: kind, payload: AnyJSON(jsonObject: payload.objectValue?.mapValues(\.any) ?? [:]) ?? AnyJSON(.null))
            },
            metadata: AnyJSON(jsonObject: message.metadata.objectValue?.mapValues(\.any) ?? [:]),
            createdAt: LedgerClock.parse(message.createdAt) ?? Date(),
            completedAt: message.completedAt.flatMap(LedgerClock.parse)
        )
    }
}
