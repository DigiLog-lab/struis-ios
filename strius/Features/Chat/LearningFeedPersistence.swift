import Foundation
import Network
import OSLog
import SQLite3

private let learningFeedPersistenceLog = Logger(
    subsystem: "com.digiloglab.strius",
    category: "learning-feed-persistence"
)

nonisolated(unsafe) private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum LearningFeedPersistenceError: Error, LocalizedError {
    case unavailable(String)
    case sqlite(String)
    case encoding(Error)
    case decoding(Error)
    case eventIdentityConflict

    var errorDescription: String? {
        switch self {
        case .unavailable: "端末内の学習データを開けませんでした"
        case .sqlite: "端末内の学習データを保存できませんでした"
        case .encoding, .decoding: "端末内の学習データを読み書きできませんでした"
        case .eventIdentityConflict: "学習履歴の識別子が重複しました"
        }
    }
}

enum LearningFeedQueuedEventState: String, Codable, Sendable {
    case pending
    case retry
    case acknowledged
    case rejected
}

struct LearningFeedQueuedEvent: Sendable {
    let userID: String
    let sessionID: UUID
    let event: LearningFeedV2Event
    let state: LearningFeedQueuedEventState
    let attemptCount: Int
    let nextRetryAt: Date?
}

@MainActor
protocol LearningFeedSignOutClearing: AnyObject {
    func clearLearningFeedDataForSignOut() async
}

