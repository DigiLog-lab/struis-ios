import Foundation
import GRDB
import OSLog

private let settingsLog = Logger(subsystem: "com.digiloglab.strius", category: "settings")

/// 設定の画面を支える。AI は Claude だけ(App Attest で端末から直接使う)なので、接続の操作は無い。
@Observable
@MainActor
final class SettingsStore {
    private let runtime: DeviceRuntime?
    /// 端末の台帳(学習記録の書き出し・取り込みと、今月の使用量)。
    private let ledger: Ledger?

    init(runtime: DeviceRuntime?, ledger: Ledger? = nil) {
        self.runtime = runtime
        self.ledger = ledger
        Self.removeLegacyAnthropicKey()
    }

    // MARK: - AIモデル(Claude)

    /// タイムライン(出題・採点・見直し)の Claude のモデル。次の依頼から切り替わる(今日の記録・正誤・難しさは台帳にあるので引き継ぐ)。
    var timelineClaudeModel: String = TimelineModelPreference.current {
        didSet { TimelineModelPreference.current = timelineClaudeModel }
    }
    /// この端末で Claude を使えるか(App Attest が使える端末)。Anthropic の API キーは端末に置かない。
    let claudeAvailable = ClaudeAccess.isAvailable

    /// 以前のプロトタイプで入れた API キーを消す(Claude は App Attest で Anthropic から token を受け取り、端末にキーを置かない)。
    static func removeLegacyAnthropicKey() {
        KeychainStore(service: "com.digiloglab.strius.anthropic").delete("api-key")
    }

    // MARK: - 学習記録 (design §4.3) と使用量報告 (§8-4)

    private(set) var ledgerEventCount: Int?
    private(set) var exportedArchive: URL?
    private(set) var ledgerBusy = false
    private(set) var ledgerMessage: String?
    /// 書き出す期間(既定は今日。調べる用の書き出しを軽くする)。
    var exportPeriod: LedgerArchive.Period = .today
    /// 書き出しに答案の写真・質問の添付・記憶を入れるか(「すべて」の時はいつも入れる)。
    var exportIncludesFiles = false

    /// 既定オフ。オンのときだけ終わったターンの統計を送る (`UsageReporter`)。
    var usageReportingEnabled: Bool = UsageReporter.isEnabled {
        didSet { UsageReporter.isEnabled = usageReportingEnabled }
    }

    /// 今月のトークン使用量(台帳の `turns.executions` の `turn_tokens` をモデルごとに合計)。
    private(set) var monthlyTokenUsage: TokenUsageSummary?
    /// 今月のタイムラインの 1 問あたりの Claude の料金(モデルごと)。
    private(set) var monthlyTimelineCost: TimelineCostSummary?

    func loadLedgerSummary() async {
        guard let ledger else { return }
        ledgerEventCount = try? await ledger.eventCount()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        let since = LedgerClock.iso(monthStart)
        let turns = try? await ledger.read { db in
            try TurnRecord.filter(Column("created_at") >= since).fetchAll(db)
        }
        monthlyTokenUsage = turns.map { TokenUsageSummary.summarize($0.map(\.executions)) }
        monthlyTimelineCost = turns.map { TimelineCostSummary.summarize($0.map { TimelineCostSummary.Turn(kind: $0.kind, targetID: $0.targetId, status: $0.status, executions: $0.executions) }) }
    }

    /// 学習記録の「書き出す」: 端末の乗り換えに使うので、全部の記録と写真・添付・記憶を入れる。
    func exportAllRecords() async {
        await exportLedger(period: .all, includesFiles: true)
    }

    /// 開発者向けの「調べる用に書き出す」: 選んだ期間だけを書き出す(取り込みには使えない)。
    func exportLedger() async {
        await exportLedger(period: exportPeriod, includesFiles: exportIncludesFiles)
    }

    private func exportLedger(period: LedgerArchive.Period, includesFiles: Bool) async {
        guard let ledger, !ledgerBusy else { return }
        ledgerBusy = true
        defer { ledgerBusy = false }
        do {
            let scope = LedgerArchive.Scope(since: period.since(), includesFiles: period == .all || includesFiles)
            exportedArchive = try await LedgerArchive.export(ledger: ledger, scope: scope, suffix: period.fileSuffix)
            ledgerMessage = scope.isPartial
                ? "\(period.title)・\(scope.includesFiles ? "写真あり" : "写真なし")で書き出しました。調べる用なので、取り込みには使えません"
                : "書き出しました。共有から Files に保存できます"
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
}

/// 開発者向けの画面に出す、端末の実行環境(コマンドの helper)の様子。
struct DeviceRuntimeSummary: Equatable {
    let hyotanVersion: String
    let bootState: String
    let installSeconds: Double?
    let bootSeconds: Double?

    @MainActor
    init(runtime: DeviceRuntime?) {
        guard let runtime else {
            hyotanVersion = "-"
            bootState = "無効"
            installSeconds = nil
            bootSeconds = nil
            return
        }
        hyotanVersion = runtime.boot.hyotanVersion
        switch runtime.boot.state {
        case .idle: bootState = "未起動"
        case .installing(let fraction): bootState = "展開中 \(Int(fraction * 100))%"
        case .booting: bootState = "起動中"
        case .ready: bootState = "起動済み"
        case .failed(let message): bootState = "失敗: \(message)"
        }
        installSeconds = runtime.boot.installDuration
        bootSeconds = runtime.boot.bootDuration
    }
}

extension DeviceRuntime {
    /// `STRUIS_DEVICE_RUNTIME=1` uses the real native runtime even when the other
    /// simulator fixtures are on (used to verify the helper boot in the simulator).
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
