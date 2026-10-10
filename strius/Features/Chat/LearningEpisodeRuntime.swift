import Foundation

nonisolated enum EpisodeRendererKind: String, Codable, CaseIterable, Sendable {
    case binaryPrediction = "binary_prediction"
    case directManipulation = "direct_manipulation"
    case graphParameter = "graph_parameter"
    case dragOrder = "drag_order"
    case selectEvidence = "select_evidence"
    case numericInput = "numeric_input"
    case equationInput = "equation_input"
    case shortResponse = "short_response"
    case annotateText = "annotate_text"
    case relationshipMap = "relationship_map"
    case spatialArrangement = "spatial_arrangement"
    case timelineCause = "timeline_cause"
    case dataFilter = "data_filter"
    case codeTrace = "code_trace"
    case proofRepair = "proof_repair"
    case audioPrediction = "audio_prediction"
    case artifactCompare = "artifact_compare"
}

nonisolated struct EpisodeRendererCapability: Hashable, Sendable {
    let kind: EpisodeRendererKind
    let maximumVersion: Int
    let hasVoiceOverFallback: Bool
    let hasReducedMotionFallback: Bool
}

nonisolated struct EpisodeRendererRegistry: Sendable {
    nonisolated static let current = EpisodeRendererRegistry(capabilities: EpisodeRendererKind.allCases.map {
        EpisodeRendererCapability(
            kind: $0,
            maximumVersion: 1,
            hasVoiceOverFallback: true,
            hasReducedMotionFallback: true
        )
    })

    let capabilities: [EpisodeRendererKind: EpisodeRendererCapability]

    nonisolated init(capabilities: [EpisodeRendererCapability]) {
        self.capabilities = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.kind, $0) })
    }

    nonisolated var advertisedVersions: [String: Int] {
        Dictionary(uniqueKeysWithValues: capabilities.map { ($0.key.rawValue, $0.value.maximumVersion) })
    }

    nonisolated func kind(for rawValue: String) -> EpisodeRendererKind? {
        EpisodeRendererKind(rawValue: rawValue)
    }

    nonisolated func validate(kind rawValue: String, minimumVersion: Int) throws {
        guard let kind = kind(for: rawValue), let capability = capabilities[kind] else {
            throw LearningFeedArtifactValidationError.unsupportedRenderer(
                kind: rawValue,
                required: minimumVersion,
                available: nil
            )
        }
        guard capability.maximumVersion >= minimumVersion,
              capability.hasVoiceOverFallback,
              capability.hasReducedMotionFallback
        else {
            throw LearningFeedArtifactValidationError.unsupportedRenderer(
                kind: rawValue,
                required: minimumVersion,
                available: capability.maximumVersion
            )
        }
    }
}

nonisolated enum LearningFeedSyncStatus: String, Codable, Equatable, Sendable {
    case saved
    case saving
    case offlinePending = "offline_pending"
    case rejected
}

nonisolated enum LearningFeedTerminalAction: String, Codable, Equatable, Sendable {
    case complete
    case close
}

nonisolated struct LearningFeedStepInput: Codable, Equatable, Sendable {
    var selectedChoiceID: String?
    var parameterValue: Double
    var initialParameterValue: Double
    var text: String
    var orderedIDs: [String]
    var initialOrderedIDs: [String]
    var selectedEvidenceIDs: [String]
    var interactionCount: Int
    var directionChanges: Int
    var lastDirection: Int
    var didMeaningfullyInteract: Bool

    static func initial(for step: LearningFeedV2Step) -> LearningFeedStepInput {
        let initialParameter = step.parameters["initial_value"]?.numberValue
            ?? step.parameters["initial"]?.numberValue
            ?? step.parameters["base"]?.numberValue
            ?? 0
        let orderedIDs: [String]
        let orderKey = step.rendererKind == "timeline_cause" ? "events" : step.rendererKind == "proof_repair" ? "lines" : "items"
        if case .array(let values)? = step.parameters[orderKey] {
            orderedIDs = values.compactMap { value in
                guard case .object(let item) = value else { return nil }
                return item["id"]?.stringValue.learningFeedRuntimeNonEmpty
            }
        } else {
            orderedIDs = []
        }
        return LearningFeedStepInput(
            selectedChoiceID: nil,
            parameterValue: initialParameter,
            initialParameterValue: initialParameter,
            text: "",
            orderedIDs: orderedIDs,
            initialOrderedIDs: orderedIDs,
            selectedEvidenceIDs: [],
            interactionCount: 0,
            directionChanges: 0,
            lastDirection: 0,
            didMeaningfullyInteract: false
        )
    }
}

