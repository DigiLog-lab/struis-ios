import Foundation
import GRDB
import OSLog

private let settingsLog = Logger(subsystem: "com.digiloglab.strius", category: "settings")

/// Backs the Settings screen. The ChatGPT / Codex connection is made on the
/// device against the resident `codex app-server` (design §6.2
/// `CodexAccountRuntime`); credentials stay in the guest's `/root/.codex`.
@Observable
@MainActor
final class SettingsStore {
    private(set) var account: CodexAccount?
    private(set) var loadState: LoadState = .idle
    private(set) var busy: Bool = false
    private(set) var errorMessage: String?
    private(set) var pendingLogin: CodexLoginStart?
    private var loginWait: Task<Void, Never>?

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private let runtime: DeviceRuntime?
    /// The device ledger; the account state is kept in its `codex_account` projection (design §4.2).
    private let ledger: Ledger?

    init(runtime: DeviceRuntime?, ledger: Ledger? = nil) {
        self.runtime = runtime
        self.ledger = ledger
    }

    /// Show the account and record it in the ledger's `codex_account` row.
    private func apply(_ snapshot: CodexAccountSnapshot, pending: CodexLoginStart?) {
        account = Self.account(from: snapshot, pending: pending)
        guard let ledger else { return }
        let record = CodexAccountRecord(
            id: "device", status: snapshot.status.rawValue, authMode: snapshot.authMode, planType: snapshot.planType,
            email: snapshot.email, rateLimits: LedgerJSON(any: snapshot.rateLimits),
            resetsAt: snapshot.rateLimitResetsAt.map(LedgerClock.iso), syncedAt: LedgerClock.iso(snapshot.syncedAt), error: nil
        )
        Task {
            do {
                try await ledger.commit { db in
                    if let existing = try CodexAccountRecord.fetchOne(db, key: "device"), existing == record { return ([], ()) }
                    return ([.upsert("codex_account.synced", record)], ())
                }
            } catch {
                settingsLog.error("codex account record failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - 学習記録 (design §4.3) と使用量報告 (§8-4)

    private(set) var ledgerEventCount: Int?
    private(set) var exportedArchive: URL?
    private(set) var ledgerBusy = false
    private(set) var ledgerMessage: String?

    /// 既定オフ。オンのときだけ終わったターンの統計を送る (`UsageReporter`)。
    var usageReportingEnabled: Bool = UsageReporter.isEnabled {
        didSet { UsageReporter.isEnabled = usageReportingEnabled }
    }

    func loadLedgerSummary() async {
        guard let ledger else { return }
        ledgerEventCount = try? await ledger.eventCount()
    }

    func exportLedger() async {
        guard let ledger, !ledgerBusy else { return }
        ledgerBusy = true
        defer { ledgerBusy = false }
        do {
            exportedArchive = try await LedgerArchive.export(ledger: ledger)
            ledgerMessage = "書き出しました。共有から Files に保存できます"
        } catch {
            settingsLog.error("ledger export failed: \(String(describing: error), privacy: .public)")
            ledgerMessage = "書き出せませんでした: \(error.localizedDescription)"
        }
    }

    func importLedger(from url: URL) async {
        guard let ledger, !ledgerBusy else { return }
        ledgerBusy = true
        defer { ledgerBusy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let manifest = try await LedgerArchive.importArchive(from: url, into: ledger)
            ledgerMessage = "\(manifest.eventCount) 件の記録を取り込みました"
        } catch {
            settingsLog.error("ledger import failed: \(String(describing: error), privacy: .public)")
            ledgerMessage = "取り込めませんでした: \(error.localizedDescription)"
        }
        ledgerEventCount = try? await ledger.eventCount()
    }

    var runtimeSummary: DeviceRuntimeSummary {
        DeviceRuntimeSummary(runtime: runtime)
    }

    func refresh() async {
        if case .loading = loadState { return }

        if Self.usesSimulatorFixtures {
            account = Self.simulatorAccount
            loadState = .loaded
            errorMessage = nil
            return
        }
        guard let runtime else {
            loadState = .failed("実行環境がありません")
            return
        }
        loadState = .loading
        do {
            try await runtime.ensureRunning()
            let snapshot = try await runtime.account.readAccount()
            apply(snapshot, pending: pendingLogin)
            loadState = .loaded
            errorMessage = nil
        } catch {
            settingsLog.error("codex account refresh failed: \(String(describing: error), privacy: .public)")
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Device-code login: show the code, wait for the learner to finish in the browser,
    /// then read the account from the app-server.
    func connect() async {
        guard !busy else { return }

        if Self.usesSimulatorFixtures {
            account = Self.simulatorAccount
            errorMessage = nil
            return
        }
        guard let runtime else { return }

        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await runtime.ensureRunning()
            let login = try await runtime.account.startDeviceLogin()
            pendingLogin = login
            account = Self.connecting(login: login, previous: account)
            loginWait?.cancel()
            loginWait = Task { [weak self] in
                await self?.waitForLogin(login)
            }
        } catch {
            settingsLog.error("codex connect failed: \(String(describing: error), privacy: .public)")
            errorMessage = Self.connectionMessage(for: error.localizedDescription)
        }
    }

    private func waitForLogin(_ login: CodexLoginStart) async {
        guard let runtime else { return }
        do {
            try await runtime.account.waitForLoginCompleted(loginID: login.loginID)
            guard pendingLogin?.loginID == login.loginID else { return }
            pendingLogin = nil
            let snapshot = try await runtime.account.readAccount()
            apply(snapshot, pending: nil)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard pendingLogin?.loginID == login.loginID else { return }
            pendingLogin = nil
            settingsLog.error("codex login did not complete: \(String(describing: error), privacy: .public)")
            errorMessage = Self.connectionMessage(for: error.localizedDescription)
            account = Self.disconnected(error: error.localizedDescription)
        }
    }

    func cancelPendingLogin() async {
        guard let login = pendingLogin, let runtime else { return }
        loginWait?.cancel()
        loginWait = nil
        pendingLogin = nil
        await runtime.account.cancelLogin(loginID: login.loginID)
        account = Self.disconnected(error: nil)
    }

    /// Kept for the connection screen's periodic check; the wait task drives completion.
    func pollConnection() async {
        guard pendingLogin == nil, account?.status == .connecting else { return }
        await sync()
    }

    func sync() async {
        guard !busy else { return }

        if Self.usesSimulatorFixtures {
            account = Self.simulatorAccount
            errorMessage = nil
            return
        }
        guard let runtime else { return }

        busy = true
        defer { busy = false }
        do {
            try await runtime.ensureRunning()
            let snapshot = try await runtime.account.readAccount()
            apply(snapshot, pending: pendingLogin)
            errorMessage = nil
        } catch {
            settingsLog.error("codex sync failed: \(String(describing: error), privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() async {
        guard !busy else { return }

        if Self.usesSimulatorFixtures {
            account = Self.disconnected(error: nil)
            errorMessage = nil
            return
        }
        guard let runtime else { return }

        busy = true
        defer { busy = false }
        do {
            try await runtime.ensureRunning()
            try await runtime.account.logout()
            pendingLogin = nil
            let snapshot = try await runtime.account.readAccount()
            apply(snapshot, pending: nil)
            errorMessage = nil
        } catch {
            settingsLog.error("codex disconnect failed: \(String(describing: error), privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Mapping

    nonisolated static func account(from snapshot: CodexAccountSnapshot, pending: CodexLoginStart?) -> CodexAccount {
        let status: CodexAccount.Status
        switch snapshot.status {
        case .connected: status = .connected
        case .rateLimited: status = .rateLimited
        case .disconnected: status = pending == nil ? .disconnected : .connecting
        }
        return CodexAccount(
            id: "device",
            status: status,
            authMode: snapshot.authMode,
            planType: snapshot.planType,
            accountEmail: snapshot.email,
            rateLimitStatus: AnyJSON(jsonObject: snapshot.rateLimits),
            rateLimitResetsAt: snapshot.rateLimitResetsAt,
            lastSyncedAt: snapshot.syncedAt,
            error: nil,
            loginID: pending?.loginID,
            verificationURL: pending?.verificationURL,
            userCode: pending?.userCode
        )
    }

    nonisolated private static func connecting(login: CodexLoginStart, previous: CodexAccount?) -> CodexAccount {
        CodexAccount(
            id: "device", status: .connecting, authMode: "chatgptDeviceCode",
            planType: previous?.planType, accountEmail: previous?.accountEmail,
            rateLimitStatus: nil, rateLimitResetsAt: nil, lastSyncedAt: previous?.lastSyncedAt, error: nil,
            loginID: login.loginID, verificationURL: login.verificationURL, userCode: login.userCode
        )
    }

    nonisolated private static func disconnected(error: String?) -> CodexAccount {
        CodexAccount(
            id: "device", status: error == nil ? .disconnected : .error, authMode: nil, planType: nil,
            accountEmail: nil, rateLimitStatus: nil, rateLimitResetsAt: nil, lastSyncedAt: nil, error: error,
            loginID: nil, verificationURL: nil, userCode: nil
        )
    }

    nonisolated private static func connectionMessage(for rawMessage: String) -> String {
        if isDeviceCodePermissionError(rawMessage) {
            return "Device Code認証が許可されていません。ChatGPTの設定を確認してください。"
        }
        if rawMessage.localizedCaseInsensitiveContains("error sending request") {
            return "OpenAI に接続できませんでした。ネットワークを確認して、もう一度お試しください。"
        }
        return rawMessage
    }

    nonisolated private static func isDeviceCodePermissionError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        let mentionsDeviceCode = lowered.contains("device") && lowered.contains("code")
        let mentionsPermission = lowered.contains("permission")
            || lowered.contains("disabled")
            || lowered.contains("not enabled")
            || lowered.contains("not allowed")
        return mentionsDeviceCode && mentionsPermission
    }

    private static var simulatorAccount: CodexAccount {
        CodexAccount(
            id: "simulator-codex",
            status: .connected,
            authMode: "chatgpt",
            planType: "plus",
            accountEmail: "simulator@struis.local",
            rateLimitStatus: AnyJSON(
                .object([
                    "rateLimits": .object([
                        "primary": .object([
                            "usedPercent": .number(36),
                            "remaining": .number(640),
                            "limit": .number(1000)
                        ])
                    ])
                ])
            ),
            rateLimitResetsAt: Date().addingTimeInterval(60 * 60 * 8),
            lastSyncedAt: Date(),
            error: nil,
            loginID: nil,
            verificationURL: nil,
            userCode: nil
        )
    }

    private static var usesSimulatorFixtures: Bool {
        SimulatorFixtures.isEnabled && !DeviceRuntime.isForcedInFixtures
    }
}

/// What the Settings screen shows about the on-device runtime.
struct DeviceRuntimeSummary: Equatable {
    let hyotanVersion: String
    let rootfsVersion: Int?
    let codexVersion: String?
    let alpineVersion: String?
    let bootState: String
    let appServerState: String
    let installSeconds: Double?
    let bootSeconds: Double?
    let initializeSeconds: Double?

    @MainActor
    init(runtime: DeviceRuntime?) {
        guard let runtime else {
            hyotanVersion = "-"
            rootfsVersion = nil
            codexVersion = nil
            alpineVersion = nil
            bootState = "無効"
            appServerState = "停止"
            installSeconds = nil
            bootSeconds = nil
            initializeSeconds = nil
            return
        }
        hyotanVersion = runtime.boot.hyotanVersion
        rootfsVersion = nil
        codexVersion = "0.153.4"
        alpineVersion = nil
        switch runtime.boot.state {
        case .idle: bootState = "未起動"
        case .installing(let fraction): bootState = "展開中 \(Int(fraction * 100))%"
        case .booting: bootState = "起動中"
        case .ready: bootState = "起動済み"
        case .failed(let message): bootState = "失敗: \(message)"
        }
        switch runtime.appServerState {
        case .stopped: appServerState = "停止"
        case .starting: appServerState = "起動中"
        case .running: appServerState = "実行中"
        case .failed(let message): appServerState = "失敗: \(message)"
        }
        installSeconds = runtime.boot.installDuration
        bootSeconds = runtime.boot.bootDuration
        initializeSeconds = runtime.initializeDuration
    }
}

extension DeviceRuntime {
    /// `STRUIS_DEVICE_RUNTIME=1` uses the real native runtime even when the other
    /// simulator fixtures are on (used to verify boot / login in the simulator).
    nonisolated static var isForcedInFixtures: Bool {
        ProcessInfo.processInfo.environment["STRUIS_DEVICE_RUNTIME"] == "1"
    }
}

extension AnyJSON {
    /// Build the opaque JSON container from a Foundation JSON object.
    init?(jsonObject: JSONObject) {
        guard JSONSerialization.isValidJSONObject(jsonObject),
              let data = try? JSONSerialization.data(withJSONObject: jsonObject),
              let value = try? JSONDecoder().decode(AnyJSONValue.self, from: data)
        else { return nil }
        self.init(value)
    }
}
