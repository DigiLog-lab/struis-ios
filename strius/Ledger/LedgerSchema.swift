import Foundation
import GRDB

/// SQLite schema for the device ledger (design §4). `ledger_events` is the
/// source of truth; every other table is a projection rebuilt from it.
nonisolated enum LedgerSchema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "ledger_meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
            try db.create(table: "ledger_events") { t in
                t.autoIncrementedPrimaryKey("seq")
                t.column("device_id", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("entity", .text).notNull()
                t.column("entity_id", .text).notNull()
                t.column("payload", .text).notNull()
                t.column("created_at", .text).notNull()
                t.column("synced_seq", .integer)
            }
            try db.create(index: "idx_ledger_events_entity", on: "ledger_events", columns: ["entity", "entity_id"])
            try createProjections(db)
        }
        // iCloud 同期 (Issue #51)。イベントは元の端末と連番 `(origin_device_id, origin_seq)` で一意にし、
        // 外から来たイベントを二重に足さない。自端末のイベントは挿入時に `device_id` と `seq` で埋める。
        migrator.registerMigration("sync-v1") { db in
            try db.alter(table: "ledger_events") { t in
                t.add(column: "origin_device_id", .text)
                t.add(column: "origin_seq", .integer)
            }
            try db.execute(sql: "UPDATE ledger_events SET origin_device_id = device_id, origin_seq = seq")
            try db.create(index: "idx_ledger_events_origin", on: "ledger_events", columns: ["origin_device_id", "origin_seq"], unique: true)
            try db.execute(sql: """
                CREATE TRIGGER ledger_events_local_origin AFTER INSERT ON ledger_events
                WHEN NEW.origin_seq IS NULL
                BEGIN
                    UPDATE ledger_events SET origin_device_id = NEW.device_id, origin_seq = NEW.seq WHERE seq = NEW.seq;
                END
                """)
            // 読めなかった外のイベント(知らない表・復号やデコードの失敗)。版が上がったら適用し直す。
            try db.create(table: "sync_pending") { t in
                t.column("record_name", .text).primaryKey()
                t.column("origin_device_id", .text)
                t.column("origin_seq", .integer)
                t.column("kind", .text)
                t.column("entity", .text)
                t.column("entity_id", .text)
                t.column("payload", .text)
                t.column("created_at", .text)
                t.column("record", .blob)
                t.column("reason", .text).notNull()
                t.column("app_build", .text).notNull()
                t.column("received_at", .text).notNull()
            }
            // 同期する `captures/`・`attachments/`・`memory/` のファイル。`dirty` は未送信(`deleted` なら消したことを未送信)。
            try db.create(table: "sync_files") { t in
                t.column("path", .text).primaryKey()
                t.column("record_name", .text).notNull().unique()
                t.column("sha256", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("modified_at", .text).notNull()
                t.column("dirty", .boolean).notNull().defaults(to: true)
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("system_fields", .blob)
            }
            // 手元で消した(単元の削除で物理削除した)イベントのうち、CloudKit からも消すもの。
            try db.create(table: "sync_tombstones") { t in
                t.column("record_name", .text).primaryKey()
            }
        }
        return migrator
    }

    static func createProjections(_ db: Database) throws {
        try db.create(table: "workbook_units") { t in
            t.column("id", .text).primaryKey()
            t.column("title", .text).notNull()
            t.column("outcome", .text).notNull().defaults(to: "")
            t.column("status", .text).notNull()
            t.column("source", .text).notNull()
            t.column("position", .integer).notNull().defaults(to: 0)
            t.column("overview", .text).notNull().defaults(to: "{}")
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
            t.column("passed_at", .text)
        }
        try db.create(table: "workbook_subunits") { t in
            t.column("id", .text).primaryKey()
            t.column("unit_id", .text).notNull().indexed()
            t.column("title", .text).notNull()
            t.column("outcome", .text).notNull().defaults(to: "")
            t.column("position", .integer).notNull().defaults(to: 0)
            t.column("stage", .integer).notNull()
            t.column("status", .text).notNull()
            t.column("n", .integer).notNull()
            t.column("threshold", .double).notNull().defaults(to: 0.8)
            t.column("assistance", .text).notNull().defaults(to: "independent_first")
            t.column("scoring_unit", .text).notNull().defaults(to: "")
            t.column("metadata", .text).notNull().defaults(to: "{}")
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
            t.column("passed_at", .text)
        }
        try db.create(table: "workbook_problems") { t in
            t.column("id", .text).primaryKey()
            t.column("subunit_id", .text).notNull().indexed()
            t.column("position", .integer).notNull().defaults(to: 0)
            t.column("prompt", .text).notNull()
            t.column("answer_key", .text).notNull().defaults(to: "")
            t.column("checkpoints", .text).notNull().defaults(to: "[]")
            t.column("source", .text).notNull()
            t.column("hint_given_at", .text)
            t.column("created_at", .text).notNull()
        }
        try db.create(table: "workbook_sets") { t in
            t.column("id", .text).primaryKey()
            t.column("subunit_id", .text).notNull().indexed()
            t.column("stage", .integer).notNull()
            t.column("kind", .text).notNull()
            t.column("status", .text).notNull()
            t.column("problem_ids", .text).notNull().defaults(to: "[]")
            t.column("gate", .text).notNull().defaults(to: "{}")
            t.column("result", .text)
            t.column("error", .text)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
            t.column("graded_at", .text)
        }
        try db.create(table: "workbook_captures") { t in
            t.column("id", .text).primaryKey()
            t.column("status", .text).notNull()
            t.column("image_path", .text).notNull()
            t.column("content_type", .text).notNull()
            t.column("sha256", .text).notNull()
            t.column("byte_count", .integer).notNull()
            t.column("context", .text).notNull().defaults(to: "{}")
            t.column("subunit_id", .text).indexed()
            t.column("set_id", .text)
            t.column("verdicts", .text).notNull().defaults(to: "[]")
            t.column("summary", .text).notNull().defaults(to: "{}")
            t.column("candidates", .text).notNull().defaults(to: "[]")
            t.column("error", .text)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
            t.column("graded_at", .text)
        }
        try db.create(table: "workbook_attempts") { t in
            t.column("id", .text).primaryKey()
            t.column("subunit_id", .text).notNull().indexed()
            t.column("problem_id", .text).notNull().indexed()
            t.column("capture_id", .text).notNull()
            t.column("set_id", .text)
            t.column("sequence", .integer).notNull()
            t.column("verdict", .text).notNull()
            t.column("score", .double).notNull()
            t.column("assisted", .boolean).notNull().defaults(to: false)
            t.column("error_tag", .text).notNull().defaults(to: "")
            t.column("note", .text).notNull().defaults(to: "")
            t.column("created_at", .text).notNull()
            t.uniqueKey(["capture_id", "problem_id"])
        }
        try db.create(table: "workbook_proposals") { t in
            t.column("id", .text).primaryKey()
            t.column("thread_id", .text)
            t.column("message_id", .text)
            t.column("status", .text).notNull()
            t.column("request", .text).notNull()
            t.column("overview", .text).notNull().defaults(to: "{}")
            t.column("unit_id", .text)
            t.column("error", .text)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(table: "threads") { t in
            t.column("id", .text).primaryKey()
            t.column("title", .text).notNull()
            t.column("source", .text).notNull().defaults(to: "user")
            t.column("latest_preview", .text)
            t.column("last_message_at", .text)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(table: "messages") { t in
            t.column("id", .text).primaryKey()
            t.column("thread_id", .text).notNull().indexed()
            t.column("role", .text).notNull()
            t.column("status", .text).notNull()
            t.column("plain_text", .text)
            t.column("blocks", .text).notNull().defaults(to: "[]")
            t.column("metadata", .text).notNull().defaults(to: "{}")
            t.column("created_at", .text).notNull()
            t.column("completed_at", .text)
        }
        try db.create(table: "learning_progress") { t in
            t.column("revision", .integer).primaryKey()
            t.column("state", .text).notNull()
            t.column("message_id", .text)
            t.column("turn_id", .text)
            t.column("saved_at", .text).notNull()
        }
        try db.create(table: "turns") { t in
            t.column("id", .text).primaryKey()
            t.column("kind", .text).notNull()
            t.column("target_id", .text)
            t.column("thread_id", .text).indexed()
            t.column("status", .text).notNull()
            t.column("round", .integer).notNull().defaults(to: 1)
            t.column("plan", .text).notNull()
            t.column("outcome", .text)
            t.column("codex_thread_id", .text)
            t.column("codex_turn_id", .text)
            t.column("executions", .text).notNull().defaults(to: "[]")
            t.column("error", .text)
            t.column("created_at", .text).notNull()
            t.column("started_at", .text)
            t.column("completed_at", .text)
        }
        try db.create(table: "codex_threads") { t in
            t.column("thread_id", .text).primaryKey()
            t.column("codex_thread_id", .text).notNull()
            t.column("last_turn_id", .text)
            t.column("last_completed_at", .text)
            t.column("created_at", .text).notNull()
        }
        try db.create(table: "codex_account") { t in
            t.column("id", .text).primaryKey()
            t.column("status", .text).notNull()
            t.column("auth_mode", .text)
            t.column("plan_type", .text)
            t.column("email", .text)
            t.column("rate_limits", .text).notNull().defaults(to: "{}")
            t.column("resets_at", .text)
            t.column("synced_at", .text)
            t.column("error", .text)
        }
        try db.create(table: "thread_branches") { t in
            t.column("id", .text).primaryKey()
            t.column("stem_thread_id", .text).notNull().indexed()
            t.column("branch_thread_id", .text).notNull().unique()
            t.column("anchor_message_id", .text).notNull()
            t.column("anchor_codex_turn_id", .text).notNull()
            t.column("client_request_id", .text).notNull().unique()
            t.column("first_question_preview", .text).notNull()
            t.column("status", .text).notNull()
            t.column("last_merged_message_id", .text)
            t.column("merge_pending", .boolean).notNull().defaults(to: false)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(table: "branch_fork_attempts") { t in
            t.column("id", .text).primaryKey()
            t.column("stem_thread_id", .text).notNull()
            t.column("client_request_id", .text).notNull().unique()
            t.column("codex_thread_id", .text).notNull()
            t.column("branch_id", .text)
            t.column("status", .text).notNull()
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
    }

    static func dropProjections(_ db: Database) throws {
        for entity in LedgerEntity.allCases {
            try db.drop(table: entity.rawValue)
        }
    }
}
