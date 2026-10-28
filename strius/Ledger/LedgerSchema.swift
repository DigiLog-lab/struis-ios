import Foundation
import GRDB

/// SQLite schema for the device ledger (design §4). `ledger_events` is the
/// source of truth; every other table is a projection rebuilt from it.
nonisolated enum LedgerSchema {
    /// 移行の登録順(Issue #57)。タイムライン (#46) の `v2`〜`v5` と iCloud 同期 (#51) の `sync-v1` は、どちらも
    /// `v1` の上に表・列を足すだけで互いに触らない。GRDB は済んでいない移行を登録順に流すので、どちらが先に済んだ台帳
    /// (`v1`〜`v5` / `v1`+`sync-v1`)からでも、残りを流せば同じ形になる(`LedgerMigrationTests`)。
    static let migrations: [(id: String, migrate: @Sendable (Database) throws -> Void)] = [
        ("v1", createV1),
        // 学習タイムライン(Issue #46)。v1 の台帳に表を足すだけで、既存の行は変えない。
        ("v2-timeline", createTimelineProjections),
        // 知識グラフの点の「まだ掘っていない」印(2026-10-24)。列を足すだけで、既存の行は空(タイムラインが開いた時に付ける)。
        ("v3-timeline-expansion", addTimelineExpansion),
        // 採点の見直し(2026-10-25): 3つの正誤・採点したモデルのメモと書き起こし・関係するスキル・見直し。列を足すだけ。
        ("v4-timeline-review", addTimelineReview),
        // 今日の記録(2026-10-27): 出来事ごとに、その時点の文を 1 件ずつ保存する(キャッシュの先頭を後から書き換えない)。
        ("v5-timeline-log", addTimelineLog),
        // iCloud 同期 (Issue #51)。
        ("sync-v1", addSync),
    ]

    static var migrator: DatabaseMigrator {
        migrator(migrations.map(\.id))
    }

    /// 指定した移行だけを、その順で登録する(テストで前の版の台帳を作る)。
    static func migrator(_ ids: [String]) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for id in ids {
            guard let migration = migrations.first(where: { $0.id == id }) else { preconditionFailure("unknown migration \(id)") }
            migrator.registerMigration(id, migrate: migration.migrate)
        }
        return migrator
    }

    static func createV1(_ db: Database) throws {
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
        try createV1Projections(db)
    }

    /// iCloud 同期 (Issue #51)。イベントは元の端末と連番 `(origin_device_id, origin_seq)` で一意にし、
    /// 外から来たイベントを二重に足さない。自端末のイベントは挿入時に `device_id` と `seq` で埋める。
    static func addSync(_ db: Database) throws {
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

    /// 作り直し(`Ledger.rebuild`)で使う、今の全部の射影。
    static func createProjections(_ db: Database) throws {
        try createV1Projections(db)
        try createTimelineProjections(db)
        try addTimelineExpansion(db)
        try addTimelineReview(db)
        try addTimelineLog(db)
    }

    static func addTimelineLog(_ db: Database) throws {
        try db.alter(table: "timeline_attempts") { t in
            t.add(column: "disputed_at", .text)
        }
        try db.create(table: "timeline_log") { t in
            t.column("id", .text).primaryKey()
            t.column("day", .text).notNull().indexed()
            t.column("seq", .integer).notNull()
            t.column("kind", .text).notNull()
            t.column("attempt_id", .text)
            t.column("unit_id", .text)
            t.column("skill_ids", .text).notNull().defaults(to: "[]")
            t.column("text", .text).notNull()
            t.column("created_at", .text).notNull()
        }
    }

    static func addTimelineReview(_ db: Database) throws {
        try db.alter(table: "timeline_attempts") { t in
            t.add(column: "grade", .text)
            t.add(column: "notes", .text)
            t.add(column: "transcript", .text)
            t.add(column: "skill_ids", .text)
            t.add(column: "skills_pending", .boolean)
            t.add(column: "skill_marks", .text)
            t.add(column: "dispute", .text)
            t.add(column: "review_notes", .text)
            t.add(column: "reviewed_at", .text)
        }
    }

    static func addTimelineExpansion(_ db: Database) throws {
        try db.alter(table: "timeline_skills") { t in
            t.add(column: "expansion", .text)
        }
    }

    static func createTimelineProjections(_ db: Database) throws {
        try db.create(table: "timeline_skills") { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("unit_id", .text).indexed()
            t.column("status", .text).notNull()
            t.column("correct_dates", .text).notNull().defaults(to: "[]")
            t.column("mastery_threshold", .integer).notNull().defaults(to: 3)
            t.column("attempts", .integer).notNull().defaults(to: 0)
            t.column("last_correct_at", .text)
            t.column("next_review_at", .text)
            t.column("review_count", .integer).notNull().defaults(to: 0)
            t.column("replaced_by", .text).notNull().defaults(to: "[]")
            t.column("source", .text).notNull()
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(table: "timeline_skill_edges") { t in
            t.column("id", .text).primaryKey()
            t.column("skill_id", .text).notNull().indexed()
            t.column("requires_skill_id", .text).notNull().indexed()
            t.column("relation", .text).notNull()
            t.column("source", .text).notNull()
            t.column("note", .text).notNull().defaults(to: "")
            t.column("created_at", .text).notNull()
        }
        try db.create(table: "timeline_map_changes") { t in
            t.column("id", .text).primaryKey()
            t.column("kind", .text).notNull()
            t.column("detail", .text).notNull().defaults(to: "{}")
            t.column("attempt_ids", .text).notNull().defaults(to: "[]")
            t.column("reviewed", .boolean).notNull().defaults(to: false)
            t.column("source", .text).notNull()
            t.column("created_at", .text).notNull()
        }
        try db.create(table: "timeline_batches") { t in
            t.column("id", .text).primaryKey()
            t.column("purpose", .text).notNull()
            t.column("status", .text).notNull()
            t.column("reason", .text).notNull().defaults(to: "")
            t.column("accuracy", .double)
            t.column("level_cap", .integer)
            t.column("request", .text).notNull().defaults(to: "{}")
            t.column("model", .text).notNull().defaults(to: "")
            t.column("input_tokens", .integer).notNull().defaults(to: 0)
            t.column("output_tokens", .integer).notNull().defaults(to: 0)
            t.column("cache_write_tokens", .integer).notNull().defaults(to: 0)
            t.column("cache_read_tokens", .integer).notNull().defaults(to: 0)
            t.column("retries", .integer).notNull().defaults(to: 0)
            t.column("rejected", .text).notNull().defaults(to: "[]")
            t.column("error", .text)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(table: "timeline_cards") { t in
            t.column("id", .text).primaryKey()
            t.column("batch_id", .text).indexed()
            t.column("position", .integer).notNull().defaults(to: 0)
            t.column("kind", .text).notNull()
            t.column("level", .integer).notNull()
            t.column("skills", .text).notNull().defaults(to: "[]")
            t.column("type_name", .text).notNull().defaults(to: "")
            t.column("prompt", .text).notNull()
            t.column("math", .text).notNull().defaults(to: "")
            t.column("question", .text).notNull().defaults(to: "")
            t.column("answer_key", .text).notNull().defaults(to: "")
            t.column("answer_expr", .text).notNull().defaults(to: "")
            t.column("checkpoints", .text).notNull().defaults(to: "[]")
            t.column("common_mistakes", .text).notNull().defaults(to: "[]")
            t.column("estimated_seconds", .integer).notNull().defaults(to: 60)
            t.column("chain", .text)
            t.column("easier_of", .text)
            t.column("subunit_id", .text)
            t.column("unit_id", .text)
            t.column("payload", .text).notNull().defaults(to: "{}")
            t.column("origin", .text).notNull()
            t.column("status", .text).notNull()
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
        try db.create(table: "timeline_attempts") { t in
            t.column("id", .text).primaryKey()
            t.column("card_id", .text).notNull().indexed()
            t.column("capture_path", .text)
            t.column("verdict", .text).notNull()
            t.column("checkpoint_results", .text).notNull().defaults(to: "[]")
            t.column("errors", .text).notNull().defaults(to: "[]")
            t.column("learner_answer", .text).notNull().defaults(to: "")
            t.column("cause", .text).notNull().defaults(to: "unknown")
            t.column("seconds", .double).notNull().defaults(to: 0)
            t.column("first_try", .boolean).notNull().defaults(to: true)
            t.column("assisted", .boolean).notNull().defaults(to: false)
            t.column("skip_reason", .text)
            t.column("key_suspect", .boolean).notNull().defaults(to: false)
            t.column("counts_for_accuracy", .boolean).notNull().defaults(to: true)
            t.column("feedback", .text).notNull().defaults(to: "")
            t.column("created_at", .text).notNull()
            t.column("graded_at", .text)
        }
        try db.create(table: "timeline_dips") { t in
            t.column("id", .text).primaryKey()
            t.column("trigger", .text).notNull()
            t.column("chosen", .text)
            t.column("cards_after", .integer).notNull().defaults(to: 0)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
    }

    /// v1 の射影(この形のまま変えない。表を足すときは別の migration にする)。
    static func createV1Projections(_ db: Database) throws {
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
