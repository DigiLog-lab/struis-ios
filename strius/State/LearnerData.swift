import Foundation
import UIKit


/// The learner's on-device data stack: ledger, bundled assets and turn queue
/// (design §2). Created once at launch and shared with the stores.
@Observable
@MainActor
final class LearnerData {
    let ledger: Ledger
    let assets: AssetCache
    let turns: TurnCoordinator
    let runner: any TurnRunning
    let iCloud: ICloudSync
    let isEphemeral: Bool
    /// DEBUG の模擬のターンで動いている(実 AI に繋がない)。
    let usesMockTurns: Bool

    init(runtime: DeviceRuntime?) {
        var ephemeral = false
        #if DEBUG
        // Simulator fixtures start from a fresh workbook on every launch, like the old in-memory fixture.
        ephemeral = SimulatorFixtures.isEnabled && !DeviceRuntime.isForcedInFixtures
            && ProcessInfo.processInfo.environment["STRUIS_LEDGER"] != "persistent"
        ephemeral = ephemeral || ProcessInfo.processInfo.environment["STRUIS_LEDGER"] == "memory"
        #endif
        isEphemeral = ephemeral
        do {
            try StruisPaths.prepare()
            ledger = ephemeral ? try Ledger.inMemory() : try Ledger(path: StruisPaths.ledger, installationID: UIDevice.current.identifierForVendor?.uuidString)
        } catch {
            fatalError("ledger unavailable: \(error)")
        }
        // iCloud sync (Issue #51) only for the real ledger, never under unit tests or fixtures.
        var syncs = !ephemeral && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #if DEBUG
        syncs = syncs && !SimulatorFixtures.isEnabled && ProcessInfo.processInfo.environment["STRUIS_ICLOUD_SYNC"] != "off"
        #endif
        iCloud = ICloudSync(ledger: ledger, cloud: syncs ? CloudKitSyncTransport(
            stateURL: StruisPaths.root.appendingPathComponent("sync/engine-state.json"),
            temporary: FileManager.default.temporaryDirectory.appendingPathComponent("struis-sync", isDirectory: true)
        ) : nil)
        var useMock = false
        #if DEBUG
        useMock = MockTurnRunner.isEnabled || runtime == nil || (SimulatorFixtures.isEnabled && !DeviceRuntime.isForcedInFixtures)
        #endif
        let cache: AssetCache = AssetCache()
        assets = cache
        let conversations: ClaudeConversationStore = ClaudeConversationStore(queue: ledger.queue)
        let claude: (DeviceRuntime) -> ClaudeTurnRunner = { runtime in
            ClaudeTurnRunner(assets: cache, conversations: conversations) { await runtime.start() }
        }
        #if DEBUG
        // Simulator の実 AI の検証では `STRUIS_DEVICE_RUNTIME=1` も要る(無いとモック)。
        runner = useMock ? MockTurnRunner() : claude(runtime!)
        #else
        runner = claude(runtime!)
        #endif
        usesMockTurns = useMock
        turns = TurnCoordinator(ledger: ledger, assets: assets, runner: runner)
        TimelineQueryHost.install(ledger)
    }

    private var usageReporter: UsageReporter?

    /// Start the usage reporter and seed fixtures (DEBUG).
    func prepare(client: APIClient) async {
        if usageReporter == nil {
            let reporter = UsageReporter(ledger: ledger, client: client)
            usageReporter = reporter
            await reporter.start()
        }
        #if DEBUG
        if SimulatorFixtures.isEnabled || (isEphemeral && ProcessInfo.processInfo.environment["STRUIS_UNIT_DELETION_UI_TEST"] == "1") {
            await LedgerFixtures.seedWorkbookIfEmpty(ledger)
            await LedgerFixtures.seedChatIfEmpty(ledger)
        }
        #endif
    }
}
