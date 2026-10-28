import SwiftUI

@main
struct striusApp: App {
    @State private var apiClient: APIClient
    @State private var auth: AuthStore
    @State private var bootstrap: BootstrapStore
    @State private var chat: ChatStore
    @State private var settings: SettingsStore
    @State private var learningFeedRuntime: LearningFeedRuntimeServices
    @State private var workbook: WorkbookStore
    @State private var workbookCoordinator = WorkbookCoordinator()
    @State private var deviceRuntime: DeviceRuntime?
    @State private var learnerData: LearnerData
    @State private var timeline: TimelineStore

    init() {
        #if DEBUG
        // UI tests: launch phases and main-thread stalls, read per test by the UI test bundle.
        UITestDiagnostics.start()
        // Verification aid: capture hyotan kernel messages (printk goes to stdio).
        if let path = ProcessInfo.processInfo.environment["STRUIS_STDIO_LOG"], !path.isEmpty {
            freopen(path, "w", stderr)
            freopen(path, "a", stdout)
            setvbuf(stdout, nil, _IOLBF, 0)
            setvbuf(stderr, nil, _IONBF, 0)
        }
        #endif
        let client = APIClient()
        let auth = AuthStore(client: client)
        let learningFeedRuntime = LearningFeedRuntimeServices(api: client)
        auth.setSignOutDataCleaner(learningFeedRuntime)
        let deviceRuntime: DeviceRuntime? = DeviceRuntime.isEnabledAtLaunch ? DeviceRuntime() : nil
        let learnerData = LearnerData(runtime: deviceRuntime)
        let settings = SettingsStore(runtime: deviceRuntime, ledger: learnerData.ledger)
        let bootstrap = BootstrapStore(client: client, ledger: learnerData.ledger)
        let chat = ChatStore(ledger: learnerData.ledger, turns: learnerData.turns)
        let workbook = WorkbookStore(ledger: learnerData.ledger, turns: learnerData.turns)
        let timeline = TimelineStore(ledger: learnerData.ledger, turns: learnerData.turns)
        auth.onSessionEnded = {
            bootstrap.reset()
            chat.reset()
            workbook.reset()
            timeline.reset()
            client.clearResourceCache()
            KaTeXLayoutCache.clear()
        }
        _apiClient = State(initialValue: client)
        _auth = State(initialValue: auth)
        _bootstrap = State(initialValue: bootstrap)
        _chat = State(initialValue: chat)
        _settings = State(initialValue: settings)
        _learningFeedRuntime = State(initialValue: learningFeedRuntime)
        _workbook = State(initialValue: workbook)
        _deviceRuntime = State(initialValue: deviceRuntime)
        _learnerData = State(initialValue: learnerData)
        _timeline = State(initialValue: timeline)
        #if DEBUG
        UITestDiagnostics.launch("init-end")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(apiClient)
                .environment(auth)
                .environment(bootstrap)
                .environment(chat)
                .environment(settings)
                .environment(learningFeedRuntime)
                .environment(workbook)
                .environment(workbookCoordinator)
                .environment(learnerData)
                .environment(timeline)
                .tint(Theme.Palette.accentLight)
                .progressViewStyle(StruisProgressViewStyle())
                .task {
                    // Prepare native runtime data and start the extension's app-server in the background;
                    // the ledger-backed screens do not wait for it (design §6.5).
                    guard let deviceRuntime, !SimulatorFixtures.isEnabled || DeviceRuntime.isForcedInFixtures else { return }
                    await deviceRuntime.start()
                }
        }
    }
}
