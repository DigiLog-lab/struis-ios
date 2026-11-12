import StoreKit
import SwiftUI

/// Struis の App Clip(#133): タイムアタックのリンクから開き、届いた5問を解いて相手の記録と比べ、送り返す。
/// 採点は App Attest の token で Claude に直接頼む(自前のサーバーは無い)。無料で解けるのは1日3セットまで(端末の中で数える)。
@main
struct StruisClipApp: App {
    @State private var challenge: TimeAttack.Challenge?
    @State private var unreadable = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                Theme.ground.ignoresSafeArea()
                if let challenge {
                    ClipChallengeView(session: TimeAttackSession(mode: .challenge(challenge), transport: ClipTransport()))
                        .id(challenge.latest?.total ?? 0)
                } else {
                    ClipWaitingView(unreadable: unreadable)
                }
            }
            .foregroundStyle(Theme.primaryText)
            .tint(Theme.Palette.accentLight)
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in open(activity.webpageURL) }
            .onOpenURL { open($0) }
            .onAppear {
                #if DEBUG
                // Simulator の検証: 起動の環境変数でリンクを渡す。
                if challenge == nil, let link = ProcessInfo.processInfo.environment["STRUIS_TIMEATTACK_LINK"] { open(URL(string: link)) }
                #endif
            }
        }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        do {
            challenge = try TimeAttackLink.challenge(from: url)
            unreadable = false
        } catch {
            unreadable = true
        }
    }
}

/// リンクが無い(App Clip のカードから直接開いた・リンクが壊れていた)時。
private struct ClipWaitingView: View {
    let unreadable: Bool

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                TimeAttackMark(size: 32)
                Text("Struis").font(Typography.brandName)
            }
            Text(unreadable ? "このリンクは読めませんでした。送ってくれた人に、もう一度送ってもらってください。"
                            : "友達から届いたタイムアタックのリンクを開くと、ここで解けます。")
                .font(Typography.body).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .accessibilityIdentifier("clip-waiting")
    }
}

private struct ClipChallengeView: View {
    @State var session: TimeAttackSession
    @State private var showsAppStore = false
    @State private var counted = false
    /// 同意の画面を出しているか(初めてと、規約が新しくなった時だけ)。
    @State private var asksConsent = false
    private let local = TimeAttackLocal()

    var body: some View {
        VStack(spacing: 0) {
            switch session.phase {
            case .intro, .preparing:
                if asksConsent {
                    ClipConsentView(onDecided: { decided in
                        asksConsent = false
                        run(with: decided)
                    }, onBack: { asksConsent = false })
                } else {
                    header
                    TimeAttackIntroView(field: session.field, rival: session.rival, setsLeft: setsLeft,
                                        capturesPhoto: local.clipGrading(termsVersion: LegalVersion.terms) != .selfCheck, onStart: begin)
                }
            case .running:
                TimeAttackRunView(field: session.field, problems: session.problems, capturesPhoto: session.grading == .ai,
                                  onQuit: restart) { laps, photo in
                    Task { await session.finish(laps: laps, photo: photo) }
                }
            case .grading:
                TimeAttackWaitView(text: "考えています")
            case .selfCheck:
                TimeAttackSelfCheckView(problems: session.problems, onSubmit: session.submitSelfCheck)
            case .result:
                TimeAttackResultView(session: session, secondaryTitle: "似た問題を解く", onSecondary: { showsAppStore = true })
                    // 下に出る App Store の案内に、補助のボタンと説明が隠れないようにする。
                    .safeAreaPadding(.bottom, showsAppStore ? 110 : 0)
            case .failed(let message):
                TimeAttackFailedView(message: message, retryTitle: session.hasPhoto ? "もう一度読む" : nil,
                                     onRetry: { Task { await session.retryGrading() } },
                                     onClose: restart)
            }
        }
        .onAppear { session.onGradingStarted = countSet }
        .onChange(of: session.phase) { _, phase in
            if phase == .result { showsAppStore = true }
        }
        .appStoreOverlay(isPresented: $showsAppStore) {
            SKOverlay.AppClipConfiguration(position: .bottom)
        }
    }

    /// 今日あと何回 AI で採点できるか。AI で採点すると決めた人にだけ見せ、使い切っていても始められる(その回は自分で採点する)。
    private var setsLeft: Int? {
        let left = local.clipSetsLeft()
        return local.clipGrading(termsVersion: LegalVersion.terms) == .ai && left > 0 ? left : nil
    }

    /// 「始める」: 今の規約の版でまだ決めていなければ同意の画面へ、決めていればそのまま解き始める。
    private func begin() {
        if let decided = local.clipGrading(termsVersion: LegalVersion.terms) {
            run(with: decided)
        } else {
            asksConsent = true
        }
    }

    /// AI で採点すると決めていても、今日の無料の分を使い切っていたら、その回は自分で採点する(写真は送らない)。
    private func run(with decided: TimeAttackLocal.ClipGrading) {
        session.grading = decided == .ai && local.clipSetsLeft() > 0 ? .ai : .selfCheck
        session.start()
    }

    /// 1セットにつき1回だけ数える(読み直しは数えない。自分で採点する時は AI に頼まないので数えない)。
    private func countSet() {
        guard !counted else { return }
        counted = true
        local.useClipSet()
    }

    /// やめた・失敗した時は、始める前の画面に戻す(同じ5問を最初から)。
    private func restart() {
        let fresh = TimeAttackSession(mode: session.mode, transport: session.transport)
        fresh.onGradingStarted = countSet
        counted = false
        session = fresh
    }

    private var header: some View {
        HStack(spacing: 10) {
            TimeAttackMark(size: 32)
            Text("Struis").font(Typography.brandName)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
    }
}
