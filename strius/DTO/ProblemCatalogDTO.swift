import Foundation

struct ProblemCatalogViewDTO: Decodable, Hashable, Sendable {
    static let maximumFullScreenNodes = 24
    static let maximumFullScreenEdges = 48

    let schemaVersion: Int
    let viewID: String
    let viewKind: String
    let catalogGeneration: String
    let title: String?
    let scopePath: [ProblemCatalogScopeItemDTO]
    let queryRequest: ProblemCatalogQueryRequest?
    let clientQueryDraft: ProblemCatalogClientQueryDraft?
    let interpretation: ProblemCatalogInterpretationDTO?
    let nodes: [ProblemCatalogNodeDTO]
    let edges: [ProblemCatalogEdgeDTO]
    let focusNodeIDs: [String]
    let truncation: ProblemCatalogTruncationDTO
    let nextCursor: String?
    let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case viewID = "viewId"
        case viewKind
        case catalogGeneration
        case title
        case scopePath
        case queryRequest
        case clientQueryDraft
        case interpretation
        case nodes
        case edges
        case focusNodeIDs = "focusNodeIds"
        case truncation
        case nextCursor
        case createdAt
    }

    init(
        schemaVersion: Int,
        viewID: String,
        viewKind: String = "tree",
        catalogGeneration: String,
        title: String?,
        scopePath: [ProblemCatalogScopeItemDTO],
        queryRequest: ProblemCatalogQueryRequest? = nil,
        clientQueryDraft: ProblemCatalogClientQueryDraft? = nil,
        interpretation: ProblemCatalogInterpretationDTO?,
        nodes: [ProblemCatalogNodeDTO],
        edges: [ProblemCatalogEdgeDTO],
        focusNodeIDs: [String],
        truncation: ProblemCatalogTruncationDTO,
        nextCursor: String?,
        createdAt: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.viewID = viewID
        self.viewKind = viewKind
        self.catalogGeneration = catalogGeneration
        self.title = title
        self.scopePath = scopePath
        self.queryRequest = queryRequest
        self.clientQueryDraft = clientQueryDraft
        self.interpretation = interpretation
        self.nodes = nodes
        self.edges = edges
        self.focusNodeIDs = focusNodeIDs
        self.truncation = truncation
        self.nextCursor = nextCursor
        self.createdAt = createdAt
    }

    func limited(maximumNodes: Int, maximumEdges: Int) -> ProblemCatalogViewDTO {
        var seenNodeIDs = Set<String>()
        let visibleNodes = Array(
            nodes
                .filter { seenNodeIDs.insert($0.id).inserted }
                .prefix(max(0, maximumNodes))
        )
        let visibleNodeIDs = Set(visibleNodes.map(\.id))
        let visibleEdges = edges
            .filter { visibleNodeIDs.contains($0.fromNodeID) && visibleNodeIDs.contains($0.toNodeID) }
            .prefix(max(0, maximumEdges))

        return ProblemCatalogViewDTO(
            schemaVersion: schemaVersion,
            viewID: viewID,
            viewKind: viewKind,
            catalogGeneration: catalogGeneration,
            title: title,
            scopePath: scopePath,
            queryRequest: queryRequest,
            clientQueryDraft: clientQueryDraft,
            interpretation: interpretation,
            nodes: visibleNodes,
            edges: Array(visibleEdges),
            focusNodeIDs: focusNodeIDs.filter(visibleNodeIDs.contains),
            truncation: truncation,
            nextCursor: nextCursor,
            createdAt: createdAt
        )
    }
}

struct ProblemCatalogScopeItemDTO: Codable, Identifiable, Hashable, Sendable {
    let kind: String
    let id: String
    let label: String

    var nodeID: String { id }
    var title: String { label }
}

struct ProblemCatalogInterpretationDTO: Decodable, Hashable, Sendable {
    let confidence: Double
    let needsClarification: Bool
    let resolvedTerms: [String]

    init(
        confidence: Double = 1,
        needsClarification: Bool = false,
        resolvedTerms: [String] = []
    ) {
        self.confidence = confidence
        self.needsClarification = needsClarification
        self.resolvedTerms = resolvedTerms
    }

    private enum CodingKeys: String, CodingKey {
        case confidence
        case needsClarification
        case resolvedTerms
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        needsClarification = try container.decodeIfPresent(Bool.self, forKey: .needsClarification) ?? false
        resolvedTerms = try container.decodeIfPresent([String].self, forKey: .resolvedTerms) ?? []
    }
}