nonisolated struct LearningFeedSessionSnapshot: Codable, Equatable, Sendable {
    let userID: String
    let sessionID: UUID
    let packID: UUID
    let packContentHash: String
    var episodeIndex: Int
    var stepIndex: Int
    var input: LearningFeedStepInput
    var nextSequenceNo: Int
    var didStart: Bool
    var episodeStartedAt: Date
    var stepStartedAt: Date
    var syncStatus: LearningFeedSyncStatus
    var lastClientEventID: UUID?
    var serverRevision: Int?
    var chatThreadID: UUID? = nil
    var terminalAction: LearningFeedTerminalAction?
    var terminalDelivered: Bool
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case userID = "userId"
        case sessionID = "sessionId"
        case packID = "packId"
        case packContentHash
        case episodeIndex
        case stepIndex
        case input
        case nextSequenceNo
        case didStart
        case episodeStartedAt
        case stepStartedAt
        case syncStatus
        case lastClientEventID = "lastClientEventId"
        case serverRevision
        case chatThreadID = "chatThreadId"
        case terminalAction
        case terminalDelivered
        case updatedAt
    }
}

nonisolated enum LearningEpisodeAction: Equatable, Sendable {
    case opened(offline: Bool, occurredAt: Date, monotonicOffsetMs: Int)
    case selectChoice(String)
    case setParameter(Double)
    case setText(String)
    case moveOrderedItem(from: Int, to: Int)
    case toggleEvidence(String)
    case advance(boundaryChoice: String?, offline: Bool, occurredAt: Date, monotonicOffsetMs: Int)
    case close(offline: Bool, occurredAt: Date, monotonicOffsetMs: Int)
    case syncAcknowledged(clientEventIDs: Set<UUID>, serverRevision: Int?)
    case syncFailed
    case syncRejected
    case reconcile(LearningFeedV2SessionSnapshotResponse, occurredAt: Date)
}

nonisolated enum LearningEpisodeEffect: Equatable, Sendable {
    case enqueue([LearningFeedV2Event])
    case persistSnapshot
    case requestTerminal(LearningFeedTerminalAction)
}

