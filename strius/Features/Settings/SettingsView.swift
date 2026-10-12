import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(BootstrapStore.self) private var bootstrap
    @Environment(APIClient.self) private var apiClient
    @Environment(LearnerData.self) private var learnerData
    @Environment(\.colorScheme) private var scheme

    /// オンボーディングをもう一度見る。nil の入口(質問画面の設定)では行を出さない。
    let onReplayOnboarding: (() -> Void)?

    init(onReplayOnboarding: (() -> Void)? = nil) {
        self.onReplayOnboarding = onReplayOnboarding
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statusPill
                settingsList
                if onReplayOnboarding != nil {
                    onboardingRow
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 36)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollContentBackground(.hidden)
        .task {
            await settings.refresh()
            await learnerData.refreshAssets(client: apiClient)
        }
    }

    private var settingsList: some View {
        VStack(spacing: 0) {
            if Auth0Config.authenticationRequired {
                SettingsHomeRow(
                    icon: "person",
                    title: "アカウント",
                    detail: accountDetail,
                    value: "管理"
                ) {
                    AccountSettingsDetail()
                }
                divider
            }
            SettingsHomeRow(
                icon: "sparkle",
                title: "ChatGPT / Codex",
                detail: settings.account?.isConnected == true ? [planLabel, "接続済み"].compactMap { $0 }.joined(separator: " / ") : "未接続",
                value: settings.account?.isConnected == true ? "接続済み" : "接続"
            ) {
                CodexSettingsDetail()
            }
            .accessibilityIdentifier("settings-row-codex")
            divider
            SettingsHomeRow(
                icon: "cpu",
                title: "AIモデル",
                detail: modelDetail,
                value: settings.modelProvider.displayName
            ) {
                ModelProviderSettingsDetail()
            }
            .accessibilityIdentifier("settings-row-model")
            divider
            SettingsHomeRow(
                icon: "arrow.down.circle",
                title: "配信データ",
                detail: learnerData.deliverySummary,
                value: learnerData.requiresDelivery && !learnerData.isDeliveryReady ? "更新" : "利用可"
            ) {
                DeliverySettingsDetail()
            }
            .accessibilityIdentifier("settings-row-delivery")
            divider
            if Auth0Config.authenticationRequired {
                SettingsHomeRow(
                    icon: "folder",
                    title: "ファイル",
                    detail: "Workspaceの内容",
                    value: "表示"
                ) {
                    WorkspaceBrowserView()
                }
                divider
            }
            SettingsHomeRow(
                icon: "line.3.horizontal",
                title: "表示",
                detail: "テーマ、レイアウト幅",
                value: "システム"
            ) {
                DisplaySettingsDetail()
            }
            divider
            SettingsHomeRow(
                icon: "externaldrive",
                title: "詳細設定",
                detail: "端末データ",
                value: "管理"
            ) {
                AdvancedSettingsDetail()
            }
            .accessibilityIdentifier("settings-row-advanced")
        }
        .settingsCard()
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isReady ? Theme.growth(scheme) : Theme.textTertiary(scheme))
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(Typography.caption)
                .foregroundStyle(Theme.textPrimary(scheme))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassSurface(.thin, in: Capsule())
    }

    /// オンボーディングをもう一度見る(Release でも出す)。
    private var onboardingRow: some View {
        SettingsActionRow(
            title: "オンボーディング",
            detail: "最初の画面をもう一度見ます",
            actionTitle: "もう一度見る",
            action: { onReplayOnboarding?() }
        )
        .settingsCard()
        .accessibilityIdentifier("settings-replay-onboarding")
    }

    /// 選んでいる実行先で質問できるか(GPT は ChatGPT の接続、Claude は API キー)。
    private var isReady: Bool {
        settings.modelProvider == .anthropic ? settings.claudeAvailable : settings.account?.isConnected == true
    }

    private var statusText: String {
        if settings.modelProvider == .anthropic {
            return settings.claudeAvailable ? "Claude / App Attest" : "Claude / この端末では使えません"
        }
        return settings.account?.isConnected == true ? ["Codex接続済み", planLabel].compactMap { $0 }.joined(separator: " / ") : "Codex未接続"
    }

    private var modelDetail: String {
        switch settings.modelProvider {
        case .openai: return "ChatGPT / Codex で GPT を使う"
        case .anthropic: return settings.claudeAvailable ? "App Attest で Claude を使う" : "この端末では Claude を使えません"
        }
    }

    private var accountDetail: String {
        let name = bootstrap.user?.displayName ?? "Learner"
        if let email = bootstrap.user?.email, !email.isEmpty {
            return "\(name) / \(email)"
        }
        return name
    }

    /// 学習者に見せるプランの名前。内部の識別子(`prolite` など)はそのまま出さない(D13)。分からなければ出さない。
    private var planLabel: String? {
        CodexPlanName.display(settings.account?.planType)
    }

    private var divider: some View {
        SettingsDivider()
    }
}

