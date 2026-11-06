import Foundation
import GRDB
import OSLog

nonisolated private let erasureLog = Logger(subsystem: "com.digiloglab.strius", category: "ledger")

/// 学習記録をまとめて消す(#78)。運営者は学習記録を持たないので、消去の請求にはこの機能で応える。
///
/// - 消す端末: 端末の記録(台帳・答案・写真・添付・学習メモ・会話の控え・`backups/` の ZIP)を消し、iCloud のゾーンを作り直す。
///   iCloud の Key-Value ストアに消去の印(`Marker`)を置く。
/// - 同じ Apple ID の別の端末: 印より前に作られた台帳なら、端末の記録を同じように消す(ゾーンは消す端末が作り直す)。
///   印より後に作られた台帳(印の後に入れた端末)は消さずに、印を受け取った扱いにする。
/// - どの端末も、印より前に作られた出来事・ファイルを同期で受け取らない(遅れて届いた古い記録で戻さない)。
/// - 途中で止まっても、次の起動で続きから消す(端末に消去の記録 `Journal` を置く)。
/// - 使用額・お試しの数・年齢の判定・同意の記録(Keychain と iCloud の Key-Value ストア)は消さない(消すとお試しの枠が戻る)。
nonisolated enum LearningErasure {
    /// 消去の印。同じ印は 1 回だけ消す。
    struct Marker: Codable, Equatable, Sendable {
        var id: String
        var at: Date

        static func new(now: Date = Date()) -> Marker { Marker(id: UUID().uuidString.lowercased(), at: now) }

        /// 時刻は 1 秒未満も残す(同じ秒に書かれた、消す前の記録も外すため)。
        var text: String {
            (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }

        init(id: String, at: Date) {
            self.id = id
            self.at = at
        }

        init?(text: String?) {
            guard let data = text?.data(using: .utf8), let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return nil }
            self = marker
        }

        /// 台帳の `created_at` と比べる時刻(出来事の `created_at` と同じ形)。
        var ledgerTime: String { LedgerClock.iso(at) }
    }

    /// 端末に置く消去の記録(続きから消すため)。
    struct Journal: Codable, Equatable, Sendable {
        var marker: Marker
        /// 別の端末の消去を受けて消している(iCloud のゾーンは作り直さない)。
        var remote: Bool
        /// 端末の記録を消し終えた(残りは iCloud のゾーンの作り直し)。
        var localDone: Bool
    }

    /// iCloud の Key-Value ストアの鍵(消去の印)。
    static let markerKey = "learning.erasure.v1"
    /// 台帳の `ledger_meta` の鍵: この台帳が受け取った消去の印と、台帳を作った時刻。
    static let appliedMetaKey = "learning_erasure"
    static let createdMetaKey = "created_at"

    /// 消す端末の記録のフォルダ(`Application Support/Struis/` から)。
    static let folders = ["captures", "attachments", "memory", "diagnostics", "conversation-images", "backups"]

    static func journalURL(_ root: URL) -> URL { root.appendingPathComponent("learning-erasure.json") }

    static func journal(at root: URL) -> Journal? {
        guard let data = try? Data(contentsOf: journalURL(root)) else { return nil }
        return try? JSONDecoder().decode(Journal.self, from: data)
    }

    static func write(_ journal: Journal, at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: journalURL(root), options: .atomic)
    }

    // MARK: - 端末の設定に残る学習の内容

    /// 学習の内容を持つ UserDefaults の鍵(オンボーディングの回答は `clearDeviceState` で、同意と年齢を残して消す)。
    static let defaultsKeys: [String] = [
        OnboardingProfile.unitCreationThreadKey, OnboardingProfile.pendingUnitCreationAttachmentsKey, OnboardingProfile.legacyProfileKey,
        "onboarding.planDraft.v1", "reminder.subunit.v1",
    ]
    static let defaultsPrefixes: [String] = ["workbook.subunitHeaderCollapsed."]

    /// 端末の設定(UserDefaults)と一時フォルダに残る学習の内容を消す。オンボーディングの回答は、同意と年齢の記録だけを残す
    /// (同意と年齢は Keychain と iCloud にも残り、消さない)。オンボーディングを終えた印もそのまま(最初からやり直させない)。
    static func clearDeviceState(defaults: UserDefaults = .standard, temporary: URL = FileManager.default.temporaryDirectory) {
        for key in defaultsKeys { defaults.removeObject(forKey: key) }
        for key in defaults.dictionaryRepresentation().keys where defaultsPrefixes.contains(where: key.hasPrefix) { defaults.removeObject(forKey: key) }
        if let profile = OnboardingProfile.load(defaults) {
            var kept = OnboardingProfile()
            kept.ageBand = profile.ageBand
            kept.ageDeclaration = profile.ageDeclaration
            kept.ageCheckedAt = profile.ageCheckedAt
            kept.termsAcceptedAt = profile.termsAcceptedAt
            kept.photoConsentAt = profile.photoConsentAt
            kept.save(defaults)
        }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: temporary.path)) ?? [] where name.hasPrefix("struis-ledger-") || name == "composer-intake" {
            try? fm.removeItem(at: temporary.appendingPathComponent(name))
        }
    }

    // MARK: - iCloud の Key-Value ストアの印

    static func cloudMarker(_ store: any DeviceValueStore = CloudValueStore()) -> Marker? {
        Marker(text: store.string(markerKey))
    }

    static func publish(_ marker: Marker, to store: any DeviceValueStore = CloudValueStore()) {
        // 新しい印だけを置く(遅れて届いた古い消去で、新しい印を上書きしない)。
        if let current = cloudMarker(store), current.at > marker.at { return }
        store.set(marker.text, markerKey)
    }
}

