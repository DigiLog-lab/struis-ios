import Foundation
import GRDB

/// One append-only ledger event (design §4.4). Events are self-contained: the
/// payload is the complete row after the change (or a deletion marker), so a
/// projection can always be rebuilt by replaying `seq` order and a future sync
/// endpoint can apply `(device_id, seq)` idempotently.
nonisolated struct LedgerEvent: Codable, Hashable, Sendable {
    /// Semantic name for audit and sync: `unit.created`, `subunit.stage_set`, `capture.graded`, …
    let kind: String
    let entity: LedgerEntity
    let entityID: String
    /// The full row after the change (`row`) or `{"deleted": true}`.
    let payload: LedgerJSON

    enum CodingKeys: String, CodingKey {
        case kind, entity, payload
        case entityID = "entity_id"
    }

    /// Upsert event for a row.
    static func upsert<Row: LedgerRow>(_ kind: String, _ row: Row) -> LedgerEvent {
        LedgerEvent(kind: kind, entity: Row.entity, entityID: row.entityID, payload: Self.encode(row))
    }

    static func delete(_ kind: String, entity: LedgerEntity, entityID: String) -> LedgerEvent {
        LedgerEvent(kind: kind, entity: entity, entityID: entityID, payload: .object(["deleted": .bool(true)]))
    }

    var isDeletion: Bool { payload["deleted"]?.boolValue == true }

    nonisolated static func encode<Row: Encodable>(_ row: Row) -> LedgerJSON {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(row), let value = try? JSONDecoder().decode(LedgerJSON.self, from: data) else {
            return .null
        }
        return value
    }

    nonisolated static func decode<Row: Decodable>(_ type: Row.Type, from payload: LedgerJSON) throws -> Row {
        let data = try JSONEncoder().encode(payload)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Row.self, from: data)
    }

    /// Apply this event to the projection tables. This is the only code path
    /// that writes projections (tested by `LedgerRebuildTests`).
    func apply(to db: Database) throws {
        if isDeletion {
            try db.execute(sql: "DELETE FROM \(entity.rawValue) WHERE \(Self.primaryKeyColumn(entity)) = ?", arguments: [entityID])
            return
        }
        switch entity {
        case .workbookUnits: try Self.decode(WorkbookUnitRecord.self, from: payload).save(db)
        case .workbookSubunits: try Self.decode(WorkbookSubunitRecord.self, from: payload).save(db)
        case .workbookProblems: try Self.decode(WorkbookProblemRecord.self, from: payload).save(db)
        case .workbookSets: try Self.decode(WorkbookSetRecord.self, from: payload).save(db)
        case .workbookCaptures: try Self.decode(WorkbookCaptureRecord.self, from: payload).save(db)
        case .workbookAttempts: try Self.decode(WorkbookAttemptRecord.self, from: payload).save(db)
        case .workbookProposals: try Self.decode(WorkbookProposalRecord.self, from: payload).save(db)
        case .threads: try Self.decode(ThreadRecord.self, from: payload).save(db)
        case .messages: try Self.decode(MessageRecord.self, from: payload).save(db)
        case .learningProgress: try Self.decode(ProgressRevisionRecord.self, from: payload).save(db)
        case .turns: try Self.decode(TurnRecord.self, from: payload).save(db)
        case .codexThreads: try Self.decode(CodexThreadRecord.self, from: payload).save(db)
        case .codexAccount: try Self.decode(CodexAccountRecord.self, from: payload).save(db)
        case .threadBranches: try Self.decode(ThreadBranchRecord.self, from: payload).save(db)
        case .branchForkAttempts: try Self.decode(BranchForkAttemptRecord.self, from: payload).save(db)
        case .timelineSkills: try Self.decode(TimelineSkillRecord.self, from: payload).save(db)
        case .timelineSkillEdges: try Self.decode(TimelineSkillEdgeRecord.self, from: payload).save(db)
        case .timelineMapChanges: try Self.decode(TimelineMapChangeRecord.self, from: payload).save(db)
        case .timelineBatches: try Self.decode(TimelineBatchRecord.self, from: payload).save(db)
        case .timelineCards: try Self.decode(TimelineCardRecord.self, from: payload).save(db)
        case .timelineAttempts: try Self.decode(TimelineAttemptRecord.self, from: payload).save(db)
        case .timelineDips: try Self.decode(TimelineDipRecord.self, from: payload).save(db)
        }
    }

    nonisolated static func primaryKeyColumn(_ entity: LedgerEntity) -> String {
        switch entity {
        case .learningProgress: "revision"
        case .codexThreads: "thread_id"
        default: "id"
        }
    }
}

/// A stored event with its ledger position.
nonisolated struct StoredLedgerEvent: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    static let databaseTableName = "ledger_events"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var seq: Int64?
    var deviceId: String
    var kind: String
    var entity: String
    var entityId: String
    var payload: String
    var createdAt: String
    var syncedSeq: Int64?

    var event: LedgerEvent? {
        guard let entity = LedgerEntity(rawValue: entity), let payload = LedgerJSON.parse(payload) else { return nil }
        return LedgerEvent(kind: kind, entity: entity, entityID: entityId, payload: payload)
    }

    init(seq: Int64? = nil, deviceId: String, event: LedgerEvent, createdAt: String, syncedSeq: Int64? = nil) {
        self.seq = seq
        self.deviceId = deviceId
        self.kind = event.kind
        self.entity = event.entity.rawValue
        self.entityId = event.entityID
        self.payload = event.payload.canonicalText
        self.createdAt = createdAt
        self.syncedSeq = syncedSeq
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        seq = inserted.rowID
    }
}