private struct DeliverySettingsDetail: View {
    @Environment(APIClient.self) private var apiClient
    @Environment(LearnerData.self) private var learnerData
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SettingsDetailScaffold(eyebrow: "DELIVERY", title: "配信データ") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("質問の準備")
                        .font(Typography.heading2)
                    Text("質問に使うプロンプトとスキーマをこの端末に保存します。")
                        .font(Typography.bodyCompact)
                        .foregroundStyle(Theme.textSecondary(scheme))
                }

                VStack(spacing: 0) {
                    SettingsInfoRow(title: "状態", detail: learnerData.deliveryDetail)
                    SettingsDivider()
                    SettingsActionRow(
                        title: "配信データ",
                        detail: learnerData.deliverySummary,
                        actionTitle: learnerData.isDeliveryRefreshing ? "更新中" : "更新",
                        disabled: learnerData.isDeliveryRefreshing || !learnerData.requiresDelivery
                    ) {
                        Task { await learnerData.refreshAssets(client: apiClient) }
                    }
                    .accessibilityIdentifier("settings-delivery-refresh")
                }
                .settingsCard()
            }
        }
    }
}

/// GPT と Claude の切り替え。どちらも端末内の Codex で動き、Claude は API キーで直接呼ぶ。
private struct ModelProviderSettingsDetail: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var settings = settings
        SettingsDetailScaffold(eyebrow: "MODEL", title: "AIモデル") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("使うモデル")
                        .font(Typography.heading2)
                    Text("新しく始める会話・単元づくり・採点から切り替わります。続きの会話は、始めたときのモデルのまま続きます。")
                        .font(Typography.bodyCompact)
                        .foregroundStyle(Theme.textSecondary(scheme))
                }
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        ProviderSegmented(selection: $settings.modelProvider)
                        Text(providerSummary)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary(scheme))
                            .accessibilityIdentifier("settings-model-summary")
                    }
                    .padding(16)
                }
                .settingsCard()

                if settings.modelProvider == .anthropic, !settings.claudeAvailable {
                    Text(ModelProviderError.claudeUnavailable.localizedDescription)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.regress(scheme))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .settingsCard()
                        .accessibilityIdentifier("settings-model-claude-unavailable")
                }
            }
        }
    }

    private var providerSummary: String {
        switch settings.modelProvider {
        case .openai:
            return "ChatGPT / Codex の接続で \(CodexModels.astraModel) を使います。"
        case .anthropic:
            return "\(ClaudeModels.displayName(ClaudeModels.astraModel)) を使います(下調べは \(ClaudeModels.displayName(ClaudeModels.lunaModel)))。この iPhone の Struis が正規のアプリであることを App Attest で示し、Anthropic に直接送ります。API キーや中継サーバーはありません。"
        }
    }
}

