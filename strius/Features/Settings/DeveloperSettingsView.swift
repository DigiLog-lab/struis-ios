import StoreKit
import SwiftUI

/// App Store の本番か、内部の配布(Xcode・プロトタイプ・TestFlight)か。
/// 料金やトークンなどの内部情報は内部の配布にだけ出す。判定できない時は本番として隠す。
nonisolated enum InternalBuild {
    /// プロトタイプの Bundle ID か(`com.digiloglab.strius.preview.s01` など。`AGENT_BUNDLE_PREFIX`)。
    static func isPrototype(bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.contains(".preview") ?? false
    }

    /// ビルドと Bundle ID だけで内部と分かるか。TestFlight は App Store と同じビルドなのでここでは分からない。
    static var isKnownInternal: Bool {
        #if DEBUG
        return true
        #else
        return isPrototype(bundleIdentifier: Bundle.main.bundleIdentifier)
        #endif
    }

    /// 内部の配布か。TestFlight は App Store の取引情報の環境(sandbox)で見分ける。
    static func resolve() async -> Bool {
        if isKnownInternal { return true }
        guard let result: VerificationResult<AppTransaction> = try? await AppTransaction.shared,
              case .verified(let transaction) = result else { return false }
        return transaction.environment == .sandbox || transaction.environment == .xcode
    }
}

