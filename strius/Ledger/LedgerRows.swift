import Foundation
import GRDB

/// Projection rows (design §4.2). Column names mirror `backend/migrations/032_workbook.sql`,
/// `021_codex_app_server.sql` and the chat tables so the screen DTOs stay unchanged.
/// Every row is written only by `LedgerEvent` application (see `Ledger`).

nonisolated protocol LedgerRow: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    static var entity: LedgerEntity { get }
    var entityID: String { get }
}

extension LedgerRow {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    static var databaseTableName: String { entity.rawValue }
}

nonisolated enum LedgerEntity: String, Codable, Sendable, CaseIterable {
    case workbookUnits = "workbook_units"
    case workbookSubunits = "workbook_subunits"
    case workbookProblems = "workbook_problems"
    case workbookSets = "workbook_sets"
    case workbookCaptures = "workbook_captures"
    case workbookAttempts = "workbook_attempts"
    case workbookProposals = "workbook_proposals"
    case threads
    case messages
    case learningProgress = "learning_progress"
    case turns
    case codexThreads = "codex_threads"
    case codexAccount = "codex_account"
    case threadBranches = "thread_branches"
    case branchForkAttempts = "branch_fork_attempts"
    case timelineSkills = "timeline_skills"
    case timelineSkillEdges = "timeline_skill_edges"
    case timelineMapChanges = "timeline_map_changes"
    case timelineBatches = "timeline_batches"
    case timelineCards = "timeline_cards"
    case timelineAttempts = "timeline_attempts"
    case timelineDips = "timeline_dips"
}

// MARK: - Workbook

nonisolated struct WorkbookUnitRecord: LedgerRow {
    static let entity = LedgerEntity.workbookUnits
    var id: String
    var title: String
    var outcome: String
    var status: String  // active | passed | archived
    var source: String  // consult | capture | manual
    var position: Int
    var overview: LedgerJSON
    var createdAt: String
    var updatedAt: String
    var passedAt: String?
    var entityID: String { id }
}

nonisolated struct WorkbookSubunitRecord: LedgerRow {
    static let entity = LedgerEntity.workbookSubunits
    var id: String
    var unitId: String
    var title: String
    var outcome: String
    var position: Int
    var stage: Int
    var status: String  // pending | active | passed
    var n: Int
    var threshold: Double
    var assistance: String
    var scoringUnit: String
    var metadata: LedgerJSON
    var createdAt: String
    var updatedAt: String
    var passedAt: String?
    var entityID: String { id }
}

nonisolated struct WorkbookProblemRecord: LedgerRow {
    static let entity = LedgerEntity.workbookProblems
    var id: String
    var subunitId: String
    var position: Int
    var prompt: String
    var answerKey: String
    var checkpoints: [String]
    var source: String  // generated | capture
    var hintGivenAt: String?
    var createdAt: String
    var entityID: String { id }
}

nonisolated struct WorkbookSetRecord: LedgerRow {
    static let entity = LedgerEntity.workbookSets
    var id: String
    var subunitId: String
    var stage: Int
    var kind: String  // example | practice (過去の remedial は演習として読む)
    var status: String  // generating | open | graded | superseded | failed
    var problemIds: [String]
    var gate: LedgerJSON
    var result: LedgerJSON?
    var error: String?
    var createdAt: String
    var updatedAt: String
    var gradedAt: String?
    var entityID: String { id }
}

nonisolated struct WorkbookCaptureRecord: LedgerRow {
    static let entity = LedgerEntity.workbookCaptures
    var id: String
    var status: String  // identifying | graded | triage | failed
    var imagePath: String  // relative to StruisPaths.captures
    var contentType: String
    var sha256: String
    var byteCount: Int
    var context: LedgerJSON
    var subunitId: String?
    var setId: String?
    var verdicts: LedgerJSON
    var summary: LedgerJSON
    var candidates: LedgerJSON
    var error: String?
    var createdAt: String
    var updatedAt: String
    var gradedAt: String?
    var entityID: String { id }
}

