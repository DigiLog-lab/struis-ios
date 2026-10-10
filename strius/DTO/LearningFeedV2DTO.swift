import CryptoKit
import Foundation

nonisolated enum LearningFeedArtifactVersion: String, Codable, Sendable {
    case v1 = "1.0"
    case v2 = "2.0"
    case v21 = "2.1"
}

nonisolated enum LearningFeedStage: String, Codable, CaseIterable, Sendable {
    case preloaded
    case hook
    case committed
    case exploring
    case consequence
    case invariantCheck = "invariant_check"
    case variationCheck = "variation_check"
    case schoolTransfer = "school_transfer"
    case boundary
    case completed
    case paused
    case closed
    case offlinePending = "offline_pending"
    case failed
}

nonisolated struct LearningFeedV2PrefetchRequest: Encodable, Sendable {
    let threadID: UUID?
    let studyContextID: UUID?
    let availableSeconds: Int
    let learnerRequest: String?
    let entrySource: String
    let contextMode: String
    let clientCapabilities: LearningFeedClientCapabilities

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case studyContextID = "studyContextId"
        case availableSeconds
        case learnerRequest
        case entrySource
        case contextMode
        case clientCapabilities
    }
}

nonisolated struct LearningFeedClientCapabilities: Codable, Sendable {
    let artifactVersions: [String]
    let renderers: [String: Int]
}

nonisolated struct ExperienceLaunchRequest: Encodable, Sendable {
    let clientIntentID: UUID
    let routeEpoch: Int
    let deviceID: String
    let appSessionID: UUID
    let launchSource: String
    let explicitIntent: String
    let availableSeconds: Int
    let studyContextID: UUID?
    let threadID: UUID?
    let requestedSubject: String?
    let requestedRepresentation: String?
    let clientCapabilities: ExperienceClientCapabilities
}

nonisolated struct ExperienceClientCapabilities: Encodable, Sendable {
    let artifactVersions: [String]
    let renderers: [String: Int]
    let accessibility: ExperienceAccessibilityCapabilities
}

nonisolated struct ExperienceAccessibilityCapabilities: Encodable, Sendable {
    let reduceMotion: Bool
    let screenReader: Bool
    let dynamicTypeCategory: String
}

nonisolated struct ExperienceLaunchResponse: Decodable, Sendable {
    let clientIntentID: UUID
    let routeEpoch: Int
    let resolutionKind: String
    let decisionID: UUID
    let candidateSurface: String
    let reasonCode: String
    let learningReservation: LearningFeedV2PrefetchResponse?
}

nonisolated struct ExperienceLaunchResolveRequest: Encodable, Sendable {
    let chosenSurface: String
    let resolution: String
    let resolvedAt: Date
}

nonisolated struct LearningFeedV2PrefetchResponse: Codable, Identifiable, Sendable {
    var id: UUID { sessionID }

    let sessionID: UUID
    let serverRevision: Int
    let serverTime: Date
    let reservedAt: Date
    let expiresAt: Date
    let status: String
    let packManifest: LearningFeedV2Manifest
    let episodes: [LearningFeedV2Episode]
    let assets: [[String: JSONValue]]
    let rendererRequirements: [LearningFeedRendererRequirement]
    let contentHashes: [String]
    let invalidation: [String: JSONValue]
    let pack: LearningFeedV2Pack

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case serverRevision
        case serverTime
        case reservedAt
        case expiresAt
        case status
        case packManifest
        case episodes
        case assets
        case rendererRequirements
        case contentHashes
        case invalidation
        case pack
    }
}

nonisolated struct LearningFeedV2Pack: Codable, Sendable {
    let artifactType: String
    let artifactVersion: String
    let schemaMajor: Int
    let schemaMinor: Int
    let manifest: LearningFeedV2Manifest
    let title: String
    let estimatedSeconds: Int
    let episodes: [LearningFeedV2Episode]
}

nonisolated struct LearningFeedV2Manifest: Codable, Sendable {
    let packID: UUID
    let artifactVersion: String
    let problemStableID: String
    let problemBundleID: UUID
    let problemRevision: Int
    let problemContentHash: String
    let contentHash: String
    let rendererRequirements: [LearningFeedRendererRequirement]
    let audiencePolicy: [String: JSONValue]
    let assets: [[String: JSONValue]]
    let selection: [String: JSONValue]
    let expiresAt: Date
    let verificationStatus: String
    let verificationMethods: [String]
    let verifiedAt: Date?
    let invalidatedAt: Date?
    let invalidatedReason: String?

    private enum CodingKeys: String, CodingKey {
        case packID = "packId"
        case artifactVersion
        case problemStableID = "problemStableId"
        case problemBundleID = "problemBundleId"
        case problemRevision
        case problemContentHash
        case contentHash
        case rendererRequirements
        case audiencePolicy
        case assets
        case selection
        case expiresAt
        case verificationStatus
        case verificationMethods
        case verifiedAt
        case invalidatedAt
        case invalidatedReason
    }
}

