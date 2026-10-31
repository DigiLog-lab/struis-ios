import SwiftUI

/// Top-level shell for the app. The root is the learning timeline 「タイムライン」(Issue #46): it is
/// the first screen after launch. The workbook home 「単元」 is kept as it is and covers the timeline
/// full screen from the timeline's top-left 「単元」; its top-left 「タイムライン」 closes it again. The chat
/// is the 「質問」 child screen. Sign-in is delegated to AuthStore + SignInEntryView.
struct AppRootView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(BootstrapStore.self) private var bootstrap
    @Environment(ChatStore.self) private var chat
    @Environment(APIClient.self) private var apiClient
    @Environment(LearnerData.self) private var learnerData
    @Environment(WorkbookStore.self) private var workbook
    @Environment(WorkbookCoordinator.self) private var coordinator
    @Environment(LearningFeedRuntimeServices.self) private var learningFeedRuntime
    @Environment(TimelineStore.self) private var timeline
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    /// オンボーディングは Release でも出す(§7.2)。完了は端末に保存し、2 回目の起動からは出さない。
    @State private var isShowingOnboarding = Self.initiallyShowsOnboarding
    @State private var onboardingSessionID = 0
    @State private var isSettingsPresented = false
    /// 単元ホームをタイムラインの上に重ねている。
    @State private var isUnitsPresented = Self.startsOnUnits
    /// 画面全体の大きさ(iPad の横向き・縦向きを、右の質問の欄を含めた幅で決める)。
    @State private var screenSize: CGSize = .zero
    /// 利用枠を使い切った時のシート(カードの切れ目で出す。#40 の 12、#62 のソフトリミット)。
    /// DEBUG: `STRUIS_START_SCREEN=limit` で起動した時に出す(画面の確認用)。
    @State private var limitSnapshot: UsageSnapshot? = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STRUIS_START_SCREEN"] == "limit" { return UsageMeter.shared.snapshot() }
        #endif
        return nil
    }()

    /// DEBUG: 設定の「利用枠」を開いた状態から始める(`STRUIS_START_SCREEN=usage`。画面の確認用)。
    @State private var isUsagePreviewPresented: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["STRUIS_START_SCREEN"] == "usage"
        #else
        return false
        #endif
    }()

    /// 起動した時に単元ホームを重ねた状態から始めるか(DEBUG: 単元ホームから操作する UI テストの起動に使う)。
    private static var startsOnUnits: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["STRUIS_START_SCREEN"] == "units"
        #else
        return false
        #endif
    }

    private static var initiallyShowsOnboarding: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-reset-onboarding") {
            UserDefaults.standard.removeObject(forKey: OnboardingProfile.completedKey)
            UserDefaults.standard.removeObject(forKey: OnboardingProfile.profileKey)
            UserDefaults.standard.removeObject(forKey: OnboardingProfile.unitCreationThreadKey)
            UserDefaults.standard.removeObject(forKey: OnboardingModel.draftKey)
            _ = OnboardingRecords.shared
        }
        if onboardingStart != nil { return true }
        #endif
        return showsOnboardingOnSignIn
    }

    /// DEBUG: 途中の画面から始める(`STRUIS_ONBOARDING_START=<画面名>`。画面の確認用)。
    private static var onboardingStart: OnboardingStep? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["STRUIS_ONBOARDING_START"].flatMap(OnboardingStep.init(rawValue:))
        #else
        return nil
        #endif
    }

    /// サインインした時にオンボーディングを出すか(完了の記録が無い)。
    private static var showsOnboardingOnSignIn: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-learning-feed-e2e") || arguments.contains("-skip-onboarding") || arguments.contains("-workbook") {
            return false
        }
        #endif
        return !OnboardingProfile.isCompleted()
    }

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-immersion-lab") {
            ImmersionLabView()
        } else if ProcessInfo.processInfo.arguments.contains("-problem-catalog-lab") {
            ProblemCatalogLabView()
        } else {
            standardRootContent
        }
        #else
        standardRootContent
        #endif
    }

    private var standardRootContent: some View {
        // サインイン → オンボーディング → ホーム。
        Group {
            if auth.canUseApp, isShowingOnboarding {
                // 最後の行き先はタイムライン(計画の小単元 1 から、30 秒で解ける問題が 1 枚目に入っている)。
                OnboardingFlowView(learnerData: learnerData, subscriptions: subscriptions, start: Self.onboardingStart) {
                    OnboardingProfile.markCompleted()
                    UserDefaults.standard.removeObject(forKey: OnboardingProfile.unitCreationThreadKey)
                    isShowingOnboarding = false
                    isUnitsPresented = false
                    Task { await workbook.refreshHome() }
                }
                .id(onboardingSessionID)
                .onAppear { chat.start() }
            } else {
                authenticatedContent
            }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) { MainThreadWatchdogProbe() }
        #endif
        // 台帳・配信の準備と中断ターンの後始末は、オンボーディング中にも進める。
        // サインアウトでオンボーディングの記録は消える。次にサインインした学習者にはオンボーディングから見せる。
        .onChange(of: auth.canUseApp) { wasSignedIn, signedIn in
            if wasSignedIn, !signedIn, !OnboardingProfile.isCompleted() { isShowingOnboarding = true }
            // 起動時の復元でセッションが終わって記録が消えた後(サインイン済みの状態を一度も通らない)に
            // サインインした時も、完了の記録が無ければオンボーディングから始める。
            if signedIn, !isShowingOnboarding, Self.showsOnboardingOnSignIn { isShowingOnboarding = true }
        }
        .task(id: auth.canUseApp) {
            guard auth.canUseApp else { return }
            await learnerData.prepare(client: apiClient)
            // Fixtures may have just seeded the ledger; re-read the thread list.
            await bootstrap.refreshThreads()
            await learnerData.turns.resumeUnfinished()
            await learnerData.iCloud.start()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { learnerData.iCloud.sceneBecameActive() } else { learnerData.iCloud.sceneLeftForeground() }
        }
        .font(Typography.body)
        .animation(.easeInOut(duration: Theme.Duration.standard), value: auth.canUseApp)
        .task(id: bootstrap.user?.id) {
            if Auth0Config.authenticationRequired, let userID = bootstrap.user?.id.uuidString {
                learningFeedRuntime.start(userID: userID)
            }
        }
        .task {
            if Auth0Config.authenticationRequired { await learningFeedRuntime.restoreCachedUserID() }
        }
    }

    private var timelineLayout: TimelineLayout { TimelineLayout.resolve(sizeClass: sizeClass, size: screenSize) }

    /// iPad でタイムラインの右に開く質問(問題と書いた答案は左に見えたまま)。単元づくりはシートのまま出す。
    private var sideQuestion: WorkbookQuestionContext? {
        guard timelineLayout.isPad, !isUnitsPresented, let question = coordinator.question, question.purpose == .question else { return nil }
        return question
    }

    private var timelineWithQuestionPanel: some View {
        HStack(spacing: 0) {
            LearningTimelineView(store: timeline, onOpenUnits: { isUnitsPresented = true }, layout: timelineLayout)
                // 欄の入力でキーボードが出ても、タイムライン(書いた答案)の大きさは変えない。
                .ignoresSafeArea(.keyboard)
            if let context = sideQuestion {
                WorkbookQuestionScreen(context: context, onClose: { coordinator.question = nil })
                    .id(context.id)
                    .frame(width: TimelineLayout.questionPanelWidth)
                    .background(Theme.ground.ignoresSafeArea())
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1).ignoresSafeArea() }
                    .transition(.move(edge: .trailing))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("timeline-question-panel")
            }
        }
        .animation(.easeInOut(duration: Theme.Duration.standard), value: sideQuestion?.id)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { screenSize = $0 }
    }

    @ViewBuilder
    private var authenticatedContent: some View {
        Group {
            if auth.canUseApp {
                timelineWithQuestionPanel
                    // 単元ホームは中身を変えずに、全画面で重ねる(画面の移り方・撮る・質問をそのまま持つ)。
                    .fullScreenCover(isPresented: $isUnitsPresented) {
                        WorkbookHomeView(onOpenSettings: { isSettingsPresented = true }, onCloseTimeline: { isUnitsPresented = false })
                            .sheet(isPresented: $isSettingsPresented) {
                                RootSettingsSheet(onReplayOnboarding: {
                                    isUnitsPresented = false
                                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
                                        onboardingSessionID += 1
                                        isShowingOnboarding = true
                                    }
                                })
                                .presentationDetents([.large])
                            }
                    }
                    // タイムラインの「質問」と、単元づくり(オンボーディングの後・案内の1枚)。単元ホームを重ねている間は、単元ホームが出す。
                    // iPad では、タイムラインの「質問」はシートにせず右の欄で開く(timelineWithQuestionPanel)。
                    .sheet(item: Binding(get: { isUnitsPresented || sideQuestion != nil ? nil : coordinator.question }, set: { coordinator.question = $0 })) { context in
                        WorkbookQuestionScreen(context: context)
                    }
                    // 単元づくりの「はじめる」など、単元ホームの中の画面へ移る時は、単元ホームを重ねてから移る。
                    .onChange(of: coordinator.path) { _, path in
                        guard !path.isEmpty, !isUnitsPresented else { return }
                        // 質問のシートを閉じている途中に重ねると出ないことがあるので、閉じ終わるのを待つ。
                        Task {
                            try? await Task.sleep(for: .milliseconds(450))
                            isUnitsPresented = true
                        }
                    }
                    .onAppear { chat.start() }
                    .task {
                        if case .idle = bootstrap.loadState {
                            await bootstrap.refresh()
                        }
                    }
                    // 次のカードに替わった時(解いている途中のカードは採点まで終わっている)に、使い切っていたら下から出す。
                    .onChange(of: timeline.currentID) { _, current in
                        guard current != nil, limitSnapshot == nil else { return }
                        let snapshot = UsageMeter.shared.snapshot()
                        if snapshot.isExhausted { limitSnapshot = snapshot }
                    }
                    .sheet(isPresented: $isUsagePreviewPresented) {
                        NavigationStack { UsageSettingsView() }
                    }
                    .sheet(item: $limitSnapshot) { snapshot in
                        UsageLimitSheet(snapshot: snapshot, store: subscriptions) { limitSnapshot = nil }
                            .presentationDetents([.height(380)])
                            .presentationDragIndicator(.visible)
                    }
            } else if auth.isRestoring {
                SessionRestoringView()
            } else {
                SignInEntryView()
            }
        }
    }
}