nonisolated struct LearningEpisodeReducer: Sendable {
    private static let prohibitedPayloadKeys: Set<String> = [
        "is_correct", "correct", "evidence_tier", "mastery", "verification_status",
    ]

    func reduce(
        state: inout LearningFeedSessionSnapshot,
        action: LearningEpisodeAction,
        pack: LearningFeedV2Pack
    ) -> [LearningEpisodeEffect] {
        guard !pack.episodes.isEmpty,
              pack.episodes.indices.contains(state.episodeIndex),
              pack.episodes[state.episodeIndex].steps.indices.contains(state.stepIndex)
        else {
            return []
        }

        let episode = pack.episodes[state.episodeIndex]
        let step = episode.steps[state.stepIndex]
        switch action {
        case .opened(let offline, let occurredAt, let monotonicOffsetMs):
            guard !state.didStart else { return [] }
            let started = makeEvent(
                state: &state,
                episode: episode,
                step: step,
                eventType: "session_started",
                payload: [:],
                offline: offline,
                occurredAt: occurredAt,
                monotonicOffsetMs: monotonicOffsetMs,
                pack: pack
            )
            let firstFrame = makeEvent(
                state: &state,
                episode: episode,
                step: step,
                eventType: "episode_first_frame",
                payload: [
                    "load_ms": .number(Double(monotonicOffsetMs)),
                    "renderer": .string(step.rendererKind),
                    "renderer_version": .number(Double(step.rendererVersion)),
                ],
                offline: offline,
                occurredAt: occurredAt,
                monotonicOffsetMs: monotonicOffsetMs,
                pack: pack
            )
            state.didStart = true
            state.episodeStartedAt = occurredAt
            state.stepStartedAt = occurredAt
            state.syncStatus = offline ? .offlinePending : .saving
            state.updatedAt = occurredAt
            return [.enqueue([started, firstFrame]), .persistSnapshot]

        case .selectChoice(let choiceID):
            guard step.choices.contains(where: { $0.id == choiceID }) else { return [] }
            state.input.selectedChoiceID = choiceID
            state.input.didMeaningfullyInteract = true
            state.input.interactionCount += 1
            return [.persistSnapshot]

        case .setParameter(let value):
            let lower = step.parameters["minimum"]?.numberValue ?? step.parameters["min"]?.numberValue ?? 0
            let upper = step.parameters["maximum"]?.numberValue ?? step.parameters["max"]?.numberValue ?? 10
            let bounded = min(max(value, lower), upper)
            let direction = bounded == state.input.parameterValue ? 0 : (bounded > state.input.parameterValue ? 1 : -1)
            if state.input.lastDirection != 0, direction != 0, direction != state.input.lastDirection {
                state.input.directionChanges += 1
            }
            if direction != 0 {
                state.input.lastDirection = direction
                state.input.interactionCount += 1
                state.input.didMeaningfullyInteract = true
            }
            state.input.parameterValue = bounded
            return [.persistSnapshot]

        case .setText(let value):
            let configuredMaximum = step.interactionConfig["max_length"]?.numberValue.map(Int.init) ?? 2_000
            state.input.text = String(value.prefix(max(1, min(configuredMaximum, 2_000))))
            state.input.didMeaningfullyInteract = !state.input.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            return [.persistSnapshot]

        case .moveOrderedItem(let source, let destination):
            guard state.input.orderedIDs.indices.contains(source),
                  destination >= 0, destination < state.input.orderedIDs.count,
                  source != destination
            else { return [] }
            let item = state.input.orderedIDs.remove(at: source)
            state.input.orderedIDs.insert(item, at: destination)
            let direction = destination > source ? 1 : -1
            if state.input.lastDirection != 0, direction != state.input.lastDirection {
                state.input.directionChanges += 1
            }
            state.input.lastDirection = direction
            state.input.interactionCount += 1
            state.input.didMeaningfullyInteract = true
            return [.persistSnapshot]

        case .toggleEvidence(let evidenceID):
            guard step.choices.contains(where: { $0.id == evidenceID }) else { return [] }
            let selectionMode = step.interactionConfig["selection_mode"]?.stringValue ?? "single"
            state.input.selectedEvidenceIDs = updatedEvidenceIDs(
                current: state.input.selectedEvidenceIDs,
                selecting: evidenceID,
                selectionMode: selectionMode
            )
            state.input.didMeaningfullyInteract = !state.input.selectedEvidenceIDs.isEmpty
            state.input.interactionCount += 1
            return [.persistSnapshot]

        case .advance(let boundaryChoice, let offline, let occurredAt, let monotonicOffsetMs):
            guard canAdvance(state: state, step: step, boundaryChoice: boundaryChoice) else { return [] }
            if step.stage == .boundary {
                let choice = boundaryChoice ?? "close"
                let hasNextEpisode = state.episodeIndex + 1 < pack.episodes.count
                let continues = choice == "next" && hasNextEpisode
                var events = [makeEvent(
                    state: &state,
                    episode: episode,
                    step: step,
                    eventType: "boundary_choice",
                    payload: ["choice": .string(continues ? "continue" : "end")],
                    offline: offline,
                    occurredAt: occurredAt,
                    monotonicOffsetMs: monotonicOffsetMs,
                    pack: pack
                )]
                events.append(makeEvent(
                    state: &state,
                    episode: episode,
                    step: step,
                    eventType: "episode_completed",
                    payload: [
                        "duration_ms": .number(Double(Self.durationMs(
                            from: state.episodeStartedAt,
                            to: occurredAt
                        ))),
                    ],
                    offline: offline,
                    occurredAt: occurredAt,
                    monotonicOffsetMs: monotonicOffsetMs,
                    pack: pack
                ))
                if continues {
                    state.episodeIndex += 1
                    state.stepIndex = 0
                    let nextEpisode = pack.episodes[state.episodeIndex]
                    let nextStep = nextEpisode.steps[0]
                    state.input = .initial(for: nextStep)
                    state.episodeStartedAt = occurredAt
                    state.stepStartedAt = occurredAt
                    events.append(makeEvent(
                        state: &state,
                        episode: nextEpisode,
                        step: nextStep,
                        eventType: "episode_first_frame",
                        payload: [
                            "load_ms": .number(0),
                            "renderer": .string(nextStep.rendererKind),
                            "renderer_version": .number(Double(nextStep.rendererVersion)),
                        ],
                        offline: offline,
                        occurredAt: occurredAt,
                        monotonicOffsetMs: monotonicOffsetMs,
                        pack: pack
                    ))
                    state.syncStatus = offline ? .offlinePending : .saving
                    state.updatedAt = occurredAt
                    return [.enqueue(events), .persistSnapshot]
                }
                events.append(makeEvent(
                    state: &state,
                    episode: episode,
                    step: step,
                    eventType: "session_ended",
                    payload: [
                        "reason": .string("completed"),
                        "within_budget": .bool(true),
                    ],
                    offline: offline,
                    occurredAt: occurredAt,
                    monotonicOffsetMs: monotonicOffsetMs,
                    pack: pack
                ))
                state.terminalAction = .complete
                state.syncStatus = offline ? .offlinePending : .saving
                state.updatedAt = occurredAt
                return [.enqueue(events), .persistSnapshot, .requestTerminal(.complete)]
            }

            var events: [LearningFeedV2Event] = []
            if let eventType = eventType(for: step.stage) {
                events.append(makeEvent(
                    state: &state,
                    episode: episode,
                    step: step,
                    eventType: eventType,
                    payload: payload(
                        for: step,
                        input: state.input,
                        durationMs: Self.durationMs(from: state.stepStartedAt, to: occurredAt)
                    ),
                    offline: offline,
                    occurredAt: occurredAt,
                    monotonicOffsetMs: monotonicOffsetMs,
                    pack: pack
                ))
            }

            if state.stepIndex + 1 < episode.steps.count {
                let completedInput = state.input
                state.stepIndex += 1
                let nextStep = episode.steps[state.stepIndex]
                state.input = transitionInput(
                    from: step,
                    completedInput: completedInput,
                    to: nextStep
                )
                state.stepStartedAt = occurredAt
            }
            state.syncStatus = offline ? .offlinePending : .saving
            state.updatedAt = occurredAt
            return events.isEmpty ? [.persistSnapshot] : [.enqueue(events), .persistSnapshot]

        case .close(let offline, let occurredAt, let monotonicOffsetMs):
            guard state.terminalAction == nil else { return [] }
            let event = makeEvent(
                state: &state,
                episode: episode,
                step: step,
                eventType: "session_ended",
                payload: [
                    "reason": .string("user_closed"),
                    "within_budget": .bool(true),
                ],
                offline: offline,
                occurredAt: occurredAt,
                monotonicOffsetMs: monotonicOffsetMs,
                pack: pack
            )
            state.terminalAction = .close
            state.syncStatus = offline ? .offlinePending : .saving
            state.updatedAt = occurredAt
            return [.enqueue([event]), .persistSnapshot, .requestTerminal(.close)]

        case .syncAcknowledged(let ids, let revision):
            if let last = state.lastClientEventID, ids.contains(last) {
                state.syncStatus = .saved
            }
            state.serverRevision = revision ?? state.serverRevision
            return [.persistSnapshot]

        case .syncFailed:
            state.syncStatus = .offlinePending
            return [.persistSnapshot]

        case .syncRejected:
            state.syncStatus = .rejected
            return [.persistSnapshot]

        case .reconcile(let server, let occurredAt):
            state.serverRevision = server.serverRevision
            if server.isPackInvalidated {
                state.syncStatus = .rejected
            }
            if let episodeID = server.currentEpisodeID,
               let episodeIndex = pack.episodes.firstIndex(where: { $0.id == episodeID }),
               let stepID = server.currentStepID,
               let stepIndex = pack.episodes[episodeIndex].steps.firstIndex(where: { $0.id == stepID }),
               episodeIndex > state.episodeIndex || (episodeIndex == state.episodeIndex && stepIndex > state.stepIndex)
            {
                state.episodeIndex = episodeIndex
                state.stepIndex = stepIndex
                state.input = .initial(for: pack.episodes[episodeIndex].steps[stepIndex])
                state.episodeStartedAt = occurredAt
                state.stepStartedAt = occurredAt
            }
            return [.persistSnapshot]
        }
    }

    func canAdvance(
        state: LearningFeedSessionSnapshot,
        step: LearningFeedV2Step,
        boundaryChoice: String? = nil
    ) -> Bool {
        if step.stage == .hook || step.stage == .consequence { return true }
        if step.stage == .boundary { return boundaryChoice == "next" || boundaryChoice == "close" }
        guard let kind = EpisodeRendererKind(rawValue: step.renderer) else { return false }
        let minimumActions = max(1, step.completionCondition.minimumActions)
        switch kind {
        case .binaryPrediction:
            return state.input.selectedChoiceID != nil && state.input.interactionCount >= minimumActions
        case .directManipulation, .graphParameter, .dragOrder:
            return state.input.didMeaningfullyInteract && state.input.interactionCount >= minimumActions
        case .selectEvidence, .annotateText, .relationshipMap, .dataFilter, .audioPrediction,
             .artifactCompare:
            return !state.input.selectedEvidenceIDs.isEmpty && state.input.interactionCount >= minimumActions
        case .spatialArrangement, .timelineCause, .codeTrace, .proofRepair:
            return state.input.didMeaningfullyInteract && state.input.interactionCount >= minimumActions
        case .numericInput, .equationInput, .shortResponse:
            return !state.input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func updatedEvidenceIDs(
        current: [String],
        selecting evidenceID: String,
        selectionMode: String
    ) -> [String] {
        if selectionMode == "single" {
            return current == [evidenceID] ? [] : [evidenceID]
        }
        if let index = current.firstIndex(of: evidenceID) {
            var updated = current
            updated.remove(at: index)
            return updated
        }
        return current + [evidenceID]
    }

    private func eventType(for stage: LearningFeedStage) -> String? {
        switch stage {
        case .committed: "prediction_submitted"
        case .exploring: "interaction_committed"
        case .consequence: "consequence_revealed"
        case .invariantCheck: "invariant_checked"
        case .variationCheck: "variation_completed"
        case .schoolTransfer: "school_transfer_completed"
        case .preloaded, .hook, .boundary, .completed, .paused, .closed, .offlinePending, .failed: nil
        }
    }

    private func transitionInput(
        from completedStep: LearningFeedV2Step,
        completedInput: LearningFeedStepInput,
        to nextStep: LearningFeedV2Step
    ) -> LearningFeedStepInput {
        var nextInput = LearningFeedStepInput.initial(for: nextStep)
        guard completedStep.stage == .exploring, nextStep.stage == .consequence else {
            return nextInput
        }

        let completedKind = EpisodeRendererKind(rawValue: completedStep.renderer)
        let nextKind = EpisodeRendererKind(rawValue: nextStep.renderer)
        let completedUsesParameter = completedKind == .directManipulation || completedKind == .graphParameter
        let nextUsesParameter = nextKind == .directManipulation || nextKind == .graphParameter
        let completedParameterID = completedStep.interactionConfig["parameter_id"]?
            .stringValue.learningFeedRuntimeNonEmpty
        let nextParameterID = nextStep.interactionConfig["parameter_id"]?
            .stringValue.learningFeedRuntimeNonEmpty
        if completedUsesParameter, nextUsesParameter,
           completedParameterID != nil, completedParameterID == nextParameterID
        {
            let lower = nextStep.parameters["minimum"]?.numberValue
                ?? nextStep.parameters["min"]?.numberValue
                ?? 0
            let upper = nextStep.parameters["maximum"]?.numberValue
                ?? nextStep.parameters["max"]?.numberValue
                ?? 10
            let carriedValue = min(max(completedInput.parameterValue, lower), upper)
            nextInput.parameterValue = carriedValue
            nextInput.initialParameterValue = carriedValue
        } else if completedKind == .dragOrder, nextKind == .dragOrder,
                  Set(completedInput.orderedIDs) == Set(nextInput.orderedIDs)
        {
            nextInput.orderedIDs = completedInput.orderedIDs
            nextInput.initialOrderedIDs = completedInput.orderedIDs
        } else if completedKind == .selectEvidence, nextKind == .selectEvidence {
            let nextIDs = Set(nextStep.choices.map(\.id))
            nextInput.selectedEvidenceIDs = completedInput.selectedEvidenceIDs.filter(nextIDs.contains)
        } else if completedKind == .binaryPrediction, nextKind == .binaryPrediction,
                  let selected = completedInput.selectedChoiceID,
                  nextStep.choices.contains(where: { $0.id == selected })
        {
            nextInput.selectedChoiceID = selected
        }
        return nextInput
    }

    private func payload(
        for step: LearningFeedV2Step,
        input: LearningFeedStepInput,
        durationMs: Int
    ) -> [String: JSONValue] {
        let raw: [String: JSONValue]
        switch EpisodeRendererKind(rawValue: step.renderer) {
        case .binaryPrediction:
            raw = ["option_id": .string(input.selectedChoiceID ?? "")]
        case .directManipulation, .graphParameter:
            raw = [
                "parameter_id": .string(step.interactionConfig["parameter_id"]?.stringValue ?? ""),
                "initial_value": .number(input.initialParameterValue),
                "final_value": .number(input.parameterValue),
                "action_count": .number(Double(input.interactionCount)),
                "direction_changes": .number(Double(input.directionChanges)),
                "duration_ms": .number(Double(durationMs)),
            ]
        case .dragOrder, .timelineCause, .proofRepair:
            raw = [
                "initial_ordered_ids": .array(input.initialOrderedIDs.map(JSONValue.string)),
                "ordered_ids": .array(input.orderedIDs.map(JSONValue.string)),
                "action_count": .number(Double(input.interactionCount)),
                "direction_changes": .number(Double(input.directionChanges)),
                "duration_ms": .number(Double(durationMs)),
            ]
        case .selectEvidence, .annotateText, .relationshipMap, .spatialArrangement,
             .dataFilter, .audioPrediction, .artifactCompare:
            raw = [
                "selected_ids": .array(input.selectedEvidenceIDs.map(JSONValue.string)),
                "action_count": .number(Double(input.interactionCount)),
                "duration_ms": .number(Double(durationMs)),
            ]
        case .numericInput, .equationInput, .shortResponse:
            raw = ["value": .string(input.text)]
        case .codeTrace:
            raw = [
                "trace_step": .number(input.parameterValue),
                "action_count": .number(Double(input.interactionCount)),
                "direction_changes": .number(Double(input.directionChanges)),
                "duration_ms": .number(Double(durationMs)),
            ]
        case nil:
            raw = [:]
        }
        return raw.filter { !Self.prohibitedPayloadKeys.contains($0.key) }
    }

    private static func durationMs(from start: Date, to end: Date) -> Int {
        let milliseconds = max(0, end.timeIntervalSince(start) * 1_000)
        return Int(min(86_400_000, milliseconds))
    }

    private func makeEvent(
        state: inout LearningFeedSessionSnapshot,
        episode: LearningFeedV2Episode,
        step: LearningFeedV2Step,
        eventType: String,
        payload: [String: JSONValue],
        offline: Bool,
        occurredAt: Date,
        monotonicOffsetMs: Int,
        pack: LearningFeedV2Pack
    ) -> LearningFeedV2Event {
        let event = LearningFeedV2Event(
            clientEventID: UUID(),
            sequenceNo: state.nextSequenceNo,
            episodeID: episode.id,
            episodeVersionID: episode.episodeVersionID,
            stepID: step.id,
            eventType: eventType,
            payload: payload.filter { !Self.prohibitedPayloadKeys.contains($0.key) },
            occurredAt: occurredAt,
            monotonicOffsetMs: monotonicOffsetMs,
            artifactVersion: pack.artifactVersion,
            offline: offline,
            runtime: LearningFeedEventRuntime(
                rendererKind: step.renderer,
                rendererVersion: step.rendererVersion,
                packContentHash: pack.manifest.contentHash
            )
        )
        state.nextSequenceNo += 1
        state.lastClientEventID = event.clientEventID
        return event
    }
}

private extension String {
    nonisolated var learningFeedRuntimeNonEmpty: String? { isEmpty ? nil : self }
}