nonisolated struct LearningFeedVerification: Codable, Sendable {
    let status: String
    let methods: [String]
    let verifiedAt: Date?
}

nonisolated struct LearningFeedRendererRequirement: Codable, Hashable, Sendable {
    let kind: String
    let minimumVersion: Int
}

nonisolated struct LearningFeedSemanticElement: Codable, Hashable, Sendable {
    let id: String
    let meaning: String
}

nonisolated struct LearningFeedKernelRef: Codable, Sendable {
    let problemID: String
    let problemBundleID: UUID
    let revision: Int
    let solutionRevisionHash: String
    let sourceRefs: [String]

    private enum CodingKeys: String, CodingKey {
        case problemID = "problemId"
        case problemBundleID = "problemBundleId"
        case revision
        case solutionRevisionHash
        case sourceRefs
    }
}

nonisolated struct LearningFeedLearningContract: Codable, Sendable {
    let targetSkillIDs: [String]
    let prerequisiteSkillIDs: [String]
    let invariant: String
    let misconceptionIDs: [String]
    let curriculumRefs: [String]

    private enum CodingKeys: String, CodingKey {
        case targetSkillIDs = "targetSkillIds"
        case prerequisiteSkillIDs = "prerequisiteSkillIds"
        case invariant
        case misconceptionIDs = "misconceptionIds"
        case curriculumRefs
    }
}

nonisolated struct LearningFeedAudience: Codable, Sendable {
    let educationStage: String
    let grade: String
    let readingLoad: String
    let contentSafetyBand: String
}

nonisolated struct LearningFeedRenderPolicy: Codable, Sendable {
    let scaffoldLevel: Int
    let representationStart: String
    let maxSimultaneousRelations: Int
    let inputFreedom: String
    let motionPolicy: String
    let audioRequired: Bool
}

nonisolated struct LearningFeedTiming: Codable, Sendable {
    let estimatedSeconds: Int
    let firstActionTargetMs: Int
    let minimumCompletionBoundaryMs: Int
}

nonisolated struct LearningFeedLocalFeedback: Codable, Sendable {
    let mode: String
    let branchReceipts: [String]
}

nonisolated struct LearningFeedV2Episode: Codable, Identifiable, Sendable {
    var id: UUID { episodeID }

    let artifactType: String
    let artifactVersion: String
    let schemaMajor: Int
    let schemaMinor: Int
    let episodeID: UUID
    let episodeVersionID: UUID
    let contentHash: String
    let expiresAt: Date
    let title: String
    let kernelRef: LearningFeedKernelRef
    let learningContract: LearningFeedLearningContract
    let audience: LearningFeedAudience
    let renderPolicy: LearningFeedRenderPolicy
    let timing: LearningFeedTiming
    let rendererRequirements: [LearningFeedRendererRequirement]
    let semanticElements: [LearningFeedSemanticElement]
    let steps: [LearningFeedV2Step]
    let localFeedback: LearningFeedLocalFeedback
    let verification: LearningFeedVerification

    private enum CodingKeys: String, CodingKey {
        case artifactType
        case artifactVersion
        case schemaMajor
        case schemaMinor
        case episodeID = "episodeId"
        case episodeVersionID = "episodeVersionId"
        case contentHash
        case expiresAt
        case title
        case kernelRef
        case learningContract
        case audience
        case renderPolicy
        case timing
        case rendererRequirements
        case semanticElements
        case steps
        case localFeedback
        case verification
    }
}

nonisolated struct LearningFeedCompletionCondition: Codable, Equatable, Sendable {
    let kind: String
    let minimumActions: Int
}

nonisolated struct LearningFeedV2Step: Codable, Identifiable, Sendable {
    let id: String
    let stage: LearningFeedStage
    let rendererKind: String
    let rendererVersion: Int
    let prompt: String
    let sceneState: [String: JSONValue]
    let interactionConfig: [String: JSONValue]
    let completionCondition: LearningFeedCompletionCondition
    let nextStep: [String: String?]
    let semanticElementIDs: [String]
    let accessibility: LearningFeedAccessibility
    let evidenceTier: String
    let localFeedbackRef: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case stage
        case rendererKind
        case rendererVersion
        case prompt
        case sceneState
        case interactionConfig
        case completionCondition
        case nextStep
        case semanticElementIDs = "semanticElementIds"
        case accessibility
        case evidenceTier
        case localFeedbackRef
    }

    var renderer: String { rendererKind }

    var choices: [LearningFeedV2Choice] {
        choices(for: "choices")
    }

    func choices(for key: String) -> [LearningFeedV2Choice] {
        guard case .array(let values)? = interactionConfig[key] else { return [] }
        return values.compactMap { value in
            guard case .object(let object) = value,
                  let id = object["id"]?.stringValue.learningFeedNonEmpty,
                  let label = object["label"]?.stringValue.learningFeedNonEmpty
            else { return nil }
            return LearningFeedV2Choice(id: id, label: label)
        }
    }

    var parameters: [String: JSONValue] {
        if case .object(let values)? = interactionConfig["parameters"] { return values }
        return interactionConfig.merging(sceneState) { current, _ in current }
    }
}

