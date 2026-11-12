import DeclaredAgeRange
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
    @State private var isConsentPresented = false
    @State private var isCheckingAge = false
    @Environment(\.requestAgeRange) private var requestAgeRange
    private let local = TimeAttackLocal()

    var body: some View {
        VStack(spacing: 0) {
            switch session.phase {
            case .intro, .preparing:
                header
                if isConsentPresented {
                    ClipConsentView(isChecking: isCheckingAge, onAgree: agree, onDecline: { decide(.selfCheck) })
                } else {
                    TimeAttackIntroView(field: session.field, rival: session.rival, setsLeft: shownSetsLeft, onStart: begin)
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

    /// 今日あと何回 AI で採点できるか。AI で採点する人にだけ見せる(自分で採点する人は回数に関係ない)。
    private var shownSetsLeft: Int? {
        ClipGradingChoice.stored == .ai ? max(local.clipSetsLeft(), 0) : nil
    }

    /// 始める: 送ることへの同意と年齢をまだ確かめていなければ、先に同意の画面を出す。
    private func begin() {
        if let stored = ClipGradingChoice.stored {
            start(stored)
        } else {
            isConsentPresented = true
        }
    }

    /// 同意した: Apple の年齢確認で 16歳以上と分かった時だけ AI で採点する(未満・共有しなかった時は自分で採点)。
    private func agree() {
        isCheckingAge = true
        Task {
            let grading = await checkedGrading()
            isCheckingAge = false
            decide(grading)
        }
    }

    private func checkedGrading() async -> TimeAttackSession.Grading {
        #if DEBUG
        // Simulator では Apple の確認を出せないので差し替える(`STRUIS_AGE_RANGE=under16|under18|adult|declined`)。
        if let forced = ProcessInfo.processInfo.environment["STRUIS_AGE_RANGE"] {
            return forced == "adult" || forced == "under18" ? .ai : .selfCheck
        }
        #endif
        do {
            switch try await requestAgeRange(ageGates: 16) {
            case .sharing(let range):
                return (range.lowerBound ?? 0) >= 16 ? .ai : .selfCheck
            case .declinedSharing:
                return .selfCheck
            @unknown default:
                return .selfCheck
            }
        } catch {
            return .selfCheck
        }
    }

    private func decide(_ grading: TimeAttackSession.Grading) {
        ClipGradingChoice.stored = grading
        isConsentPresented = false
        start(grading)
    }

    /// AI で採点する人でも、今日の回数を使い切っていたら、その回は自分で採点する(写真は送らない)。
    private func start(_ grading: TimeAttackSession.Grading) {
        session.grading = grading == .ai && local.clipSetsLeft() > 0 ? .ai : .selfCheck
        session.start()
    }

    /// 1セットにつき1回だけ数える(読み直しは数えない。自分で採点する時は数えない)。
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

/// App Clip で答案の写真を送るかの決め(同意の文の版ごとに端末に残す)。本体の同意とは別。
private enum ClipGradingChoice {
    /// 同意の文を変えたら上げる(もう一度同意の画面を出す)。
    static let version = "clip-2026-11-12"
    private static let key = "timeattack.clip.grading"

    static var stored: TimeAttackSession.Grading? {
        get {
            switch UserDefaults.standard.string(forKey: key) {
            case "\(version):ai": .ai
            case "\(version):self": .selfCheck
            default: nil
            }
        }
        set {
            guard let newValue else { UserDefaults.standard.removeObject(forKey: key); return }
            UserDefaults.standard.set("\(version):\(newValue == .ai ? "ai" : "self")", forKey: key)
        }
    }
}

/// 写真を送る前の同意。送るのは採点のためだけで、運営者は見ない。16歳未満は送らない。
private struct ClipConsentView: View {
    let isChecking: Bool
    var onAgree: () -> Void
    var onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("始める前に").font(Typography.heading2)
            Text("答えを書いた紙の写真は、採点のためだけに Anthropic(Claude を作っている会社)に送ります。運営者は写真を見ません。")
                .font(Typography.body).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            Text("16歳未満の方と、年齢を共有しなかった方は、写真を送りません。正答を見て、自分で○×をつけます。")
                .font(Typography.body).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link("利用規約", destination: URL(string: "https://struis.digiloglab.com/terms")!)
                Link("プライバシーポリシー", destination: URL(string: "https://struis.digiloglab.com/privacy")!)
            }
            .font(Typography.sans(size: 15, weight: .bold))
            .tint(Theme.accentColor)
            Spacer(minLength: 16)
            Text("「同意して始める」を押すと、利用規約とプライバシーポリシーに同意したことになります。年齢は Apple の確認で、16歳以上かだけを確かめます。")
                .font(Typography.caption).foregroundStyle(Theme.secondaryText).lineSpacing(4)
            Button(action: onAgree) {
                Group {
                    if isChecking { ProgressView().tint(Theme.onAccent) } else { Text("同意して始める") }
                }
                .font(Typography.sans(size: 17, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 52)
                .foregroundStyle(Theme.onAccent)
                .background(Theme.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isChecking)
            .accessibilityIdentifier("clip-consent-agree")
            Button(action: onDecline) {
                Text("写真を送らずに解く").font(Typography.body)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Theme.accentColor.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isChecking)
            .accessibilityIdentifier("clip-consent-decline")
        }
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        #if DEBUG
        // Simulator の検証: 自動で進める時は同意して進む(年齢は `STRUIS_AGE_RANGE` で差し替える)。
        .task {
            guard let step = ProcessInfo.processInfo.environment["STRUIS_TIMEATTACK_AUTOPLAY"].flatMap(Double.init) else { return }
            try? await Task.sleep(for: .seconds(step * 2))
            onAgree()
        }
        #endif
    }
}
