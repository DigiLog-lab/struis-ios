import Foundation
import OSLog

private let iCloudLog = Logger(subsystem: "com.digiloglab.strius", category: "sync")

/// 設定の「iCloud 同期」と、同期を走らせる時機 (Issue #51)。既定でオン。プッシュ通知は使わず、
/// 起動時・前面に戻った時・台帳に書いた直後(送信のあとに取り込み)・前面にいる間は数分おきに同期する。
@Observable
@MainActor
final class ICloudSync {
    static let enabledKey = "struis.icloudSync.enabled"
    static let lastSyncedKey = "struis.icloudSync.lastSyncedAt"
    /// Set when the learner deleted the data from iCloud settings: turning sync on again uploads everything.
    static let uploadAgainKey = "struis.icloudSync.uploadAgain"
    static let interval: Duration = .seconds(180)
    static let writeDelay: Duration = .seconds(2)

    /// false in tests, fixtures and in-memory ledgers: nothing talks to iCloud.
    let isSupported: Bool
    private(set) var isEnabled: Bool
    private(set) var account: CloudKitSyncTransport.Account = .unknown
    private(set) var lastSyncedAt: Date?
    private(set) var counts = Ledger.SyncCounts(unsent: 0, pending: 0)
    private(set) var isSyncing = false
    private(set) var isUploadingAgain = false
    /// The last problem or notable change, for the settings screen.
    private(set) var message: String?

    private let ledger: Ledger
    private let cloud: CloudKitSyncTransport?
    private let engine: LedgerSyncEngine?
    private var started = false
    private var observer: UUID?
    private var periodic: Task<Void, Never>?
    private var writeSync: Task<Void, Never>?
    private var current: Task<Void, Never>?
    private var again: Bool?

    init(ledger: Ledger, cloud: CloudKitSyncTransport?) {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        self.ledger = ledger
        self.cloud = cloud
        self.isSupported = cloud != nil
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.lastSyncedAt = UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Date
        let info = Bundle.main.infoDictionary
        let build = "\(info?["CFBundleShortVersionString"] as? String ?? "0") (\(info?["CFBundleVersion"] as? String ?? "0"))"
        self.engine = cloud.map { LedgerSyncEngine(ledger: ledger, transport: $0, build: build) }
    }

    // MARK: - Triggers

    /// Launch: sync now and after every local write.
    func start() async {
        guard isSupported, !started else { return }
        started = true
        observer = await ledger.observe(localOnly: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleAfterWrite() }
        }
        sceneBecameActive()
    }

    /// Foreground: sync now and every few minutes until the app leaves the foreground.
    func sceneBecameActive() {
        guard isSupported, started else { return }
        requestSync(fetchFirst: true)
        periodic?.cancel()
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled else { return }
                self?.requestSync(fetchFirst: true)
            }
        }
    }

    func sceneLeftForeground() {
        periodic?.cancel()
        periodic = nil
    }

    private func scheduleAfterWrite() {
        writeSync?.cancel()
        writeSync = Task { [weak self] in
            try? await Task.sleep(for: Self.writeDelay)
            guard !Task.isCancelled else { return }
            // Send first, then take in what other devices wrote.
            self?.requestSync(fetchFirst: false)
        }
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            message = nil
            if UserDefaults.standard.bool(forKey: Self.uploadAgainKey) {
                Task { await uploadAgain() }
            } else {
                requestSync(fetchFirst: true)
            }
        }
    }

    /// 「iCloud のデータを消して、この端末の内容で上げ直す」.
    func uploadAgain() async {
        guard isSupported, let engine, isEnabled else { return }
        isUploadingAgain = true
        defer { isUploadingAgain = false }
        while let running = current { await running.value }
        let task = Task { @MainActor in
            do {
                account = await cloud?.account() ?? .unknown
                guard account == .available else { return }
                try await engine.uploadAgain()
                UserDefaults.standard.set(false, forKey: Self.uploadAgainKey)
                markSynced()
                message = "iCloud のデータを、この端末の内容で上げ直しました"
            } catch {
                iCloudLog.error("upload again failed: \(String(describing: error), privacy: .public)")
                message = "上げ直せませんでした。通信を確かめて、もう一度お試しください"
            }
            await refreshCounts()
        }
        current = task
        await task.value
        current = nil
        if let next = again {
            again = nil
            requestSync(fetchFirst: next)
        }
    }

    func refreshCounts() async {
        if let counts = try? await ledger.syncCounts() { self.counts = counts }
        if let cloud, isEnabled { account = await cloud.account() }
    }

    var statusText: String {
        guard isSupported else { return "この環境では同期しません" }
        guard isEnabled else { return "オフ" }
        switch account {
        case .noAccount: return "iCloud にサインインしていません"
        case .restricted: return "この端末では iCloud を使えません"
        case .temporarilyUnavailable: return "iCloud を一時的に使えません"
        case .available, .unknown: break
        }
        if isUploadingAgain { return "上げ直しています" }
        if isSyncing { return "同期しています" }
        guard let lastSyncedAt else { return "まだ同期していません" }
        return "最後に同期: " + lastSyncedAt.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Running

    /// One sync at a time; a request while one runs runs once more afterwards.
    private func requestSync(fetchFirst: Bool) {
        guard isSupported, isEnabled, let engine else { return }
        if current != nil {
            again = (again ?? false) || fetchFirst
            return
        }
        current = Task { @MainActor [weak self] in
            await self?.run(engine, fetchFirst: fetchFirst)
            guard let self else { return }
            self.current = nil
            if let next = self.again {
                self.again = nil
                self.requestSync(fetchFirst: next)
            }
        }
    }

    private func run(_ engine: LedgerSyncEngine, fetchFirst: Bool) async {
        isSyncing = true
        defer { isSyncing = false }
        account = await cloud?.account() ?? .unknown
        guard account == .available else {
            await refreshCounts()
            return
        }
        do {
            let outcome = try await engine.sync(fetchFirst: fetchFirst)
            if outcome.deletedByLearner {
                isEnabled = false
                UserDefaults.standard.set(false, forKey: Self.enabledKey)
                UserDefaults.standard.set(true, forKey: Self.uploadAgainKey)
                message = "「設定」から iCloud のデータが消されたため、同期をオフにしました。この端末の記録はそのままです。オンにすると、この端末の内容で上げ直します"
            } else {
                markSynced()
                if outcome.backup != nil {
                    message = "ほかの端末が iCloud のデータを上げ直したため、この端末の記録を iCloud の内容に置き換えました。置き換える前の記録は、この端末に1つ残しています"
                } else if outcome.uploadedAgain {
                    message = "iCloud の暗号化の鍵が作り直されたため、この端末の記録を上げ直しました"
                } else if message?.hasPrefix("同期できませんでした") == true {
                    message = nil
                }
            }
        } catch {
            iCloudLog.error("sync failed: \(String(describing: error), privacy: .public)")
            message = "同期できませんでした。次の同期でもう一度試します"
        }
        await refreshCounts()
    }

    private func markSynced() {
        let now = Date()
        lastSyncedAt = now
        UserDefaults.standard.set(now, forKey: Self.lastSyncedKey)
    }
}
