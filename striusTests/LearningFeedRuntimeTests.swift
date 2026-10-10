import Foundation
import Testing
@testable import strius

@MainActor
struct LearningFeedRuntimeTests {
    private let fixtureNames = [
        "linear-intersection-v2.json",
        "fraction-comparison-v2.json",
        "recursion-memoization-v2.json",
    ]

    @Test func allAgeFixturesDecodeAndValidateWithTheSameV2Contract() throws {
        let router = LearningFeedArtifactRouter()
        for name in fixtureNames {
            let data = try fixtureData(named: name)
            let routed = try router.route(data, registry: .current, now: validationDate)
            guard case .v2(let pack) = routed else {
                Issue.record("\(name) was not routed to V2")
                continue
            }
            #expect(pack.episodes.count == 3)
            #expect(pack.manifest.verificationStatus == "verified")
            #expect(pack.episodes.allSatisfy { $0.verification.status == "verified" })
        }
    }

    @Test func routerSupportsV1AndRejectsFutureVersions() throws {
        let router = LearningFeedArtifactRouter()
        let v1 = try fixtureData(named: "single-choice-v1.json")
        guard case .v1(let artifact) = try router.route(v1, registry: .current, now: validationDate) else {
            Issue.record("V1 artifact was not routed to the compatibility decoder")
            return
        }
        #expect(artifact.artifactType == "LearningFeedItem")
        #expect(artifact.verification["status"] == .string("verified"))

        var futureRoot = try #require(JSONSerialization.jsonObject(with: v1) as? [String: Any])
        futureRoot["artifact_version"] = "3.0"
        let future = try JSONSerialization.data(withJSONObject: futureRoot, options: [.sortedKeys])
        do {
            _ = try router.route(future, registry: .current, now: validationDate)
            Issue.record("future artifact version was accepted")
        } catch let error as LearningFeedArtifactValidationError {
            #expect(error == .unsupportedVersion("3.0"))
        }
    }

