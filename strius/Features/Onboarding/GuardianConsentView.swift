import CloudKit
import SwiftUI

/// 16 歳未満の保護者の同意の画面(#76)。オンボーディングの中(「AI に送る内容」の代わり)と、文面の版が上がった時の出し直しの両方で使う。
/// 見た目は Design キャンバス「Struis 保護者の同意 実装イメージ」(2026-11-10 確定)。
struct GuardianConsentView: View {
    var isPad = false
    /// 版が上がった時の出し直し(見出しと説明を変え、戻るを出さない)。
    var isRenewal = false
    var onBack: (() -> Void)? = nil
    let onAccept: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var isAccepted = false

    var body: some View {
        OnboardingScaffold(onBack: isRenewal ? nil : onBack, badge: GuardianConsentText.badge, isPad: isPad) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingTitle(title: isRenewal ? GuardianConsentText.renewalTitle : GuardianConsentText.title,
                                detail: isRenewal ? GuardianConsentText.renewalLead : GuardianConsentText.lead)
                OnboardingListCard {
                    OnboardingPointRow(symbol: isPad ? "pencil.line" : "camera", title: "答案と学習の記録を AI に送ります",
                                       detail: isPad
                                           ? "画面に書いた答案、撮った答案や教材の写真、質問、学習記録、学年を、採点と説明のために米国の Anthropic に送ります。"
                                           : "答案、撮った答案や教材の写真、質問、学習記録、学年を、採点と説明のために米国の Anthropic に送ります。")
                    OnboardingPointRow(symbol: "cloud", title: "記録はこの端末と iCloud に残ります",
                                       detail: "解いた答案と学習の記録は、この端末と、同じ Apple ID の iCloud に保存します。Struis の運営者は読めません。")
                    OnboardingPointRow(symbol: "exclamationmark.bubble", title: "採点と説明は AI が行います",
                                       detail: "間違えることがあります。")
                    OnboardingPointRow(symbol: "creditcard", title: "続けるには有料のプランが必要です",
                                       detail: "お試しは3問までです。購入と解約は App Store で行います。", showsDivider: false)
                }
                .accessibilityIdentifier("onboarding-guardian-points")
                VStack(spacing: 0) {
                    linkRow("利用規約を読む", url: LegalLinks.terms)
                    linkRow("プライバシーポリシーを読む", url: LegalLinks.privacy)
                }
            }
        } footer: {
            SwipeToConfirm(title: GuardianConsentText.swipe, confirmedTitle: GuardianConsentText.swiped, identifier: "onboarding-guardian-swipe") {
                isAccepted = true
                onAccept()
            }
            Text(isAccepted ? GuardianConsentText.afterNote : GuardianConsentText.note)
                .font(Typography.sans(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding-guardian-note")
        }
    }

    private func linkRow(_ title: String, url: URL) -> some View {
        Button { openURL(url) } label: {
            HStack {
                Text(title).font(Typography.sans(size: 15, weight: .medium)).foregroundStyle(Theme.primaryText)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 右へスワイプして確かめる操作(押すだけでは同意にならない。勢いで押せないようにするため)。
/// つまみを 85% まで引くと確定、途中で離すと戻る。VoiceOver では、つまみの上の操作(ダブルタップ)で確定する。
struct SwipeToConfirm: View {
    let title: String
    var confirmedTitle: String? = nil
    var identifier: String? = nil
    let onConfirm: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isConfirmed = false

    private let height: CGFloat = 60
    private let inset: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let knob = height - inset * 2
            let travel = max(1, geometry.size.width - knob - inset * 2)
            let progress = min(1, offset / travel)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.accentColor.opacity(0.18))
                Capsule().fill(Theme.accentColor.opacity(0.35))
                    .frame(width: knob + inset * 2 + offset)
                Text(isConfirmed ? (confirmedTitle ?? title) : title)
                    .font(Typography.sans(size: 16, weight: .bold, relativeTo: .headline))
                    .foregroundStyle(Theme.primaryText)
                    .opacity(isConfirmed ? 1 : 1 - progress * 0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, knob)
                Circle()
                    .fill(Theme.accentColor)
                    .overlay {
                        Image(systemName: isConfirmed ? "checkmark" : "chevron.right.2")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                    }
                    .frame(width: knob, height: knob)
                    .offset(x: inset + offset)
            }
            .overlay { Capsule().strokeBorder(Theme.accentColor.opacity(0.3), lineWidth: 1) }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard !isConfirmed else { return }
                        offset = min(travel, max(0, value.translation.width))
                    }
                    .onEnded { _ in
                        guard !isConfirmed else { return }
                        if offset >= travel * 0.85 {
                            confirm(travel: travel)
                        } else {
                            withAnimation(.spring(duration: 0.3)) { offset = 0 }
                        }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityHint("右へスワイプすると同意します")
            .accessibilityValue(isConfirmed ? (confirmedTitle ?? "") : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { confirm(travel: travel) }
            .accessibilityIdentifier(identifier ?? "")
        }
        .frame(height: height)
        .sensoryFeedback(.success, trigger: isConfirmed)
    }

    private func confirm(travel: CGFloat) {
        guard !isConfirmed else { return }
        isConfirmed = true
        withAnimation(.easeOut(duration: 0.15)) { offset = travel }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            onConfirm()
        }
    }
}

/// オンボーディングを終えた後の保護者の同意(#76)。タイムラインに付ける。
/// - 16 歳未満で、文面の版が上がって今の版の控えが無ければ、開いた時に同意の画面を重ねて出し直す。
/// - 運営者側へ送れていない同意の記録を、開いた時と iCloud のアカウントが変わった後に送り直す。
struct GuardianConsentGate: ViewModifier {
    var isPad = false
    /// 同意の画面を出しているか。同意するまでタイムラインを始めないよう、タイムラインと共有する。
    @Binding var needsConsent: Bool

    /// 16 歳未満で、今の版の保護者の同意の控えが無い(開いた時に同意の画面を出す)。
    static var consentRequired: Bool {
        let records = OnboardingRecords.shared
        return records.needsGuardianConsent(band: records.age?.band)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if needsConsent {
                    GuardianConsentView(isPad: isPad, isRenewal: true) {
                        OnboardingRecords.shared.recordGuardianConsent()
                        needsConsent = false
                        Task { await GuardianConsentUploader.shared.sendPending() }
                    }
                    .background(Theme.ground.ignoresSafeArea())
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("guardian-consent-renewal")
                }
            }
            .task { await GuardianConsentUploader.shared.sendPending() }
            .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
                Task { await GuardianConsentUploader.shared.sendPending() }
            }
    }
}
