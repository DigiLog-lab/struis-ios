import SwiftUI
import UniformTypeIdentifiers

/// 設定のホーム。本番は利用者が決めることだけを並べ、内部の情報は「開発者向け」にまとめる。
struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(APIClient.self) private var apiClient
    @Environment(LearnerData.self) private var learnerData
    @State private var usage: UsageStatus = UsageStatus()
    /// 内部の配布か。TestFlight は開いてから分かるので、最初は Bundle ID とビルドで決める。
    @State private var isInternalBuild: Bool = InternalBuild.isKnownInternal

    /// ChatGPT(Codex)の入口。経路は選択肢から外した(#40)ので、DEBUG の検証(`-show-codex-settings`)でだけ出す。
    static var showsCodexEntry: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-show-codex-settings")
        #else
        return false
        #endif
    }

    var body: some View {
        SettingsScreen(title: "設定") {
            notices
            if Auth0Config.authenticationRequired {
                SettingsSection {
                    SettingsLinkRow(title: "アカウント") {
                        AccountSettingsDetail()
                    }
                }
            }
            SettingsSection {
                SettingsLinkRow(title: "利用枠", value: "今週 \(usage.snapshot.percent)%") {
                    UsageSettingsView()
                }
                .accessibilityIdentifier("settings-row-usage")
            }
            SettingsSection {
                ReminderRows()
                SettingsDivider()
                ThemeRow()
            }
            SettingsSection {
                SettingsLinkRow(title: "iCloud 同期", value: learnerData.iCloud.isEnabled && learnerData.iCloud.isSupported ? "オン" : "オフ") {
                    ICloudSyncSettingsDetail()
                }
                .accessibilityIdentifier("settings-row-icloud")
                SettingsDivider()
                SettingsLinkRow(title: "学習記録") {
                    LearningRecordSettingsDetail()
                }
                .accessibilityIdentifier("settings-row-learning-record")
                if Auth0Config.authenticationRequired {
                    SettingsDivider()
                    SettingsLinkRow(title: "ファイル") {
                        WorkspaceBrowserView()
                    }
                }
            }
            SettingsSection {
                SettingsExternalLinkRow(title: "利用規約", url: LegalLinks.terms)
                SettingsDivider()
                SettingsExternalLinkRow(title: "プライバシーポリシー", url: LegalLinks.privacy)
            }
            if isInternalBuild || Self.showsCodexEntry {
                SettingsSection {
                    if isInternalBuild {
                        SettingsLinkRow(title: "開発者向け") {
                            DeveloperSettingsView()
                        }
                        .accessibilityIdentifier("settings-row-developer")
                    }
                    if isInternalBuild && Self.showsCodexEntry {
                        SettingsDivider()
                    }
                    if Self.showsCodexEntry {
                        SettingsLinkRow(title: "ChatGPT / Codex", value: settings.account?.isConnected == true ? "接続済み" : "未接続") {
                            CodexSettingsDetail()
                        }
                        .accessibilityIdentifier("settings-row-codex")
                    }
                }
            }
        }
        .task {
            usage.refresh()
            isInternalBuild = await InternalBuild.resolve()
            await settings.refresh()
            await learnerData.refreshAssets(client: apiClient)
        }
    }

    /// 利用者が動かないと直らないことだけを、一番上に出す。普段は何も出ない。
    @ViewBuilder
    private var notices: some View {
        if learnerData.isDeliveryFailed {
            SettingsNotice(
                title: "質問の準備ができていません",
                detail: "必要なデータを更新できませんでした",
                actionTitle: "更新する",
                actionDisabled: learnerData.isDeliveryRefreshing
            ) {
                Task { await learnerData.refreshAssets(client: apiClient) }
            }
            .accessibilityIdentifier("settings-delivery-notice")
        }
        if settings.modelProvider == .anthropic, !settings.claudeAvailable {
            SettingsNotice(title: "この端末では使えません", detail: ModelProviderError.claudeUnavailable.localizedDescription)
                .accessibilityIdentifier("settings-model-claude-unavailable")
        }
    }
}

