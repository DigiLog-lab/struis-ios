import CloudKit
import Foundation
import OSLog

nonisolated private let cloudLog = Logger(subsystem: "com.digiloglab.strius", category: "sync")

/// `SyncTransport` over the learner's private CloudKit database (Issue #51): one zone `Ledger`, driven by
/// `CKSyncEngine` with automatic sync off. The app decides when to sync (launch, foreground, after a write,
/// every few minutes in the foreground); push notifications are not used. Every field is in
/// `encryptedValues` and files are `CKAsset`s, so only the learner's devices can read the contents.
actor CloudKitSyncTransport: SyncTransport, CKSyncEngineDelegate {
    nonisolated static let containerIdentifier = "iCloud.com.digiloglab.strius"

    enum Account: Equatable, Sendable {
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
        case unknown
    }

    private let stateURL: URL
    private let temporary: URL
    private let zoneID = CKRecordZone.ID(zoneName: SyncNames.zone)
    private lazy var container = CKContainer(identifier: Self.containerIdentifier)
    private var engine: CKSyncEngine?
    private var staged: [CKRecord.ID: SyncRecord] = [:]
    private var fetched = SyncFetch()
    private var sent = SyncSendResult()
    private var state = SyncStateKeeper()

    /// - Parameters:
    ///   - stateURL: where the engine's state (change tokens) is kept between launches.
    ///   - temporary: scratch directory for assets on their way in and out.
    init(stateURL: URL, temporary: URL) {
        self.stateURL = stateURL
        self.temporary = temporary
    }

    func account() async -> Account {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            default: return .unknown
            }
        } catch {
            cloudLog.error("iCloud account status failed: \(String(describing: error), privacy: .public)")
            return .unknown
        }
    }

    private func syncEngine() -> CKSyncEngine {
        if let engine { return engine }
        let state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: state, delegate: self)
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration)
        // The ledger knows what is unsent; each send stages its own batch.
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        if state == nil { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
        self.engine = engine
        return engine
    }

    // MARK: - SyncTransport

    func fetchChanges() async throws -> SyncFetch {
        // Assets of the previous fetch were taken in, or will be fetched again.
        try? FileManager.default.removeItem(at: incoming)
        if state.begin(fetch: true) { reloadFromKeptState() }
        // What a failed fetch delivered is fetched again from the kept state.
        fetched = SyncFetch()
        do {
            try await syncEngine().fetchChanges()
        } catch {
            fetched = SyncFetch()
            throw error
        }
        let result = fetched
        fetched = SyncFetch()
        return result
    }

    func commitFetch() async throws {
        if let data = state.commit() { try keep(data) }
    }

    func send(_ batch: SyncBatch) async throws -> SyncSendResult {
        // A fetch that was not taken in must not be kept with the state the send moves on.
        if state.begin(fetch: false) { reloadFromKeptState() }
        let engine = syncEngine()
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        staged = [:]
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for record in batch.records {
            let id = CKRecord.ID(recordName: record.recordName, zoneID: zoneID)
            staged[id] = record
            changes.append(.saveRecord(id))
        }
        for name in batch.deletions {
            changes.append(.deleteRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
        }
        engine.state.add(pendingRecordZoneChanges: changes)
        sent = SyncSendResult()
        defer {
            staged = [:]
            try? FileManager.default.removeItem(at: outgoing)
        }
        try await engine.sendChanges()
        let result = sent
        sent = SyncSendResult()
        return result
    }

    func resetZone() async throws {
        if let engine { engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges) }
        let database = container.privateCloudDatabase
        do {
            _ = try await database.deleteRecordZone(withID: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {}
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        // A fresh engine state: this device must not take its own deletion for another device's.
        engine = nil
        state.reset()
        try? FileManager.default.removeItem(at: stateURL)
    }

    /// Drop the engine whose state moved past changes that are not in the ledger; the next use loads the kept state.
    private func reloadFromKeptState() {
        engine = nil
        cloudLog.notice("fetched changes were not taken in; fetching them again")
    }

    private func keep(_ data: Data) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: stateURL, options: .atomic)
    }

    nonisolated func decodeArchived(_ data: Data) -> SyncRecord? {
        guard let record = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data) else { return nil }
        return try? Self.decode(record, copyingAssetsTo: FileManager.default.temporaryDirectory).get()
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            // During a fetch the state is kept by `commitFetch()`, after the changes are in the ledger.
            do {
                if let data = state.update(try JSONEncoder().encode(update.stateSerialization)) { try keep(data) }
            } catch {
                cloudLog.error("sync state not saved: \(String(describing: error), privacy: .public)")
            }
        case .accountChange(let change):
            switch change.changeType {
            case .signIn: break
            default:
                // Another Apple ID (or none): its zone is not this one; start over with a fresh state.
                engine = nil
                state.reset()
                try? FileManager.default.removeItem(at: stateURL)
            }
        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == zoneID {
                switch deletion.reason {
                case .purged: fetched.zoneDeletion = .purged
                case .encryptedDataReset: fetched.zoneDeletion = .encryptedDataReset
                default: fetched.zoneDeletion = .deleted
                }
                // Anything fetched before belonged to the deleted zone.
                fetched.records = []
                fetched.deletions = []
                fetched.unreadable = []
            }
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications where modification.record.recordID.zoneID == zoneID {
                let record = modification.record
                switch Self.decode(record, copyingAssetsTo: incoming) {
                case .success(let decoded): fetched.records.append(decoded)
                case .failure(let failure):
                    let archived = try? NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
                    fetched.unreadable.append(UnreadableRecord(recordName: record.recordID.recordName, reason: failure.reason, archived: archived))
                }
            }
            for deletion in changes.deletions where deletion.recordID.zoneID == zoneID {
                fetched.deletions.append(deletion.recordID.recordName)
            }
        case .sentRecordZoneChanges(let changes):
            for record in changes.savedRecords {
                sent.saved[record.recordID.recordName] = record.recordType == SyncNames.fileType ? Self.systemFields(record) : nil
            }
            for failure in changes.failedRecordSaves {
                let record = failure.record
                let name = record.recordID.recordName
                switch failure.error.code {
                case .serverRecordChanged:
                    if record.recordType == SyncNames.eventType {
                        // Events never change; the one in the zone is this one.
                        sent.saved[name] = .some(nil)
                    } else if let server = failure.error.serverRecord, case .success(.file(let newer)) = Self.decode(server, copyingAssetsTo: incoming) {
                        sent.failures[name] = .conflict(newer)
                    } else {
                        sent.failures[name] = .retry("conflict")
                    }
                case .zoneNotFound, .userDeletedZone:
                    if (failure.error.userInfo[CKErrorUserDidResetEncryptedDataKey] as? NSNumber)?.boolValue == true {
                        sent.encryptedDataReset = true
                    } else {
                        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    }
                    sent.failures[name] = .retry("zone")
                default:
                    sent.failures[name] = .retry(String(describing: failure.error.code))
                }
            }
            for id in changes.deletedRecordIDs { sent.deleted.insert(id.recordName) }
            for (id, error) in changes.failedRecordDeletes {
                if error.code == .unknownItem || error.code == .zoneNotFound { sent.deleted.insert(id.recordName) }
                else { sent.failures[id.recordName] = .retry(String(describing: error.code)) }
            }
        case .sentDatabaseChanges(let changes):
            for failure in changes.failedZoneSaves {
                cloudLog.error("zone save failed: \(String(describing: failure.error.code), privacy: .public)")
            }
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        let staged = staged
        let outgoing = outgoing
        let zoneID = zoneID
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { id in
            guard let record = staged[id] else { return nil }
            return Self.makeRecord(record, zoneID: zoneID, scratch: outgoing)
        }
    }

    // MARK: - Records

    private var incoming: URL { temporary.appendingPathComponent("incoming", isDirectory: true) }
    private var outgoing: URL { temporary.appendingPathComponent("outgoing", isDirectory: true) }

    nonisolated struct DecodeFailure: Error {
        var reason: String
    }

    /// The CloudKit record for a ledger event or file. Contents only in `encryptedValues` and assets.
    nonisolated static func makeRecord(_ record: SyncRecord, zoneID: CKRecordZone.ID, scratch: URL) -> CKRecord? {
        let id = CKRecord.ID(recordName: record.recordName, zoneID: zoneID)
        switch record {
        case .event(let event):
            let ck = CKRecord(recordType: SyncNames.eventType, recordID: id)
            let values = ck.encryptedValues
            values["entity"] = event.entity
            values["entityID"] = event.entityID
            values["kind"] = event.kind
            values["createdAt"] = event.createdAt
            values["originDevice"] = event.originDeviceID
            values["originSeq"] = event.originSeq
            let payload = Data(event.payload.utf8)
            if payload.count > SyncNames.inlinePayloadLimit {
                let url = scratch.appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                    try payload.write(to: url, options: .atomic)
                } catch { return nil }
                values["payload"] = Data()
                ck["payloadAsset"] = CKAsset(fileURL: url)
            } else {
                values["payload"] = payload
            }
            return ck
        case .file(let file):
            guard FileManager.default.fileExists(atPath: file.fileURL.path) else { return nil }
            let ck = file.systemFields.flatMap(record(systemFields:)) ?? CKRecord(recordType: SyncNames.fileType, recordID: id)
            let values = ck.encryptedValues
            values["path"] = file.path
            values["sha256"] = file.sha256
            values["modifiedAt"] = file.modifiedAt
            ck["file"] = CKAsset(fileURL: file.fileURL)
            return ck
        }
    }

    nonisolated static func decode(_ record: CKRecord, copyingAssetsTo directory: URL) -> Result<SyncRecord, DecodeFailure> {
        let values = record.encryptedValues
        func asset(_ key: String) throws -> URL? {
            guard let source = (record[key] as? CKAsset)?.fileURL else { return nil }
            // The downloaded asset is only guaranteed to exist while the event is handled.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: copy)
            return copy
        }
        switch record.recordType {
        case SyncNames.eventType:
            guard let entity = values["entity"] as? String, let entityID = values["entityID"] as? String,
                  let kind = values["kind"] as? String, let createdAt = values["createdAt"] as? String,
                  let device = values["originDevice"] as? String, let seq = values["originSeq"] as? Int64,
                  var payload = values["payload"] as? Data else {
                return .failure(DecodeFailure(reason: "missing event fields"))
            }
            guard SyncNames.event(device, seq) == record.recordID.recordName else { return .failure(DecodeFailure(reason: "record name mismatch")) }
            if payload.isEmpty {
                do {
                    if let url = try asset("payloadAsset") { payload = try Data(contentsOf: url) }
                } catch { return .failure(DecodeFailure(reason: "payload asset unreadable")) }
            }
            guard let text = String(data: payload, encoding: .utf8) else { return .failure(DecodeFailure(reason: "payload is not UTF-8")) }
            return .success(.event(SyncEventRecord(originDeviceID: device, originSeq: seq, kind: kind, entity: entity, entityID: entityID, payload: text, createdAt: createdAt)))
        case SyncNames.fileType:
            guard let path = values["path"] as? String, let sha = values["sha256"] as? String, let modifiedAt = values["modifiedAt"] as? String else {
                return .failure(DecodeFailure(reason: "missing file fields"))
            }
            guard SyncNames.file(path) == record.recordID.recordName else { return .failure(DecodeFailure(reason: "record name mismatch")) }
            let url: URL
            do {
                guard let copied = try asset("file") else { return .failure(DecodeFailure(reason: "file asset missing")) }
                url = copied
            } catch { return .failure(DecodeFailure(reason: "file asset unreadable")) }
            return .success(.file(SyncFileRecord(path: path, sha256: sha, modifiedAt: modifiedAt, fileURL: url, systemFields: systemFields(record))))
        default:
            return .failure(DecodeFailure(reason: "unknown record type \(record.recordType)"))
        }
    }

    nonisolated static func systemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    nonisolated static func record(systemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
