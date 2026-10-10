import Foundation
import OSLog

private let learningEpisodeLog = Logger(
    subsystem: "com.digiloglab.strius",
    category: "learning-episode"
)

nonisolated enum LearningFeedDeepDiveGate {
    static func isReady(
        isOnline: Bool,
        forceOffline: Bool,
        syncStatus: LearningFeedSyncStatus,
        hasUnacknowledgedEvents: Bool
    ) -> Bool {
        isOnline
            && !forceOffline
            && syncStatus == .saved
            && !hasUnacknowledgedEvents
    }
}

@Observable
@MainActor
final class LearningEpisodeStore {
    private(set) var state: LearningFeedSessionSnapshot
    private(set) var runtimeError: String?
    private(set) var deepDiveError: String?
    private(set) var isStarting = true

    let reservation: LearningFeedV2PrefetchResponse

    private let userID: String
    private let deviceID: String
    private let api: APIClient
    private let runtime: LearningFeedRuntimeServices
    private let launchDecisionID: UUID?
    private let reducer = LearningEpisodeReducer()
    private let startedUptime = ProcessInfo.processInfo.systemUptime
    private var snapshotTask: Task<Void, Never>?
    private var forceOffline = false
    private var activationTask: Task<Void, Never>?

    init(
        reservation: LearningFeedV2PrefetchResponse,
        userID: String,
        deviceID: String,
        chatThreadID: UUID?,
        api: APIClient,
        runtime: LearningFeedRuntimeServices,
        launchDecisionID: UUID? = nil
    ) {
        self.reservation = reservation
        self.userID = userID
        self.deviceID = deviceID
        self.api = api
        self.runtime = runtime
        self.launchDecisionID = launchDecisionID

        let firstStep = reservation.pack.episodes[0].steps[0]
        let now = Date()
        state = LearningFeedSessionSnapshot(
            userID: userID,
            sessionID: reservation.sessionID,
            packID: reservation.pack.manifest.packID,
            packContentHash: reservation.pack.manifest.contentHash,
            episodeIndex: 0,
            stepIndex: 0,
            input: .initial(for: firstStep),
            nextSequenceNo: 0,
            didStart: false,
            episodeStartedAt: now,
            stepStartedAt: now,
            syncStatus: .saved,
            lastClientEventID: nil,
            serverRevision: reservation.serverRevision,
            chatThreadID: chatThreadID,
            terminalAction: nil,
            terminalDelivered: false,
            updatedAt: now
        )
    }

    var pack: LearningFeedV2Pack { reservation.pack }

    func setDeepDiveError(_ message: String?) {
        deepDiveError = message
    }

    var currentEpisode: LearningFeedV2Episode {
        pack.episodes[state.episodeIndex]
    }

    var currentStep: LearningFeedV2Step {
        currentEpisode.steps[state.stepIndex]
    }

    var progress: Double {
        let completedEpisodes = pack.episodes.prefix(state.episodeIndex).reduce(0) { $0 + $1.steps.count }
        let total = max(1, pack.episodes.reduce(0) { $0 + $1.steps.count })
        return Double(completedEpisodes + state.stepIndex + 1) / Double(total)
    }

    var canAdvance: Bool {
        guard state.syncStatus != .rejected, state.terminalAction == nil else { return false }
        return reducer.canAdvance(state: state, step: currentStep)
    }

    var syncText: String {
        switch state.syncStatus {
        case .saved: "保存済み"
        case .saving: "保存中"
        case .offlinePending: "接続が戻ったら保存します"
        case .rejected: "この問題は続けられません"
        }
    }