extension Ledger {
    /// この台帳が受け取った消去の印(この時刻より前の記録は同期で受け取らない)。
    nonisolated func appliedErasure() -> LearningErasure.Marker? {
        LearningErasure.Marker(text: try? queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM ledger_meta WHERE key = ?", arguments: [LearningErasure.appliedMetaKey])
        })
    }

    /// 台帳を作った時刻(#78 より前に作った台帳は nil。どの消去の印よりも前とみなす)。
    nonisolated func createdAt() -> String? {
        try? queue.read { db in try String.fetchOne(db, sql: "SELECT value FROM ledger_meta WHERE key = ?", arguments: [LearningErasure.createdMetaKey]) }
    }

    /// 消している途中の記録。
    nonisolated func pendingErasure() -> LearningErasure.Journal? { LearningErasure.journal(at: deletionRoot) }

    /// 別の端末の消去の印を受けて、この端末で何をするか。
    nonisolated enum RemoteErasure: Equatable, Sendable {
        /// 受け取り済み。
        case none
        /// 印より後に作った台帳: 消さずに受け取った扱いにする。
        case acknowledge
        /// 印より前に作った台帳: この端末の記録を消す。
        case erase
    }

    nonisolated func remoteErasure(for marker: LearningErasure.Marker) -> RemoteErasure {
        if let applied = appliedErasure(), applied.id == marker.id || applied.at >= marker.at { return .none }
        if pendingErasure()?.marker.id == marker.id { return .none }
        if let created = createdAt(), created > marker.ledgerTime { return .acknowledge }
        return .erase
    }

    /// 印を受け取った扱いにする(消さない)。これより前の記録は、同期で受け取らない。
    func acknowledgeErasure(_ marker: LearningErasure.Marker) throws {
        try queue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO ledger_meta (key, value) VALUES (?, ?)", arguments: [LearningErasure.appliedMetaKey, marker.text])
        }
    }

    /// 消し始める: 消去の記録を置く。消し終えるまで、台帳への読み書きは止まる(`ensureDeletionReady`)。
    func beginErasure(_ marker: LearningErasure.Marker, remote: Bool) throws {
        if let pending = pendingErasure(), pending.marker.id == marker.id { return }
        try LearningErasure.write(LearningErasure.Journal(marker: marker, remote: remote, localDone: false), at: deletionRoot)
    }

    /// 端末の記録を消す(何度呼んでも同じ結果。続きからでも)。台帳の出来事・射影・同期の控え・Claude との会話の控え、
    /// 答案・写真・添付・学習メモ・表示の控え・`backups/` の ZIP、実行の作業フォルダ。台帳の端末の ID・作った時刻は残す。
    func eraseLearningRecords() throws {
        guard var journal = pendingErasure() else { return }
        UnitDeletion.gate.lock(); defer { UnitDeletion.gate.unlock() }
        let marker = journal.marker
        try queue.write { db in
            try db.execute(sql: "PRAGMA secure_delete=ON")
            for table in ["ledger_events", "sync_pending", "sync_files", "sync_tombstones", "claude_conversation_messages", "claude_conversations"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            try LedgerSchema.dropProjections(db)
            try LedgerSchema.createProjections(db)
            try db.execute(sql: "DELETE FROM ledger_meta WHERE key NOT IN ('device_id', 'installation_id', ?)", arguments: [LearningErasure.createdMetaKey])
            try db.execute(sql: "INSERT OR REPLACE INTO ledger_meta (key, value) VALUES (?, ?)", arguments: [LearningErasure.appliedMetaKey, marker.text])
        }
        try UnitDeletion.compact(queue)
        let fm = FileManager.default
        // 単元の削除・取り込みの途中の記録も消す(消す対象の記録を指している)。
        for url in [UnitDeletion.journalURL(deletionRoot), LedgerArchive.importJournalURL(deletionRoot)] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        deletionFailure = nil
        for name in LearningErasure.folders {
            let url = deletionRoot.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        for root in deletionRuntimeRoots where fm.fileExists(atPath: root.path) {
            for name in try fm.contentsOfDirectory(atPath: root.path) { try fm.removeItem(at: root.appendingPathComponent(name)) }
        }
        for name in ["captures", "memory"] {
            try fm.createDirectory(at: deletionRoot.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        journal.localDone = true
        try LearningErasure.write(journal, at: deletionRoot)
        erasureLog.notice("erased the learning records on this device")
        notify(Self.replacedNotice)
    }

    /// 消し終えた(iCloud のゾーンも作り直した、または別の端末の消去を受けた)。
    func finishErasure() throws {
        let url = LearningErasure.journalURL(deletionRoot)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// 同期で届いた出来事のうち、受け取った消去の印より前に作られたもの(遅れて届いた、消した記録)の名前。
    nonisolated static func erasedRecords(_ records: [SyncEventRecord], before marker: LearningErasure.Marker?) -> Set<String> {
        guard let marker else { return [] }
        let cutoff = marker.ledgerTime
        return Set(records.filter { $0.createdAt < cutoff }.map(\.recordName))
    }
}