nonisolated struct LearningFeedV2Choice: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let label: String
}

nonisolated struct LearningFeedAccessibility: Codable, Sendable {
    let summary: String
    let semanticOrder: [String]
    let gestureFallback: String
    let reduceMotion: String
}

nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String {
        switch self {
        case .string(let value): value
        case .number(let value): value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
        case .bool(let value): String(value)
        case .object, .array, .null: ""
        }
    }

    var numberValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        case .bool, .object, .array, .null: nil
        }
    }
}

nonisolated struct LearningFeedV2ActivateBody: Encodable, Sendable {
    let deviceID: String
    let lastClientEventID: UUID?

    private enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case lastClientEventID = "lastClientEventId"
    }
}

nonisolated struct LearningFeedV2ActivateResponse: Decodable, Sendable {
    let sessionID: UUID
    let serverRevision: Int
    let serverTime: Date
    let status: String
    let packID: UUID
    let artifactVersion: String
    let firstEpisode: LearningFeedV2Episode
    let nextEpisode: [String: JSONValue]?
    let expiresAt: Date
    let pack: LearningFeedV2Pack

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case serverRevision
        case serverTime
        case status
        case packID = "packId"
        case artifactVersion
        case firstEpisode
        case nextEpisode
        case expiresAt
        case pack
    }
}

nonisolated struct LearningFeedV2EventBatchBody: Encodable, Sendable {
    let events: [LearningFeedV2Event]
}

nonisolated struct LearningFeedV2Event: Codable, Identifiable, Equatable, Sendable {
    var id: UUID { clientEventID }

    let clientEventID: UUID
    let sequenceNo: Int
    let episodeID: UUID
    let episodeVersionID: UUID
    let stepID: String
    let eventType: String
    let payload: [String: JSONValue]
    let occurredAt: Date
    let monotonicOffsetMs: Int
    let artifactVersion: String
    let offline: Bool
    let runtime: LearningFeedEventRuntime

    private enum CodingKeys: String, CodingKey {
        case clientEventID = "clientEventId"
        case sequenceNo
        case episodeID = "episodeId"
        case episodeVersionID = "episodeVersionId"
        case stepID = "stepId"
        case eventType
        case payload
        case occurredAt
        case monotonicOffsetMs
        case artifactVersion
        case offline
        case runtime
    }
}

nonisolated struct LearningFeedEventRuntime: Codable, Equatable, Sendable {
    let rendererKind: String
    let rendererVersion: Int
    let packContentHash: String
}

nonisolated struct LearningFeedV2EventBatchResponse: Decodable, Sendable {
    let sessionID: UUID
    let serverTime: Date
    let serverRevision: Int
    let authoritativeStepID: String?
    let acknowledgedClientEventIDs: [UUID]
    let stop: [String: JSONValue]?
    let results: [LearningFeedV2EventBatchResult]

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case serverTime
        case serverRevision
        case authoritativeStepID = "authoritativeStepId"
        case acknowledgedClientEventIDs = "acknowledgedClientEventIds"
        case stop
        case results
    }
}

nonisolated struct LearningFeedV2EventBatchResult: Decodable, Sendable {
    let clientEventID: UUID
    let serverEventID: UUID?
    let status: String
    let validationStatus: String
    let observationIDs: [UUID]
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case clientEventID = "clientEventId"
        case serverEventID = "serverEventId"
        case status
        case validationStatus
        case observationIDs = "observationIds"
        case reason
    }
}

nonisolated struct LearningFeedV2SessionSnapshotResponse: Decodable, Equatable, Sendable {
    let sessionID: UUID
    let serverRevision: Int
    let status: String
    let completedEventIDs: [UUID]
    let currentEpisodeID: UUID?
    let currentStepID: String?
    let pendingValidation: [UUID]
    let packInvalidation: [String: JSONValue]
    let boundary: [String: JSONValue]
    let snapshotVersion: Int
    let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case serverRevision
        case status
        case completedEventIDs = "completedEventIds"
        case currentEpisodeID = "currentEpisodeId"
        case currentStepID = "currentStepId"
        case pendingValidation
        case packInvalidation
        case boundary
        case snapshotVersion
        case expiresAt
    }

    var isPackInvalidated: Bool {
        packInvalidation["invalidated"] == .bool(true)
            || packInvalidation["status"]?.stringValue == "invalidated"
    }
}

nonisolated struct LearningFeedV2CompleteBody: Encodable, Sendable {
    let lastClientEventID: UUID?

    private enum CodingKeys: String, CodingKey {
        case lastClientEventID = "lastClientEventId"
    }
}

nonisolated struct LearningFeedV2CloseBody: Encodable, Sendable {
    let endReason: String
    let lastClientEventID: UUID?

    private enum CodingKeys: String, CodingKey {
        case endReason
        case lastClientEventID = "lastClientEventId"
    }
}