private struct ProviderSegmented: View {
    @Binding var selection: ModelProvider
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ModelProvider.allCases, id: \.self) { provider in
                Button {
                    selection = provider
                } label: {
                    Text(provider.displayName)
                        .font(Typography.bodyEmphasized)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(selection == provider ? Color(uiColor: .systemBackground) : Theme.textSecondary(scheme))
                        .background(selection == provider ? Theme.textPrimary(scheme) : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-model-\(provider.rawValue)")
                .accessibilityAddTraits(selection == provider ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
    }
}

private struct SettingsHomeRow<Destination: View>: View {
    let icon: String
    let title: String
    let detail: String
    let value: String
    @ViewBuilder let destination: Destination

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 14) {
                iconView
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Typography.title)
                        .foregroundStyle(Theme.textPrimary(scheme))
                    Text(detail)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary(scheme))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                HStack(spacing: 7) {
                    Text(value)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary(scheme))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconView: some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(Theme.accent(scheme))
            .frame(width: 44, height: 44)
            .background(Theme.accent(scheme).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AccountSettingsDetail: View {
    @Environment(BootstrapStore.self) private var bootstrap
    @Environment(AuthStore.self) private var auth
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SettingsDetailScaffold(eyebrow: "ACCOUNT", title: "アカウント") {
            VStack(spacing: 0) {
                SettingsInfoRow(title: "表示名", detail: bootstrap.user?.displayName ?? "Learner")
                SettingsDivider()
                SettingsInfoRow(title: "メール", detail: bootstrap.user?.email ?? "メール未設定")
                SettingsDivider()
                Button(role: .destructive) {
                    auth.logout()
                } label: {
                    HStack {
                        Text("この端末からログアウト")
                            .font(Typography.bodyEmphasized)
                            .foregroundStyle(Theme.regress(scheme))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                }
                .buttonStyle(.plain)
            }
            .settingsCard()
        }
    }
}

private struct CodexSettingsDetail: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SettingsDetailScaffold(eyebrow: "CODEX", title: "ChatGPT / Codex 接続") {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader
                if settings.account?.isConnected == true {
                    metricGrid
                    connectedRows
                } else {
                    disconnectedRows
                }
                if let code = settings.account?.userCode {
                    verificationBox(code: code, url: settings.account?.verificationURL)
                }
                if let message = settings.errorMessage {
                    Text(message)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.regress(scheme))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .settingsCard()
                        .accessibilityIdentifier("settings-codex-error")
                }
            }
        }
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(statusLabel)
                    .font(Typography.caption)
                    .foregroundStyle(statusColor)
                    .accessibilityIdentifier("settings-codex-status")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassSurface(.thin, in: Capsule())
                Spacer()
            }
            Text(settings.account?.accountEmail ?? "学習に使う自分の ChatGPT / Codex アカウントを管理します。")
                .font(Typography.bodyCompact)
                .foregroundStyle(Theme.textSecondary(scheme))
        }
    }

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            SettingsMetric(label: "プラン", value: CodexPlanName.display(settings.account?.planType) ?? "—")
            SettingsMetric(label: "使用中", value: usageLabel)
            SettingsMetric(label: "残り", value: remainingLabel)
            SettingsMetric(label: "リセット", value: resetLabel)
            SettingsMetric(label: "最終同期", value: lastSyncedLabel)
            SettingsMetric(label: "状態", value: statusLabel)
        }
    }

    private var connectedRows: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("接続アカウント")
                        .font(Typography.bodyEmphasized)
                    Text(settings.account?.accountEmail ?? "メール未取得")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary(scheme))
                }
                Spacer()
                Button {
                    Task { await settings.sync() }
                } label: {
                    Label("再同期", systemImage: "clock.arrow.circlepath")
                }
                .settingsActionButton()
                .disabled(settings.busy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            SettingsDivider()
            Button {
                Task { await settings.disconnect() }
            } label: {
                HStack {
                    Text("接続解除")
                        .font(Typography.bodyEmphasized)
                        .foregroundStyle(Theme.regress(scheme))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
            }
            .buttonStyle(.plain)
            .disabled(settings.busy)
        }
        .settingsCard()
    }

    private var disconnectedRows: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("ChatGPTアカウント")
                    .font(Typography.bodyEmphasized)
                Text("ChatGPT / Codex を接続すると、学習チャットで利用できます。")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
            }
            Spacer()
            Button {
                Task { await settings.connect() }
            } label: {
                Label(settings.busy ? "接続中" : "接続", systemImage: "sparkles")
            }
            .settingsActionButton(prominent: true)
            .disabled(settings.busy)
            .accessibilityIdentifier("settings-codex-connect")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .settingsCard()
    }

    private func verificationBox(code: String, url: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("認証コード")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
            Text(code)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .accessibilityIdentifier("settings-codex-user-code")
            if let url, let link = URL(string: url) {
                Link("認証ページを開く", destination: link)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.accent(scheme))
            }
        }
        .padding(16)
        .settingsCard()
    }

    private var usageLabel: String {
        guard let used = settings.account?.rateLimitPrimaryNumber("usedPercent") else { return "取得待ち" }
        return "\(Int(used.rounded()))% 使用中"
    }

    private var remainingLabel: String {
        guard let remaining = settings.account?.rateLimitPrimaryNumber("remaining") else { return "取得待ち" }
        return "\(Int(remaining.rounded()))"
    }

    private var resetLabel: String {
        guard let date = settings.account?.rateLimitResetsAt else { return "取得待ち" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var lastSyncedLabel: String {
        guard let date = settings.account?.lastSyncedAt else { return "未同期" }
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

    private var statusColor: Color {
        settings.account?.isConnected == true ? Theme.growth(scheme) : Theme.textSecondary(scheme)
    }
}

private struct DisplaySettingsDetail: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("settings.themePreference") private var themePreference = "system"

    var body: some View {
        SettingsDetailScaffold(eyebrow: "DISPLAY", title: "表示") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("表示とレイアウト")
                        .font(Typography.heading2)
                    Text("この端末だけに保存される見た目と作業面の設定。")
                        .font(Typography.bodyCompact)
                        .foregroundStyle(Theme.textSecondary(scheme))
                }
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("テーマ")
                                .font(Typography.bodyEmphasized)
                            Text(themePreferenceSummary)
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary(scheme))
                        }
                        ThemeSegmented(selection: $themePreference)
                    }
                    .padding(16)
                    SettingsDivider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("レイアウト幅")
                                .font(Typography.bodyEmphasized)
                            Text("サイドバーと作業面の幅")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary(scheme))
                        }
                        Spacer()
                        Button("リセット") {
                            // Reserved for future iPad/sidebar sizing settings.
                        }
                        .settingsActionButton()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                }
                .settingsCard()
            }
        }
    }

    private var themePreferenceSummary: String {
        switch themePreference {
        case "light": return "現在はライトです"
        case "dark": return "現在はダークです"
        default: return "システム設定に合わせます"
        }
    }
}

