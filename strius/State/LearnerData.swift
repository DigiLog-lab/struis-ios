import Foundation
import OSLog
import UIKit

private let learnerDataLog = Logger(subsystem: "com.digiloglab.strius", category: "ledger")


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

    // MARK: - 学習記録をまとめて消す(#78)

    /// 消している最中(設定の画面の表示)。
    private(set) var isErasing = false
    /// 端末の記録を消した後に、画面の状態を空に戻す(`striusApp` が各ストアを戻す)。
    var onLearningRecordsErased: (@MainActor () async -> Void)?
    private var erasureObserver: NSObjectProtocol?

    nonisolated enum ErasureResult: Equatable, Sendable {
        /// 端末と iCloud の記録を消した。
        case erased
        /// 端末の記録は消した。iCloud の記録は、次に iCloud に繋がった時に消す。
        case cloudPending
    }

    /// 設定の「すべての学習記録を消す」。消去の記録を置いてから、止める → 端末の記録 → 端末の設定 → iCloud の順に消す。
    /// 途中で止まっても、次の起動で `resumeErasure` が続きから消す。
    func eraseAllLearningRecords() async throws -> ErasureResult {
        isErasing = true
        defer { isErasing = false }
        let marker = ledger.pendingErasure()?.marker ?? LearningErasure.Marker.new()
        try await ledger.beginErasure(marker, remote: false)
        // 別の端末にも消してもらう印。ゾーンを作り直す前に置く(先にゾーンが消えた端末も、印で backups の ZIP まで消す)。
        if !isEphemeral { LearningErasure.publish(marker) }
        try await eraseOnThisDevice()
        return await iCloud.eraseCloud() ? .erased : .cloudPending
    }

    /// 起動した時: 途中で止まった消去の続きと、別の端末の消去の印を確かめる。印が届いたら(iCloud の Key-Value ストア)もう一度。
    func resumeErasure() async {
        if erasureObserver == nil, !isEphemeral {
            erasureObserver = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                                    object: NSUbiquitousKeyValueStore.default, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.applyRemoteErasure() }
                }
            }
        }
        if let pending = ledger.pendingErasure() {
            do {
                if !pending.localDone { try await eraseOnThisDevice() }
                if pending.remote { try await ledger.finishErasure() } else { _ = await iCloud.eraseCloud() }
            } catch {
                learnerDataLog.error("resuming the erasure failed: \(String(describing: error), privacy: .public)")
            }
        }
        await applyRemoteErasure()
    }

    /// 別の端末で学習記録が消された(iCloud の Key-Value ストアの印): この台帳が印より前に作られていれば、この端末の記録も消す。
    func applyRemoteErasure(marker: LearningErasure.Marker? = nil) async {
        guard !isErasing, let marker = marker ?? (isEphemeral ? nil : LearningErasure.cloudMarker()) else { return }
        do {
            switch ledger.remoteErasure(for: marker) {
            case .none:
                return
            case .acknowledge:
                try await ledger.acknowledgeErasure(marker)
            case .erase:
                isErasing = true
                defer { isErasing = false }
                learnerDataLog.notice("learning records were erased on another device; erasing here")
                try await ledger.beginErasure(marker, remote: true)
                try await eraseOnThisDevice()
                try await ledger.finishErasure()
            }
        } catch {
            learnerDataLog.error("applying the erasure from another device failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// この端末の記録を消す(何度呼んでも同じ結果)。動いているターンを止めてから、台帳とファイル、端末の設定、会話の控えを消し、
    /// 画面を空に戻す。
    private func eraseOnThisDevice() async throws {
        await turns.stopEverything()
        try await ledger.eraseLearningRecords()
        LearningErasure.clearDeviceState()
        ThreadContextStore.shared.removeAll()
        await onLearningRecordsErased?()
    }

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