nonisolated struct LearningFeedV2TerminalResponse: Decodable, Sendable {
    let sessionID: UUID
    let status: String
    let summary: [String: JSONValue]
    let chatMessage: String
    let pendingSync: Bool
    let delayedTransfer: [[String: JSONValue]]
    let chatThreadID: UUID?
    let chatMessageID: UUID?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case status
        case summary
        case chatMessage
        case pendingSync
        case delayedTransfer
        case chatThreadID = "chatThreadId"
        case chatMessageID = "chatMessageId"
    }
}

nonisolated struct LearningFeedV1PublicArtifact: Decodable, Sendable {
    let artifactType: String
    let artifactVersion: String
    let audience: [String: JSONValue]
    let learningContract: [String: JSONValue]
    let source: [String: JSONValue]
    let experience: [String: JSONValue]
    let verification: [String: JSONValue]
}

nonisolated enum LearningFeedRoutedArtifact: Sendable {
    case v1(LearningFeedV1PublicArtifact)
    case v2(LearningFeedV2Pack)
}

nonisolated enum LearningFeedArtifactValidationError: Error, Equatable, LocalizedError {
    case malformed(String)
    case unsupportedVersion(String)
    case unsupportedRenderer(kind: String, required: Int, available: Int?)
    case privateAnswerField(String)
    case notVerified
    case expired
    case invalidContentHash
    case invalidStructure(String)

    var errorDescription: String? {
        switch self {
        case .malformed: "学習データを読み込めませんでした"
        case .unsupportedVersion: "この学習データはアプリの更新が必要です"
        case .unsupportedRenderer: "この問題の表示にはアプリの更新が必要です"
        case .privateAnswerField: "学習データの検証に失敗しました"
        case .notVerified: "検証済みの問題を確認できませんでした"
        case .expired: "この問題の利用期限が切れています"
        case .invalidContentHash: "学習データの整合性を確認できませんでした"
        case .invalidStructure: "学習データの構成を確認できませんでした"
        }
    }
}