private struct AdvancedSettingsDetail: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @State private var isImporterPresented = false

    var body: some View {
        SettingsDetailScaffold(eyebrow: "ADVANCED", title: "詳細設定") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("詳細設定")
                        .font(Typography.heading2)
                    Text("この端末に保存されたデータ")
                        .font(Typography.bodyCompact)
                        .foregroundStyle(Theme.textSecondary(scheme))
                }
                VStack(spacing: 0) {
                    SettingsActionRow(title: "下書き", detail: "保存なし", actionTitle: "削除", destructive: true, disabled: true) {}
                    SettingsDivider()
                    SettingsActionRow(title: "キャッシュ", detail: "保存なし", actionTitle: "削除", destructive: true, disabled: true) {}
                }
                .settingsCard()
                VStack(alignment: .leading, spacing: 4) {
                    Text("学習記録")
                        .font(Typography.heading2)
                    Text("記録はこの端末だけにあります。書き出したファイルで別の端末に移せます")
                        .font(Typography.bodyCompact)
                        .foregroundStyle(Theme.textSecondary(scheme))
                }
                ledgerCard
                VStack(alignment: .leading, spacing: 4) {
                    Text("実行環境")
                        .font(Typography.heading2)
                    Text("この端末で動く Codex と Python")
                        .font(Typography.bodyCompact)
                        .foregroundStyle(Theme.textSecondary(scheme))
                }
                let runtime = settings.runtimeSummary
                VStack(spacing: 0) {
                    SettingsInfoRow(title: "Hyotan", detail: runtime.hyotanVersion)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings-runtime-hyotan")
                    SettingsDivider()
                    SettingsInfoRow(
                        title: "Codex / Python",
                        detail: runtime.codexVersion.map { "\($0) / 3.14" } ?? "-"
                    )
                    SettingsDivider()
                    SettingsInfoRow(title: "起動", detail: runtime.bootState + durationSuffix(runtime.installSeconds, label: "準備") + durationSuffix(runtime.bootSeconds, label: "起動"))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings-runtime-boot")
                    SettingsDivider()
                    SettingsInfoRow(title: "Codex app-server", detail: runtime.appServerState + durationSuffix(runtime.initializeSeconds, label: "initialize"))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings-runtime-appserver")
                }
                .settingsCard()
            }
        }
    }

    @ViewBuilder
    private var ledgerCard: some View {
        @Bindable var settings = settings
        let count = settings.ledgerEventCount
        VStack(spacing: 0) {
            SettingsActionRow(
                title: "書き出す",
                detail: count.map { "\($0) 件の記録と画像・記憶を zip に" } ?? "記録と画像・記憶を zip に",
                actionTitle: settings.ledgerBusy ? "処理中" : "書き出す",
                disabled: settings.ledgerBusy
            ) {
                Task { await settings.exportLedger() }
            }
            .accessibilityIdentifier("settings-ledger-export")
            if let archive = settings.exportedArchive {
                SettingsDivider()
                HStack {
                    Text(archive.lastPathComponent)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary(scheme))
                        .lineLimit(1)
                    Spacer()
                    ShareLink(item: archive) { Text("保存・共有") }
                        .accessibilityIdentifier("settings-ledger-share")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            SettingsDivider()
            SettingsActionRow(
                title: "取り込む",
                detail: count == 0 ? "書き出したファイルから記録を戻す" : "空の端末でだけ取り込めます",
                actionTitle: "選ぶ",
                disabled: settings.ledgerBusy || count != 0
            ) {
                isImporterPresented = true
            }
            .accessibilityIdentifier("settings-ledger-import")
            if Auth0Config.authenticationRequired {
                SettingsDivider()
                Toggle(isOn: $settings.usageReportingEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("使用量を送る")
                            .font(Typography.bodyEmphasized)
                        Text("モデル名・所要時間・トークン数だけ。会話やファイルは送りません")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary(scheme))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .accessibilityIdentifier("settings-usage-reporting")
            }
            if let message = settings.ledgerMessage {
                SettingsDivider()
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("settings-ledger-message")
            }
        }
        .settingsCard()
        .task { await settings.loadLedgerSummary() }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result {
                Task { await settings.importLedger(from: url) }
            }
        }
    }

    private func durationSuffix(_ seconds: Double?, label: String) -> String {
        guard let seconds else { return "" }
        return " (\(label) \(String(format: "%.1f", seconds))s)"
    }
}