private struct SessionRestoringView: View {
    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            ProgressView().progressViewStyle(StruisProgressViewStyle())
                .controlSize(.large)
                .tint(.secondary)
        }
    }
}

private struct RootSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onReplayOnboarding: () -> Void

    var body: some View {
        NavigationStack {
            SettingsView {
                dismiss()
                onReplayOnboarding()
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

#if DEBUG
#Preview("AppRootView — Workbook home") {
    let client = APIClient()
    let auth = AuthStore(client: client)
    let learnerData = LearnerData(runtime: nil)
    let bootstrap = BootstrapStore(client: client, ledger: learnerData.ledger)
    let chat = ChatStore(ledger: learnerData.ledger, turns: learnerData.turns)
    let settings = SettingsStore(runtime: nil)
    let learningFeedRuntime = LearningFeedRuntimeServices(api: client)
    let workbook = WorkbookStore(ledger: learnerData.ledger, turns: learnerData.turns)
    AppRootView()
        .environment(client)
        .environment(auth)
        .environment(bootstrap)
        .environment(chat)
        .environment(settings)
        .environment(learnerData)
        .environment(learningFeedRuntime)
        .environment(workbook)
        .environment(WorkbookCoordinator())
        .environment(TimelineStore(ledger: learnerData.ledger, turns: learnerData.turns))
}
#endif