/// 開発者向け: AI モデル・料金・トークン・実行環境・配信データ・調べる用の書き出し。本番には出さない。
struct DeveloperSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LearnerData.self) private var learnerData
    @Environment(APIClient.self) private var apiClient

    var body: some View {
        SettingsScreen(title: "開発者向け") {
            modelSection
            costSection
            tokenSection
            runtimeSection
            deliverySection
            exportSection
        }
        .task { await settings.loadLedgerSummary() }
    }

    // MARK: - AI モデル

    @ViewBuilder
    private var modelSection: some View {
        @Bindable var bindable: SettingsStore = settings
        SettingsSection(header: "AI モデル") {
            HStack(spacing: 12) {
                Text("タイムライン")
                    .font(Typography.body)
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 12)
                Picker("タイムライン", selection: $bindable.timelineClaudeModel) {
                    ForEach(TimelineModelPreference.choices, id: \.self) { (model: String) in
                        Text(Self.shortName(model)).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                .accessibilityIdentifier("settings-timeline-model")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            SettingsDivider()
            SettingsValueRow(title: "質問", value: Self.shortName(ClaudeModels.astraModel))
            SettingsDivider()
            SettingsValueRow(title: "下調べ", value: Self.shortName(ClaudeModels.lunaModel))
            SettingsDivider()
            SettingsValueRow(
                title: "知識グラフ",
                value: Self.shortName(TimelineModels.fallback(role: TimelineModels.graphRole)?.model ?? "-")
            )
        }
    }

    // MARK: - 料金

    private var costSection: some View {
        SettingsSection(header: "今月の Claude の料金") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(totalCostText)
                    .font(Typography.sans(size: 30, weight: .bold, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.primaryText)
                    .monospacedDigit()
                    .accessibilityIdentifier("settings-token-usage-cost")
                Spacer(minLength: 12)
                Text("公開価格からの概算")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            ForEach(settings.monthlyTokenUsage?.models.filter { $0.estimatedCostUSD != nil } ?? []) { (usage: TokenUsageSummary.Model) in
                SettingsDivider()
                SettingsValueRow(title: Self.shortName(usage.model), value: Self.costText(usage))
            }
            let timeline: [TimelineCostSummary.Model] = settings.monthlyTimelineCost?.models.filter { $0.answers > 0 } ?? []
            if !timeline.isEmpty {
                SettingsDivider()
                Text("タイムラインの 1 問あたり")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                ForEach(timeline) { (usage: TimelineCostSummary.Model) in
                    timelineRow(usage)
                }
                Color.clear.frame(height: 10)
            }
        }
    }

    private var totalCostText: String {
        guard let cost: Double = settings.monthlyTokenUsage?.estimatedCostUSD else { return "記録なし" }
        return String(format: "約 $%.2f", cost)
    }

    private func timelineRow(_ usage: TimelineCostSummary.Model) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.shortName(usage.model))
                    .font(Typography.body)
                    .foregroundStyle(Theme.primaryText)
                Text("\(usage.answers) 問・合計 \(String(format: "$%.2f", usage.estimatedCostUSD))")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            Text(usage.perAnswerUSD.map { String(format: usage.costIncomplete ? "$%.3f 以上" : "$%.3f", $0) } ?? "-")
                .font(Typography.body)
                .foregroundStyle(Theme.primaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-timeline-cost-\(usage.model)")
    }

    private static func costText(_ usage: TokenUsageSummary.Model) -> String {
        guard let cost: Double = usage.estimatedCostUSD else { return "-" }
        return String(format: usage.costIncomplete ? "約 $%.2f 以上" : "約 $%.2f", cost)
    }

    // MARK: - トークン

    private var tokenSection: some View {
        let models: [TokenUsageSummary.Model] = settings.monthlyTokenUsage?.models ?? []
        return SettingsSection(header: "今月のトークン") {
            if models.isEmpty {
                SettingsValueRow(title: "使用量", value: "まだ記録がありません")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Self.headerCell("モデル").gridColumnAlignment(.leading)
                            Self.headerCell("入力")
                            Self.headerCell("キャッシュ")
                            Self.headerCell("出力")
                            Self.headerCell("回")
                        }
                        ForEach(models) { (usage: TokenUsageSummary.Model) in
                            GridRow {
                                Self.valueCell(Self.shortName(usage.model))
                                    .gridColumnAlignment(.leading)
                                    .accessibilityIdentifier("settings-token-usage-\(usage.model)")
                                Self.valueCell(Self.compact(usage.inputTokens))
                                Self.valueCell(Self.compact(usage.cachedInputTokens))
                                Self.valueCell(Self.compact(usage.outputTokens))
                                Self.valueCell("\(usage.executions)")
                            }
                        }
                    }
                    if let note: String = Self.tokenNote(models) {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        SettingsNote(text: note)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private static func headerCell(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Theme.secondaryText)
    }

    private static func valueCell(_ text: String) -> some View {
        Text(text)
            .font(Typography.bodyCompact)
            .foregroundStyle(Theme.primaryText)
            .monospacedDigit()
    }

    private static func tokenNote(_ models: [TokenUsageSummary.Model]) -> String? {
        let write5m: Int = models.reduce(0) { $0 + $1.cacheWrite5mTokens }
        let write1h: Int = models.reduce(0) { $0 + $1.cacheWrite1hTokens }
        let extra: Int = models.reduce(0) { $0 + $1.extraRequests }
        var lines: [String] = []
        if write5m > 0 || write1h > 0 { lines.append("キャッシュ書き込み 5分 \(compact(write5m))・1時間 \(compact(write1h))") }
        if extra > 0 { lines.append("追加の要求 \(extra) 回") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func compact(_ number: Int) -> String {
        number.formatted(.number.notation(.compactName).locale(Locale(identifier: "en_US")))
    }

    /// 「Claude Haiku 5.5」→「Haiku 5.5」。表の幅に収めるため。
    private static func shortName(_ model: String) -> String {
        ClaudeModels.displayName(model).replacingOccurrences(of: "Claude ", with: "")
    }

    // MARK: - 実行環境

    private var runtimeSection: some View {
        let runtime: DeviceRuntimeSummary = settings.runtimeSummary
        return SettingsSection(header: "実行環境") {
            SettingsValueRow(title: "Hyotan", value: runtime.hyotanVersion)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings-runtime-hyotan")
            SettingsDivider()
            SettingsValueRow(title: "起動", value: runtime.bootState + Self.duration(runtime.installSeconds, label: "準備") + Self.duration(runtime.bootSeconds, label: "起動"))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings-runtime-boot")
        }
    }

    private static func duration(_ seconds: Double?, label: String) -> String {
        guard let seconds else { return "" }
        return "・\(label) \(String(format: "%.1f", seconds))s"
    }

    // MARK: - 配信データ

    private var deliverySection: some View {
        SettingsSection(header: "配信データ") {
            SettingsValueRow(title: "状態", value: learnerData.deliverySummary)
            SettingsDivider()
            SettingsButtonRow(
                title: learnerData.isDeliveryRefreshing ? "更新中" : "更新する",
                disabled: learnerData.isDeliveryRefreshing || !learnerData.requiresDelivery
            ) {
                Task { await learnerData.refreshAssets(client: apiClient) }
            }
            .accessibilityIdentifier("settings-delivery-refresh")
        }
    }

    // MARK: - 調べる用の書き出し

    @ViewBuilder
    private var exportSection: some View {
        @Bindable var bindable: SettingsStore = settings
        SettingsSection(header: "調べる用に書き出す", footer: "取り込みには使えません。") {
            Picker("書き出す期間", selection: $bindable.exportPeriod) {
                ForEach(LedgerArchive.Period.allCases.filter { $0 != .all }) { (period: LedgerArchive.Period) in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityIdentifier("settings-ledger-export-period")
            SettingsDivider()
            Toggle(isOn: $bindable.exportIncludesFiles) {
                Text("答案の写真・添付・記憶も入れる")
                    .font(Typography.bodyCompact)
                    .foregroundStyle(Theme.primaryText)
            }
            .tint(Theme.accentColor)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .accessibilityIdentifier("settings-ledger-export-files")
            SettingsDivider()
            SettingsButtonRow(
                title: settings.ledgerBusy ? "処理中" : "書き出す",
                systemImage: "square.and.arrow.up",
                disabled: settings.ledgerBusy
            ) {
                Task { await settings.exportLedger() }
            }
            .accessibilityIdentifier("settings-ledger-export-partial")
            LedgerExportResultRows()
        }
    }
}
