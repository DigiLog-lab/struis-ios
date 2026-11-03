import StoreKit
import SwiftUI

/// 今週の利用の見え方(#40 の 11・12、#62)。使用額かプランが変わったら読み直す。
@Observable
@MainActor
final class UsageStatus {
    private(set) var snapshot: UsageSnapshot
    private let meter: UsageMeter
    private var observer: NSObjectProtocol?

    init(meter: UsageMeter = .shared) {
        self.meter = meter
        snapshot = meter.snapshot()
        observer = NotificationCenter.default.addObserver(forName: .usageMeterChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() { snapshot = meter.snapshot() }

    /// 「11月2日（月）0:00」。
    nonisolated static func resetText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日（E）H:mm"
        return formatter.string(from: date)
    }

    /// 「11月2日（月）」。
    nonisolated static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日（E）"
        return formatter.string(from: date)
    }
}

/// 使用率のバー。
struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(Theme.accentColor).frame(width: max(fraction > 0 ? 8 : 0, geometry.size.width * fraction))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// 設定 › 利用枠: 今週の使用率のゲージ・残りの目安の問題数・戻る日時・今のプラン・「プランを変える」・解約(契約中だけ)。
/// 解約は Apple の管理シートの中で行う(アプリから直接解約する API は無い)。
struct UsageSettingsView: View {
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var status: UsageStatus = UsageStatus()
    @State private var isPaywallPresented: Bool = false
    @State private var isManagePresented: Bool = false

    var body: some View {
        SettingsScreen(title: "利用枠") {
            gauge(status.snapshot)
            planSection
        }
        .onAppear { status.refresh() }
        .sheet(isPresented: $isPaywallPresented) {
            OnboardingPaywallView(store: subscriptions, isPad: TimelineLayout.isPad(sizeClass), onClose: { isPaywallPresented = false }) {
                isPaywallPresented = false
            }
        }
        .manageSubscriptionsSheet(isPresented: $isManagePresented)
        // 画面を開いた時と管理シートを閉じた時に読み直す(解約の予約は `.subscriptionStatusTask` に届かないことがある)。
        .task(id: isManagePresented) {
            if !isManagePresented { await subscriptions.refreshStatus() }
        }
        .accessibilityIdentifier("usage-settings")
    }

    /// 地に直接置く計器。これがこの画面の主役。
    private func gauge(_ snapshot: UsageSnapshot) -> some View {
        let until: String = untilText(snapshot)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("今週の使用量")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
                Text("\(snapshot.percent)%")
                    .font(Typography.sans(size: 30, weight: .bold, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.primaryText)
                    .monospacedDigit()
                    .accessibilityIdentifier("usage-percent")
            }
            UsageBar(fraction: snapshot.fraction)
            HStack(spacing: 12) {
                Text("残り 約\(snapshot.remainingProblems)問")
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityIdentifier("usage-remaining")
                Spacer(minLength: 0)
                Text(until)
                    .foregroundStyle(Theme.secondaryText)
            }
            .font(Typography.caption)
            .monospacedDigit()
            SettingsNote(text: "問題数は目安で、質問や写真の量で前後します。100% に達しても、解いている途中の問題は採点まで終わらせます。")
                .padding(.top, 4)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("今週の使用量 \(snapshot.percent)%。残り 約\(snapshot.remainingProblems)問。\(until)")
    }

    /// 枠が戻る前にプランが終わる時は、戻る日時を出さない(その日にはもう使えないため)。
    private func untilText(_ snapshot: UsageSnapshot) -> String {
        if let cancelsAt: Date = subscriptions.cancelsAt, cancelsAt < snapshot.resetsAt {
            return "\(UsageStatus.dayText(cancelsAt))まで使えます"
        }
        return "\(UsageStatus.resetText(snapshot.resetsAt)) に 0% に戻ります"
    }

    private var planSection: some View {
        let plan: UsagePlan? = subscriptions.plan
        let isCancelled: Bool = subscriptions.cancelsAt != nil
        return SettingsSection(header: "プラン") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan?.displayName ?? "お試し")
                        .font(Typography.title)
                        .foregroundStyle(Theme.primaryText)
                    if isCancelled {
                        Text("解約済み・次の請求はありません")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier("usage-cancels-at")
                    } else if let plan {
                        Text("週 約\(plan.weeklyProblems)問が目安")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 12)
                if let plan {
                    Text("\(subscriptions.price(of: plan)) / 月")
                        .font(Typography.body)
                        .foregroundStyle(Theme.secondaryText)
                        .monospacedDigit()
                        .padding(.top, 3)
                        .accessibilityIdentifier("usage-plan")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            SettingsDivider()
            if isCancelled {
                SettingsButtonRow(title: "プランを続ける", systemImage: SettingsChevron.symbolName) {
                    isManagePresented = true
                }
                .accessibilityIdentifier("usage-manage-subscription")
                SettingsDivider()
                SettingsButtonRow(title: "プランを変える", tone: .secondary, systemImage: SettingsChevron.symbolName) {
                    isPaywallPresented = true
                }
                .accessibilityIdentifier("usage-change-plan")
            } else {
                SettingsButtonRow(title: plan == nil ? "プランを選ぶ" : "プランを変える", systemImage: SettingsChevron.symbolName) {
                    isPaywallPresented = true
                }
                .accessibilityIdentifier("usage-change-plan")
                if plan != nil {
                    SettingsDivider()
                    SettingsButtonRow(title: "解約・支払いの管理", tone: .secondary, systemImage: SettingsChevron.symbolName) {
                        isManagePresented = true
                    }
                    .accessibilityIdentifier("usage-manage-subscription")
                }
            }
        }
    }
}

/// 利用枠を使い切った時のシート(下から)。解いている途中のカードは採点まで終わらせてから出す(ソフトリミット)。
/// Apple Intelligence(PCC)への切り替えは、アプリにその経路がまだ無いので出さない。
struct UsageLimitSheet: View {
    let snapshot: UsageSnapshot
    let store: SubscriptionStore
    let onClose: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var isPaywallPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Text("今週の利用枠を使い切りました")
                    .font(Typography.sans(size: 22, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.primaryText).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("閉じる")
                .padding(.top, -8)
                .padding(.trailing, -10)
            }
            UsageBar(fraction: 1)
            Text("\(UsageStatus.resetText(snapshot.resetsAt)) に 0% に戻ります。プランを上げると、すぐに続けられます。")
                .font(Typography.sans(size: 15, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if let next = snapshot.plan?.upgrade ?? (snapshot.plan == nil ? .light : nil) {
                OnboardingPrimaryButton(title: "\(next.displayName)にする（\(store.price(of: next)) / 月）", isEnabled: store.purchasing == nil, identifier: "usage-limit-upgrade") {
                    Task { if await store.purchase(next) { onClose() } }
                }
            }
            if let error = store.errorMessage { TrialErrorText(text: error) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .background(Theme.card.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-limit-sheet")
        .task { await store.loadProducts() }
    }
}
