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

    /// 「11月2日(月)0:00」。
    static func resetText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日(E)H:mm"
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

/// 設定 › 利用枠: 今週の使用率のゲージ・残りの目安の問題数・リセットの日時・今のプラン・「プランを変える」。
struct UsageSettingsView: View {
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var status = UsageStatus()
    @State private var isPaywallPresented = false

    var body: some View {
        let snapshot = status.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .lastTextBaseline) {
                        Text("今週").font(Typography.sans(size: 15, weight: .bold)).foregroundStyle(Theme.primaryText)
                        Spacer()
                        Text("\(snapshot.percent)%")
                            .font(Typography.sans(size: 34, weight: .bold, relativeTo: .largeTitle))
                            .foregroundStyle(Theme.primaryText)
                            .monospacedDigit()
                            .accessibilityIdentifier("usage-percent")
                    }
                    UsageBar(fraction: snapshot.fraction)
                    HStack {
                        Text("残りの目安 約\(snapshot.remainingProblems)問").accessibilityIdentifier("usage-remaining")
                        Spacer()
                        Text("\(UsageStatus.resetText(snapshot.resetsAt)) に戻ります")
                    }
                    .font(Typography.sans(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                }
                .padding(18)
                .struisSurface(radius: Theme.Radius.cardLarge)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("今週の利用枠 \(snapshot.percent)% 使用。残りの目安 約\(snapshot.remainingProblems)問。\(UsageStatus.resetText(snapshot.resetsAt)) に戻ります")

                VStack(spacing: 0) {
                    HStack {
                        Text("プラン").font(Typography.sans(size: 15, weight: .bold))
                        Spacer()
                        Text(subscriptions.plan.map { "\($0.displayName)   \(subscriptions.price(of: $0)) / 月" } ?? "お試し")
                            .font(Typography.sans(size: 15, weight: .medium)).foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier("usage-plan")
                    }
                    .padding(.vertical, 14)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    Button { isPaywallPresented = true } label: {
                        HStack {
                            Text(subscriptions.plan == nil ? "プランを選ぶ" : "プランを変える").font(Typography.sans(size: 15, weight: .bold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
                        }
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("usage-change-plan")
                }
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 18)
                .struisSurface(radius: Theme.Radius.cardLarge)

                Text("問題数は目安です。質問や写真の量によって前後します。100%に達しても、解いている途中の問題は採点まで終わらせます。")
                    .font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText).lineSpacing(3)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 36)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle("利用枠")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { status.refresh() }
        .sheet(isPresented: $isPaywallPresented) {
            OnboardingPaywallView(store: subscriptions, isPad: TimelineLayout.isPad(sizeClass), onClose: { isPaywallPresented = false }) {
                isPaywallPresented = false
            }
        }
        .accessibilityIdentifier("usage-settings")
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
            Text("\(UsageStatus.resetText(snapshot.resetsAt)) に戻ります。プランを上げると、すぐに続けられます。")
                .font(Typography.sans(size: 15, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if let next = snapshot.plan?.upgrade ?? (snapshot.plan == nil ? .light : nil) {
                OnboardingPrimaryButton(title: "\(next.displayName)にする(\(store.price(of: next)) / 月)", isEnabled: store.purchasing == nil, identifier: "usage-limit-upgrade") {
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