nonisolated struct LearningFeedArtifactRouter: Sendable {
    private static let forbiddenPublicKeys: Set<String> = [
        "answer_key", "canonical_answer", "correct", "correct_answer", "correct_branch_id",
        "correct_option_id", "correct_option_ids", "correct_value", "is_correct",
        "private_answer_key", "rubric", "scoring_rule", "scoring_rules",
    ]

    private let decoder: JSONDecoder

    nonisolated init() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = LearningFeedCoding.dateDecodingStrategy
        self.decoder = decoder
    }

    nonisolated func decodePrefetch(
        _ data: Data,
        registry: EpisodeRendererRegistry,
        now: Date = Date()
    ) throws -> LearningFeedV2PrefetchResponse {
        let root = try Self.object(from: data)
        try Self.rejectPrivateAnswerFields(in: root)
        try Self.validateCanonicalNumbers(in: root)
        guard let packObject = root["pack"] as? [String: Any] else {
            throw LearningFeedArtifactValidationError.malformed("missing pack")
        }
        guard Self.version(in: packObject) == LearningFeedArtifactVersion.v2.rawValue else {
            throw LearningFeedArtifactValidationError.unsupportedVersion(Self.version(in: packObject) ?? "missing")
        }
        let response: LearningFeedV2PrefetchResponse
        do {
            response = try decoder.decode(LearningFeedV2PrefetchResponse.self, from: data)
        } catch {
            throw LearningFeedArtifactValidationError.malformed(String(describing: error))
        }
        try validate(response.pack, rawPack: packObject, registry: registry, now: now)
        guard response.expiresAt > now,
              response.packManifest.contentHash == response.pack.manifest.contentHash,
              response.packManifest.packID == response.pack.manifest.packID,
              response.episodes.map(\.episodeID) == response.pack.episodes.map(\.episodeID),
              response.rendererRequirements == response.pack.manifest.rendererRequirements,
              response.contentHashes.contains(response.pack.manifest.contentHash)
        else {
            throw LearningFeedArtifactValidationError.invalidStructure("prefetch metadata mismatch")
        }
        return response
    }

    nonisolated func decodeActivate(
        _ data: Data,
        registry: EpisodeRendererRegistry,
        expectedContentHash: String,
        now: Date = Date()
    ) throws -> LearningFeedV2ActivateResponse {
        let root = try Self.object(from: data)
        try Self.rejectPrivateAnswerFields(in: root)
        try Self.validateCanonicalNumbers(in: root)
        guard let packObject = root["pack"] as? [String: Any] else {
            throw LearningFeedArtifactValidationError.malformed("missing pack")
        }
        let response: LearningFeedV2ActivateResponse
        do {
            response = try decoder.decode(LearningFeedV2ActivateResponse.self, from: data)
        } catch {
            throw LearningFeedArtifactValidationError.malformed(String(describing: error))
        }
        try validate(response.pack, rawPack: packObject, registry: registry, now: now)
        guard response.pack.manifest.contentHash == expectedContentHash,
              response.expiresAt > now
        else {
            throw LearningFeedArtifactValidationError.invalidContentHash
        }
        return response
    }

    nonisolated func route(
        _ data: Data,
        registry: EpisodeRendererRegistry,
        now: Date = Date()
    ) throws -> LearningFeedRoutedArtifact {
        let object = try Self.object(from: data)
        try Self.rejectPrivateAnswerFields(in: object)
        try Self.validateCanonicalNumbers(in: object)
        switch Self.version(in: object) {
        case LearningFeedArtifactVersion.v1.rawValue:
            let requiredKeys: Set<String> = [
                "artifact_type", "artifact_version", "audience", "learning_contract",
                "source", "experience", "verification",
            ]
            guard Set(object.keys) == requiredKeys else {
                throw LearningFeedArtifactValidationError.invalidStructure("invalid V1 root keys")
            }
            let artifact: LearningFeedV1PublicArtifact
            do {
                artifact = try decoder.decode(LearningFeedV1PublicArtifact.self, from: data)
            } catch {
                throw LearningFeedArtifactValidationError.malformed(String(describing: error))
            }
            guard artifact.artifactType == "LearningFeedItem",
                  artifact.artifactVersion == LearningFeedArtifactVersion.v1.rawValue,
                  artifact.verification["status"]?.stringValue == "verified",
                  case .object(let interaction)? = artifact.experience["interaction_schema"],
                  interaction["kind"]?.stringValue == "single_choice"
            else {
                throw LearningFeedArtifactValidationError.invalidStructure("invalid V1 public contract")
            }
            return .v1(artifact)
        case LearningFeedArtifactVersion.v2.rawValue, LearningFeedArtifactVersion.v21.rawValue:
            let pack: LearningFeedV2Pack
            do {
                pack = try decoder.decode(LearningFeedV2Pack.self, from: data)
            } catch {
                throw LearningFeedArtifactValidationError.malformed(String(describing: error))
            }
            try validate(pack, rawPack: object, registry: registry, now: now)
            return .v2(pack)
        case let version?:
            throw LearningFeedArtifactValidationError.unsupportedVersion(version)
        case nil:
            throw LearningFeedArtifactValidationError.unsupportedVersion("missing")
        }
    }

    nonisolated private func validate(
        _ pack: LearningFeedV2Pack,
        rawPack: [String: Any],
        registry: EpisodeRendererRegistry,
        now: Date
    ) throws {
        guard pack.artifactType == "LearningFeedPack",
              [LearningFeedArtifactVersion.v2.rawValue, LearningFeedArtifactVersion.v21.rawValue].contains(pack.artifactVersion),
              pack.schemaMajor == 2,
              pack.manifest.artifactVersion == pack.artifactVersion,
              pack.schemaMinor == (pack.artifactVersion == LearningFeedArtifactVersion.v21.rawValue ? 1 : 0)
        else {
            throw LearningFeedArtifactValidationError.unsupportedVersion(pack.artifactVersion)
        }
        guard pack.manifest.verificationStatus == "verified", pack.manifest.verifiedAt != nil else {
            throw LearningFeedArtifactValidationError.notVerified
        }
        if pack.artifactVersion == LearningFeedArtifactVersion.v21.rawValue {
            try Self.validateAdaptiveV21Raw(rawPack)
        }
        guard pack.manifest.expiresAt > now else { throw LearningFeedArtifactValidationError.expired }
        guard (3...6).contains(pack.episodes.count),
              !pack.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pack.estimatedSeconds > 0,
              Set(pack.episodes.map(\.episodeID)).count == pack.episodes.count,
              Set(pack.episodes.map(\.episodeVersionID)).count == pack.episodes.count
        else {
            throw LearningFeedArtifactValidationError.invalidStructure("invalid pack metadata")
        }
        for requirement in pack.manifest.rendererRequirements {
            try registry.validate(kind: requirement.kind, minimumVersion: requirement.minimumVersion)
        }
        for episode in pack.episodes {
            guard episode.kernelRef.problemBundleID == pack.manifest.problemBundleID else {
                throw LearningFeedArtifactValidationError.invalidStructure("problem kernel mismatch")
            }
            try validate(episode, registry: registry, now: now)
        }
        guard pack.manifest.contentHash.hasPrefix("sha256:"),
              try Self.contentHash(of: rawPack) == Self.normalizedHash(pack.manifest.contentHash)
        else {
            throw LearningFeedArtifactValidationError.invalidContentHash
        }
    }

    nonisolated private static func validateAdaptiveV21Raw(_ rawPack: [String: Any]) throws {
        guard let episodes = rawPack["episodes"] as? [[String: Any]], !episodes.isEmpty else {
            throw LearningFeedArtifactValidationError.invalidStructure("2.1 episodes are required")
        }
        let allowedModels: Set<String> = [
            "bounded_scalar", "linear_relation", "inverse_relation", "piecewise_relation",
            "sequence_order", "spatial_flow", "constraint_satisfaction", "evidence_graph",
            "timeline_dependency", "finite_state_trace",
        ]
        for episode in episodes {
            guard let variant = episode["variant"] as? [String: Any],
                  let preview = episode["launch_preview"] as? [String: Any],
                  let contract = episode["adaptive_learning_contract"] as? [String: Any],
                  let boundary = contract["finite_boundary"] as? [String: Any],
                  variant["verification_status"] as? String == "verified",
                  let difference = variant["expected_seconds_to_difference"] as? Int,
                  let expectedBoundary = variant["expected_boundary_seconds"] as? Int,
                  let maximum = boundary["max_seconds"] as? Int,
                  boundary["auto_next"] as? Bool == false,
                  difference > 0, difference <= expectedBoundary, expectedBoundary <= maximum,
                  let explorable = variant["explorable_axes"] as? [String], explorable.count <= 1,
                  preview["question"] as? String != nil,
                  preview["source_summary"] as? String != nil,
                  preview["first_meaningful_action"] as? String != nil
            else {
                throw LearningFeedArtifactValidationError.invalidStructure("invalid 2.1 adaptive contract")
            }
            let models = episode["deterministic_models"] as? [[String: Any]] ?? []
            for model in models {
                guard let kind = model["kind"] as? String,
                      allowedModels.contains(kind),
                      model["version"] as? Int == 1,
                      model["parameters"] as? [String: Any] != nil,
                      model["output_bindings"] as? [String: Any] != nil
                else {
                    throw LearningFeedArtifactValidationError.invalidStructure("unsupported deterministic model")
                }
            }
        }
    }

    nonisolated private func validate(
        _ episode: LearningFeedV2Episode,
        registry: EpisodeRendererRegistry,
        now: Date
    ) throws {
        guard episode.artifactType == "LearningEpisode",
              [LearningFeedArtifactVersion.v2.rawValue, LearningFeedArtifactVersion.v21.rawValue].contains(episode.artifactVersion),
              episode.schemaMajor == 2,
              episode.verification.status == "verified",
              episode.verification.verifiedAt != nil,
              episode.expiresAt > now
        else {
            throw LearningFeedArtifactValidationError.notVerified
        }
        let requiredStages: [LearningFeedStage] = [
            .hook, .committed, .exploring, .consequence, .invariantCheck,
            .variationCheck, .schoolTransfer, .boundary,
        ]
        let stages = episode.steps.map(\.stage)
        let positions = requiredStages.compactMap { stages.firstIndex(of: $0) }
        guard positions.count == requiredStages.count,
              positions == positions.sorted(),
              Set(episode.steps.map(\.id)).count == episode.steps.count
        else {
            throw LearningFeedArtifactValidationError.invalidStructure("invalid stage order or duplicate step")
        }
        let semanticIDs = Set(episode.semanticElements.map(\.id))
        guard semanticIDs.count == episode.semanticElements.count else {
            throw LearningFeedArtifactValidationError.invalidStructure("duplicate semantic element")
        }
        let stepIDs = Set(episode.steps.map(\.id))
        let allowedNextConditions: Set<String> = [
            "submitted", "correct", "incorrect", "hint_used", "server_evaluation_ready",
        ]
        let declaredRenderers = Dictionary(
            uniqueKeysWithValues: episode.rendererRequirements.map { ($0.kind, $0.minimumVersion) }
        )
        for requirement in episode.rendererRequirements {
            try registry.validate(kind: requirement.kind, minimumVersion: requirement.minimumVersion)
        }
        for step in episode.steps {
            guard !step.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !step.semanticElementIDs.isEmpty,
                  step.semanticElementIDs.allSatisfy(semanticIDs.contains),
                  !step.nextStep.isEmpty,
                  Set(step.nextStep.keys).isSubset(of: allowedNextConditions),
                  step.nextStep.values.compactMap({ $0 }).allSatisfy(stepIDs.contains),
                  !step.accessibility.summary.isEmpty,
                  !step.accessibility.semanticOrder.isEmpty,
                  !step.accessibility.gestureFallback.isEmpty,
                  !step.accessibility.reduceMotion.isEmpty
            else {
                throw LearningFeedArtifactValidationError.invalidStructure("invalid step contract")
            }
            let semanticOrder = step.accessibility.semanticOrder
            guard semanticOrder.count == step.semanticElementIDs.count,
                  Set(semanticOrder).count == semanticOrder.count,
                  semanticOrder.allSatisfy(step.semanticElementIDs.contains)
            else {
                throw LearningFeedArtifactValidationError.invalidStructure(
                    "accessibility semantic order must include every step semantic element exactly once"
                )
            }
            guard let declaredVersion = declaredRenderers[step.rendererKind],
                  declaredVersion <= step.rendererVersion,
                  step.stage != .exploring || step.completionCondition.kind == "meaningful_action",
                  ![LearningFeedStage.invariantCheck, .schoolTransfer].contains(step.stage)
                    || step.completionCondition.kind == "scored_response"
            else {
                throw LearningFeedArtifactValidationError.invalidStructure("renderer or completion contract mismatch")
            }
            try registry.validate(kind: step.rendererKind, minimumVersion: step.rendererVersion)
            try validateInteractionConfig(for: step)
        }
    }

    nonisolated private func validateInteractionConfig(for step: LearningFeedV2Step) throws {
        let config = step.interactionConfig
        let valid: Bool
        switch step.rendererKind {
        case "binary_prediction":
            valid = Self.hasExactKeys(config, required: ["input_mode", "choices"])
                && Self.strictString(config["input_mode"]) == "single_choice"
                && Self.validChoices(config["choices"], count: 2...3)
        case "graph_parameter":
            valid = Self.validParameterRange(config, requiresModel: true)
        case "direct_manipulation":
            valid = Self.validParameterRange(config, requiresModel: false)
        case "drag_order":
            valid = Self.hasExactKeys(config, required: ["items"])
                && Self.validChoices(config["items"], count: 2...20)
        case "select_evidence":
            let selectionMode = Self.strictString(config["selection_mode"])
            valid = Self.hasExactKeys(config, required: ["choices", "selection_mode"])
                && Self.validChoices(config["choices"], count: 2...20)
                && ["single", "multiple"].contains(selectionMode ?? "")
        case "numeric_input":
            valid = Self.hasExactKeys(
                config,
                required: ["input_mode"],
                optional: ["placeholder", "unit"]
            )
                && Self.strictString(config["input_mode"]) == "number"
                && Self.validOptionalString(config["placeholder"], maximumLength: 100)
                && Self.validOptionalString(config["unit"], maximumLength: 40)
        case "equation_input":
            valid = Self.hasExactKeys(
                config,
                required: ["input_mode"],
                optional: ["placeholder"]
            )
                && Self.strictString(config["input_mode"]) == "equation"
                && Self.validOptionalString(config["placeholder"], maximumLength: 100)
        case "short_response":
            let maxLengthIsValid: Bool
            if let maxLength = config["max_length"] {
                maxLengthIsValid = Self.strictInteger(maxLength).map { (1...2_000).contains($0) } ?? false
            } else {
                maxLengthIsValid = true
            }
            valid = Self.hasExactKeys(
                config,
                required: ["input_mode"],
                optional: ["placeholder", "max_length"]
            )
                && Self.strictString(config["input_mode"]) == "short_response"
                && Self.validOptionalString(config["placeholder"], maximumLength: 200)
                && maxLengthIsValid
        case "annotate_text":
            valid = Self.hasExactKeys(config, required: ["text", "selectable_segment_ids", "segments"])
                && Self.strictString(config["text"]) != nil
                && Self.validChoices(config["segments"], count: 1...100)
        case "relationship_map":
            valid = Self.hasExactKeys(config, required: ["nodes", "allowed_relations"])
                && Self.validChoices(config["nodes"], count: 2...40)
        case "spatial_arrangement":
            valid = Self.hasExactKeys(config, required: ["items", "zones"])
                && Self.validChoices(config["items"], count: 2...40)
                && Self.validChoices(config["zones"], count: 1...20)
        case "timeline_cause":
            valid = Self.hasExactKeys(config, required: ["events", "allow_causal_links"])
                && Self.validChoices(config["events"], count: 2...40)
        case "data_filter":
            valid = Self.hasExactKeys(config, required: ["columns", "rows", "filterable_column_ids"])
                && Self.validChoices(config["columns"], count: 1...30)
        case "code_trace":
            valid = Self.hasExactKeys(config, required: ["language", "source_lines", "trace_variables", "max_steps"])
                && Self.strictString(config["language"]) != nil
        case "proof_repair":
            valid = Self.hasExactKeys(config, required: ["lines", "repair_actions"])
                && Self.validChoices(config["lines"], count: 2...80)
        case "audio_prediction":
            valid = Self.hasExactKeys(config, required: ["asset_id", "transcript_fallback", "choices"])
                && Self.strictString(config["asset_id"]) != nil
                && Self.strictString(config["transcript_fallback"]) != nil
                && Self.validChoices(config["choices"], count: 2...6)
        case "artifact_compare":
            valid = Self.hasExactKeys(config, required: ["left", "right", "criteria"])
                && Self.validChoices(config["criteria"], count: 1...20)
        default:
            valid = false
        }
        guard valid else {
            throw LearningFeedArtifactValidationError.invalidStructure(
                "interaction_config does not match renderer \(step.rendererKind)"
            )
        }
    }

    nonisolated private static func validParameterRange(
        _ config: [String: JSONValue],
        requiresModel: Bool
    ) -> Bool {
        let required = Set([
            "parameter_id", "label", "min", "max", "step", "initial_value",
        ]).union(requiresModel ? ["model"] : [])
        guard hasExactKeys(config, required: required),
              strictString(config["parameter_id"]) != nil,
              strictString(config["label"]) != nil,
              let minimum = strictNumber(config["min"]),
              let maximum = strictNumber(config["max"]),
              let step = strictNumber(config["step"]),
              let initialValue = strictNumber(config["initial_value"]),
              minimum < maximum,
              step > 0,
              (minimum...maximum).contains(initialValue)
        else {
            return false
        }
        guard requiresModel else { return true }
        guard case .object(let model)? = config["model"] else { return false }
        let modelKeys: Set<String> = [
            "kind", "red_slope", "red_intercept", "blue_slope", "blue_intercept",
        ]
        return hasExactKeys(model, required: modelKeys)
            && strictString(model["kind"]) == "linear_intersection"
            && strictNumber(model["red_slope"]) != nil
            && strictNumber(model["red_intercept"]) != nil
            && strictNumber(model["blue_slope"]) != nil
            && strictNumber(model["blue_intercept"]) != nil
    }

    nonisolated private static func validChoices(
        _ value: JSONValue?,
        count: ClosedRange<Int>
    ) -> Bool {
        guard case .array(let choices)? = value, count.contains(choices.count) else { return false }
        return choices.allSatisfy { choice in
            guard case .object(let object) = choice else { return false }
            return hasExactKeys(object, required: ["id", "label"])
                && strictString(object["id"]) != nil
                && strictString(object["label"]) != nil
        }
    }

    nonisolated private static func hasExactKeys(
        _ object: [String: JSONValue],
        required: Set<String>,
        optional: Set<String> = []
    ) -> Bool {
        let keys = Set(object.keys)
        return required.isSubset(of: keys) && keys.isSubset(of: required.union(optional))
    }

    nonisolated private static func strictString(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return string
    }

    nonisolated private static func strictNumber(_ value: JSONValue?) -> Double? {
        guard case .number(let number)? = value, number.isFinite else { return nil }
        return number
    }

    nonisolated private static func strictInteger(_ value: JSONValue) -> Int? {
        guard case .number(let number) = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= Double(Int.min),
              number <= Double(Int.max)
        else {
            return nil
        }
        return Int(number)
    }

    nonisolated private static func validOptionalString(
        _ value: JSONValue?,
        maximumLength: Int
    ) -> Bool {
        guard let value else { return true }
        switch value {
        case .null:
            return true
        case .string(let string):
            return string.count <= maximumLength
        default:
            return false
        }
    }

    private static func object(from data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LearningFeedArtifactValidationError.malformed("root is not an object")
        }
        return object
    }

    private static func version(in object: [String: Any]) -> String? {
        (object["artifact_version"] as? String)
            ?? ((object["manifest"] as? [String: Any])?["artifact_version"] as? String)
    }

    private static func rejectPrivateAnswerFields(in value: Any, path: String = "$") throws {
        if let object = value as? [String: Any] {
            for (key, nested) in object {
                let normalized = key.replacingOccurrences(of: "-", with: "_").lowercased()
                let isAllowlistedTransitionCondition = normalized == "correct"
                    && path.hasSuffix(".next_step")
                if forbiddenPublicKeys.contains(normalized), !isAllowlistedTransitionCondition {
                    throw LearningFeedArtifactValidationError.privateAnswerField("\(path).\(key)")
                }
                try rejectPrivateAnswerFields(in: nested, path: "\(path).\(key)")
            }
        } else if let array = value as? [Any] {
            for (index, nested) in array.enumerated() {
                try rejectPrivateAnswerFields(in: nested, path: "\(path)[\(index)]")
            }
        }
    }

    private static func validateCanonicalNumbers(in value: Any, path: String = "$") throws {
        if let object = value as? [String: Any] {
            for (key, nested) in object {
                try validateCanonicalNumbers(in: nested, path: "\(path).\(key)")
            }
            return
        }
        if let array = value as? [Any] {
            for (index, nested) in array.enumerated() {
                try validateCanonicalNumbers(in: nested, path: "\(path)[\(index)]")
            }
            return
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return
        }
        let double = number.doubleValue
        guard double.isFinite else {
            throw LearningFeedArtifactValidationError.invalidStructure("non-finite number at \(path)")
        }
        if double == 0 || double.rounded(.towardZero) == double { return }
        let absolute = abs(double)
        guard absolute >= 0.0001, absolute <= 1_000_000_000_000_000 else {
            throw LearningFeedArtifactValidationError.invalidStructure(
                "decimal outside cross-client canonical range at \(path)"
            )
        }
    }

    private static func contentHash(of rawPack: [String: Any]) throws -> String {
        var mutable = rawPack
        guard var manifest = mutable["manifest"] as? [String: Any] else {
            throw LearningFeedArtifactValidationError.invalidContentHash
        }
        manifest.removeValue(forKey: "content_hash")
        mutable["manifest"] = manifest
        guard JSONSerialization.isValidJSONObject(mutable) else {
            throw LearningFeedArtifactValidationError.invalidContentHash
        }
        let canonical = try JSONSerialization.data(
            withJSONObject: mutable,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedHash(_ value: String) -> String {
        String(value.dropFirst("sha256:".count))
    }
}

private extension String {
    nonisolated var learningFeedNonEmpty: String? { isEmpty ? nil : self }
}

nonisolated enum LearningFeedCoding {
    nonisolated static let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = {
        return .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = fractional.date(from: raw) { return date }
            if let date = plain.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized ISO8601 date: \(raw)"
            )
        }
    }()
}
