import CryptoKit
import Foundation

/// iCloud 同期 (Issue #51) の送受信の境目。アプリでは CloudKit (`CloudKitSyncTransport`)、
/// 単体テストでは2つのインメモリ台帳をつなぐ偽の transport がこの protocol を実装する。
/// 記録の形は `docs/communication-and-storage.md` の「iCloud 同期」が正。
nonisolated protocol SyncTransport: Sendable {
    /// Changes in the zone `Ledger` since the previous fetch.
    func fetchChanges() async throws -> SyncFetch
    /// Save and delete records. A record missing from both `saved` and `failures` was not attempted.
    func send(_ batch: SyncBatch) async throws -> SyncSendResult
    /// Delete the zone `Ledger` and create it again, empty.
    func resetZone() async throws
    /// Read a record kept by `UnreadableRecord.archived` again (after the app was updated).
    func decodeArchived(_ data: Data) -> SyncRecord?
}

nonisolated extension SyncTransport {
    func decodeArchived(_ data: Data) -> SyncRecord? { nil }
}

/// One `LedgerEvent` record: a `ledger_events` row with the device and sequence it was written with.
nonisolated struct SyncEventRecord: Sendable, Hashable {
    var originDeviceID: String
    var originSeq: Int64
    var kind: String
    var entity: String
    var entityID: String
    /// `LedgerJSON.canonicalText` of the payload.
    var payload: String
    var createdAt: String

    var recordName: String { SyncNames.event(originDeviceID, originSeq) }

    init(originDeviceID: String, originSeq: Int64, kind: String, entity: String, entityID: String, payload: String, createdAt: String) {
        self.originDeviceID = originDeviceID
        self.originSeq = originSeq
        self.kind = kind
        self.entity = entity
        self.entityID = entityID
        self.payload = payload
        self.createdAt = createdAt
    }

    init?(_ stored: StoredLedgerEvent) {
        guard let device = stored.originDeviceId, let seq = stored.originSeq else { return nil }
        self.init(originDeviceID: device, originSeq: seq, kind: stored.kind, entity: stored.entity, entityID: stored.entityId,
                  payload: stored.payload, createdAt: stored.createdAt)
    }

    /// Ordering for last-writer-wins: `created_at`, then the larger device ID, then the sequence there.
    var order: (String, String, Int64) { (createdAt, originDeviceID, originSeq) }
}

/// One `LedgerFile` record: a file under `captures/`, `attachments/` or `memory/`.
nonisolated struct SyncFileRecord: Sendable, Hashable {
    /// Relative to `Application Support/Struis/`, e.g. `captures/cap-1.jpg`.
    var path: String
    var sha256: String
    var modifiedAt: String
    /// Local file holding the contents (the source file when sending, a downloaded asset when fetched).
    var fileURL: URL
    /// CloudKit system fields (change tag) of the record this device last saw, archived.
    var systemFields: Data?

    var recordName: String { SyncNames.file(path) }
}

nonisolated enum SyncRecord: Sendable, Hashable {
    case event(SyncEventRecord)
    case file(SyncFileRecord)

    var recordName: String {
        switch self {
        case .event(let event): event.recordName
        case .file(let file): file.recordName
        }
    }
}

/// A record that arrived but could not be read (decryption, a missing field). Kept, not dropped.
nonisolated struct UnreadableRecord: Sendable, Hashable {
    var recordName: String
    var reason: String
    /// The record itself, archived, so a later version of the app can read it again.
    var archived: Data?
}

nonisolated enum ZoneDeletion: String, Sendable, Hashable {
    /// Another device deleted the zone to upload its ledger again.
    case deleted
    /// The learner deleted the app's data in iCloud settings.
    case purged
    /// The learner reset the iCloud keychain; encrypted fields can no longer be read.
    case encryptedDataReset
}

nonisolated struct SyncFetch: Sendable {
    var zoneDeletion: ZoneDeletion?
    var records: [SyncRecord] = []
    var deletions: [String] = []
    var unreadable: [UnreadableRecord] = []
}

nonisolated struct SyncBatch: Sendable {
    var records: [SyncRecord] = []
    var deletions: [String] = []
    var isEmpty: Bool { records.isEmpty && deletions.isEmpty }
}

nonisolated enum SyncSendFailure: Sendable, Hashable {
    /// Try again on the next sync (network, throttling).
    case retry(String)
    /// A newer version of a `LedgerFile` record is in the zone.
    case conflict(SyncFileRecord)
}

nonisolated struct SyncSendResult: Sendable {
    /// Saved record names, with the new system fields of `LedgerFile` records.
    var saved: [String: Data?] = [:]
    var deleted: Set<String> = []
    var failures: [String: SyncSendFailure] = [:]
    /// The zone is gone because the learner reset the iCloud keychain (`zoneNotFound` with
    /// `CKErrorUserDidResetEncryptedDataKey`).
    var encryptedDataReset = false
}

nonisolated enum SyncNames {
    static let zone = "Ledger"
    static let eventType = "LedgerEvent"
    static let fileType = "LedgerFile"
    /// `memory/` などのうち同期するもの。`LedgerArchive.fileRoots` から `diagnostics` を除く。
    static let fileRoots = LedgerArchive.fileRoots.filter { $0 != "diagnostics" }
    /// `payload` larger than this goes to the `payloadAsset` asset.
    static let inlinePayloadLimit = 900 * 1024

    static func event(_ device: String, _ seq: Int64) -> String { "\(device).\(seq)" }

    /// `LedgerFile` record name: SHA-256 (hex) of the relative path.
    static func file(_ path: String) -> String { sha256(Data(path.utf8)) }

    /// `(device, seq)` of a `LedgerEvent` record name, or nil for a `LedgerFile` record name.
    static func eventOrigin(_ name: String) -> (String, Int64)? {
        guard let dot = name.lastIndex(of: "."), let seq = Int64(name[name.index(after: dot)...]) else { return nil }
        return (String(name[..<dot]), seq)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A relative path the sync may write: under a synced root, no `.`/`..`/empty components.
    static func isSyncedPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, fileRoots.contains(parts[0]) else { return false }
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}