nonisolated struct WorkbookAttemptRecord: LedgerRow {
    static let entity = LedgerEntity.workbookAttempts
    var id: String
    var subunitId: String
    var problemId: String
    var captureId: String
    var setId: String?
    var sequence: Int
    var verdict: String
    var score: Double
    var assisted: Bool
    var errorTag: String
    var note: String
    var createdAt: String
    var entityID: String { id }
}

nonisolated struct WorkbookProposalRecord: LedgerRow {
    static let entity = LedgerEntity.workbookProposals
    var id: String
    var threadId: String?
    var messageId: String?
    var status: String  // generating | ready | started | failed
    var request: String
    var overview: LedgerJSON
    var unitId: String?
    var error: String?
    var createdAt: String
    var updatedAt: String
    var entityID: String { id }
}

// MARK: - Chat

nonisolated struct ThreadRecord: LedgerRow {
    static let entity = LedgerEntity.threads
    var id: String
    var title: String
    var source: String  // user | branch
    var latestPreview: String?
    var lastMessageAt: String?
    var createdAt: String
    var updatedAt: String
    var entityID: String { id }
}

nonisolated struct MessageRecord: LedgerRow {
    static let entity = LedgerEntity.messages
    var id: String
    var threadId: String
    var role: String  // user | assistant | system
    var status: String  // pending | completed | failed
    var plainText: String?
    var blocks: LedgerJSON
    var metadata: LedgerJSON
    var createdAt: String
    var completedAt: String?
    var entityID: String { id }
}

nonisolated struct ProgressRevisionRecord: LedgerRow {
    static let entity = LedgerEntity.learningProgress
    var revision: Int
    var state: LedgerJSON
    var messageId: String?
    var turnId: String?
    var savedAt: String
    var entityID: String { String(revision) }
}

// MARK: - Turns and Codex

nonisolated struct TurnRecord: LedgerRow {
    static let entity = LedgerEntity.turns
    var id: String
    var kind: String  // chat | workbook_grading | workbook_set | workbook_unit | thread_fork | thread_inject
    var targetId: String?
    var threadId: String?
    var status: String  // queued | running | completed | failed | interrupted
    var round: Int
    var plan: LedgerJSON
    var outcome: LedgerJSON?
    var codexThreadId: String?
    var codexTurnId: String?
    var executions: LedgerJSON
    var error: String?
    var createdAt: String
    var startedAt: String?
    var completedAt: String?
    var entityID: String { id }
}

nonisolated struct CodexThreadRecord: LedgerRow {
    static let entity = LedgerEntity.codexThreads
    var threadId: String
    var codexThreadId: String
    var lastTurnId: String?
    var lastCompletedAt: String?
    var createdAt: String
    var entityID: String { threadId }
}

nonisolated struct CodexAccountRecord: LedgerRow {
    static let entity = LedgerEntity.codexAccount
    var id: String  // always "device"
    var status: String  // disconnected | connecting | connected | rate_limited | error
    var authMode: String?
    var planType: String?
    var email: String?
    var rateLimits: LedgerJSON
    var resetsAt: String?
    var syncedAt: String?
    var error: String?
    var entityID: String { id }
}

nonisolated struct ThreadBranchRecord: LedgerRow {
    static let entity = LedgerEntity.threadBranches
    var id: String
    var stemThreadId: String
    var branchThreadId: String
    var anchorMessageId: String
    var anchorCodexTurnId: String
    var clientRequestId: String
    var firstQuestionPreview: String
    var status: String  // active | failed | archived
    var lastMergedMessageId: String?
    var mergePending: Bool
    var createdAt: String
    var updatedAt: String
    var entityID: String { id }
}

nonisolated struct BranchForkAttemptRecord: LedgerRow {
    static let entity = LedgerEntity.branchForkAttempts
    var id: String
    var stemThreadId: String
    var clientRequestId: String
    var codexThreadId: String
    var branchId: String?
    var status: String  // forked | linked
    var createdAt: String
    var updatedAt: String
    var entityID: String { id }
}