struct ProblemCatalogNodeDTO: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let parentID: String?
    let kind: String
    let title: String
    let subtitle: String?
    let groupKind: String?
    let problemCount: Int
    let attemptedCount: Int
    let solvedCount: Int
    let sourceLabel: String?
    let promptPreview: String?
    let taxonomyPath: [ProblemCatalogScopeItemDTO]
    let problemRef: ProblemCatalogProblemRefDTO?
    let problemStatus: String?
    let progress: ProblemCatalogProgressDTO

    var isProblem: Bool { kind == "problem" }
    var canOpenChildren: Bool { !isProblem }

    private enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "nodeId"
        case parentID = "parentId"
        case kind
        case title
        case subtitle
        case groupKind
        case problemCount
        case attemptedCount
        case solvedCount
        case sourceLabel
        case promptPreview
        case taxonomyPath
        case problemRef
        case problemStatus
        case progress
    }

    init(
        id: String,
        parentID: String?,
        kind: String,
        title: String,
        subtitle: String? = nil,
        groupKind: String? = nil,
        problemCount: Int = 0,
        attemptedCount: Int = 0,
        solvedCount: Int = 0,
        sourceLabel: String? = nil,
        promptPreview: String? = nil,
        taxonomyPath: [ProblemCatalogScopeItemDTO] = [],
        problemRef: ProblemCatalogProblemRefDTO? = nil,
        problemStatus: String? = nil,
        progress: ProblemCatalogProgressDTO = ProblemCatalogProgressDTO()
    ) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.groupKind = groupKind
        self.problemCount = problemCount
        self.attemptedCount = attemptedCount
        self.solvedCount = solvedCount
        self.sourceLabel = sourceLabel
        self.promptPreview = promptPreview
        self.taxonomyPath = taxonomyPath
        self.problemRef = problemRef
        self.problemStatus = problemStatus
        self.progress = progress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decode(String.self, forKey: .nodeID)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "group"
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        groupKind = try container.decodeIfPresent(String.self, forKey: .groupKind)
        problemCount = try container.decodeIfPresent(Int.self, forKey: .problemCount) ?? (kind == "problem" ? 1 : 0)
        attemptedCount = try container.decodeIfPresent(Int.self, forKey: .attemptedCount) ?? 0
        solvedCount = try container.decodeIfPresent(Int.self, forKey: .solvedCount) ?? 0
        sourceLabel = try container.decodeIfPresent(String.self, forKey: .sourceLabel)
        promptPreview = try container.decodeIfPresent(String.self, forKey: .promptPreview)
        taxonomyPath = try container.decodeIfPresent([ProblemCatalogScopeItemDTO].self, forKey: .taxonomyPath) ?? []
        problemRef = try container.decodeIfPresent(ProblemCatalogProblemRefDTO.self, forKey: .problemRef)
        problemStatus = try container.decodeIfPresent(String.self, forKey: .problemStatus)
        progress = try container.decodeIfPresent(ProblemCatalogProgressDTO.self, forKey: .progress)
            ?? ProblemCatalogProgressDTO()
    }
}

struct ProblemCatalogProblemRefDTO: Decodable, Hashable, Sendable {
    let problemID: String
    let revision: Int
    let contentHash: String
    let sourceLocator: String
    let problemBundleID: String?

    private enum CodingKeys: String, CodingKey {
        case problemID = "problemId"
        case revision
        case contentHash
        case sourceLocator
        case problemBundleID = "problemBundleId"
    }

    var problemBundleUUID: UUID? {
        problemBundleID.flatMap(UUID.init(uuidString:))
    }

    init(
        problemID: String,
        revision: Int,
        contentHash: String,
        sourceLocator: String,
        problemBundleID: String? = nil
    ) {
        self.problemID = problemID
        self.revision = revision
        self.contentHash = contentHash
        self.sourceLocator = sourceLocator
        self.problemBundleID = problemBundleID
    }
}

struct ProblemCatalogProgressDTO: Decodable, Hashable, Sendable {
    let state: String
    let attemptCount: Int
    let correctCount: Int
    let lastResult: String?
    let lastAttemptAt: String?

    private enum CodingKeys: String, CodingKey {
        case state
        case attemptCount
        case correctCount
        case lastResult
        case lastAttemptAt
    }

    init(
        state: String = "not_started",
        attemptCount: Int = 0,
        correctCount: Int = 0,
        lastResult: String? = nil,
        lastAttemptAt: String? = nil
    ) {
        self.state = state
        self.attemptCount = attemptCount
        self.correctCount = correctCount
        self.lastResult = lastResult
        self.lastAttemptAt = lastAttemptAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "not_started"
        attemptCount = try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
        correctCount = try container.decodeIfPresent(Int.self, forKey: .correctCount) ?? 0
        lastResult = try container.decodeIfPresent(String.self, forKey: .lastResult)
        lastAttemptAt = try container.decodeIfPresent(String.self, forKey: .lastAttemptAt)
    }

    var completionFraction: Double {
        guard attemptCount > 0 else { return 0 }
        if state == "solved" { return 1 }
        return min(max(Double(correctCount) / Double(attemptCount), 0), 1)
    }
}

