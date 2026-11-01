import SwiftUI

/// プランの購入(#40 の 7、#62)。3 プランは機能の差がなく、1 週間に使える量だけが違う。iPad は 3 プランを横に並べる。
/// オンボーディング(お試しの後・計画の前)と、設定の「プランを変える」・使い切った時のシートから開く。
struct OnboardingPaywallView: View {
    let store: SubscriptionStore
    let isPad: Bool
    /// 設定から開いた時(見出しの左上に閉じる)。
    var onClose: (() -> Void)? = nil
    var initial: UsagePlan? = nil
    let onPurchased: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var selection: UsagePlan = .light
    @State private var isRestoring = false

    var body: some View {
        OnboardingScaffold(showsBrand: onClose == nil, isPad: isPad, columnWidth: isPad ? 800 : OnboardingMetrics.padColumn) {
            VStack(alignment: isPad ? .center : .leading, spacing: 18) {
                OnboardingTitle(title: "プランを選んでください", detail: "どのプランも使える機能は同じで、1週間に使える量だけが違います。")
                    .multilineTextAlignment(isPad ? .center : .leading)
                    .frame(maxWidth: isPad ? 560 : .infinity)
                let layout = isPad ? AnyLayout(HStackLayout(alignment: .top, spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
                layout {
                    ForEach(UsagePlan.allCases, id: \.self) { plan in planCard(plan) }
                }
                Text("問題数は目安です。質問や写真の量によって前後します。使った量は設定の「利用枠」で確認できます。")
                    .font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText).lineSpacing(3)
                    .multilineTextAlignment(isPad ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = store.errorMessage { TrialErrorText(text: error) }
            }
            .padding(.top, isPad ? 40 : 4)
        } footer: {
            OnboardingPrimaryButton(title: store.purchasing == nil ? "\(selection.displayName)\(onClose == nil ? "で始める" : "にする")" : "購入しています",
                                    isEnabled: store.purchasing == nil && !(onClose != nil && store.plan == selection), identifier: "paywall-purchase") {
                Task { if await store.purchase(selection) { onPurchased() } }
            }
            Text("毎月自動で更新されます。いつでも App Store の設定から解約できます。")
                .font(Typography.sans(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            HStack(spacing: 18) {
                Button(isRestoring ? "確かめています" : "購入を復元") {
                    isRestoring = true
                    Task {
                        await store.restore()
                        isRestoring = false
                        if store.plan != nil { onPurchased() }
                    }
                }
                .disabled(isRestoring)
                .accessibilityIdentifier("paywall-restore")
                Button("利用規約") { openURL(LegalLinks.terms) }
                Button("プライバシーポリシー") { openURL(LegalLinks.privacy) }
            }
            .font(Typography.sans(size: 12, weight: .medium))
            .underline()
            .foregroundStyle(Theme.primaryText)
            .buttonStyle(.plain)
            .frame(minHeight: 32)
        }
        .overlay(alignment: .topLeading) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.primaryText).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8).padding(.top, 12)
                .accessibilityLabel("閉じる")
            }
        }
        .task {
            selection = initial ?? store.plan?.upgrade ?? store.plan ?? .light
            await store.loadProducts()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paywall")
    }

    private func subtitle(_ plan: UsagePlan) -> String {
        [plan.ratioText, "週 約\(plan.weeklyProblems)問が目安"].compactMap { $0 }.joined(separator: "・")
    }

    @ViewBuilder
    private func planCard(_ plan: UsagePlan) -> some View {
        let selected = selection == plan
        Button { selection = plan } label: {
            Group {
                if isPad {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(plan.displayName).font(Typography.sans(size: 16, weight: .bold)).foregroundStyle(Theme.primaryText)
                        price(plan, size: 24)
                        Text(subtitle(plan)).font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                } else {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().strokeBorder(selected ? Theme.accentColor : Theme.tertiaryText, lineWidth: 1.5).frame(width: 22, height: 22)
                            if selected { Circle().fill(Theme.accentColor).frame(width: 22, height: 22); Circle().fill(Theme.card).frame(width: 8, height: 8) }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plan.displayName).font(Typography.sans(size: 17, weight: .bold)).foregroundStyle(Theme.primaryText)
                            Text(subtitle(plan)).font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 2)
                        price(plan, size: 17)
                    }
                }
            }
            .padding(isPad ? 18 : 16)
            .struisSurface(radius: Theme.Radius.cardLarge)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous)
                    .strokeBorder(selected ? Theme.accentColor : Color.clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("paywall-plan-\(plan.rawValue)")
    }

    private func price(_ plan: UsagePlan, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(store.price(of: plan)).font(Typography.sans(size: size, weight: .bold)).foregroundStyle(Theme.primaryText).monospacedDigit()
            Text("/ 月").font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
        // App Store の商品から読めた値段か(読めない間は料金表の値段を出す)。
        .accessibilityValue(store.products[plan] == nil ? "料金表" : "App Store")
        .accessibilityIdentifier("paywall-price-\(plan.rawValue)")
    }
}
