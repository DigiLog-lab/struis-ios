import CryptoKit
import Foundation
import GRDB
import OSLog

nonisolated private let conversationLog = Logger(subsystem: "com.digiloglab.strius", category: "claude-conversation")

/// 続く会話(チャット・分岐・下調べの親)の履歴を、Claude の Messages の形のまま台帳に残す。
///
/// 台帳のイベント(`ledger_events`)には入れない: 同期・書き出しの対象ではなく、この端末でモデルに送り直すための控え。
/// 別の端末や書き出しから戻した台帳では履歴が無いので、`recent_thread_history.md` で続ける(Codex の rollout と同じ扱い)。
/// - 署名付きの thinking はそのまま残す(次の要求でそのまま送り返す)。
/// - 画像は本体を入れず、`conversation-images/` に置いたファイルの場所だけを残す(送る時に読み戻す)。
/// - モデルの返事と道具の結果のたびに 1 行足す。アプリが落ちても、最後に足した行から続ける。
nonisolated final class ClaudeConversationStore: Sendable {
    /// 1 件の発話(Messages の `role` と `content`)。
    nonisolated struct Message: Sendable {
        var role: String
        var content: [[String: AnySendable]]
        var turnID: String?

        init(role: String, content: [[String: Any]], turnID: String?) {
            self.role = role
            self.content = content.map { $0.mapValues(AnySendable.init) }
            self.turnID = turnID
        }

        var blocks: [[String: Any]] { content.map { $0.mapValues(\.value) } }
    }

    /// 会話の控え(スレッドごと)。
    nonisolated struct Conversation: Sendable, Equatable {
        var threadID: String
        var kind: String
        var model: String
        /// 直近の要求で送った入力のトークン数(キャッシュの読み書きを含む)。上限に近づいたら新しいスレッドへ移る。
        var lastPromptTokens: Int
        var forkedFrom: String?
    }

    private let queue: DatabaseQueue
    private let imageRoot: URL

    init(queue: DatabaseQueue, imageRoot: URL = StruisPaths.root.appendingPathComponent("conversation-images", isDirectory: true)) {
        self.queue = queue
        self.imageRoot = imageRoot
    }

    /// 台帳とは別の、テスト用の空の控え。
    static func temporary() throws -> ClaudeConversationStore {
        let directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("claude-conversations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue: DatabaseQueue = try DatabaseQueue(path: directory.appendingPathComponent("conversations.sqlite").path)
        try queue.write { db in try createTables(db) }
        return ClaudeConversationStore(queue: queue, imageRoot: directory.appendingPathComponent("images", isDirectory: true))
    }

    /// 台帳の移行 `v6-claude-conversations`。
    static func createTables(_ db: Database) throws {
        try db.create(table: "claude_conversations", ifNotExists: true) { t in
            t.column("thread_id", .text).primaryKey()
            t.column("kind", .text).notNull()
            t.column("model", .text).notNull()
            t.column("forked_from", .text)
            t.column("last_prompt_tokens", .integer).notNull().defaults(to: 0)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(table: "claude_conversation_messages", ifNotExists: true) { t in
            t.column("thread_id", .text).notNull()
            t.column("seq", .integer).notNull()
            t.column("turn_id", .text)
            t.column("role", .text).notNull()
            t.column("content", .text).notNull()
            t.column("created_at", .text).notNull()
            t.primaryKey(["thread_id", "seq"])
        }
    }

    // MARK: - 読む

    func conversation(_ threadID: String) throws -> Conversation? {
        try queue.read { db -> Conversation? in
            guard let row: Row = try Row.fetchOne(db, sql: "SELECT * FROM claude_conversations WHERE thread_id = ?", arguments: [threadID]) else { return nil }
            return Conversation(threadID: row["thread_id"], kind: row["kind"], model: row["model"], lastPromptTokens: row["last_prompt_tokens"], forkedFrom: row["forked_from"])
        }
    }

    /// 送る形の履歴(画像は本体に戻す)。読み戻せない画像は、その旨の文にする。
    func messages(_ threadID: String) throws -> [Message] {
        let rows: [(role: String, content: String, turnID: String?)] = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT role, content, turn_id FROM claude_conversation_messages WHERE thread_id = ? ORDER BY seq", arguments: [threadID])
                .map { (role: $0["role"], content: $0["content"], turnID: $0["turn_id"]) }
        }
        return rows.map { row in
            let stored: [[String: Any]] = (try? JSONSerialization.jsonObject(with: Data(row.content.utf8))) as? [[String: Any]] ?? []
            return Message(role: row.role, content: stored.map(restoreImages), turnID: row.turnID)
        }
    }

    // MARK: - 書く

    func begin(threadID: String, kind: String, model: String, forkedFrom: String? = nil) throws {
        let now: String = LedgerClock.now()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO claude_conversations (thread_id, kind, model, forked_from, last_prompt_tokens, created_at, updated_at)
                VALUES (?, ?, ?, ?, 0, ?, ?) ON CONFLICT(thread_id) DO NOTHING
                """, arguments: [threadID, kind, model, forkedFrom, now, now])
        }
    }

    /// 1 件足す。画像はファイルに置き、場所だけを残す。
    func append(threadID: String, turnID: String?, role: String, content: [[String: Any]]) throws {
        let stored: [[String: Any]] = try content.map(storeImages)
        let data: Data = try JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys, .withoutEscapingSlashes])
        let text: String = String(decoding: data, as: UTF8.self)
        let now: String = LedgerClock.now()
        try queue.write { db in
            let next: Int = (try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM claude_conversation_messages WHERE thread_id = ?", arguments: [threadID]) ?? 0) + 1
            try db.execute(sql: "INSERT INTO claude_conversation_messages (thread_id, seq, turn_id, role, content, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [threadID, next, turnID, role, text, now])
            try db.execute(sql: "UPDATE claude_conversations SET updated_at = ? WHERE thread_id = ?", arguments: [now, threadID])
        }
    }

    func recordPromptTokens(threadID: String, tokens: Int) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE claude_conversations SET last_prompt_tokens = ?, updated_at = ? WHERE thread_id = ?",
                           arguments: [tokens, LedgerClock.now(), threadID])
        }
    }

    /// 分岐: 元の会話の `lastTurnID` のターンまでを新しいスレッドに写す。そのターンが見つからなければ全部を写す。
    func fork(from source: String, upTo lastTurnID: String?, into threadID: String) throws {
        let now: String = LedgerClock.now()
        try queue.write { db in
            guard let row: Row = try Row.fetchOne(db, sql: "SELECT kind, model, last_prompt_tokens FROM claude_conversations WHERE thread_id = ?", arguments: [source]) else {
                throw ClaudeConversationError.missing(source)
            }
            var limit: Int = try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM claude_conversation_messages WHERE thread_id = ?", arguments: [source]) ?? 0
            if let lastTurnID, let last = try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM claude_conversation_messages WHERE thread_id = ? AND turn_id = ?", arguments: [source, lastTurnID]) {
                limit = last
            }
            let kind: String = row["kind"]
            let model: String = row["model"]
            let tokens: Int = row["last_prompt_tokens"]
            try db.execute(sql: """
                INSERT INTO claude_conversations (thread_id, kind, model, forked_from, last_prompt_tokens, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [threadID, kind, model, source, tokens, now, now])
            try db.execute(sql: """
                INSERT INTO claude_conversation_messages (thread_id, seq, turn_id, role, content, created_at)
                SELECT ?, seq, turn_id, role, content, created_at FROM claude_conversation_messages WHERE thread_id = ? AND seq <= ?
                """, arguments: [threadID, source, limit])
        }
    }

    /// 単元の削除などで消す会話。
    func remove(_ threadIDs: Set<String>) throws {
        guard !threadIDs.isEmpty else { return }
        try queue.write { db in
            for id in threadIDs {
                try db.execute(sql: "DELETE FROM claude_conversation_messages WHERE thread_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM claude_conversations WHERE thread_id = ?", arguments: [id])
            }
        }
    }

    // MARK: - 画像

    private func storeImages(_ block: [String: Any]) throws -> [String: Any] {
        var block: [String: Any] = block
        if block["type"] as? String == "image", let source = block["source"] as? [String: Any], source["type"] as? String == "base64",
           let base64 = source["data"] as? String, let mediaType = source["media_type"] as? String, let bytes = Data(base64Encoded: base64) {
            let name: String = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + "." + Self.fileExtension(mediaType)
            let url: URL = imageRoot.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: imageRoot, withIntermediateDirectories: true)
                try bytes.write(to: url, options: .atomic)
            }
            block["source"] = ["type": "struis_file", "path": name, "media_type": mediaType] as [String: Any]
        }
        if let nested = block["content"] as? [[String: Any]] {
            block["content"] = try nested.map(storeImages)
        }
        return block
    }

    private func restoreImages(_ block: [String: Any]) -> [String: Any] {
        var block: [String: Any] = block
        if block["type"] as? String == "image", let source = block["source"] as? [String: Any], source["type"] as? String == "struis_file" {
            let name: String = (source["path"] as? String ?? "").replacingOccurrences(of: "/", with: "")
            guard !name.isEmpty, let bytes = try? Data(contentsOf: imageRoot.appendingPathComponent(name)) else {
                conversationLog.error("conversation image missing: \(name, privacy: .public)")
                return ["type": "text", "text": "[An image from earlier in this conversation is no longer available.]"]
            }
            block["source"] = ["type": "base64", "media_type": source["media_type"] as? String ?? "image/jpeg", "data": bytes.base64EncodedString()] as [String: Any]
        }
        if let nested = block["content"] as? [[String: Any]] {
            block["content"] = nested.map(restoreImages)
        }
        return block
    }

    private static func fileExtension(_ mediaType: String) -> String {
        switch mediaType {
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "jpg"
        }
    }
}

nonisolated enum ClaudeConversationError: Error, LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing: "前の会話の記録が見つかりません。新しい会話で送ってください。"
        }
    }
}
