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
            try createV1Projections(db)
        }
        // 学習タイムライン(Issue #46)。v1 の台帳に表を足すだけで、既存の行は変えない。
        migrator.registerMigration("v2-timeline") { db in
            try createTimelineProjections(db)
        }
        return migrator
    }

    /// 作り直し(`Ledger.rebuild`)で使う、今の全部の射影。
    static func createProjections(_ db: Database) throws {
        try createV1Projections(db)
        try createTimelineProjections(db)
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
