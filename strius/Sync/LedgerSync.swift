import Foundation
import GRDB
import OSLog

nonisolated private let syncLog = Logger(subsystem: "com.digiloglab.strius", category: "sync")

/// 台帳の iCloud 同期の側 (Issue #51)。外から来たイベントは `Ledger.append` を通さず、元の端末の ID と
/// 連番を保ったまま足す(`(origin_device_id, origin_seq)` の一意制約で二重に足さない)。行ごとに
/// `created_at` の新しいイベントだけを射影に反映し、古いイベントは `ledger_events` に残すだけにする。
extension Ledger {
    nonisolated struct SyncOutbox: Sendable {
        var events: [SyncEventRecord]
        var tombstones: [String]
    }

    nonisolated struct FileOutbox: Sendable {
        var saves: [SyncFileRecord] = []
        var deletions: [String] = []
    }

    nonisolated struct SyncCounts: Sendable, Equatable {
        /// Events, files and deletions not yet in CloudKit.
        var unsent: Int
        /// Events kept because this version cannot read them.
        var pending: Int
    }

    nonisolated struct IngestResult: Sendable, Equatable {
        var applied = 0
        var stored = 0
        var pending = 0
        var dropped = 0
        var deletedUnits = 0
    }

    nonisolated enum IngestOutcome: Sendable {
        case applied(LedgerEvent)
        case stored
        case pending
        case dropped
        case duplicate
    }

    /// Notice sent to observers after the ledger was replaced; every store re-reads.
    nonisolated static var replacedNotice: [LedgerEvent] {
        LedgerEntity.allCases.map { LedgerEvent.delete("sync.replaced", entity: $0, entityID: "") }
    }

    /// Whether this device wrote the current version of a row (not another device through the sync).
    nonisolated static func isLocal(_ entity: LedgerEntity, _ id: String, deviceID: String, _ db: Database) throws -> Bool {
        let origin = try String.fetchOne(db, sql: """
            SELECT origin_device_id FROM ledger_events WHERE entity = ? AND entity_id = ?
            ORDER BY created_at DESC, origin_device_id DESC, origin_seq DESC LIMIT 1
            """, arguments: [entity.rawValue, id])
        return origin == nil || origin == deviceID
    }

    // MARK: - Outgoing

    /// Events not yet sent (`synced_seq IS NULL`) and records to delete. `codex_account` never leaves the device.
    func syncOutbox(limit: Int) throws -> SyncOutbox {
        try ensureDeletionReady()
        return try queue.read { db in
            let rows = try StoredLedgerEvent.fetchAll(db, sql: """
                SELECT * FROM ledger_events WHERE synced_seq IS NULL AND entity != ? ORDER BY seq LIMIT ?
                """, arguments: [LedgerEntity.codexAccount.rawValue, limit])
            let tombstones = try String.fetchAll(db, sql: "SELECT record_name FROM sync_tombstones ORDER BY record_name LIMIT ?", arguments: [limit])
            return SyncOutbox(events: rows.compactMap(SyncEventRecord.init), tombstones: tombstones)
        }
    }

    func markSyncSent(saved: [String], deleted: [String]) throws {
        try queue.write { db in
            for name in saved {
                guard let (device, seq) = SyncNames.eventOrigin(name) else { continue }
                try db.execute(sql: "UPDATE ledger_events SET synced_seq = origin_seq WHERE origin_device_id = ? AND origin_seq = ?", arguments: [device, seq])
                // Erased by a unit deletion while it was on the way: remove it from CloudKit too.
                if db.changesCount == 0 {
                    try db.execute(sql: "INSERT OR IGNORE INTO sync_tombstones (record_name) VALUES (?)", arguments: [name])
                }
            }
            for name in deleted {
                try db.execute(sql: "DELETE FROM sync_tombstones WHERE record_name = ?", arguments: [name])
            }
        }
    }

    func syncCounts() throws -> SyncCounts {
        try queue.read { db in
            let events = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ledger_events WHERE synced_seq IS NULL AND entity != ?", arguments: [LedgerEntity.codexAccount.rawValue]) ?? 0
            let files = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_files WHERE dirty = 1") ?? 0
            let tombstones = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_tombstones") ?? 0
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_pending") ?? 0
            return SyncCounts(unsent: events + files + tombstones, pending: pending)
        }
    }

