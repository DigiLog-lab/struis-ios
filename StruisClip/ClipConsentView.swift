import DeclaredAgeRange
import SwiftUI

/// App Clip の同意(#133): 解き始める前に、規約と「答案の写真を AI に送る」ことへの同意を取り、Apple の年齢確認で
/// 16歳以上と分かった時だけ写真を送って AI が採点する。16歳未満・年齢を共有しなかった・同意しなかった時は、写真を送らず
/// 正答と見比べて自分で○×をつける。決めた結果は今の規約の版と一緒に端末に残し、次からは聞かない。
struct ClipConsentView: View {
    var onDecided: (TimeAttackLocal.ClipGrading) -> Void
    var onBack: () -> Void

    @Environment(\.requestAgeRange) private var requestAgeRange
    @Environment(\.openURL) private var openURL
    @State private var isChecking = false
    private let local = TimeAttackLocal()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Theme.card.opacity(0.8), in: Circle())
                        .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("戻る")
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 44)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("はじめる前に").font(Typography.heading1)
                    VStack(spacing: 0) {
                        point("camera", "答案の写真を AI に送ります",
                              "撮った答案の写真を、採点のためだけに米国の Anthropic に送ります。Struis の運営者は見られず、写真はこの端末にも残しません。")
                        Divider().overlay(Theme.hairline)
                        point("checkmark.circle", "採点は AI が行います", "間違えることがあります。")
                        Divider().overlay(Theme.hairline)
                        point("person.2", "16歳未満の方は自分で採点します",
                              "次に Apple の年齢の確認が出ます。16歳未満の時と、年齢を共有しなかった時は写真を送らず、正答と見比べて自分で○×をつけます。")
                    }
                    .padding(.horizontal, 16)
                    .struisSurface(radius: Theme.Radius.cardLarge)
                    VStack(spacing: 0) {
                        link("利用規約を読む", LegalLinks.terms)
                        link("プライバシーポリシーを読む", LegalLinks.privacy)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            VStack(spacing: 10) {
                Button(action: agree) {
                    Text(isChecking ? "年齢を確かめています" : "同意して始める")
                        .font(Typography.sans(size: 17, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(Theme.onAccent)
                        .background(Theme.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isChecking)
                .accessibilityIdentifier("clip-consent-agree")
                Button {
                    decide(.selfMarked)
                } label: {
                    Text("写真を送らずに、自分で採点する")
                        .font(Typography.body)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Theme.accentColor.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isChecking)
                .accessibilityIdentifier("clip-consent-self")
                Text("「同意して始める」を押すと、利用規約とプライバシーポリシーに同意したことになります。")
                    .font(Typography.caption).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .foregroundStyle(Theme.primaryText)
        #if DEBUG
        // Simulator の確認: `STRUIS_CLIP_CONSENT=agree|self` で、少し待ってから押す。
        .task {
            guard let choice = ProcessInfo.processInfo.environment["STRUIS_CLIP_CONSENT"] else { return }
            try? await Task.sleep(for: .seconds(3))
            if choice == "agree" { agree() } else { decide(.selfMarked) }
        }
        #endif
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.accentColor).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Typography.sans(size: 15, weight: .bold))
                Text(detail).font(Typography.bodyCompact).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Button { openURL(url) } label: {
            HStack {
                Text(title).font(Typography.body)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func agree() {
        isChecking = true
        Task {
            let band = await ageBand()
            isChecking = false
            decide(TimeAttackLocal.clipGrading(for: band))
        }
    }

    /// Apple の年齢確認(区切りは本体と同じ 16・18)。共有しなかった・確かめられなかった時は nil(自分で採点する)。
    private func ageBand() async -> AgeBand? {
        #if DEBUG
        // Simulator では Apple の確認を出せないので、結果を差し替える(`STRUIS_AGE_RANGE=under16|under18|adult|declined`)。
        if let forced = ProcessInfo.processInfo.environment["STRUIS_AGE_RANGE"] { return AgeBand(rawValue: forced) }
        #endif
        do {
            switch try await requestAgeRange(ageGates: 16, 18) {
            case .sharing(let range): return AgeBand.from(lowerBound: range.lowerBound, upperBound: range.upperBound)
            case .declinedSharing: return nil
            @unknown default: return nil
            }
        } catch {
            return nil
        }
    }

    private func decide(_ grading: TimeAttackLocal.ClipGrading) {
        local.recordClipGrading(grading, termsVersion: LegalVersion.terms)
        onDecided(grading)
    }
}
