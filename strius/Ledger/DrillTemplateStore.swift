import Foundation
import GRDB

/// オフライン反復の「問題の型」の控え(知識グラフの点ごとに 1 行。docs/offline-drill/format.md)。
///
/// 台帳のイベント(`ledger_events`)には入れない。Claude との会話の控え(`ClaudeConversationStore`)と同じ扱いの、この端末の控え:
/// - 型は学習の記録ではなく、点(`TimelineSkillRecord`)から AI に書かせ直せる派生物。消えても学習の記録は欠けない。
/// - 型は端末の点検(`DrillValidator`)を通ったものだけを保存する。点検器と書式の版はアプリの版ごとに違い得るので、
///   別の端末が通した型を同期で受け取ってそのまま出すことはしない(受け取った側でもう一度点検することになる)。
/// - 書式の版が上がったら全部を書かせ直す。追記だけのイベントに入れると、古い版の型が履歴に残り続ける。
/// - タイムラインのイベントの適用・同期・作り直しのコードに触れずに足せる(オンラインのタイムラインを変えない)。
/// 学習記録の消去(`eraseLearningRecords`)と単元の削除(`eraseHistory`)では、この表の行も消す。
nonisolated final class DrillTemplateStore: Sendable {
    /// 1 つの点についての結論。
    nonisolated struct Entry: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
        static let databaseTableName: String = "drill_templates"
        static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
        static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

        /// 点の ID(`TimelineSkillRecord.id`)。
        var skillId: String
        /// ready(点検を通った型がある)| excluded(対象から外した)
        var status: String
        /// 書いた時の書式の版(`DrillTemplate.currentFormat`)。
        var format: Int
        /// 点検を通った型(キーの順をそろえた JSON)。外した点は空。
        var template: String?
        /// 数値の点検をした型か。
        var numericCheck: Bool
        /// 点検で作れた、互いに違う問題の数。
        var problems: Int
        /// 外した理由(JSON の文字列の配列)。
        var reasons: String
        /// AI が「型にできない」と答えたか(偽は、2 回とも点検に落ちた)。
        var declined: Bool
        var createdAt: String
        var updatedAt: String
    }

    static let statusReady: String = "ready"
    static let statusExcluded: String = "excluded"

    private let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// 台帳の移行 `v7-drill-templates`。
    static func createTables(_ db: Database) throws {
        try db.create(table: "drill_templates", ifNotExists: true) { (t: TableDefinition) -> Void in
            t.column("skill_id", .text).primaryKey()
            t.column("status", .text).notNull()
            t.column("format", .integer).notNull()
            t.column("template", .text)
            t.column("numeric_check", .boolean).notNull().defaults(to: false)
            t.column("problems", .integer).notNull().defaults(to: 0)
            t.column("reasons", .text).notNull().defaults(to: "[]")
            t.column("declined", .boolean).notNull().defaults(to: false)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
        }
    }

    /// 消す点の分の行を消す(単元の削除)。
    static func erase(skillIDs: Set<String>, from db: Database) throws {
        for id: String in skillIDs {
            try db.execute(sql: "DELETE FROM drill_templates WHERE skill_id = ?", arguments: [id])
        }
    }

    // MARK: - 書く

    /// 結論を保存する(同じ点の前の行は置き換える)。
    func save(skillID: String, outcome: DrillAuthoringOutcome) throws {
        let now: String = LedgerClock.now()
        var entry: Entry = Entry(skillId: skillID, status: DrillTemplateStore.statusExcluded, format: DrillTemplate.currentFormat, template: nil,
                                 numericCheck: false, problems: 0, reasons: "[]", declined: false, createdAt: now, updatedAt: now)
        switch outcome {
        case DrillAuthoringOutcome.ready(let json, let numericallyChecked, let problems):
            entry.status = DrillTemplateStore.statusReady
            entry.template = json
            entry.numericCheck = numericallyChecked
            entry.problems = problems
        case DrillAuthoringOutcome.excluded(let reasons, let declined):
            entry.reasons = String(decoding: try JSONEncoder().encode(reasons), as: UTF8.self)
            entry.declined = declined
        }
        let stored: Entry = entry
        try queue.write { (db: Database) -> Void in
            var row: Entry = stored
            if let previous: Entry = try Entry.fetchOne(db, key: skillID) { row.createdAt = previous.createdAt }
            try row.save(db)
        }
    }

    func remove(skillID: String) throws {
        try queue.write { (db: Database) -> Void in
            try DrillTemplateStore.erase(skillIDs: [skillID], from: db)
        }
    }

    // MARK: - 読む

    func entry(for skillID: String) throws -> Entry? {
        try queue.read { (db: Database) -> Entry? in try Entry.fetchOne(db, key: skillID) }
    }

    /// まだ AI に頼んでいない点か(行が無い、または前の書式の版で書いた)。外した点は、同じ書式の版の間は頼み直さない。
    func needsAuthoring(skillID: String) throws -> Bool {
        guard let entry: Entry = try entry(for: skillID) else { return true }
        return entry.format != DrillTemplate.currentFormat
    }

    /// オフラインで出せる型(今の書式の版で、点検を通ったもの)。読めない行は無いものとして扱う。
    func template(for skillID: String) throws -> DrillTemplate? {
        guard let entry: Entry = try entry(for: skillID), entry.status == DrillTemplateStore.statusReady,
              entry.format == DrillTemplate.currentFormat, let json: String = entry.template else { return nil }
        return try? DrillTemplate.decode(json: json)
    }

    /// 型がある点の ID(今の書式の版)。
    func readySkillIDs() throws -> [String] {
        try queue.read { (db: Database) -> [String] in
            try String.fetchAll(db, sql: "SELECT skill_id FROM drill_templates WHERE status = ? AND format = ? ORDER BY skill_id",
                                arguments: [DrillTemplateStore.statusReady, DrillTemplate.currentFormat])
        }
    }

    /// 外した理由。
    func excludedReasons(for skillID: String) throws -> [String] {
        guard let entry: Entry = try entry(for: skillID), entry.status == DrillTemplateStore.statusExcluded else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(entry.reasons.utf8))) ?? []
    }
}
