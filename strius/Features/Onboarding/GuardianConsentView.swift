import CloudKit
import SwiftUI

/// 16 歳未満の保護者の同意の画面(#76)。オンボーディングの中と、文面の版が上がった時の出し直しの両方で使う。
struct GuardianConsentView: View {
    var isPad = false
    var onBack: (() -> Void)? = nil
    let onAccept: () -> Void

    var body: some View {
        OnboardingScaffold(onBack: onBack, isPad: isPad) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingTitle(title: GuardianConsentText.title, detail: GuardianConsentText.lead)
                OnboardingListCard {
                    let symbols = ["paperplane", "cloud", "exclamationmark.bubble"]
                    ForEach(Array(GuardianConsentText.points.enumerated()), id: \.offset) { index, point in
                        GuardianConsentPointRow(symbol: symbols[index % symbols.count], text: point, showsDivider: index < GuardianConsentText.points.count - 1)
                    }
                }
                .accessibilityIdentifier("onboarding-guardian-points")
            }
        } footer: {
            SwipeToConfirm(title: GuardianConsentText.swipe, identifier: "onboarding-guardian-swipe", onConfirm: onAccept)
            Text("右へスワイプすると、保護者として同意したことになります。")
                .font(Typography.sans(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
    }
}

/// 同意の内容の 1 行(見出しだけ)。
private struct GuardianConsentPointRow: View {
    let symbol: String
    let text: String
    let showsDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accentColor)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(text)
                    .font(Typography.sans(size: 15, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            if showsDivider { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 16) }
        }
    }
}

/// 右へスワイプして確かめる操作(押すだけでは同意にならない。勢いで押せないようにするため)。
/// VoiceOver では、つまみの上の操作(ダブルタップ)で同意する。
struct SwipeToConfirm: View {
    let title: String
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
                Text(title)
                    .font(Typography.sans(size: 16, weight: .bold, relativeTo: .headline))
                    .foregroundStyle(Theme.primaryText)
                    .opacity(1 - progress * 0.8)
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
                    .onEnded { value in
                        guard !isConfirmed else { return }
                        if offset >= travel * 0.85 || value.predictedEndTranslation.width >= travel * 1.2 && offset >= travel * 0.6 {
                            confirm(travel: travel)
                        } else {
                            withAnimation(.spring(duration: 0.3)) { offset = 0 }
                        }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityHint("右へスワイプすると同意します")
            .accessibilityValue(isConfirmed ? "同意しました" : "")
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
            try? await Task.sleep(for: .milliseconds(250))
            onConfirm()
        }
    }
}

/// オンボーディングを終えた後の保護者の同意(#76)。タイムラインに付ける。
/// - 16 歳未満で、文面の版が上がって今の版の控えが無ければ、開いた時に同意の画面を重ねて出し直す。
/// - 運営者側へ送れていない同意の記録を、開いた時と iCloud にサインインした後に送り直す。
struct GuardianConsentGate: ViewModifier {
    var isPad = false
    @State private var needsConsent = GuardianConsentGate.consentRequired

    private static var consentRequired: Bool {
        let records = OnboardingRecords.shared
        return records.needsGuardianConsent(band: records.age?.band)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if needsConsent {
                    GuardianConsentView(isPad: isPad) {
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