actor LearningFeedLocalPersistence {
    private var database: OpaquePointer?
    private var initializationError: LearningFeedPersistenceError?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    static var defaultDatabaseURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("Struis", isDirectory: true)
            .appendingPathComponent("learning-feed-v2.sqlite3", isDirectory: false)
    }

    init(databaseURL: URL = LearningFeedLocalPersistence.defaultDatabaseURL) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = LearningFeedCoding.dateDecodingStrategy
        self.decoder = decoder

        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var handle: OpaquePointer?
            let result = sqlite3_open_v2(
                databaseURL.path,
                &handle,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard result == SQLITE_OK, let handle else {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                if let handle { sqlite3_close(handle) }
                throw LearningFeedPersistenceError.unavailable(message)
            }
            database = handle
            try Self.execute(handle, sql: "PRAGMA journal_mode=WAL")
            try Self.execute(handle, sql: "PRAGMA foreign_keys=ON")
            try Self.execute(handle, sql: "PRAGMA busy_timeout=2500")
            try Self.migrate(handle)
        } catch let error as LearningFeedPersistenceError {
            initializationError = error
        } catch {
            initializationError = .unavailable(error.localizedDescription)
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func cacheReservation(userID: String, response: LearningFeedV2PrefetchResponse, rawData: Data) throws {
        let database = try requireDatabase()
        let sql = """
        INSERT INTO learning_feed_pack_cache (
          user_id, pack_id, content_hash, expires_at, payload, cached_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(user_id, pack_id) DO UPDATE SET
          content_hash = excluded.content_hash,
          expires_at = excluded.expires_at,
          payload = excluded.payload,
          cached_at = excluded.cached_at
        """
        let statement = try prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        bind(userID, to: statement, at: 1)
        bind(response.pack.manifest.packID.uuidString, to: statement, at: 2)
        bind(response.pack.manifest.contentHash, to: statement, at: 3)
        sqlite3_bind_double(statement, 4, response.expiresAt.timeIntervalSince1970)
        _ = rawData.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 5, bytes.baseAddress, Int32(rawData.count), sqliteTransient)
        }
        sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
        try stepDone(statement, database: database)
    }

    func latestCachedReservationData(userID: String, now: Date = Date()) throws -> Data? {
        try cachedReservationData(userID: userID, now: now).first
    }

    func cachedReservationData(userID: String, now: Date = Date()) throws -> [Data] {
        let database = try requireDatabase()
        let statement = try prepare(
            database,
            sql: """
            SELECT payload FROM learning_feed_pack_cache
            WHERE user_id = ? AND expires_at > ?
            ORDER BY cached_at DESC
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(userID, to: statement, at: 1)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        var result: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            result.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        }
        return result
    }

    func latestCachedUserID(now: Date = Date()) throws -> String? {
        let database = try requireDatabase()
        let statement = try prepare(
            database,
            sql: """
            SELECT user_id FROM learning_feed_pack_cache
            WHERE expires_at > ?
            ORDER BY cached_at DESC LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return stringColumn(statement, at: 0)
    }

    func enqueue(userID: String, sessionID: UUID, events: [LearningFeedV2Event]) throws {
        guard !events.isEmpty else { return }
        let database = try requireDatabase()
        try Self.execute(database, sql: "BEGIN IMMEDIATE")
        do {
            try insertEvents(database: database, userID: userID, sessionID: sessionID, events: events)
            try Self.execute(database, sql: "COMMIT")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    func enqueueAndSaveSnapshot(
        userID: String,
        sessionID: UUID,
        events: [LearningFeedV2Event],
        snapshot: LearningFeedSessionSnapshot
    ) throws {
        let database = try requireDatabase()
        try Self.execute(database, sql: "BEGIN IMMEDIATE")
        do {
            try insertEvents(database: database, userID: userID, sessionID: sessionID, events: events)
            try upsertSnapshot(database: database, snapshot: snapshot)
            try Self.execute(database, sql: "COMMIT")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    func pendingEvents(
        userID: String,
        sessionID: UUID,
        now: Date = Date(),
        limit: Int = 100
    ) throws -> [LearningFeedQueuedEvent] {
        let database = try requireDatabase()
        let statement = try prepare(
            database,
            sql: """
            SELECT payload, sync_state, attempt_count, next_retry_at
            FROM learning_feed_event_queue
            WHERE user_id = ? AND session_id = ?
              AND sync_state IN ('pending', 'retry')
              AND (next_retry_at IS NULL OR next_retry_at <= ?)
            ORDER BY sequence_no ASC LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(userID, to: statement, at: 1)
        bind(sessionID.uuidString, to: statement, at: 2)
        sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
        sqlite3_bind_int(statement, 4, Int32(max(1, min(limit, 100))))
        var result: [LearningFeedQueuedEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            let event: LearningFeedV2Event
            do {
                event = try decoder.decode(LearningFeedV2Event.self, from: data)
            } catch {
                throw LearningFeedPersistenceError.decoding(error)
            }
            let state = stringColumn(statement, at: 1).flatMap(LearningFeedQueuedEventState.init(rawValue:)) ?? .retry
            let retryValue = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3)
            result.append(LearningFeedQueuedEvent(
                userID: userID,
                sessionID: sessionID,
                event: event,
                state: state,
                attemptCount: Int(sqlite3_column_int(statement, 2)),
                nextRetryAt: retryValue.map(Date.init(timeIntervalSince1970:))
            ))
        }
        return result
    }

    func pendingSessionIDs(userID: String) throws -> [UUID] {
        let database = try requireDatabase()
        let statement = try prepare(
            database,
            sql: """
            SELECT DISTINCT session_id FROM learning_feed_event_queue
            WHERE user_id = ? AND sync_state IN ('pending', 'retry')
            ORDER BY session_id
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(userID, to: statement, at: 1)
        var result: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = stringColumn(statement, at: 0), let id = UUID(uuidString: raw) {
                result.append(id)
            }
        }
        return result
    }

    func hasUnacknowledgedEvents(userID: String, sessionID: UUID) throws -> Bool {
        let database = try requireDatabase()
        let statement = try prepare(
            database,
            sql: """
            SELECT 1 FROM learning_feed_event_queue
            WHERE user_id = ? AND session_id = ? AND sync_state IN ('pending', 'retry')
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(userID, to: statement, at: 1)
        bind(sessionID.uuidString, to: statement, at: 2)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func hasRejectedEvents(userID: String, sessionID: UUID) throws -> Bool {
        let database = try requireDatabase()
        let statement = try prepare(
            database,
            sql: """
            SELECT 1 FROM learning_feed_event_queue
            WHERE user_id = ? AND session_id = ? AND sync_state = 'rejected'
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(userID, to: statement, at: 1)
        bind(sessionID.uuidString, to: statement, at: 2)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func markAcknowledged(userID: String, clientEventIDs: Set<UUID>) throws {
        try updateEventStates(
            userID: userID,
            clientEventIDs: clientEventIDs,
            state: .acknowledged,
            error: nil,
            nextRetryAt: nil
        )
    }

    func markRejected(userID: String, clientEventIDs: Set<UUID>, reason: String?) throws {
        try updateEventStates(
            userID: userID,
            clientEventIDs: clientEventIDs,
            state: .rejected,
            error: reason,
            nextRetryAt: nil
        )
    }

    func markRetry(userID: String, queuedEvents: [LearningFeedQueuedEvent], error: String) throws {
        let retryDate = Date().addingTimeInterval(Self.retryDelay(for: queuedEvents.map(\.attemptCount).max() ?? 0))
        try updateEventStates(
            userID: userID,
            clientEventIDs: Set(queuedEvents.map(\.event.clientEventID)),
            state: .retry,
            error: error,
            nextRetryAt: retryDate,
            incrementAttempt: true
        )
    }

    func saveSnapshot(_ snapshot: LearningFeedSessionSnapshot) throws {
        let database = try requireDatabase()
        try upsertSnapshot(database: database, snapshot: snapshot)
    }

    private func upsertSnapshot(database: OpaquePointer, snapshot: LearningFeedSessionSnapshot) throws {
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw LearningFeedPersistenceError.encoding(error)
        }
        let statement = try prepare(
            database,
            sql: """
            INSERT INTO learning_feed_session_snapshot (
              user_id, session_id, pack_content_hash, payload, updated_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(user_id, session_id) DO UPDATE SET
              pack_content_hash = excluded.pack_content_hash,
              payload = excluded.payload,
              updated_at = excluded.updated_at
            WHERE excluded.updated_at >= learning_feed_session_snapshot.updated_at
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(snapshot.userID, to: statement, at: 1)
        bind(snapshot.sessionID.uuidString, to: statement, at: 2)
        bind(snapshot.packContentHash, to: statement, at: 3)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(data.count), sqliteTransient)
        }
        sqlite3_bind_double(statement, 5, snapshot.updatedAt.timeIntervalSince1970)
        try stepDone(statement, database: database)
    }

    func loadSnapshot(userID: String, sessionID: UUID) throws -> LearningFeedSessionSnapshot? {
        let database = try requireDatabase()
        let statement = try prepare(
            database,
            sql: "SELECT payload FROM learning_feed_session_snapshot WHERE user_id = ? AND session_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(userID, to: statement, at: 1)
        bind(sessionID.uuidString, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0)
        else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        do {
            return try decoder.decode(LearningFeedSessionSnapshot.self, from: data)
        } catch {
            throw LearningFeedPersistenceError.decoding(error)
        }
    }

    func allSnapshots(userID: String) throws -> [LearningFeedSessionSnapshot] {
        let database = try requireDatabase()
        let statement = try prepare(
            database,
            sql: "SELECT payload FROM learning_feed_session_snapshot WHERE user_id = ? ORDER BY updated_at"
        )
        defer { sqlite3_finalize(statement) }
        bind(userID, to: statement, at: 1)
        var result: [LearningFeedSessionSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            do {
                result.append(try decoder.decode(LearningFeedSessionSnapshot.self, from: data))
            } catch {
                throw LearningFeedPersistenceError.decoding(error)
            }
        }
        return result
    }

    func markTerminalDelivered(userID: String, sessionID: UUID) throws {
        guard var snapshot = try loadSnapshot(userID: userID, sessionID: sessionID) else { return }
        snapshot.terminalDelivered = true
        try saveSnapshot(snapshot)
    }

    func clear(userID: String) throws {
        let database = try requireDatabase()
        try Self.execute(database, sql: "BEGIN IMMEDIATE")
        do {
            for table in ["learning_feed_pack_cache", "learning_feed_event_queue", "learning_feed_session_snapshot"] {
                let statement = try prepare(database, sql: "DELETE FROM \(table) WHERE user_id = ?")
                bind(userID, to: statement, at: 1)
                try stepDone(statement, database: database)
                sqlite3_finalize(statement)
            }
            try Self.execute(database, sql: "COMMIT")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    func clearAll() throws {
        let database = try requireDatabase()
        try Self.execute(database, sql: "BEGIN IMMEDIATE")
        do {
            try Self.execute(database, sql: "DELETE FROM learning_feed_pack_cache")
            try Self.execute(database, sql: "DELETE FROM learning_feed_event_queue")
            try Self.execute(database, sql: "DELETE FROM learning_feed_session_snapshot")
            try Self.execute(database, sql: "COMMIT")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    private func updateEventStates(
        userID: String,
        clientEventIDs: Set<UUID>,
        state: LearningFeedQueuedEventState,
        error: String?,
        nextRetryAt: Date?,
        incrementAttempt: Bool = false
    ) throws {
        guard !clientEventIDs.isEmpty else { return }
        let database = try requireDatabase()
        try Self.execute(database, sql: "BEGIN IMMEDIATE")
        do {
            for id in clientEventIDs {
                let statement = try prepare(
                    database,
                    sql: """
                    UPDATE learning_feed_event_queue SET
                      sync_state = ?,
                      attempt_count = attempt_count + ?,
                      next_retry_at = ?,
                      last_error = ?,
                      updated_at = ?
                    WHERE user_id = ? AND client_event_id = ?
                    """
                )
                bind(state.rawValue, to: statement, at: 1)
                sqlite3_bind_int(statement, 2, incrementAttempt ? 1 : 0)
                if let nextRetryAt {
                    sqlite3_bind_double(statement, 3, nextRetryAt.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(statement, 3)
                }
                if let error { bind(error, to: statement, at: 4) } else { sqlite3_bind_null(statement, 4) }
                sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
                bind(userID, to: statement, at: 6)
                bind(id.uuidString, to: statement, at: 7)
                try stepDone(statement, database: database)
                sqlite3_finalize(statement)
            }
            try Self.execute(database, sql: "COMMIT")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    private func insertEvents(
        database: OpaquePointer,
        userID: String,
        sessionID: UUID,
        events: [LearningFeedV2Event]
    ) throws {
        for event in events {
            let payload: Data
            do {
                payload = try encoder.encode(event)
            } catch {
                throw LearningFeedPersistenceError.encoding(error)
            }
            if let existing = try existingEventPayload(
                database: database,
                userID: userID,
                clientEventID: event.clientEventID
            ) {
                guard existing == payload else { throw LearningFeedPersistenceError.eventIdentityConflict }
                continue
            }
            let statement = try prepare(
                database,
                sql: """
                INSERT INTO learning_feed_event_queue (
                  user_id, client_event_id, session_id, sequence_no, payload,
                  sync_state, attempt_count, next_retry_at, last_error, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, 'pending', 0, NULL, NULL, ?, ?)
                """
            )
            bind(userID, to: statement, at: 1)
            bind(event.clientEventID.uuidString, to: statement, at: 2)
            bind(sessionID.uuidString, to: statement, at: 3)
            sqlite3_bind_int64(statement, 4, Int64(event.sequenceNo))
            _ = payload.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 5, bytes.baseAddress, Int32(payload.count), sqliteTransient)
            }
            let now = Date().timeIntervalSince1970
            sqlite3_bind_double(statement, 6, now)
            sqlite3_bind_double(statement, 7, now)
            do {
                try stepDone(statement, database: database)
                sqlite3_finalize(statement)
            } catch {
                sqlite3_finalize(statement)
                throw error
            }
        }
    }

    private func existingEventPayload(
        database: OpaquePointer,
        userID: String,
        clientEventID: UUID
    ) throws -> Data? {
        let statement = try prepare(
            database,
            sql: "SELECT payload FROM learning_feed_event_queue WHERE user_id = ? AND client_event_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(userID, to: statement, at: 1)
        bind(clientEventID.uuidString, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0)
        else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    private func requireDatabase() throws -> OpaquePointer {
        if let initializationError { throw initializationError }
        guard let database else { throw LearningFeedPersistenceError.unavailable("database not open") }
        return database
    }

    private func prepare(_ database: OpaquePointer, sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw LearningFeedPersistenceError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func stringColumn(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func stepDone(_ statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LearningFeedPersistenceError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func retryDelay(for attempt: Int) -> TimeInterval {
        min(pow(2, Double(max(0, attempt))), 60)
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw LearningFeedPersistenceError.sqlite(message)
        }
    }

    private static func migrate(_ database: OpaquePointer) throws {
        try execute(database, sql: """
        CREATE TABLE IF NOT EXISTS learning_feed_pack_cache (
          user_id TEXT NOT NULL,
          pack_id TEXT NOT NULL,
          content_hash TEXT NOT NULL,
          expires_at REAL NOT NULL,
          payload BLOB NOT NULL,
          cached_at REAL NOT NULL,
          PRIMARY KEY (user_id, pack_id)
        )
        """)
        try execute(database, sql: """
        CREATE TABLE IF NOT EXISTS learning_feed_event_queue (
          user_id TEXT NOT NULL,
          client_event_id TEXT NOT NULL,
          session_id TEXT NOT NULL,
          sequence_no INTEGER NOT NULL,
          payload BLOB NOT NULL,
          sync_state TEXT NOT NULL,
          attempt_count INTEGER NOT NULL DEFAULT 0,
          next_retry_at REAL,
          last_error TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY (user_id, client_event_id),
          UNIQUE (user_id, session_id, sequence_no)
        )
        """)
        try execute(database, sql: """
        CREATE TABLE IF NOT EXISTS learning_feed_session_snapshot (
          user_id TEXT NOT NULL,
          session_id TEXT NOT NULL,
          pack_content_hash TEXT NOT NULL,
          payload BLOB NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY (user_id, session_id)
        )
        """)
        try execute(database, sql: "CREATE INDEX IF NOT EXISTS learning_feed_event_retry_idx ON learning_feed_event_queue(user_id, sync_state, next_retry_at)")
    }
}

@Observable
@MainActor
final class LearningFeedRuntimeServices: LearningFeedSignOutClearing {
    let persistence: LearningFeedLocalPersistence
    let registry: EpisodeRendererRegistry
    let artifactRouter: LearningFeedArtifactRouter

    private(set) var isOnline = true
    private(set) var cachedUserID: String?

    private let api: APIClient
    private let connectivity = NWPathMonitor()
    private let connectivityQueue = DispatchQueue(label: "com.digiloglab.strius.learning-feed-network")
    private var currentUserID: String?
    private var retryTask: Task<Void, Never>?
    private var syncingSessions: Set<UUID> = []

    init(
        api: APIClient,
        persistence: LearningFeedLocalPersistence = LearningFeedLocalPersistence(),
        registry: EpisodeRendererRegistry = .current,
        artifactRouter: LearningFeedArtifactRouter = LearningFeedArtifactRouter()
    ) {
        self.api = api
        self.persistence = persistence
        self.registry = registry
        self.artifactRouter = artifactRouter
        connectivity.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOnline = self.isOnline
                self.isOnline = path.status == .satisfied
                if !wasOnline, self.isOnline {
                    self.requestBackgroundSync()
                }
            }
        }
        connectivity.start(queue: connectivityQueue)
    }

    func start(userID: String) {
        currentUserID = userID
        cachedUserID = userID
        guard retryTask == nil else {
            requestBackgroundSync()
            return
        }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncAllPending()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func restoreCachedUserID() async {
        guard cachedUserID == nil else { return }
        cachedUserID = try? await persistence.latestCachedUserID()
    }

    func resumableReservation(userID: String, now: Date = Date()) async -> LearningFeedV2PrefetchResponse? {
        do {
            let candidates = try await persistence.cachedReservationData(userID: userID, now: now)
            for data in candidates {
                guard let reservation = try? artifactRouter.decodePrefetch(
                    data,
                    registry: registry,
                    now: now
                ),
                    let snapshot = try await persistence.loadSnapshot(
                        userID: userID,
                        sessionID: reservation.sessionID
                    ),
                    snapshot.terminalAction == nil,
                    !snapshot.terminalDelivered,
                    snapshot.packID == reservation.pack.manifest.packID,
                    snapshot.packContentHash == reservation.pack.manifest.contentHash,
                    reservation.pack.episodes.indices.contains(snapshot.episodeIndex),
                    reservation.pack.episodes[snapshot.episodeIndex].steps.indices.contains(snapshot.stepIndex)
                else {
                    continue
                }
                return reservation
            }
        } catch {
            learningFeedPersistenceLog.error("learning feed resume lookup failed: \(String(describing: error))")
        }
        return nil
    }

    func requestBackgroundSync() {
        Task { [weak self] in
            await self?.syncAllPending()
        }
    }

    func syncSession(userID: String, sessionID: UUID) async -> LearningFeedV2SessionSnapshotResponse? {
        guard isOnline,
              currentUserID == userID,
              !syncingSessions.contains(sessionID)
        else { return nil }
        syncingSessions.insert(sessionID)
        defer { syncingSessions.remove(sessionID) }

        do {
            while true {
                let queued = try await persistence.pendingEvents(userID: userID, sessionID: sessionID)
                guard !queued.isEmpty else { break }
                do {
                    let response: LearningFeedV2EventBatchResponse = try await api.send(
                        .learningFeedV2EventsBatch(sessionID: sessionID),
                        body: LearningFeedV2EventBatchBody(events: queued.map(\.event))
                    )
                    let acknowledged = Set(response.results.filter {
                        $0.status == "accepted" || $0.status == "duplicate"
                    }.map(\.clientEventID)).union(response.acknowledgedClientEventIDs)
                    let rejectedResults = response.results.filter { $0.status == "rejected" }
                    try await persistence.markAcknowledged(userID: userID, clientEventIDs: acknowledged)
                    for result in rejectedResults {
                        try await persistence.markRejected(
                            userID: userID,
                            clientEventIDs: [result.clientEventID],
                            reason: result.reason
                        )
                    }
                    if response.stop != nil { break }
                    if acknowledged.isEmpty, rejectedResults.isEmpty { break }
                } catch {
                    try await persistence.markRetry(
                        userID: userID,
                        queuedEvents: queued,
                        error: error.localizedDescription
                    )
                    return nil
                }
            }

            if let local = try await persistence.loadSnapshot(userID: userID, sessionID: sessionID),
               let terminal = local.terminalAction,
               !local.terminalDelivered,
               try await persistence.hasUnacknowledgedEvents(userID: userID, sessionID: sessionID) == false
            {
                switch terminal {
                case .complete:
                    let _: LearningFeedV2TerminalResponse = try await api.send(
                        .learningFeedV2Complete(sessionID: sessionID),
                        body: LearningFeedV2CompleteBody(lastClientEventID: local.lastClientEventID)
                    )
                case .close:
                    let _: LearningFeedV2TerminalResponse = try await api.send(
                        .learningFeedV2Close(sessionID: sessionID),
                        body: LearningFeedV2CloseBody(
                            endReason: "user_closed",
                            lastClientEventID: local.lastClientEventID
                        )
                    )
                }
                try await persistence.markTerminalDelivered(userID: userID, sessionID: sessionID)
            }

            return try await api.send(.learningFeedV2Snapshot(sessionID: sessionID))
        } catch {
            learningFeedPersistenceLog.error("learning feed sync failed: \(String(describing: error))")
            return nil
        }
    }

    func clearLearningFeedDataForSignOut() async {
        retryTask?.cancel()
        retryTask = nil
        currentUserID = nil
        cachedUserID = nil
        syncingSessions.removeAll()
        do {
            try await persistence.clearAll()
        } catch {
            learningFeedPersistenceLog.error("learning feed sign-out cleanup failed: \(String(describing: error))")
        }
    }

    private func syncAllPending() async {
        guard isOnline, let currentUserID else { return }
        do {
            let queuedSessions = try await persistence.pendingSessionIDs(userID: currentUserID)
            let snapshots = try await persistence.allSnapshots(userID: currentUserID)
            let terminalSessions = snapshots.filter {
                $0.terminalAction != nil && !$0.terminalDelivered
            }.map(\.sessionID)
            for sessionID in Set(queuedSessions + terminalSessions) {
                _ = await syncSession(userID: currentUserID, sessionID: sessionID)
            }
        } catch {
            learningFeedPersistenceLog.error("learning feed retry scan failed: \(String(describing: error))")
        }
    }
}