private struct SettingsDetailScaffold<Content: View>: View {
    let eyebrow: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(eyebrow)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.accent(.dark))
                        .textCase(.uppercase)
                    Text(title)
                        .font(Typography.heroSerif)
                }
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 36)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let detail: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Typography.bodyEmphasized)
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
    }
}

private struct SettingsActionRow: View {
    let title: String
    let detail: String
    let actionTitle: String
    var destructive = false
    var disabled = false
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Typography.bodyEmphasized)
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
            }
            Spacer()
            Button(actionTitle, action: action)
                .settingsActionButton(destructive: destructive)
                .disabled(disabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
    }
}

private struct SettingsMetric: View {
    let label: String
    let value: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(Typography.micro)
                .foregroundStyle(Theme.textTertiary(scheme))
            Text(value)
                .font(Typography.bodyEmphasized)
                .foregroundStyle(Theme.textPrimary(scheme))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .settingsCard(cornerRadius: Theme.Radius.stat)
    }
}

private struct ThemeSegmented: View {
    @Binding var selection: String
    @Environment(\.colorScheme) private var scheme

    private let options = [
        ("light", "ライト"),
        ("dark", "ダーク"),
        ("system", "システム")
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    selection = value
                } label: {
                    Text(label)
                        .font(Typography.bodyEmphasized)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(selection == value ? Color(uiColor: .systemBackground) : Theme.textSecondary(scheme))
                        .background(selection == value ? Theme.textPrimary(scheme) : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
    }
}

private struct SettingsDivider: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(Theme.separator(scheme))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

private struct SettingsCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
            }
    }
}

private struct SettingsActionButtonModifier: ViewModifier {
    var prominent = false
    var destructive = false

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .font(Typography.caption)
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background, in: Capsule())
            .buttonStyle(.plain)
    }

    private var foreground: Color {
        if destructive { return Theme.regress(scheme) }
        if prominent { return Color(uiColor: .systemBackground) }
        return Theme.textPrimary(scheme)
    }

    private var background: Color {
        if prominent { return Theme.textPrimary(scheme) }
        if destructive { return Theme.regress(scheme).opacity(0.12) }
        return Color(uiColor: .tertiarySystemGroupedBackground)
    }
}

private extension View {
    func settingsCard(cornerRadius: CGFloat = Theme.Radius.cardLarge) -> some View {
        modifier(SettingsCardModifier(cornerRadius: cornerRadius))
    }

    func settingsActionButton(prominent: Bool = false, destructive: Bool = false) -> some View {
        modifier(SettingsActionButtonModifier(prominent: prominent, destructive: destructive))
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
