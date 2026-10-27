import Foundation
import OSLog

private let dataLog = Logger(subsystem: "com.digiloglab.strius", category: "learner-data")

/// The learner's on-device data stack: ledger, delivery cache and turn queue
/// (design §2). Created once at launch and shared with the stores.
@Observable
@MainActor
final class LearnerData {
    let ledger: Ledger
    let assets: AssetCache
    let turns: TurnCoordinator
    let runner: any TurnRunning
    let isEphemeral: Bool
    let requiresDelivery: Bool
    private(set) var deliveryState: DeliveryState = .idle

    enum DeliveryState: Equatable {
        case idle
        case refreshing
        case ready(String)
        case failed(String)
    }

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
            ledger = ephemeral ? try Ledger.inMemory() : try Ledger(path: StruisPaths.ledger)
        } catch {
            fatalError("ledger unavailable: \(error)")
        }
        var useMock = false
        #if DEBUG
        useMock = MockTurnRunner.isEnabled || runtime == nil || (SimulatorFixtures.isEnabled && !DeviceRuntime.isForcedInFixtures)
        #endif
        assets = AssetCache(lenient: useMock)
        #if DEBUG
        if useMock {
            runner = MockTurnRunner()
        } else {
            runner = CodexTurnRunner(runtime: runtime!, assets: assets)
        }
        #else
        runner = CodexTurnRunner(runtime: runtime!, assets: assets)
        #endif
        requiresDelivery = !useMock
        turns = TurnCoordinator(ledger: ledger, assets: assets, runner: runner)
        TimelineQueryHost.install(ledger)
    }

    private var usageReporter: UsageReporter?

    /// Seed fixtures (DEBUG) and refresh the delivery cache.
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
        if let local = LocalDirectoryAssetSource.fromEnvironment {
            await refreshAssets(from: local)
            return
        }
        if SimulatorFixtures.isEnabled { return }
        #endif
        await refreshAssets(client: client)
    }

    /// Refresh the authenticated delivery cache from the server. This is shared
    /// by the authenticated launch path and the Settings recovery path.
    func refreshAssets(client: APIClient) async {
        guard requiresDelivery else { return }
        #if DEBUG
        if let local = LocalDirectoryAssetSource.fromEnvironment {
            await refreshAssets(from: local)
            return
        }
        if SimulatorFixtures.isEnabled { return }
        #endif
        await refreshAssets(from: ServerAssetSource(client: client))
    }

    func refreshAssets(from source: any AssetSource) async {
        guard requiresDelivery, deliveryState != .refreshing else { return }
        deliveryState = .refreshing
        do {
            let manifest = try await assets.refresh(from: source)
            deliveryState = .ready(manifest.fetchedAt ?? "")
        } catch {
            dataLog.error("delivery refresh failed: \(String(describing: error), privacy: .public)")
            // An older complete cache is still valid because turns never fetch
            // from the server. Keep it usable while reporting the refresh issue.
            if await assets.isReady {
                deliveryState = .ready("cached")
            } else {
                deliveryState = .failed(Self.deliveryMessage(for: error))
            }
        }
    }

    var isDeliveryReady: Bool {
        guard requiresDelivery else { return true }
        if case .ready = deliveryState { return true }
        return false
    }

    var isDeliveryRefreshing: Bool {
        if case .refreshing = deliveryState { return true }
        return false
    }

    var deliverySummary: String {
        guard requiresDelivery else { return "この環境では準備済み" }
        switch deliveryState {
        case .idle: return "未準備"
        case .refreshing: return "更新中"
        case .ready: return "利用できます"
        case .failed: return "更新が必要です"
        }
    }

    var deliveryDetail: String {
        guard requiresDelivery else { return "試験用データで質問できます" }
        switch deliveryState {
        case .idle: return "質問に必要なデータを確認します"
        case .refreshing: return "質問に必要なデータを更新しています"
        case .ready: return "質問を送信できます"
        case .failed: return "設定から配信データを更新してください"
        }
    }

    private static func deliveryMessage(for error: Error) -> String {
        guard let apiError = error as? APIError else {
            return "配信データを更新できませんでした。もう一度お試しください"
        }
        switch apiError {
        case .unauthorized:
            return "ログイン状態を確認してから、もう一度更新してください"
        case .transport:
            return "ネットワークに接続できません。接続を確認して、もう一度更新してください"
        case .server, .decoding, .invalidResponse:
            return "配信データを更新できませんでした。もう一度お試しください"
        }
    }
}
