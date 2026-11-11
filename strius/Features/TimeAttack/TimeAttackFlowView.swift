import SwiftUI

/// 本体のタイムアタックの画面: 問題を作る(届いたリンクなら始める前の画面)→ 解く → 採点 → 結果。
struct TimeAttackFlowView: View {
    @State var session: TimeAttackSession
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            switch session.phase {
            case .preparing, .grading:
                TimeAttackWaitView(text: "考えています")
            case .intro:
                VStack(spacing: 0) {
                    HStack {
                        Button(action: onClose) {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .background(Theme.card.opacity(0.8), in: Circle())
                                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("閉じる")
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    TimeAttackIntroView(field: session.field, rival: session.rival, onStart: session.start)
                }
            case .running:
                TimeAttackRunView(field: session.field, problems: session.problems, onQuit: onClose) { laps, photo in
                    Task { await session.finish(laps: laps, photo: photo) }
                }
            case .result:
                TimeAttackResultView(session: session, secondaryTitle: "別の5問でもう一度", onSecondary: again, onClose: onClose)
            case .failed(let message):
                TimeAttackFailedView(message: message, retryTitle: session.hasPhoto ? "もう一度読む" : "もう一度作る", onRetry: retry, onClose: onClose)
            }
        }
        .foregroundStyle(Theme.primaryText)
        .task { await session.prepare() }
    }

    private func retry() {
        Task {
            if session.hasPhoto { await session.retryGrading() } else { await session.prepare() }
        }
    }

    /// 同じ分野で、新しい5問を作り直す(同じ問題を解き直すと、覚えた分だけ速くなるため)。
    private func again() {
        let unit: (String, String)
        switch session.mode {
        case .own(let title, let context): unit = (title, context)
        case .challenge(let challenge): unit = (challenge.field, "")
        }
        session = TimeAttackSession(mode: .own(unitTitle: unit.0, context: unit.1), transport: session.transport)
        Task { await session.prepare() }
    }
}

/// 本体が入っている端末でタイムアタックのリンクが開かれた時に、届いた5問を解く画面を出す。
struct TimeAttackLinkHandler: ViewModifier {
    @State private var opened: OpenedChallenge?

    private struct OpenedChallenge: Identifiable {
        let id = UUID()
        let challenge: TimeAttack.Challenge
    }

    func body(content: Content) -> some View {
        content
            .onOpenURL(perform: open)
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { open(url) }
            }
            .fullScreenCover(item: $opened) { item in
                TimeAttackFlowView(session: TimeAttackSession(mode: .challenge(item.challenge), transport: AppTimeAttackTransport())) {
                    opened = nil
                }
            }
    }

    private func open(_ url: URL) {
        guard let challenge = try? TimeAttackLink.challenge(from: url) else { return }
        opened = OpenedChallenge(challenge: challenge)
    }
}

extension View {
    func timeAttackLinks() -> some View { modifier(TimeAttackLinkHandler()) }
}