/// 通知のオンオフと時刻。時刻は分まで自由に選べる(オンボーディングは 3 択のまま)。
private struct ReminderRows: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOn: Bool = StudyReminder.time != nil
    @State private var selection: Date = (StudyReminder.time ?? StudyReminder.lastTime).date()
    /// iOS の設定で通知が拒否されている(時刻を選んでも届かない)。
    @State private var isDenied: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $isOn) {
                Text("通知")
                    .font(Typography.body)
                    .foregroundStyle(Theme.primaryText)
            }
            .tint(Theme.accentColor)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .accessibilityIdentifier("settings-reminder-toggle")
            if isOn {
                SettingsDivider()
                HStack(spacing: 12) {
                    Text("時刻")
                        .font(Typography.body)
                        .foregroundStyle(Theme.primaryText)
                    Spacer(minLength: 12)
                    DatePicker("時刻", selection: $selection, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                        .accessibilityIdentifier("settings-reminder-time")
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                if isDenied {
                    SettingsDivider()
                    SettingsButtonRow(title: "通知が許可されていません", detail: "iOS の設定で許可すると届きます", systemImage: SettingsChevron.symbolName) {
                        if let url: URL = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                    .accessibilityIdentifier("settings-reminder-denied")
                }
            }
        }
        .onChange(of: isOn) { (_: Bool, turnedOn: Bool) in
            if turnedOn {
                apply()
            } else {
                isDenied = false
                StudyReminder.cancel()
            }
        }
        .onChange(of: selection) { (_: Date, _: Date) in
            if isOn { apply() }
        }
        .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
            // iOS の設定から戻ってきた時に読み直す。許可されたら通知を置き直す。
            if phase == .active, isOn { apply() }
        }
        .task {
            if isOn { isDenied = await StudyReminder.isDenied() }
        }
    }

    private func apply() {
        let time: ReminderTime = ReminderTime(date: selection)
        Task {
            let granted: Bool = await StudyReminder.update(to: time)
            isDenied = !granted
        }
    }
}

/// テーマ。押すと iOS のメニューが開く。
private struct ThemeRow: View {
    @AppStorage(ThemePreference.storageKey) private var selection: ThemePreference = .system

    var body: some View {
        Menu {
            Picker("テーマ", selection: $selection) {
                ForEach(ThemePreference.allCases) { (theme: ThemePreference) in
                    Text(theme.title).tag(theme)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Text("テーマ")
                    .font(Typography.body)
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 12)
                Text(selection.title)
                    .font(Typography.body)
                    .foregroundStyle(Theme.secondaryText)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-row-theme")
    }
}

/// 学習記録: 記録を 1 つのファイルにして別の端末に移す。
private struct LearningRecordSettingsDetail: View {
    @Environment(SettingsStore.self) private var settings
    @State private var isImporterPresented: Bool = false

    var body: some View {
        @Bindable var bindable: SettingsStore = settings
        let count: Int? = settings.ledgerEventCount
        SettingsScreen(title: "学習記録") {
            SettingsSection(header: "別の端末に移す", footer: "iCloud 同期がオンなら、同じ Apple ID の端末には自動で届きます。") {
                SettingsButtonRow(
                    title: settings.ledgerBusy ? "処理中" : "書き出す",
                    detail: "記録・答案の写真・記憶を 1 つのファイルにします",
                    systemImage: "square.and.arrow.up",
                    disabled: settings.ledgerBusy
                ) {
                    Task { await settings.exportAllRecords() }
                }
                .accessibilityIdentifier("settings-ledger-export")
                SettingsDivider()
                SettingsButtonRow(
                    title: "取り込む",
                    detail: count == 0 ? "書き出したファイルから記録を戻します" : "記録が入っている端末には取り込めません",
                    disabled: settings.ledgerBusy || count != 0
                ) {
                    isImporterPresented = true
                }
                .accessibilityIdentifier("settings-ledger-import")
                LedgerExportResultRows()
            }
            if Auth0Config.authenticationRequired {
                SettingsSection(footer: "モデル名・所要時間・トークン数だけです。会話やファイルは送りません。") {
                    Toggle(isOn: $bindable.usageReportingEnabled) {
                        Text("使用量を送る")
                            .font(Typography.body)
                            .foregroundStyle(Theme.primaryText)
                    }
                    .tint(Theme.accentColor)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .accessibilityIdentifier("settings-usage-reporting")
                }
            }
        }
        .task { await settings.loadLedgerSummary() }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.zip]) { (result: Result<URL, any Error>) in
            if case .success(let url) = result {
                Task { await settings.importLedger(from: url) }
            }
        }
    }
}

/// 書き出しのあとに出す行(保存・共有と、結果の文言)。学習記録と開発者向けで共有する。
struct LedgerExportResultRows: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        if let archive: URL = settings.exportedArchive {
            SettingsDivider()
            HStack(spacing: 12) {
                Text(archive.lastPathComponent)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 12)
                ShareLink(item: archive) {
                    Text("保存・共有")
                        .font(Typography.body)
                        .foregroundStyle(Theme.primaryText)
                }
                .accessibilityIdentifier("settings-ledger-share")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
        }
        if let message: String = settings.ledgerMessage {
            SettingsDivider()
            SettingsNote(text: message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .accessibilityIdentifier("settings-ledger-message")
        }
    }
}

