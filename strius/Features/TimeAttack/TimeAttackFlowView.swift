import Observation
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
                TimeAttackFailedView(message: message, retryTitle: retryTitle, onRetry: retry, onClose: onClose)
            }
        }
        .foregroundStyle(Theme.primaryText)
        .task { await session.prepare() }
        .onAppear { TimeAttackPresence.shared.isPresented = true }
        .onDisappear { TimeAttackPresence.shared.isPresented = false }
    }

    /// 撮った後なら読み直し、自分で始めた時は作り直し。届いた5問を解き始める前に止められた時は、やり直しを出さない。
    private var retryTitle: String? {
        if session.hasPhoto { return "もう一度読む" }
        if case .own = session.mode { return "もう一度作る" }
        return nil
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

/// タイムアタックを開いているか。タイムラインはこの間、iPad の道具パレット(PKToolPicker)を隠す
/// (道具パレットは全画面の画面の上にも残り、解く画面の「次へ」を塞いだ)。
@MainActor
@Observable
final class TimeAttackPresence {
    static let shared = TimeAttackPresence()
    var isPresented = false
}

/// 本体が入っている端末でタイムアタックのリンクが開かれた時に、届いた5問を解く画面を出す。
struct TimeAttackLinkHandler: ViewModifier {
    @State private var opened: OpenedChallenge?
    #if DEBUG
    /// Simulator の検証: 起動の環境変数 `STRUIS_TIMEATTACK_UNIT` で、その分野のタイムアタックをすぐ開く。
    @State private var demo: TimeAttackSession?
    #endif

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
                TimeAttackFlowView(session: Self.challengeSession(item.challenge)) {
                    opened = nil
                }
            }
            #if DEBUG
            .fullScreenCover(item: $demo) { session in
                TimeAttackFlowView(session: session) { demo = nil }
            }
            .task {
                let environment = ProcessInfo.processInfo.environment
                try? await Task.sleep(for: .seconds(1))
                if let link = environment["STRUIS_TIMEATTACK_LINK"].flatMap(URL.init(string:)) { open(link) }
                if let unit = environment["STRUIS_TIMEATTACK_UNIT"], !unit.isEmpty {
                    demo = TimeAttackSession(mode: .own(unitTitle: unit, context: ""), transport: AppTimeAttackTransport())
                }
            }
            #endif
    }

    private static func challengeSession(_ challenge: TimeAttack.Challenge) -> TimeAttackSession {
        let transport = AppTimeAttackTransport()
        let session = TimeAttackSession(mode: .challenge(challenge), transport: transport)
        session.preflight = { transport.startDenial() }
        return session
    }

    private func open(_ url: URL) {
        guard let challenge = try? TimeAttackLink.challenge(from: url) else { return }
        opened = OpenedChallenge(challenge: challenge)
    }
}

extension View {
    func timeAttackLinks() -> some View { modifier(TimeAttackLinkHandler()) }
}
