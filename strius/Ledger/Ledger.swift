import Foundation
import GRDB
import OSLog

private let ledgerLog = Logger(subsystem: "com.digiloglab.strius", category: "ledger")

/// App container locations for learner data (design §4.1). Backed up by the
/// device backup; never visible to the guest (`/workspace` is elsewhere).
nonisolated enum StruisPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Struis", isDirectory: true)
    }()
    static let ledger = root.appendingPathComponent("ledger.sqlite")
    static let captures = root.appendingPathComponent("captures", isDirectory: true)
    static let memory = root.appendingPathComponent("memory", isDirectory: true)
    static let assets = root.appendingPathComponent("assets", isDirectory: true)

    static func prepare() throws {
        for directory in [root, captures, memory, assets] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

nonisolated enum LedgerError: Error, LocalizedError, Sendable {
    case notFound(String)
    case conflict(String)
    case invalid(String)
    case rejected(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notFound(let what): "\(what) が見つかりません"
        case .conflict(let what): what
        case .invalid(let what): what
        case .rejected(_, let message): message
        }
    }

    var code: String? {
        if case .rejected(let code, _) = self { return code }
        return nil
    }
}

/// The device ledger (design §4). All mutation goes through `commit`, which
/// appends events and applies them to the projections in one transaction.
actor Ledger {
    nonisolated let queue: DatabaseQueue
    nonisolated let deviceID: String
    nonisolated let deletionRoot: URL
    nonisolated let deletionRuntimeRoots: [URL]
    private var deletionFailure: String?
    private var observers: [UUID: @Sendable ([LedgerEvent]) -> Void] = [:]

    init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: path.path, configuration: configuration)
        try LedgerSchema.migrator.migrate(queue)
        self.deletionRoot = path.deletingLastPathComponent()
        self.deletionRuntimeRoots = path.standardizedFileURL == StruisPaths.ledger.standardizedFileURL ? [HyotanBoot.codexHome, HyotanBoot.sharedCodexHome, HyotanBoot.workspaceRoot, HyotanBoot.legacyRoot, HyotanBoot.legacyRoot.deletingLastPathComponent().appendingPathComponent("agentcase")] : []
        self.queue = queue
        self.deviceID = try queue.write { db in
            if let existing = try String.fetchOne(db, sql: "SELECT value FROM ledger_meta WHERE key = 'device_id'") {
                return existing
            }
            let id = LedgerID.make()
            try db.execute(sql: "INSERT INTO ledger_meta (key, value) VALUES ('device_id', ?)", arguments: [id])
            return id
        }
        do {
            try LedgerArchive.recoverImport(queue: queue, root: deletionRoot)
            try UnitDeletion.recover(queue: queue, root: deletionRoot, runtimeRoots: deletionRuntimeRoots)
        }
        catch { deletionFailure = String(describing: error) }
    }

    /// In-memory ledger for tests and previews.
    static func inMemory() throws -> Ledger {
        try Ledger(path: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("struis-\(UUID().uuidString)").appendingPathComponent("ledger.sqlite"))
    }

    func ensureDeletionReady() throws {
        if FileManager.default.fileExists(atPath: LedgerArchive.importJournalURL(deletionRoot).path) {
            throw LedgerError.conflict("台帳の取り込みを完了できませんでした。アプリを開き直してください。")
        }
        if deletionFailure != nil { throw LedgerError.conflict("単元の削除を再開してください") }
        if FileManager.default.fileExists(atPath: UnitDeletion.journalURL(deletionRoot).path) { throw LedgerError.conflict("単元を削除しています") }
    }

    func deletionScope(unitID: String) throws -> UnitDeletion.Scope {
        try queue.read { try UnitDeletion.scope(db: $0, unitID: unitID) }
    }

    func pendingDeletion() -> UnitDeletion.Fact? {
        guard let data = try? Data(contentsOf: UnitDeletion.journalURL(deletionRoot)), let journal = try? JSONDecoder().decode(UnitDeletion.Journal.self, from: data) else { return nil }
        return journal.fact
    }

    func deleteUnit(id: String, extraCodexIDs: Set<String> = []) throws -> UnitDeletion.Fact {
        UnitDeletion.gate.lock(); defer { UnitDeletion.gate.unlock() }
        if let pending = pendingDeletion() {
            do {
                try UnitDeletion.recover(queue: queue, root: deletionRoot, runtimeRoots: deletionRuntimeRoots)
                deletionFailure = nil
                if pending.unitID == id, try queue.read({ try WorkbookUnitRecord.fetchOne($0, key: id) }) == nil {
                    notify([.delete("unit.deleted", entity: .workbookUnits, entityID: id)])
                    return pending
                }
            } catch { deletionFailure = String(describing: error); throw error }
        }
        try ensureDeletionReady()
        if let previous = try queue.read({ db in try StoredLedgerEvent.filter(Column("kind") == "unit.deleted" && Column("entity_id") == id).fetchOne(db) }), let payload = previous.event?.payload {
            return try LedgerEvent.decode(UnitDeletion.Fact.self, from: payload)
        }
        let journal = try queue.read { try UnitDeletion.prepare(db: $0, root: deletionRoot, unitID: id, extraCodexIDs: extraCodexIDs, runtimeRoots: deletionRuntimeRoots) }
        try JSONEncoder().encode(journal).write(to: UnitDeletion.journalURL(deletionRoot), options: .atomic)
        do {
            for change in journal.changes { try UnitDeletion.write(change) }
            try queue.write { db in
                try db.execute(sql: "PRAGMA secure_delete=ON")
                for stored in try StoredLedgerEvent.fetchAll(db) {
                    guard let old = stored.event else { continue }
                    if journal.fact.scope.contains(old.entity, old.entityID) || !UnitDeletion.references(old.payload).isDisjoint(with: journal.fact.scope.all) {
                        try db.execute(sql: "DELETE FROM ledger_events WHERE seq=?", arguments: [stored.seq])
                    }
                }
                for event in journal.events {
                    try db.execute(sql: "DELETE FROM ledger_events WHERE entity=? AND entity_id=?", arguments: [event.entity.rawValue, event.entityID])
                }
                try Self.append(journal.events, deviceID: deviceID, to: db)
            }
            try UnitDeletion.recover(queue: queue, root: deletionRoot, runtimeRoots: deletionRuntimeRoots)
        } catch {
            // Roll back only before the fact was committed. After commit forward recovery is required.
            if (try? UnitDeletion.committed(journal, queue: queue)) == false {
                do { try UnitDeletion.recover(queue: queue, root: deletionRoot, runtimeRoots: deletionRuntimeRoots) }
                catch { deletionFailure = String(describing: error) }
            } else { deletionFailure = String(describing: error) }
            throw error
        }
        deletionFailure = nil
        notify(journal.events)
        return journal.fact
    }

    /// Memory mutation and its validation share the same serialization boundary as deletion.
    func withMemory<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try ensureDeletionReady()
        UnitDeletion.gate.lock(); defer { UnitDeletion.gate.unlock() }
        return try queue.read(block)
    }

    // MARK: - Reads

    func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try ensureDeletionReady()
        return try queue.read(block)
    }

    // MARK: - Writes

    /// Read the current projections and append the returned events atomically.
    /// The block must not modify projection tables directly.
    @discardableResult
    func commit<T: Sendable>(_ block: @Sendable (Database) throws -> (events: [LedgerEvent], result: T)) throws -> T {
        try ensureDeletionReady()
        let deviceID = deviceID
        let (events, result) = try queue.write { db -> ([LedgerEvent], T) in
            let (events, result) = try block(db)
            try Self.append(events, deviceID: deviceID, to: db)
            return (events, result)
        }
        if !events.isEmpty { notify(events) }
        return result
    }

    /// Append events without a read phase.
    func append(_ events: [LedgerEvent]) throws {
        try ensureDeletionReady()
        guard !events.isEmpty else { return }
        let deviceID = deviceID
        try queue.write { db in
            try Self.append(events, deviceID: deviceID, to: db)
        }
        notify(events)
    }

    nonisolated static func append(_ events: [LedgerEvent], deviceID: String, to db: Database) throws {
        let now = LedgerClock.now()
        let facts = try StoredLedgerEvent.filter(Column("kind") == "unit.deleted").fetchAll(db)
        var removed = Set<String>()
        for fact in facts {
            if let scope = fact.event?.payload["scope"]?["ids"]?.objectValue {
                for value in scope.values { removed.formUnion(value.arrayValue?.compactMap(\.stringValue) ?? []) }
            }
        }
        for event in events {
            if !event.isDeletion && (removed.contains(event.entityID) || !UnitDeletion.references(event.payload).isDisjoint(with: removed)) {
                throw LedgerError.conflict("削除した単元の結果は保存できません")
            }
            let stored = StoredLedgerEvent(deviceId: deviceID, event: event, createdAt: now)
            try stored.insert(db)
            try event.apply(to: db)
        }
    }

    func exportArchive(root: URL, to directory: URL) throws -> URL {
        try ensureDeletionReady()
        UnitDeletion.gate.lock(); defer { UnitDeletion.gate.unlock() }
        return try LedgerArchive.exportSnapshot(stored: events(), deviceID: deviceID, root: root, directory: directory)
    }

    // MARK: - Rebuild / export

    /// Drop every projection and replay `ledger_events` (design §4.1).
    func rebuild() throws {
        try ensureDeletionReady()
        try queue.write { db in
            try LedgerSchema.dropProjections(db)
            try LedgerSchema.createProjections(db)
            let rows = try StoredLedgerEvent.order(Column("seq")).fetchAll(db)
            for row in rows {
                guard let event = row.event else { continue }
                try event.apply(to: db)
            }
        }
    }

    func events(since seq: Int64 = 0, limit: Int? = nil) throws -> [StoredLedgerEvent] {
        try ensureDeletionReady()
        return try queue.read { db in
            var request = StoredLedgerEvent.filter(Column("seq") > seq).order(Column("seq"))
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db)
        }
    }

    /// Import events into an empty ledger (design §4.3). Sequence numbers are reassigned locally.
    func importEvents(_ events: [LedgerEvent]) throws {
        let count = try queue.read { db in try StoredLedgerEvent.fetchCount(db) }
        guard count == 0 else { throw LedgerError.conflict("取り込みは空の台帳にだけできます") }
        try append(events)
    }

    func importArchive(events: [LedgerEvent], files: [String: Data], root: URL) throws {
        try ensureDeletionReady()
        UnitDeletion.gate.lock(); defer { UnitDeletion.gate.unlock() }
        guard try eventCount() == 0 else { throw LedgerError.conflict("取り込みは空の台帳にだけできます") }
        let changes = try files.sorted(by: { $0.key < $1.key }).map { path, data in
            let target = root.appendingPathComponent(path)
            return UnitDeletion.Change(path: target.path, before: FileManager.default.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil, after: data)
        }
        let journal = LedgerArchive.ImportJournal(id: LedgerID.make(), changes: changes)
        try JSONEncoder().encode(journal).write(to: LedgerArchive.importJournalURL(deletionRoot), options: .atomic)
        do {
            try queue.write { db in
                // Verify empty again inside the transaction before installing any files.
                guard try StoredLedgerEvent.fetchCount(db) == 0 else { throw LedgerError.conflict("取り込みは空の台帳にだけできます") }
                try Self.append(events, deviceID: deviceID, to: db)
                for change in changes { try UnitDeletion.write(change) }
                try db.execute(sql: "INSERT OR REPLACE INTO ledger_meta (key,value) VALUES ('archive_import_id',?)", arguments: [journal.id])
            }
            try LedgerArchive.recoverImport(queue: queue, root: deletionRoot)
        } catch {
            do { try LedgerArchive.recoverImport(queue: queue, root: deletionRoot) }
            catch { deletionFailure = String(describing: error) }
            throw error
        }
        notify(events)
    }

    func eventCount() throws -> Int {
        try queue.read { db in try StoredLedgerEvent.fetchCount(db) }
    }

    /// Fingerprint of every projection row, used to prove rebuild/import equality.
    func projectionDigest() throws -> String {
        try queue.read { db in
            var lines: [String] = []
            for entity in LedgerEntity.allCases {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(entity.rawValue) ORDER BY \(LedgerEvent.primaryKeyColumn(entity))")
                for row in rows {
                    let pairs = row.columnNames.sorted().map { "\($0)=\(String(describing: row[$0] as DatabaseValue))" }
                    lines.append(entity.rawValue + ":" + pairs.joined(separator: ","))
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Observation

    func observe(_ handler: @escaping @Sendable ([LedgerEvent]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func unobserve(_ id: UUID) {
        observers[id] = nil
    }

    private func notify(_ events: [LedgerEvent]) {
        for handler in observers.values { handler(events) }
    }
}