/// iCloud 同期 (Issue #51)。同じ Apple ID の端末どうしで、学習記録と画像・記憶を利用者の iCloud だけで同期する。
private struct ICloudSyncSettingsDetail: View {
    @Environment(LearnerData.self) private var learnerData
    @State private var isConfirmingUploadAgain: Bool = false

    private static let syncedPrefix: String = "最後に同期: "

    var body: some View {
        let sync: ICloudSync = learnerData.iCloud
        let status: String = sync.statusText
        SettingsScreen(title: "iCloud 同期") {
            SettingsSection(footer: "単元・問題・採点・会話・進み具合と、答案の写真・添付・記憶を、自分の iCloud だけに保存します。中身は暗号化され、開発者は読めません。") {
                Toggle(isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) })) {
                    Text("iCloud 同期")
                        .font(Typography.body)
                        .foregroundStyle(Theme.primaryText)
                }
                .tint(Theme.accentColor)
                .disabled(!sync.isSupported)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .accessibilityIdentifier("settings-icloud-toggle")
                SettingsDivider()
                Group {
                    if status.hasPrefix(Self.syncedPrefix) {
                        SettingsValueRow(title: "最後に同期", value: String(status.dropFirst(Self.syncedPrefix.count)))
                    } else {
                        SettingsValueRow(title: "状態", value: status)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings-icloud-status")
                if sync.counts.unsent > 0 {
                    SettingsDivider()
                    SettingsValueRow(title: "未送信", value: "\(sync.counts.unsent) 件")
                        .accessibilityElement(children: .combine)
                }
                if sync.counts.pending > 0 {
                    SettingsDivider()
                    SettingsValueRow(title: "保留中", value: "\(sync.counts.pending) 件(アプリを更新すると取り込みます)")
                        .accessibilityElement(children: .combine)
                }
                if let message: String = sync.message {
                    SettingsDivider()
                    SettingsNote(text: message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("settings-icloud-message")
                }
            }
            SettingsSection(footer: "iCloud の記録を消して、この端末の内容に置き換えます。ほかの端末の記録も次に開いた時に置き換わり、置き換える前の記録はその端末に 1 つ残ります。") {
                SettingsButtonRow(
                    title: sync.isUploadingAgain ? "処理中" : "この端末の内容で上げ直す",
                    tone: .destructive,
                    disabled: !sync.isSupported || !sync.isEnabled || sync.isUploadingAgain
                ) {
                    isConfirmingUploadAgain = true
                }
                .accessibilityIdentifier("settings-icloud-upload-again")
            }
        }
        .task { await sync.refreshCounts() }
        .confirmationDialog("iCloud のデータを上げ直しますか？", isPresented: $isConfirmingUploadAgain, titleVisibility: .visible) {
            Button("消して上げ直す", role: .destructive) {
                Task { await sync.uploadAgain() }
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("iCloud にある記録を消して、この端末の記録と画像・記憶を上げ直します。ほかの端末の記録は、この内容に置き換わります")
        }
    }
}

private struct AccountSettingsDetail: View {
    @Environment(BootstrapStore.self) private var bootstrap
    @Environment(AuthStore.self) private var auth