    @Test func publicArtifactRejectsAnswerBearingFieldsBeforeDecode() throws {
        let router = LearningFeedArtifactRouter()
        var root = try #require(JSONSerialization.jsonObject(
            with: fixtureData(named: "linear-intersection-v2.json")
        ) as? [String: Any])
        var episodes = try #require(root["episodes"] as? [[String: Any]])
        var firstEpisode = episodes[0]
        var steps = try #require(firstEpisode["steps"] as? [[String: Any]])
        var firstStep = steps[0]
        var scene = try #require(firstStep["scene_state"] as? [String: Any])
        scene["correct_value"] = "leaked"
        firstStep["scene_state"] = scene
        steps[0] = firstStep
        firstEpisode["steps"] = steps
        episodes[0] = firstEpisode
        root["episodes"] = episodes
        let poisoned = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

        do {
            _ = try router.route(poisoned, registry: .current, now: validationDate)
            Issue.record("public answer field was accepted")
        } catch let error as LearningFeedArtifactValidationError {
            guard case .privateAnswerField(let path) = error else {
                Issue.record("unexpected validation error: \(error)")
                return
            }
            #expect(path.contains("correct_value"))
        }
    }

    @Test func rendererRegistryAdvertisesEverySupportedKindAndRejectsUnknownKind() throws {
        #expect(
            EpisodeRendererRegistry.current.advertisedVersions.count
                == EpisodeRendererKind.allCases.count
        )
        #expect(Set(EpisodeRendererRegistry.current.advertisedVersions.keys) == Set(EpisodeRendererKind.allCases.map(\.rawValue)))
        do {
            try EpisodeRendererRegistry.current.validate(kind: "future_renderer", minimumVersion: 1)
            Issue.record("unknown renderer was accepted")
        } catch let error as LearningFeedArtifactValidationError {
            #expect(error == .unsupportedRenderer(kind: "future_renderer", required: 1, available: nil))
        }
    }

    @Test func routerRejectsRendererConfigThatDoesNotMatchItsKind() throws {
        let router = LearningFeedArtifactRouter()
        var root = try #require(JSONSerialization.jsonObject(
            with: fixtureData(named: "linear-intersection-v2.json")
        ) as? [String: Any])
        var episodes = try #require(root["episodes"] as? [[String: Any]])
        var firstEpisode = episodes[0]
        var steps = try #require(firstEpisode["steps"] as? [[String: Any]])
        var exploring = steps[2]
        var config = try #require(exploring["interaction_config"] as? [String: Any])
        config["model"] = [
            "kind": "linear_intersection",
            "left_rate": 2.0,
            "left_initial": 1.0,
            "right_rate": 1.0,
            "right_initial": 4.0,
        ]
        exploring["interaction_config"] = config
        steps[2] = exploring
        firstEpisode["steps"] = steps
        episodes[0] = firstEpisode
        root["episodes"] = episodes
        let invalid = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

        do {
            _ = try router.route(invalid, registry: .current, now: validationDate)
            Issue.record("renderer-specific interaction config was accepted")
        } catch let error as LearningFeedArtifactValidationError {
            guard case .invalidStructure(let reason) = error else {
                Issue.record("unexpected validation error: \(error)")
                return
            }
            #expect(reason.contains("interaction_config"))
        }
    }

    @Test func routerRejectsDecimalOutsideCrossClientCanonicalRange() throws {
        var root = try #require(JSONSerialization.jsonObject(
            with: fixtureData(named: "linear-intersection-v2.json")
        ) as? [String: Any])
        var episodes = try #require(root["episodes"] as? [[String: Any]])
        var firstEpisode = episodes[0]
        var steps = try #require(firstEpisode["steps"] as? [[String: Any]])
        var scene = try #require(steps[0]["scene_state"] as? [String: Any])
        scene["unsafe_decimal"] = 0.00001
        steps[0]["scene_state"] = scene
        firstEpisode["steps"] = steps
        episodes[0] = firstEpisode
        root["episodes"] = episodes
        let invalid = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

        do {
            _ = try LearningFeedArtifactRouter().route(
                invalid,
                registry: .current,
                now: validationDate
            )
            Issue.record("cross-client unsafe decimal was accepted")
        } catch let error as LearningFeedArtifactValidationError {
            guard case .invalidStructure(let reason) = error else {
                Issue.record("unexpected validation error: \(error)")
                return
            }
            #expect(reason.contains("cross-client canonical range"))
        }
    }

    @Test func routerRejectsIncompleteDuplicateAndUnknownAccessibilitySemanticOrder() throws {
        let data = try fixtureData(named: "linear-intersection-v2.json")
        let originalRoot = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let originalEpisodes = try #require(originalRoot["episodes"] as? [[String: Any]])
        let originalSteps = try #require(originalEpisodes[0]["steps"] as? [[String: Any]])
        let originalAccessibility = try #require(originalSteps[0]["accessibility"] as? [String: Any])
        let originalOrder = try #require(originalAccessibility["semantic_order"] as? [String])
        let firstID = try #require(originalOrder.first)

        let invalidOrders: [[String]] = [
            Array(originalOrder.dropLast()),
            Array(originalOrder.dropLast()) + [firstID],
            originalOrder + ["unknown.semantic.element"],
        ]

        for invalidOrder in invalidOrders {
            var root = originalRoot
            var episodes = originalEpisodes
            var firstEpisode = episodes[0]
            var steps = originalSteps
            var firstStep = steps[0]
            var accessibility = originalAccessibility
            accessibility["semantic_order"] = invalidOrder
            firstStep["accessibility"] = accessibility
            steps[0] = firstStep
            firstEpisode["steps"] = steps
            episodes[0] = firstEpisode
            root["episodes"] = episodes
            let invalid = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

            do {
                _ = try LearningFeedArtifactRouter().route(
                    invalid,
                    registry: .current,
                    now: validationDate
                )
                Issue.record("invalid accessibility semantic order was accepted: \(invalidOrder)")
            } catch let error as LearningFeedArtifactValidationError {
                guard case .invalidStructure(let reason) = error else {
                    Issue.record("unexpected validation error: \(error)")
                    continue
                }
                #expect(reason.contains("semantic order"))
            }
        }
    }

    @Test func deepDiveMessageEncodesPrivateSessionContextOutsideLearnerFacingText() throws {
        let sessionID = UUID(uuidString: "10000000-0000-0000-0000-000000000088")!
        let learnerText = "この結果になる理由を教えてください。"
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(CreateMessageRequest(
            text: learnerText,
            learningFeedSessionID: sessionID
        ))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(body["text"] as? String == learnerText)
        #expect(body["learning_feed_session_id"] as? String == sessionID.uuidString)
        #expect(!learnerText.contains(sessionID.uuidString))
        #expect(LearningFeedDeepDiveGate.isReady(
            isOnline: true,
            forceOffline: false,
            syncStatus: .saved,
            hasUnacknowledgedEvents: false
        ))
        #expect(!LearningFeedDeepDiveGate.isReady(
            isOnline: false,
            forceOffline: true,
            syncStatus: .offlinePending,
            hasUnacknowledgedEvents: true
        ))
        #expect(!LearningFeedDeepDiveGate.isReady(
            isOnline: true,
            forceOffline: false,
            syncStatus: .saving,
            hasUnacknowledgedEvents: true
        ))
    }

    @Test func allSharedAgeFixturesCompleteEveryStepWithTheSameReducer() throws {
        for fixtureName in fixtureNames {
            let pack = try loadPack(named: fixtureName)
            var state = makeSnapshot(pack: pack)
            let reducer = LearningEpisodeReducer()
            var visitedStepIDs: [String] = []
            var emittedEventTypes: [String] = []

            emittedEventTypes += enqueuedEvents(from: reducer.reduce(
                state: &state,
                action: .opened(
                    offline: false,
                    occurredAt: validationDate,
                    monotonicOffsetMs: 0
                ),
                pack: pack
            )).map(\.eventType)

            let expectedStepCount = pack.episodes.reduce(0) { $0 + $1.steps.count }
            for iteration in 0..<(expectedStepCount + 1) {
                guard state.terminalAction == nil else { break }
                let episode = pack.episodes[state.episodeIndex]
                let step = episode.steps[state.stepIndex]
                visitedStepIDs.append("\(episode.id.uuidString):\(step.id)")
                try satisfyCompletionInput(
                    for: step,
                    state: &state,
                    reducer: reducer,
                    pack: pack
                )
                let isFinalEpisode = state.episodeIndex == pack.episodes.count - 1
                let boundaryChoice = step.stage == .boundary
                    ? (isFinalEpisode ? "close" : "next")
                    : nil
                let effects = reducer.reduce(
                    state: &state,
                    action: .advance(
                        boundaryChoice: boundaryChoice,
                        offline: false,
                        occurredAt: validationDate.addingTimeInterval(Double(iteration + 1)),
                        monotonicOffsetMs: (iteration + 1) * 1_000
                    ),
                    pack: pack
                )
                emittedEventTypes += enqueuedEvents(from: effects).map(\.eventType)
            }

            #expect(visitedStepIDs.count == expectedStepCount, "\(fixtureName)")
            #expect(Set(visitedStepIDs).count == expectedStepCount, "\(fixtureName)")
            #expect(emittedEventTypes.contains("interaction_committed"), "\(fixtureName)")
            #expect(emittedEventTypes.contains("consequence_revealed"), "\(fixtureName)")
            #expect(emittedEventTypes.contains("school_transfer_completed"), "\(fixtureName)")
            #expect(emittedEventTypes.filter { $0 == "episode_completed" }.count == pack.episodes.count)
            #expect(state.terminalAction == .complete, "\(fixtureName)")
        }
    }

    @Test func reducerCreatesContiguousStartEventsAndResetsInputForEachStep() throws {
        let pack = try loadPack(named: "linear-intersection-v2.json")
        var state = makeSnapshot(pack: pack)
        let reducer = LearningEpisodeReducer()
        let opened = reducer.reduce(
            state: &state,
            action: .opened(offline: true, occurredAt: validationDate, monotonicOffsetMs: 120),
            pack: pack
        )
        let startEvents = opened.flatMap { effect -> [LearningFeedV2Event] in
            if case .enqueue(let events) = effect { return events }
            return []
        }
        #expect(startEvents.map(\.eventType) == ["session_started", "episode_first_frame"])
        #expect(startEvents.map(\.sequenceNo) == [0, 1])
        #expect(startEvents.allSatisfy { $0.offline })

        _ = reducer.reduce(
            state: &state,
            action: .advance(boundaryChoice: nil, offline: true, occurredAt: validationDate, monotonicOffsetMs: 200),
            pack: pack
        )
        let committedStep = pack.episodes[0].steps[state.stepIndex]
        let selected = try #require(committedStep.choices.first)
        _ = reducer.reduce(state: &state, action: .selectChoice(selected.id), pack: pack)
        #expect(state.input.selectedChoiceID == selected.id)

        let committed = reducer.reduce(
            state: &state,
            action: .advance(boundaryChoice: nil, offline: true, occurredAt: validationDate, monotonicOffsetMs: 350),
            pack: pack
        )
        let committedEvents = committed.flatMap { effect -> [LearningFeedV2Event] in
            if case .enqueue(let events) = effect { return events }
            return []
        }
        #expect(committedEvents.map(\.eventType) == ["prediction_submitted"])
        #expect(committedEvents.first?.sequenceNo == 2)
        #expect(committedEvents.first?.payload["option_id"] == .string(selected.id))
        #expect(committedEvents.first?.payload["is_correct"] == nil)
        #expect(state.input.selectedChoiceID == nil)
        #expect(state.input.text.isEmpty)
        #expect(state.stepIndex == 2)
    }

    @Test func reducerKeepsExplorationResultVisibleInConsequenceScene() throws {
        let pack = try loadPack(named: "linear-intersection-v2.json")
        let episode = try #require(pack.episodes.first { episode in
            episode.steps.contains { $0.stage == .exploring }
        })
        let exploringIndex = try #require(episode.steps.firstIndex { $0.stage == .exploring })
        let consequenceIndex = exploringIndex + 1
        #expect(episode.steps[consequenceIndex].stage == .consequence)

        var state = makeSnapshot(pack: pack)
        state.episodeIndex = try #require(pack.episodes.firstIndex { $0.id == episode.id })
        state.stepIndex = exploringIndex
        state.input = .initial(for: episode.steps[exploringIndex])
        let reducer = LearningEpisodeReducer()
        _ = reducer.reduce(state: &state, action: .setParameter(3), pack: pack)
        #expect(state.input.parameterValue == 3)

        _ = reducer.reduce(
            state: &state,
            action: .advance(
                boundaryChoice: nil,
                offline: false,
                occurredAt: validationDate,
                monotonicOffsetMs: 500
            ),
            pack: pack
        )

        #expect(state.stepIndex == consequenceIndex)
        #expect(state.input.parameterValue == 3)
        #expect(state.input.initialParameterValue == 3)
        #expect(state.input.interactionCount == 0)
    }

    @Test func boundaryQueuesChoiceThenCompletionThenNextEpisodeFirstFrame() throws {
        let pack = try loadPack(named: "linear-intersection-v2.json")
        var state = makeSnapshot(pack: pack)
        let boundaryIndex = try #require(pack.episodes[0].steps.firstIndex { $0.stage == .boundary })
        state.didStart = true
        state.stepIndex = boundaryIndex
        state.input = .initial(for: pack.episodes[0].steps[boundaryIndex])
        state.nextSequenceNo = 8

        let effects = LearningEpisodeReducer().reduce(
            state: &state,
            action: .advance(
                boundaryChoice: "next",
                offline: true,
                occurredAt: validationDate,
                monotonicOffsetMs: 900
            ),
            pack: pack
        )
        let events = enqueuedEvents(from: effects)

        #expect(events.map(\.eventType) == [
            "boundary_choice", "episode_completed", "episode_first_frame",
        ])
        #expect(events.map(\.sequenceNo) == [8, 9, 10])
        #expect(events[0].episodeID == pack.episodes[0].episodeID)
        #expect(events[1].episodeID == pack.episodes[0].episodeID)
        #expect(events[2].episodeID == pack.episodes[1].episodeID)
        #expect(state.episodeIndex == 1)
        #expect(state.stepIndex == 0)
    }

    @Test func finalBoundaryQueuesSessionEndAfterEpisodeCompletion() throws {
        let pack = try loadPack(named: "linear-intersection-v2.json")
        let episodeIndex = pack.episodes.count - 1
        let boundaryIndex = try #require(pack.episodes[episodeIndex].steps.firstIndex {
            $0.stage == .boundary
        })
        var state = makeSnapshot(pack: pack)
        state.didStart = true
        state.episodeIndex = episodeIndex
        state.stepIndex = boundaryIndex
        state.input = .initial(for: pack.episodes[episodeIndex].steps[boundaryIndex])
        state.episodeStartedAt = validationDate
        state.stepStartedAt = validationDate
        let effects = LearningEpisodeReducer().reduce(
            state: &state,
            action: .advance(
                boundaryChoice: "close",
                offline: false,
                occurredAt: validationDate.addingTimeInterval(12),
                monotonicOffsetMs: 12_000
            ),
            pack: pack
        )
        let events = enqueuedEvents(from: effects)
        #expect(events.map(\.eventType) == [
            "boundary_choice", "episode_completed", "session_ended",
        ])
        #expect(events[0].payload["choice"] == .string("end"))
        #expect(events[1].payload["duration_ms"] == .number(12_000))
        #expect(events[2].payload == [
            "reason": .string("completed"),
            "within_budget": .bool(true),
        ])
        #expect(state.terminalAction == .complete)
    }

    @Test func firstBoundaryEndCompletesTheSessionEvenWhenEpisodesRemain() throws {
        let pack = try loadPack(named: "linear-intersection-v2.json")
        let boundaryIndex = try #require(pack.episodes[0].steps.firstIndex {
            $0.stage == .boundary
        })
        var state = makeSnapshot(pack: pack)
        state.didStart = true
        state.stepIndex = boundaryIndex
        state.input = .initial(for: pack.episodes[0].steps[boundaryIndex])

        let effects = LearningEpisodeReducer().reduce(
            state: &state,
            action: .advance(
                boundaryChoice: "close",
                offline: false,
                occurredAt: validationDate.addingTimeInterval(12),
                monotonicOffsetMs: 12_000
            ),
            pack: pack
        )
        let events = enqueuedEvents(from: effects)

        #expect(events.map(\.eventType) == [
            "boundary_choice", "episode_completed", "session_ended",
        ])
        #expect(events[0].payload["choice"] == .string("end"))
        #expect(events[2].payload["reason"] == .string("completed"))
        #expect(state.episodeIndex == 0)
        #expect(state.terminalAction == .complete)
        #expect(effects.contains(.requestTerminal(.complete)))
    }

    @Test func dragOrderReadsItemIDsAndSingleEvidenceReplacesPriorSelection() throws {
        let pack = try loadPack(named: "recursion-memoization-v2.json")
        let dragStep = try #require(pack.episodes.flatMap(\.steps).first {
            $0.rendererKind == EpisodeRendererKind.dragOrder.rawValue
        })
        let dragInput = LearningFeedStepInput.initial(for: dragStep)
        #expect(dragInput.orderedIDs.count >= 2)
        #expect(dragInput.orderedIDs.allSatisfy { !$0.isEmpty })

        let episodeIndex = try #require(pack.episodes.firstIndex { episode in
            episode.steps.contains { $0.stage == .invariantCheck && $0.rendererKind == EpisodeRendererKind.selectEvidence.rawValue }
        })
        let stepIndex = try #require(pack.episodes[episodeIndex].steps.firstIndex {
            $0.stage == .invariantCheck && $0.rendererKind == EpisodeRendererKind.selectEvidence.rawValue
        })
        let evidenceStep = pack.episodes[episodeIndex].steps[stepIndex]
        let firstChoice = try #require(evidenceStep.choices.first)
        let secondChoice = try #require(evidenceStep.choices.dropFirst().first)
        var state = makeSnapshot(pack: pack)
        state.episodeIndex = episodeIndex
        state.stepIndex = stepIndex
        state.input = .initial(for: evidenceStep)
        let reducer = LearningEpisodeReducer()

        _ = reducer.reduce(state: &state, action: .toggleEvidence(firstChoice.id), pack: pack)
        _ = reducer.reduce(state: &state, action: .toggleEvidence(secondChoice.id), pack: pack)
        #expect(state.input.selectedEvidenceIDs == [secondChoice.id])
        #expect(state.input.didMeaningfullyInteract)
        #expect(reducer.updatedEvidenceIDs(
            current: [firstChoice.id],
            selecting: secondChoice.id,
            selectionMode: "multiple"
        ) == [firstChoice.id, secondChoice.id])

        let effects = reducer.reduce(
            state: &state,
            action: .advance(
                boundaryChoice: nil,
                offline: false,
                occurredAt: validationDate,
                monotonicOffsetMs: 400
            ),
            pack: pack
        )
        let event = try #require(enqueuedEvents(from: effects).first)
        #expect(event.eventType == "invariant_checked")
        #expect(event.payload == [
            "selected_ids": .array([.string(secondChoice.id)]),
            "action_count": .number(2),
            "duration_ms": .number(0),
        ])
        #expect(event.payload["is_correct"] == nil)
    }

    @Test func reducerEmitsCanonicalGraphDragAndTextPayloadShapes() throws {
        let graphPack = try loadPack(named: "linear-intersection-v2.json")
        let graphStepIndex = try #require(graphPack.episodes[0].steps.firstIndex {
            $0.stage == .exploring && $0.rendererKind == EpisodeRendererKind.graphParameter.rawValue
        })
        let graphStep = graphPack.episodes[0].steps[graphStepIndex]
        var graphState = makeSnapshot(pack: graphPack)
        graphState.stepIndex = graphStepIndex
        graphState.input = .initial(for: graphStep)
        let reducer = LearningEpisodeReducer()
        _ = reducer.reduce(
            state: &graphState,
            action: .setParameter(graphState.input.parameterValue + 1),
            pack: graphPack
        )
        let graphEffects = reducer.reduce(
            state: &graphState,
            action: .advance(
                boundaryChoice: nil,
                offline: false,
                occurredAt: validationDate.addingTimeInterval(2),
                monotonicOffsetMs: 2_000
            ),
            pack: graphPack
        )
        let graphEvent = try #require(enqueuedEvents(from: graphEffects).first)
        #expect(graphEvent.payload == [
            "parameter_id": .string("x"),
            "initial_value": .number(4),
            "final_value": .number(5),
            "action_count": .number(1),
            "direction_changes": .number(0),
            "duration_ms": .number(2_000),
        ])

        let dragPack = try loadPack(named: "recursion-memoization-v2.json")
        let dragStepIndex = try #require(dragPack.episodes[0].steps.firstIndex {
            $0.stage == .exploring && $0.rendererKind == EpisodeRendererKind.dragOrder.rawValue
        })
        let dragStep = dragPack.episodes[0].steps[dragStepIndex]
        var dragState = makeSnapshot(pack: dragPack)
        dragState.stepIndex = dragStepIndex
        dragState.input = .initial(for: dragStep)
        let initialOrder = dragState.input.orderedIDs
        _ = reducer.reduce(
            state: &dragState,
            action: .moveOrderedItem(from: 0, to: 1),
            pack: dragPack
        )
        let finalOrder = dragState.input.orderedIDs
        let dragEffects = reducer.reduce(
            state: &dragState,
            action: .advance(
                boundaryChoice: nil,
                offline: false,
                occurredAt: validationDate.addingTimeInterval(1),
                monotonicOffsetMs: 1_000
            ),
            pack: dragPack
        )
        let dragEvent = try #require(enqueuedEvents(from: dragEffects).first)
        #expect(dragEvent.payload == [
            "initial_ordered_ids": .array(initialOrder.map(JSONValue.string)),
            "ordered_ids": .array(finalOrder.map(JSONValue.string)),
            "action_count": .number(1),
            "direction_changes": .number(0),
            "duration_ms": .number(1_000),
        ])

        let textStepIndex = try #require(graphPack.episodes[0].steps.firstIndex {
            $0.stage == .invariantCheck && $0.rendererKind == EpisodeRendererKind.numericInput.rawValue
        })
        let textStep = graphPack.episodes[0].steps[textStepIndex]
        var textState = makeSnapshot(pack: graphPack)
        textState.stepIndex = textStepIndex
        textState.input = .initial(for: textStep)
        _ = reducer.reduce(state: &textState, action: .setText("3"), pack: graphPack)
        let textEffects = reducer.reduce(
            state: &textState,
            action: .advance(
                boundaryChoice: nil,
                offline: false,
                occurredAt: validationDate,
                monotonicOffsetMs: 300
            ),
            pack: graphPack
        )
        #expect(try #require(enqueuedEvents(from: textEffects).first).payload == [
            "value": .string("3"),
        ])
    }

    @Test func sqliteAtomicallyPersistsQueueAndSnapshotAndRestoresPerUser() async throws {
        let pack = try loadPack(named: "linear-intersection-v2.json")
        var snapshot = makeSnapshot(pack: pack)
        let reducer = LearningEpisodeReducer()
        let effects = reducer.reduce(
            state: &snapshot,
            action: .opened(offline: true, occurredAt: validationDate, monotonicOffsetMs: 80),
            pack: pack
        )
        let events = effects.flatMap { effect -> [LearningFeedV2Event] in
            if case .enqueue(let values) = effect { return values }
            return []
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("struis-learning-feed-tests-\(UUID().uuidString)", isDirectory: true)
        let persistence = LearningFeedLocalPersistence(
            databaseURL: directory.appendingPathComponent("runtime.sqlite3")
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try await persistence.enqueueAndSaveSnapshot(
            userID: snapshot.userID,
            sessionID: snapshot.sessionID,
            events: events,
            snapshot: snapshot
        )
        let queued = try await persistence.pendingEvents(
            userID: snapshot.userID,
            sessionID: snapshot.sessionID,
            now: validationDate.addingTimeInterval(1)
        )
        let restored = try await persistence.loadSnapshot(
            userID: snapshot.userID,
            sessionID: snapshot.sessionID
        )
        let anotherUser = try await persistence.loadSnapshot(
            userID: "another-user",
            sessionID: snapshot.sessionID
        )

        #expect(queued.map(\.event.sequenceNo) == [0, 1])
        #expect(restored == snapshot)
        #expect(anotherUser == nil)

        var newerSnapshot = snapshot
        newerSnapshot.input.text = "newer"
        newerSnapshot.updatedAt = validationDate.addingTimeInterval(2)
        try await persistence.saveSnapshot(newerSnapshot)
        var staleSnapshot = snapshot
        staleSnapshot.input.text = "stale"
        staleSnapshot.updatedAt = validationDate.addingTimeInterval(1)
        try await persistence.saveSnapshot(staleSnapshot)
        #expect(try await persistence.loadSnapshot(
            userID: snapshot.userID,
            sessionID: snapshot.sessionID
        )?.input.text == "newer")

        try await persistence.enqueue(
            userID: snapshot.userID,
            sessionID: snapshot.sessionID,
            events: events
        )
        #expect(try await persistence.pendingEvents(
            userID: snapshot.userID,
            sessionID: snapshot.sessionID,
            now: validationDate.addingTimeInterval(1)
        ).count == 2)

        try await persistence.markAcknowledged(
            userID: snapshot.userID,
            clientEventIDs: Set(events.map(\.clientEventID))
        )
        #expect(try await persistence.hasUnacknowledgedEvents(
            userID: snapshot.userID,
            sessionID: snapshot.sessionID
        ) == false)

        try await persistence.markRejected(
            userID: snapshot.userID,
            clientEventIDs: [events[0].clientEventID],
            reason: "server rejected"
        )
        #expect(try await persistence.hasRejectedEvents(
            userID: snapshot.userID,
            sessionID: snapshot.sessionID
        ))
        _ = reducer.reduce(state: &snapshot, action: .syncRejected, pack: pack)
        #expect(snapshot.syncStatus == .rejected)
    }

    @Test func cachedReservationWithActiveSnapshotIsResumableUntilTerminalChoice() async throws {
        let data = try prefetchData(
            packNamed: "linear-intersection-v2.json",
            sessionID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        let router = LearningFeedArtifactRouter()
        let reservation = try router.decodePrefetch(data, registry: .current, now: validationDate)
        var snapshot = makeSnapshot(pack: reservation.pack)
        snapshot.didStart = true
        snapshot.stepIndex = 2
        snapshot.input = .initial(for: reservation.pack.episodes[0].steps[2])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("struis-learning-feed-resume-tests-\(UUID().uuidString)", isDirectory: true)
        let persistence = LearningFeedLocalPersistence(
            databaseURL: directory.appendingPathComponent("runtime.sqlite3")
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await persistence.cacheReservation(
            userID: snapshot.userID,
            response: reservation,
            rawData: data
        )
        try await persistence.saveSnapshot(snapshot)
        let runtime = LearningFeedRuntimeServices(
            api: APIClient(session: URLSession(configuration: .ephemeral)),
            persistence: persistence
        )

        let resumed = await runtime.resumableReservation(
            userID: snapshot.userID,
            now: validationDate
        )
        #expect(resumed?.sessionID == reservation.sessionID)

        snapshot.terminalAction = .close
        try await persistence.saveSnapshot(snapshot)
        let terminal = await runtime.resumableReservation(
            userID: snapshot.userID,
            now: validationDate
        )
        #expect(terminal?.sessionID == nil)
    }

    private var validationDate: Date {
        ISO8601DateFormatter().date(from: "2026-07-19T00:00:00Z")!
    }

    private func loadPack(named name: String) throws -> LearningFeedV2Pack {
        let routed = try LearningFeedArtifactRouter().route(
            fixtureData(named: name),
            registry: .current,
            now: validationDate
        )
        guard case .v2(let pack) = routed else {
            throw LearningFeedArtifactValidationError.unsupportedVersion("1.0")
        }
        return pack
    }

    private func fixtureData(named name: String) throws -> Data {
        guard let url = Bundle(for: EngineVectorBundleMarker.self).url(
            forResource: name, withExtension: nil, subdirectory: "learning-feed"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    private func prefetchData(packNamed name: String, sessionID: UUID) throws -> Data {
        let pack = try #require(JSONSerialization.jsonObject(
            with: fixtureData(named: name)
        ) as? [String: Any])
        let manifest = try #require(pack["manifest"] as? [String: Any])
        let expiresAt = try #require(manifest["expires_at"])
        let assets = try #require(manifest["assets"])
        let rendererRequirements = try #require(manifest["renderer_requirements"])
        let contentHash = try #require(manifest["content_hash"])
        let episodes = try #require(pack["episodes"])
        let response: [String: Any] = [
            "session_id": sessionID.uuidString,
            "server_revision": 1,
            "server_time": "2026-07-19T00:00:00Z",
            "reserved_at": "2026-07-19T00:00:00Z",
            "expires_at": expiresAt,
            "status": "reserved",
            "pack_manifest": manifest,
            "episodes": episodes,
            "assets": assets,
            "renderer_requirements": rendererRequirements,
            "content_hashes": [contentHash],
            "invalidation": [String: Any](),
            "pack": pack,
        ]
        return try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    }

    private func satisfyCompletionInput(
        for step: LearningFeedV2Step,
        state: inout LearningFeedSessionSnapshot,
        reducer: LearningEpisodeReducer,
        pack: LearningFeedV2Pack
    ) throws {
        if [.hook, .consequence, .boundary].contains(step.stage) { return }

        let minimumActions = max(1, step.completionCondition.minimumActions)
        switch try #require(EpisodeRendererKind(rawValue: step.rendererKind)) {
        case .binaryPrediction:
            let choices = step.choices
            let first = try #require(choices.first)
            for index in 0..<minimumActions {
                let choice = choices.indices.contains(index % max(1, choices.count))
                    ? choices[index % choices.count]
                    : first
                _ = reducer.reduce(state: &state, action: .selectChoice(choice.id), pack: pack)
            }
        case .directManipulation, .graphParameter:
            let lower = step.interactionConfig["min"]?.numberValue ?? 0
            let upper = step.interactionConfig["max"]?.numberValue ?? lower + 1
            let increment = max(0.000_1, step.interactionConfig["step"]?.numberValue ?? 1)
            for index in 0..<minimumActions {
                let current = state.input.parameterValue
                let increasing = index.isMultiple(of: 2) && current + increment <= upper
                let candidate = increasing ? current + increment : max(lower, current - increment)
                let value = candidate == current ? min(upper, current + increment) : candidate
                _ = reducer.reduce(state: &state, action: .setParameter(value), pack: pack)
            }
        case .dragOrder:
            _ = try #require(state.input.orderedIDs.dropFirst().first)
            for index in 0..<minimumActions {
                let source = index.isMultiple(of: 2) ? 0 : 1
                let destination = source == 0 ? 1 : 0
                _ = reducer.reduce(
                    state: &state,
                    action: .moveOrderedItem(from: source, to: destination),
                    pack: pack
                )
            }
        case .selectEvidence, .annotateText, .relationshipMap, .spatialArrangement,
             .dataFilter, .audioPrediction, .artifactCompare:
            let choices = step.choices
            let first = try #require(choices.first)
            for index in 0..<minimumActions {
                let choice = choices.indices.contains(index % max(1, choices.count))
                    ? choices[index % choices.count]
                    : first
                _ = reducer.reduce(state: &state, action: .toggleEvidence(choice.id), pack: pack)
            }
            if state.input.selectedEvidenceIDs.isEmpty {
                _ = reducer.reduce(state: &state, action: .toggleEvidence(first.id), pack: pack)
            }
        case .timelineCause, .proofRepair:
            _ = try #require(state.input.orderedIDs.dropFirst().first)
            for index in 0..<minimumActions {
                let source = index.isMultiple(of: 2) ? 0 : 1
                let destination = source == 0 ? 1 : 0
                _ = reducer.reduce(
                    state: &state,
                    action: .moveOrderedItem(from: source, to: destination),
                    pack: pack
                )
            }
        case .codeTrace:
            for index in 0..<minimumActions {
                _ = reducer.reduce(state: &state, action: .setParameter(Double(index + 1)), pack: pack)
            }
        case .numericInput:
            _ = reducer.reduce(state: &state, action: .setText("1"), pack: pack)
        case .equationInput:
            _ = reducer.reduce(state: &state, action: .setText("x = 1"), pack: pack)
        case .shortResponse:
            _ = reducer.reduce(state: &state, action: .setText("理由を説明します"), pack: pack)
        }
    }

    private func enqueuedEvents(from effects: [LearningEpisodeEffect]) -> [LearningFeedV2Event] {
        effects.flatMap { effect -> [LearningFeedV2Event] in
            if case .enqueue(let events) = effect { return events }
            return []
        }
    }

    private func makeSnapshot(pack: LearningFeedV2Pack) -> LearningFeedSessionSnapshot {
        LearningFeedSessionSnapshot(
            userID: "test-user",
            sessionID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            packID: pack.manifest.packID,
            packContentHash: pack.manifest.contentHash,
            episodeIndex: 0,
            stepIndex: 0,
            input: .initial(for: pack.episodes[0].steps[0]),
            nextSequenceNo: 0,
            didStart: false,
            episodeStartedAt: validationDate,
            stepStartedAt: validationDate,
            syncStatus: .saved,
            lastClientEventID: nil,
            serverRevision: 1,
            terminalAction: nil,
            terminalDelivered: false,
            updatedAt: validationDate
        )
    }
}