    func start() async {
        defer { isStarting = false }
        do {
            if let restored = try await runtime.persistence.loadSnapshot(
                userID: userID,
                sessionID: reservation.sessionID
            ), restored.packID == reservation.pack.manifest.packID,
               restored.packContentHash == reservation.pack.manifest.contentHash,
               !restored.terminalDelivered,
               pack.episodes.indices.contains(restored.episodeIndex),
               pack.episodes[restored.episodeIndex].steps.indices.contains(restored.stepIndex)
            {
                state = restored
            }
            if !runtime.isOnline {
                guard reservation.expiresAt > Date() else {
                    throw LearningFeedArtifactValidationError.expired
                }
            }
        } catch {
            runtimeError = Self.message(for: error)
            learningEpisodeLog.error("learning episode start failed: \(String(describing: error))")
        }
    }

    func selectChoice(_ id: String) {
        applyLocally(.selectChoice(id))
        beginActivationIfNeeded()
    }

    func setParameter(_ value: Double) {
        applyLocally(.setParameter(value))
        beginActivationIfNeeded()
    }

    func setText(_ value: String) {
        applyLocally(.setText(value))
        beginActivationIfNeeded()
    }

    func moveOrderedItem(from: Int, to: Int) {
        applyLocally(.moveOrderedItem(from: from, to: to))
        beginActivationIfNeeded()
    }

    func toggleEvidence(_ id: String) {
        applyLocally(.toggleEvidence(id))
        beginActivationIfNeeded()
    }

    func advance() async {
        await activateIfNeeded()
        await apply(.advance(
            boundaryChoice: nil,
            offline: isOperatingOffline,
            occurredAt: Date(),
            monotonicOffsetMs: monotonicOffsetMs
        ))
    }

    func chooseBoundary(_ choice: String) async -> Bool {
        await activateIfNeeded()
        await apply(.advance(
            boundaryChoice: choice,
            offline: isOperatingOffline,
            occurredAt: Date(),
            monotonicOffsetMs: monotonicOffsetMs
        ))
        return state.terminalAction != nil
    }

    func close() async -> Bool {
        await apply(.close(
            offline: isOperatingOffline,
            occurredAt: Date(),
            monotonicOffsetMs: monotonicOffsetMs
        ))
        await syncNow()
        return state.terminalAction != nil
    }

    func resumeAfterForeground() async {
        await syncNow()
    }

    func prepareDeepDive() async -> Bool {
        await syncNow()
        let hasUnacknowledgedEvents = (try? await runtime.persistence.hasUnacknowledgedEvents(
            userID: userID,
            sessionID: reservation.sessionID
        )) ?? true
        return LearningFeedDeepDiveGate.isReady(
            isOnline: runtime.isOnline,
            forceOffline: forceOffline,
            syncStatus: state.syncStatus,
            hasUnacknowledgedEvents: hasUnacknowledgedEvents
        )
    }

    private var monotonicOffsetMs: Int {
        Int(max(0, (ProcessInfo.processInfo.systemUptime - startedUptime) * 1_000))
    }

    private func beginActivationIfNeeded() {
        guard !state.didStart, activationTask == nil else { return }
        activationTask = Task { await activateIfNeeded() }
    }

    private func activateIfNeeded() async {
        guard !state.didStart else { return }
        var startsOffline = !runtime.isOnline
        if !startsOffline {
            do {
                let data = try await api.sendData(
                    .learningFeedV2Activate(sessionID: reservation.sessionID),
                    body: LearningFeedV2ActivateBody(deviceID: deviceID, lastClientEventID: nil)
                )
                let response = try runtime.artifactRouter.decodeActivate(
                    data,
                    registry: runtime.registry,
                    expectedContentHash: pack.manifest.contentHash
                )
                state.serverRevision = response.serverRevision
            } catch APIError.transport(_) {
                startsOffline = true
                forceOffline = true
            } catch {
                runtimeError = Self.message(for: error)
                activationTask = nil
                return
            }
        }
        await apply(.opened(
            offline: startsOffline,
            occurredAt: Date(),
            monotonicOffsetMs: monotonicOffsetMs
        ))
        if let launchDecisionID {
            _ = try? await api.sendVoid(
                .experienceLaunchResolve(decisionID: launchDecisionID),
                body: ExperienceLaunchResolveRequest(
                    chosenSurface: "canvas",
                    resolution: "canvas_meaningful_action",
                    resolvedAt: Date()
                )
            )
        }
        activationTask = nil
    }

