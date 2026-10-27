import Foundation
import OSLog

nonisolated private let engineLog = Logger(subsystem: "com.digiloglab.strius", category: "sync")

/// One device's sync between its ledger and the zone `Ledger` (Issue #51). The transport is CloudKit in
/// the app and an in-memory cloud in the tests; everything about what to send and how to take changes in
/// lives here and in `Ledger`'s sync extension.
actor LedgerSyncEngine {
    nonisolated struct Outcome: Sendable, Equatable {
        var sent = 0
        var received = 0
        /// The ZIP of this ledger kept before it was replaced with the zone's contents.
        var backup: URL?
        /// The learner deleted the data from iCloud settings: stop syncing, keep this device's ledger.
        var deletedByLearner = false
        /// The zone was recreated here and this ledger uploaded again (keychain reset).
        var uploadedAgain = false
    }

    nonisolated let ledger: Ledger
    nonisolated let transport: any SyncTransport
    /// The app build; events kept as unreadable are retried when it changes.
    nonisolated let build: String
    private let eventBatch: Int
    private let fileBatch: Int

    init(ledger: Ledger, transport: any SyncTransport, build: String, eventBatch: Int = 300, fileBatch: Int = 20) {
        self.ledger = ledger
        self.transport = transport
        self.build = build
        self.eventBatch = eventBatch
        self.fileBatch = fileBatch
    }

    /// Take changes in, send this device's changes, and take in again when something was sent.
    @discardableResult
    func sync(fetchFirst: Bool = true) async throws -> Outcome {
        var outcome = Outcome()
        try await ledger.retryPendingSync(build: build) { [transport] in transport.decodeArchived($0) }
        if fetchFirst {
            try await fetch(into: &outcome)
            if outcome.deletedByLearner { return outcome }
        }
        outcome.sent = try await send(outcome: &outcome)
        if outcome.sent > 0 || !fetchFirst { try await fetch(into: &outcome) }
        return outcome
    }

    /// 「iCloud のデータを消して、この端末の内容で上げ直す」: recreate the zone and send everything here.
    @discardableResult
    func uploadAgain() async throws -> Outcome {
        try await transport.resetZone()
        try await ledger.prepareFullUpload()
        var outcome = Outcome(uploadedAgain: true)
        outcome.sent = try await send(outcome: &outcome)
        return outcome
    }

    // MARK: - Fetch

    private func fetch(into outcome: inout Outcome) async throws {
        let changes = try await transport.fetchChanges()
        switch changes.zoneDeletion {
        case .purged?:
            engineLog.notice("the iCloud data was deleted by the learner; sync stops")
            outcome.deletedByLearner = true
            return
        case .deleted?:
            // Another device uploaded its ledger again. Replace without asking, keeping a ZIP of this one.
            outcome.backup = try await ledger.replaceWithCloud()
        case .encryptedDataReset?:
            engineLog.notice("the iCloud keychain was reset; uploading this ledger again")
            try await transport.resetZone()
            try await ledger.prepareFullUpload()
            outcome.uploadedAgain = true
        case nil:
            break
        }
        var events: [SyncEventRecord] = []
        var files: [SyncFileRecord] = []
        for record in changes.records {
            switch record {
            case .event(let event): events.append(event)
            case .file(let file): files.append(file)
            }
        }
        try await ledger.ingestDeletions(changes.deletions)
        let result = try await ledger.ingest(events, build: build)
        let changedFiles = try await ledger.ingestFiles(files, deletions: changes.deletions.filter { SyncNames.eventOrigin($0) == nil })
        try await ledger.parkUnreadable(changes.unreadable, build: build)
        outcome.received += result.applied + result.stored + result.deletedUnits + changedFiles
    }

    // MARK: - Send

    private func send(outcome: inout Outcome) async throws -> Int {
        var sent = 0
        var resets = 0
        // Events and deleted records first, in batches, until nothing is left or a batch makes no progress.
        while true {
            let outbox = try await ledger.syncOutbox(limit: eventBatch)
            let batch = SyncBatch(records: outbox.events.map(SyncRecord.event), deletions: outbox.tombstones)
            if batch.isEmpty { break }
            let result = try await transport.send(batch)
            if result.encryptedDataReset {
                guard resets == 0 else { throw SyncEngineError.zoneUnavailable }
                resets += 1
                try await transport.resetZone()
                try await ledger.prepareFullUpload()
                outcome.uploadedAgain = true
                continue
            }
            try await ledger.markSyncSent(saved: Array(result.saved.keys), deleted: Array(result.deleted))
            sent += result.saved.count + result.deleted.count
            if !result.failures.isEmpty || result.saved.count + result.deleted.count == 0 { return sent }
        }
        let files = try ledger.scanSyncFiles()
        var saves = files.saves[...]
        var deletions = files.deletions
        while !saves.isEmpty || !deletions.isEmpty {
            let chunk = Array(saves.prefix(fileBatch))
            saves = saves.dropFirst(chunk.count)
            let result = try await transport.send(SyncBatch(records: chunk.map(SyncRecord.file), deletions: deletions))
            deletions = []
            if result.encryptedDataReset {
                // Everything goes up again on the next sync, after the zone is created again.
                try await transport.resetZone()
                try await ledger.prepareFullUpload()
                outcome.uploadedAgain = true
                return sent
            }
            try await ledger.markFilesSent(saved: result.saved, deleted: result.deleted)
            sent += result.saved.count + result.deleted.count
            var conflicts: [SyncFileRecord] = []
            for failure in result.failures.values {
                if case .conflict(let newer) = failure { conflicts.append(newer) }
            }
            if !conflicts.isEmpty { try await ledger.ingestFiles(conflicts, deletions: []) }
            if result.failures.values.contains(where: { if case .retry = $0 { true } else { false } }) { return sent }
        }
        return sent
    }
}

nonisolated enum SyncEngineError: Error, LocalizedError {
    case zoneUnavailable

    var errorDescription: String? {
        switch self {
        case .zoneUnavailable: "iCloud の保存先を作り直せませんでした"
        }
    }
}