    var body: some View {
        SettingsScreen(title: "アカウント") {
            SettingsSection {
                SettingsValueRow(title: "表示名", value: bootstrap.user?.displayName ?? "Learner")
                SettingsDivider()
                SettingsValueRow(title: "メール", value: bootstrap.user?.email ?? "メール未設定")
            }
            SettingsSection {
                SettingsButtonRow(title: "この端末からログアウト", tone: .destructive) {
                    auth.logout()
                }
            }
        }
    }
}

/// ChatGPT / Codex の接続。経路は選択肢から外した(#40)ので、DEBUG の検証(`-show-codex-settings`)でだけ開ける。
private struct CodexSettingsDetail: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        SettingsScreen(title: "ChatGPT / Codex 接続") {
            if settings.account?.isConnected == true {
                SettingsSection {
                    SettingsValueRow(title: "状態", value: statusLabel)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings-codex-status")
                    SettingsDivider()
                    SettingsValueRow(title: "接続アカウント", value: settings.account?.accountEmail ?? "メール未取得")
                    SettingsDivider()
                    SettingsValueRow(title: "プラン", value: CodexPlanName.display(settings.account?.planType) ?? "—")
                    SettingsDivider()
                    SettingsValueRow(title: "使用中", value: usageLabel)
                    SettingsDivider()
                    SettingsValueRow(title: "残り", value: remainingLabel)
                    SettingsDivider()
                    SettingsValueRow(title: "リセット", value: resetLabel)
                    SettingsDivider()
                    SettingsValueRow(title: "最終同期", value: lastSyncedLabel)
                }
                SettingsSection {
                    SettingsButtonRow(title: "再同期", disabled: settings.busy) {
                        Task { await settings.sync() }
                    }
                    SettingsDivider()
                    SettingsButtonRow(title: "接続解除", tone: .destructive, disabled: settings.busy) {
                        Task { await settings.disconnect() }
                    }
                }
            } else {
                SettingsSection(footer: "ChatGPT / Codex を接続すると、学習チャットで利用できます。") {
                    SettingsValueRow(title: "状態", value: statusLabel)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings-codex-status")
                    SettingsDivider()
                    SettingsButtonRow(title: settings.busy ? "接続中" : "接続する", disabled: settings.busy) {
                        Task { await settings.connect() }
                    }
                    .accessibilityIdentifier("settings-codex-connect")
                }
            }
            if let code: String = settings.account?.userCode {
                verificationSection(code: code, url: settings.account?.verificationURL)
            }
            if let message: String = settings.errorMessage {
                SettingsSection {
                    Text(message)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.regressColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("settings-codex-error")
                }
            }
        }
    }

    private func verificationSection(code: String, url: String?) -> some View {
        SettingsSection(header: "認証コード") {
            VStack(alignment: .leading, spacing: 8) {
                Text(code)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityIdentifier("settings-codex-user-code")
                if let url, let link: URL = URL(string: url) {
                    Link("認証ページを開く", destination: link)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.primaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var usageLabel: String {
        guard let used: Double = settings.account?.rateLimitPrimaryNumber("usedPercent") else { return "取得待ち" }
        return "\(Int(used.rounded()))% 使用中"
    }

    private var remainingLabel: String {
        guard let remaining: Double = settings.account?.rateLimitPrimaryNumber("remaining") else { return "取得待ち" }
        return "\(Int(remaining.rounded()))"
    }

    private var resetLabel: String {
        guard let date: Date = settings.account?.rateLimitResetsAt else { return "取得待ち" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var lastSyncedLabel: String {
        guard let date: Date = settings.account?.lastSyncedAt else { return "未同期" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var statusLabel: String {
        guard let status = settings.account?.status else { return "未取得" }
        switch status {
        case .connected: return "接続済み"
        case .connecting: return "接続中"
        case .rateLimited: return "利用枠待ち"
        case .error: return "要確認"
        case .disconnected: return "未接続"
        }
    }
}

private extension CodexAccount {
    func rateLimitPrimaryNumber(_ key: String) -> Double? {
        guard let primary = rateLimitPrimary else { return nil }
        return primary[key]?.numberValue
    }

    private var rateLimitPrimary: [String: AnyJSONValue]? {
        guard case let .object(root) = rateLimitStatus?.value else { return nil }
        if case let .object(rateLimits)? = root["rateLimits"],
           case let .object(primary)? = rateLimits["primary"] {
            return primary
        }
        if case let .object(buckets)? = root["rateLimitsByLimitId"] {
            for bucket in buckets.values {
                guard case let .object(bucketObject) = bucket else { continue }
                if case let .string(limitId)? = bucketObject["limitId"], limitId != "codex" {
                    continue
                }
                if case let .object(primary)? = bucketObject["primary"] {
                    return primary
                }
            }
        }
        return nil
    }
}

private extension AnyJSONValue {
    var numberValue: Double? {
        if case let .number(value) = self {
            return value
        }
        return nil
    }
}

/// ChatGPT のプランの、学習者に見せる名前(D13)。Codex が返す内部の識別子をそのまま出さない。
/// 知っている識別子だけを名前にし、知らないものは nil(画面には出さない)。架空のプラン名で埋めない。
enum CodexPlanName {
    static func display(_ planType: String?) -> String? {
        guard let key = planType?.trimmingCharacters(in: .whitespaces).lowercased(), !key.isEmpty else { return nil }
        return names[key]
    }

    private static let names: [String: String] = [
        "free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "team": "Team", "business": "Business",
        "enterprise": "Enterprise", "edu": "Edu", "education": "Edu",
    ]
}