    private var isOperatingOffline: Bool {
        forceOffline || !runtime.isOnline
    }

    private func applyLocally(_ action: LearningEpisodeAction) {
        guard state.syncStatus != .rejected, state.terminalAction == nil else { return }
        let effects = reducer.reduce(state: &state, action: action, pack: pack)
        guard effects.contains(.persistSnapshot) else { return }
        state.updatedAt = Date()
        snapshotTask?.cancel()
        let snapshot = state
        let persistence = runtime.persistence
        snapshotTask = Task {
            do {
                try await persistence.saveSnapshot(snapshot)
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.runtimeError = Self.message(for: error)
                }
            }
        }
    }

    private func apply(_ action: LearningEpisodeAction) async {
        let previous = state
        let previousStage = currentStep.stage
        let reduceStartedUptime = ProcessInfo.processInfo.systemUptime
        let effects = reducer.reduce(state: &state, action: action, pack: pack)
        if previousStage == .exploring, currentStep.stage == .consequence {
            let responseMs = Int(max(
                0,
                (ProcessInfo.processInfo.systemUptime - reduceStartedUptime) * 1_000
            ))
            learningEpisodeLog.info(
                "local consequence response_ms=\(responseMs, privacy: .public)"
            )
        }
        guard !effects.isEmpty else { return }
        do {
            let events = effects.flatMap { effect -> [LearningFeedV2Event] in
                if case .enqueue(let values) = effect { return values }
                return []
            }
            if !events.isEmpty, effects.contains(.persistSnapshot) {
                try await runtime.persistence.enqueueAndSaveSnapshot(
                    userID: userID,
                    sessionID: reservation.sessionID,
                    events: events,
                    snapshot: state
                )
            } else if effects.contains(.persistSnapshot) {
                try await runtime.persistence.saveSnapshot(state)
            }
            runtimeError = nil
            runtime.requestBackgroundSync()
            await syncNow()
        } catch {
            state = previous
            runtimeError = Self.message(for: error)
            learningEpisodeLog.error("learning episode persistence failed: \(String(describing: error))")
        }
    }

    private func syncNow() async {
        guard runtime.isOnline else {
            forceOffline = true
            _ = reducer.reduce(state: &state, action: .syncFailed, pack: pack)
            try? await runtime.persistence.saveSnapshot(state)
            return
        }
        if let server = await runtime.syncSession(userID: userID, sessionID: reservation.sessionID) {
            forceOffline = false
            _ = reducer.reduce(
                state: &state,
                action: .reconcile(server, occurredAt: Date()),
                pack: pack
            )
            let hasRejected = (try? await runtime.persistence.hasRejectedEvents(
                userID: userID,
                sessionID: reservation.sessionID
            )) ?? false
            let hasPending = (try? await runtime.persistence.hasUnacknowledgedEvents(
                userID: userID,
                sessionID: reservation.sessionID
            )) ?? true
            if hasRejected {
                _ = reducer.reduce(state: &state, action: .syncRejected, pack: pack)
            } else if !hasPending, let last = state.lastClientEventID {
                _ = reducer.reduce(
                    state: &state,
                    action: .syncAcknowledged(
                        clientEventIDs: [last],
                        serverRevision: server.serverRevision
                    ),
                    pack: pack
                )
            }
            try? await runtime.persistence.saveSnapshot(state)
        } else {
            forceOffline = true
            _ = reducer.reduce(state: &state, action: .syncFailed, pack: pack)
            try? await runtime.persistence.saveSnapshot(state)
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return "学習内容を開けませんでした"
    }
}