struct ProblemCatalogEdgeDTO: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let fromNodeID: String
    let toNodeID: String
    let relationType: String
    let weight: Double
    let confidence: Double
    let evidenceCount: Int
    let label: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case fromNodeID = "fromNodeId"
        case toNodeID = "toNodeId"
        case relationType
        case weight
        case confidence
        case evidenceCount
        case label
    }
}

struct ProblemCatalogTruncationDTO: Decodable, Hashable, Sendable {
    let shownNodes: Int
    let totalNodes: Int
    let shownEdges: Int?
    let totalEdges: Int?

    init(shownNodes: Int, totalNodes: Int, shownEdges: Int? = nil, totalEdges: Int? = nil) {
        self.shownNodes = shownNodes
        self.totalNodes = totalNodes
        self.shownEdges = shownEdges
        self.totalEdges = totalEdges
    }
}

struct ProblemCatalogProblemDetailDTO: Decodable, Hashable, Sendable {
    let schemaVersion: Int
    let catalogGeneration: String
    let problem: ProblemCatalogProblemDTO
    let revisions: [ProblemCatalogRevisionDTO]
    let recentAttempts: [ProblemCatalogAttemptSummaryDTO]

    init(
        schemaVersion: Int = 1,
        catalogGeneration: String,
        problem: ProblemCatalogProblemDTO,
        revisions: [ProblemCatalogRevisionDTO] = [],
        recentAttempts: [ProblemCatalogAttemptSummaryDTO] = []
    ) {
        self.schemaVersion = schemaVersion
        self.catalogGeneration = catalogGeneration
        self.problem = problem
        self.revisions = revisions
        self.recentAttempts = recentAttempts
    }
}

struct ProblemCatalogProblemDTO: Decodable, Hashable, Sendable {
    let problemRef: ProblemCatalogProblemRefDTO
    let status: String
    let title: String
    let prompt: String
    let difficulty: String
    let estimatedMinutes: Int?
    let sourceKind: String
    let sourceLabel: String
    let sourceRefs: [String]
    let taxonomyPath: [ProblemCatalogScopeItemDTO]
    let skillIDs: [String]
    let skillLabels: [String]
    let errorTags: [String]
    let errorLabels: [String]
    let progress: ProblemCatalogProgressDTO

    private enum CodingKeys: String, CodingKey {
        case problemRef
        case status
        case title
        case prompt
        case difficulty
        case estimatedMinutes
        case sourceKind
        case sourceLabel
        case sourceRefs
        case taxonomyPath
        case skillIDs = "skillIds"
        case skillLabels
        case errorTags
        case errorLabels
        case progress
    }
}

struct ProblemCatalogRevisionDTO: Decodable, Identifiable, Hashable, Sendable {
    let revision: Int
    let contentHash: String
    let isCurrent: Bool

    var id: String { "\(revision):\(contentHash)" }
}

struct ProblemCatalogAttemptSummaryDTO: Decodable, Identifiable, Hashable, Sendable {
    let attemptID: String
    let result: String?
    let status: String
    let createdAt: String
    let completedAt: String?

    private enum CodingKeys: String, CodingKey {
        case attemptID = "attemptId"
        case result
        case status
        case createdAt
        case completedAt
    }

    var id: String { attemptID }
}

struct ProblemCatalogQueryRequest: Codable, Hashable, Sendable {
    let query: String
    let anchorProblemBundleID: UUID?
    let scopePath: [ProblemCatalogScopeItemDTO]
    let clientQueryDraft: ProblemCatalogClientQueryDraft?
    let limit: Int
    let cursor: String?
    let catalogGeneration: String?

    private enum CodingKeys: String, CodingKey {
        case query
        case anchorProblemBundleID = "anchorProblemBundleId"
        case scopePath
        case clientQueryDraft
        case limit
        case cursor
        case catalogGeneration
    }

    init(
        query: String,
        anchorProblemBundleID: UUID? = nil,
        scopePath: [ProblemCatalogScopeItemDTO],
        clientQueryDraft: ProblemCatalogClientQueryDraft?,
        limit: Int = ProblemCatalogViewDTO.maximumFullScreenNodes,
        cursor: String? = nil,
        catalogGeneration: String? = nil
    ) {
        self.query = query
        self.anchorProblemBundleID = anchorProblemBundleID
        self.scopePath = scopePath
        self.clientQueryDraft = clientQueryDraft
        self.limit = min(max(limit, 1), ProblemCatalogViewDTO.maximumFullScreenNodes)
        self.cursor = cursor
        self.catalogGeneration = catalogGeneration
    }
}

struct ProblemCatalogClientQueryDraft: Codable, Hashable, Sendable {
    let intent: String?
    let terms: [String]
    let subject: String?
    let unit: String?
    let subunit: String?
    let skillTerms: [String]
    let sourceTerms: [String]
    let errorTerms: [String]
    let progressStates: [String]
}