    /// Everything here goes up again: after this device recreated the zone, or the keychain was reset.
    func prepareFullUpload() throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE ledger_events SET synced_seq = NULL")
            try db.execute(sql: "DELETE FROM sync_tombstones")
            try db.execute(sql: "DELETE FROM sync_files WHERE deleted = 1")
            try db.execute(sql: "UPDATE sync_files SET dirty = 1, system_fields = NULL")
        }
    }

    // MARK: - Incoming events

    /// Take in events from another device. Deletions of units run the same erasure as `deleteUnit` here.
    @discardableResult
    func ingest(_ records: [SyncEventRecord], build: String) throws -> IngestResult {
        try ensureDeletionReady()
        var result = IngestResult()
        for fact in records where fact.kind == "unit.deleted" {
            if try ingestUnitDeletion(fact, build: build) { result.deletedUnits += 1 }
        }
        let others = records.filter { $0.kind != "unit.deleted" }.sorted { $0.order < $1.order }
        guard !others.isEmpty else { return result }
        let (applied, counts) = try queue.write { db -> ([LedgerEvent], IngestResult) in
            let removed = try Self.removedIDs(db)
            var applied: [LedgerEvent] = []
            var counts = IngestResult()
            for record in others {
                switch try Self.ingest(record, removed: removed, build: build, into: db) {
                case .applied(let event): applied.append(event); counts.applied += 1
                case .stored: counts.stored += 1
                case .pending: counts.pending += 1
                case .dropped: counts.dropped += 1
                case .duplicate: break
                }
            }
            return (applied, counts)
        }
        result.applied = counts.applied
        result.stored = counts.stored
        result.pending = counts.pending
        result.dropped = counts.dropped
        if !applied.isEmpty { notify(applied, remote: true) }
        return result
    }

    nonisolated static func ingest(_ record: SyncEventRecord, removed: Set<String>, build: String, into db: Database) throws -> IngestOutcome {
        if try isKnown(record.recordName, db) { return .duplicate }
        if record.entity == LedgerEntity.codexAccount.rawValue { return .dropped }
        guard let entity = LedgerEntity(rawValue: record.entity) else {
            try park(record, reason: "unknown entity \(record.entity)", build: build, db)
            return .pending
        }
        guard let payload = LedgerJSON.parse(record.payload) else {
            try park(record, reason: "unreadable payload", build: build, db)
            return .pending
        }
        let event = LedgerEvent(kind: record.kind, entity: entity, entityID: record.entityID, payload: payload)
        // Same rule as `append`: nothing about a deleted unit comes back, even when it arrives late.
        if !event.isDeletion && (removed.contains(event.entityID) || !UnitDeletion.references(payload).isDisjoint(with: removed)) {
            try db.execute(sql: "INSERT OR IGNORE INTO sync_tombstones (record_name) VALUES (?)", arguments: [record.recordName])
            return .dropped
        }
        let latest = try Row.fetchOne(db, sql: """
            SELECT created_at, origin_device_id, origin_seq FROM ledger_events WHERE entity = ? AND entity_id = ?
            ORDER BY created_at DESC, origin_device_id DESC, origin_seq DESC LIMIT 1
            """, arguments: [record.entity, record.entityID])
        let wins = latest.map { row in
            record.order > ((row["created_at"] as String?) ?? "", (row["origin_device_id"] as String?) ?? "", (row["origin_seq"] as Int64?) ?? 0)
        } ?? true
        do {
            // An older event is still decoded once, so `rebuild()` can replay it later.
            try db.inSavepoint {
                try event.apply(to: db)
                return wins ? .commit : .rollback
            }
        } catch {
            try park(record, reason: "decode \(entity.rawValue): \(error)", build: build, db)
            return .pending
        }
        let stored = StoredLedgerEvent(remote: record)
        try stored.insert(db)
        return wins ? .applied(event) : .stored
    }

    nonisolated static func isKnown(_ recordName: String, _ db: Database) throws -> Bool {
        guard let (device, seq) = SyncNames.eventOrigin(recordName) else { return false }
        if try Bool.fetchOne(db, sql: "SELECT 1 FROM ledger_events WHERE origin_device_id = ? AND origin_seq = ?", arguments: [device, seq]) == true { return true }
        return try Bool.fetchOne(db, sql: "SELECT 1 FROM sync_pending WHERE record_name = ?", arguments: [recordName]) == true
    }

    nonisolated static func park(_ record: SyncEventRecord, reason: String, build: String, _ db: Database) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO sync_pending
            (record_name, origin_device_id, origin_seq, kind, entity, entity_id, payload, created_at, record, reason, app_build, received_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
            """, arguments: [record.recordName, record.originDeviceID, record.originSeq, record.kind, record.entity, record.entityID,
                             record.payload, record.createdAt, reason, build, LedgerClock.now()])
        syncLog.notice("kept sync event \(record.recordName, privacy: .public): \(reason, privacy: .public)")
    }

    /// Records the transport could not read at all (decryption, missing fields).
    func parkUnreadable(_ records: [UnreadableRecord], build: String) throws {
        guard !records.isEmpty else { return }
        try queue.write { db in
            for record in records {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO sync_pending (record_name, record, reason, app_build, received_at) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [record.recordName, record.archived, record.reason, build, LedgerClock.now()])
                syncLog.notice("kept unreadable record \(record.recordName, privacy: .public): \(record.reason, privacy: .public)")
            }
        }
    }

    /// Apply kept events again once the app version changed. Those still unreadable stay kept.
    @discardableResult
    func retryPendingSync(build: String, decodeArchived: @Sendable (Data) -> SyncRecord?) throws -> IngestResult {
        let rows = try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM sync_pending WHERE app_build != ?", arguments: [build]) }
        guard !rows.isEmpty else { return IngestResult() }
        var events: [SyncEventRecord] = []
        var files: [SyncFileRecord] = []
        var retried: [String] = []
        for row in rows {
            let name: String = row["record_name"]
            if let data = row["record"] as Data? {
                switch decodeArchived(data) {
                case .event(let event)?: events.append(event); retried.append(name)
                case .file(let file)?: files.append(file); retried.append(name)
                case nil: continue
                }
            } else if let device = row["origin_device_id"] as String?, let seq = row["origin_seq"] as Int64? {
                events.append(SyncEventRecord(originDeviceID: device, originSeq: seq, kind: row["kind"] ?? "", entity: row["entity"] ?? "",
                                              entityID: row["entity_id"] ?? "", payload: row["payload"] ?? "", createdAt: row["created_at"] ?? ""))
                retried.append(name)
            }
        }
        try queue.write { db in
            for name in retried { try db.execute(sql: "DELETE FROM sync_pending WHERE record_name = ?", arguments: [name]) }
            // Still unreadable here: remember that this version tried.
            try db.execute(sql: "UPDATE sync_pending SET app_build = ? WHERE app_build != ?", arguments: [build, build])
        }
        if !files.isEmpty { try ingestFiles(files, deletions: []) }
        return try ingest(events, build: build)
    }

    /// Records deleted in CloudKit by another device (the history a unit deletion erased there).
    func ingestDeletions(_ names: [String]) throws {
        let events = names.compactMap(SyncNames.eventOrigin)
        guard !events.isEmpty else { return }
        try queue.write { db in
            try db.execute(sql: "PRAGMA secure_delete=ON")
            for (device, seq) in events {
                try db.execute(sql: "DELETE FROM ledger_events WHERE origin_device_id = ? AND origin_seq = ?", arguments: [device, seq])
                try db.execute(sql: "DELETE FROM sync_pending WHERE record_name = ?", arguments: [SyncNames.event(device, seq)])
                try db.execute(sql: "DELETE FROM sync_tombstones WHERE record_name = ?", arguments: [SyncNames.event(device, seq)])
            }
        }
    }

    /// A unit deleted on another device: erase its range of events and files here as `deleteUnit` does,
    /// then keep the other device's fact. Returns false when the fact was already here or kept unreadable.
    private func ingestUnitDeletion(_ record: SyncEventRecord, build: String) throws -> Bool {
        UnitDeletion.gate.lock(); defer { UnitDeletion.gate.unlock() }
        if try queue.read({ db in try Self.isKnown(record.recordName, db) }) { return false }
        guard let entity = LedgerEntity(rawValue: record.entity), let payload = LedgerJSON.parse(record.payload),
              let remoteFact = try? LedgerEvent.decode(UnitDeletion.Fact.self, from: payload) else {
            try queue.write { db in try Self.park(record, reason: "unreadable unit deletion", build: build, db) }
            return false
        }
        let factEvent = LedgerEvent(kind: record.kind, entity: entity, entityID: record.entityID, payload: payload)
        let root = deletionRoot
        let runtimeRoots = deletionRuntimeRoots
        var journal: UnitDeletion.Journal
        if let local = try? queue.read({ db in
            try UnitDeletion.prepare(db: db, root: root, unitID: remoteFact.unitID, extraCodexIDs: remoteFact.scope.codexIDs, runtimeRoots: runtimeRoots)
        }) {
            // What this device knows about the unit (rows, files, memory, rollouts) is erased too; the other
            // device's fact replaces the one prepared here.
            journal = local
            journal.events.removeAll { $0.kind == "unit.deleted" }
            var fact = remoteFact
            for (key, ids) in local.fact.scope.ids { fact.scope.ids[key, default: []].formUnion(ids) }
            fact.scope.codexIDs.formUnion(local.fact.scope.codexIDs)
            journal.fact = fact
        } else {
            journal = UnitDeletion.Journal(fact: remoteFact, events: [], changes: [], files: [])
        }
        let prepared = journal
        try JSONEncoder().encode(prepared).write(to: UnitDeletion.journalURL(root), options: .atomic)
        do {
            for change in prepared.changes { try UnitDeletion.write(change) }
            let deviceID = deviceID
            try queue.write { db in
                try db.execute(sql: "PRAGMA secure_delete=ON")
                try Self.eraseHistory(of: prepared, from: db)
                try Self.append(prepared.events, deviceID: deviceID, to: db)
                let stored = StoredLedgerEvent(remote: record)
                try stored.insert(db)
                try factEvent.apply(to: db)
            }
            try UnitDeletion.recover(queue: queue, root: root, runtimeRoots: runtimeRoots)
        } catch {
            if (try? UnitDeletion.committed(prepared, queue: queue)) == false {
                do { try UnitDeletion.recover(queue: queue, root: root, runtimeRoots: runtimeRoots) }
                catch { deletionFailure = String(describing: error) }
            } else { deletionFailure = String(describing: error) }
            throw error
        }
        deletionFailure = nil
        syncLog.info("erased unit deleted on another device")
        if !prepared.events.isEmpty { notify(prepared.events) }
        notify([factEvent], remote: true)
        return true
    }

    // MARK: - Files

    /// Compare `captures/`・`attachments/`・`memory/` with what was last sent and return the changes.
    func scanSyncFiles() throws -> FileOutbox {
        try ensureDeletionReady()
        UnitDeletion.gate.lock(); defer { UnitDeletion.gate.unlock() }
        let root = deletionRoot.standardizedFileURL
        return try queue.write { db in
            var known: [String: Row] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM sync_files") { known[row["path"]] = row }
            var seen = Set<String>()
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            for name in SyncNames.fileRoots {
                let base = root.appendingPathComponent(name, isDirectory: true)
                guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in enumerator {
                    let values = try url.resourceValues(forKeys: Set(keys))
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    let path = name + "/" + url.standardizedFileURL.path.dropFirst(base.path.count + 1)
                    guard SyncNames.isSyncedPath(path) else { continue }
                    seen.insert(path)
                    let size = Int64(values.fileSize ?? 0)
                    let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                    let row = known[path]
                    if let row, row["deleted"] == false, row["size"] == size, row["mtime"] == mtime { continue }
                    let sha = SyncNames.sha256(try Data(contentsOf: url))
                    if let row, row["deleted"] == false, row["sha256"] == sha {
                        try db.execute(sql: "UPDATE sync_files SET size = ?, mtime = ? WHERE path = ?", arguments: [size, mtime, path])
                        continue
                    }
                    try db.execute(sql: """
                        INSERT INTO sync_files (path, record_name, sha256, size, mtime, modified_at, dirty, deleted)
                        VALUES (?, ?, ?, ?, ?, ?, 1, 0)
                        ON CONFLICT(path) DO UPDATE SET sha256 = excluded.sha256, size = excluded.size, mtime = excluded.mtime,
                            modified_at = excluded.modified_at, dirty = 1, deleted = 0
                        """, arguments: [path, SyncNames.file(path), sha, size, mtime, LedgerClock.iso(Date(timeIntervalSince1970: mtime))])
                }
            }
            for (path, row) in known where !seen.contains(path) && row["deleted"] == false {
                try db.execute(sql: "UPDATE sync_files SET deleted = 1, dirty = 1 WHERE path = ?", arguments: [path])
            }
            var outbox = FileOutbox()
            for row in try Row.fetchAll(db, sql: "SELECT * FROM sync_files WHERE dirty = 1 ORDER BY path") {
                if row["deleted"] == true {
                    outbox.deletions.append(row["record_name"])
                } else {
                    let path: String = row["path"]
                    outbox.saves.append(SyncFileRecord(path: path, sha256: row["sha256"], modifiedAt: row["modified_at"],
                                                       fileURL: root.appendingPathComponent(path), systemFields: row["system_fields"]))
                }
            }
            return outbox
        }
    }

    func markFilesSent(saved: [String: Data?], deleted: Set<String>) throws {
        try queue.write { db in
            for (name, fields) in saved {
                try db.execute(sql: "UPDATE sync_files SET dirty = 0, system_fields = ? WHERE record_name = ? AND deleted = 0", arguments: [fields, name])
            }
            for name in deleted {
                try db.execute(sql: "DELETE FROM sync_files WHERE record_name = ? AND deleted = 1", arguments: [name])
            }
        }
    }

    /// Files from another device. Per file, the later `modifiedAt` wins (`memory/` is edited on both).
    @discardableResult
    func ingestFiles(_ files: [SyncFileRecord], deletions: [String]) throws -> Int {
        guard !files.isEmpty || !deletions.isEmpty else { return 0 }
        try ensureDeletionReady()
        UnitDeletion.gate.lock(); defer { UnitDeletion.gate.unlock() }
        let root = deletionRoot.standardizedFileURL
        return try queue.write { db -> Int in
            var changed = 0
            for file in files {
                guard SyncNames.isSyncedPath(file.path) else {
                    syncLog.error("ignored sync file outside the synced roots")
                    continue
                }
                let target = root.appendingPathComponent(file.path)
                let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_files WHERE path = ?", arguments: [file.path])
                var local: (modifiedAt: String, sha: String)?
                if let row, row["deleted"] == false {
                    local = (row["modified_at"], row["sha256"])
                } else if row == nil, FileManager.default.fileExists(atPath: target.path) {
                    let modified = (try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(timeIntervalSince1970: 0)
                    local = (LedgerClock.iso(modified), SyncNames.sha256(try Data(contentsOf: target)))
                }
                if let local, local.sha == file.sha256 || (local.modifiedAt, local.sha) > (file.modifiedAt, file.sha256) {
                    // Same contents, or this device's version is newer: keep it, and send it over theirs if newer.
                    let newer = local.sha != file.sha256
                    if row != nil {
                        try db.execute(sql: "UPDATE sync_files SET system_fields = ?, dirty = ? WHERE path = ?", arguments: [file.systemFields, newer, file.path])
                    }
                    continue
                }
                let data = try Data(contentsOf: file.fileURL)
                guard SyncNames.sha256(data) == file.sha256 else {
                    syncLog.error("sync file content does not match its checksum")
                    continue
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                let values = try target.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                try db.execute(sql: """
                    INSERT INTO sync_files (path, record_name, sha256, size, mtime, modified_at, dirty, deleted, system_fields)
                    VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?)
                    ON CONFLICT(path) DO UPDATE SET sha256 = excluded.sha256, size = excluded.size, mtime = excluded.mtime,
                        modified_at = excluded.modified_at, dirty = 0, deleted = 0, system_fields = excluded.system_fields
                    """, arguments: [file.path, file.recordName, file.sha256, Int64(values.fileSize ?? data.count),
                                     values.contentModificationDate?.timeIntervalSince1970 ?? 0, file.modifiedAt, file.systemFields])
                changed += 1
            }
            for name in deletions {
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_files WHERE record_name = ?", arguments: [name]) else { continue }
                let path: String = row["path"]
                // Changed here since it was last sent: this version goes up again instead.
                if row["dirty"] == true && row["deleted"] == false {
                    try db.execute(sql: "UPDATE sync_files SET system_fields = NULL WHERE path = ?", arguments: [path])
                    continue
                }
                let target = root.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try db.execute(sql: "DELETE FROM sync_files WHERE path = ?", arguments: [path])
                changed += 1
            }
            return changed
        }
    }

    // MARK: - Replacement

    /// Another device uploaded its ledger again: keep one ZIP of this ledger in `backups/`, then empty the
    /// ledger and the synced files so the zone's contents replace them.
    @discardableResult
    func replaceWithCloud() throws -> URL {
        try ensureDeletionReady()
        UnitDeletion.gate.lock(); defer { UnitDeletion.gate.unlock() }
        let root = deletionRoot
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.removeItem(at: backups)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let stored = try queue.read { db in try StoredLedgerEvent.order(Column("seq")).fetchAll(db) }
        let backup = try LedgerArchive.exportSnapshot(stored: stored, deviceID: deviceID, root: root, directory: backups)
        try queue.write { db in
            try db.execute(sql: "PRAGMA secure_delete=ON")
            try db.execute(sql: "DELETE FROM ledger_events")
            try db.execute(sql: "DELETE FROM sync_pending")
            try db.execute(sql: "DELETE FROM sync_files")
            try db.execute(sql: "DELETE FROM sync_tombstones")
            try LedgerSchema.dropProjections(db)
            try LedgerSchema.createProjections(db)
        }
        for name in SyncNames.fileRoots {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
        syncLog.notice("replaced the ledger with the iCloud contents; backup kept")
        notify(Self.replacedNotice, remote: true)
        return backup
    }
}
