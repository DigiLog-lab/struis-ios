import Foundation
import XCTest
#if canImport(StruisEngine)
@testable import StruisEngine
#else
@testable import strius
#endif

/// Compile-time proof that the Engine API is usable from a nonisolated context
/// (the app sets SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor).
nonisolated func engineIsolationProbe(desk: URL) throws {
    var state = LearningProgress.emptyState()
    state = try LearningProgress.applyUpdate(before: state, raw: EngineJSON.null, reply: "", userMessageID: "", assistantMessageID: "", sourceMessages: [:])
    _ = try LearningProgress.contextForTurn(state: state)
    _ = try LearningProgress.turnContract(state: state, assistantMessageID: "", updateSchema: [:])
    _ = try LearningProgress.publicTrace(trace: [:], messageID: "")
    _ = try LearningProgress.scoreWindow(state: state, goalID: "")
    _ = try LearningProgress.loopStats(state: state, goalID: "")
    _ = try LearningProgress.extractUpdate("")
    _ = LearnerText.sanitizeLearnerFacingText("")
    _ = LearnerText.extractWorkbookBlocks("")
    _ = LearnerText.workbookCurrentViewTurnInput(view: [:], learnerText: "")
    _ = LearnerText.struisContextInjectedItemText(staged: nil)
    _ = LearnerText.renderRecentThreadHistory(currentThreadID: "", threadRows: [], messageRows: [])
    _ = LearnerText.selectContextThreadRows(currentThreadID: "", latestUserText: "", threadRows: [])
    _ = CodexModels.astraModel
    _ = TurnProgress.progressLabelsFromPlan(.null)
    _ = TurnProgress.progressActivityFromItem(.null)
    _ = TurnProgress.progressLabel("")
    _ = AgentText.naturalLanguageFromAgentText("")
    _ = AgentText.extractAgentTextFromItem(.null)
    _ = TutorMemory.extractEmbeddedMemoryUpdate("")
    try TutorMemory.ensureTutorMemoryFiles(desk: desk, learnerID: "")
    _ = try TutorMemory.renderTutorMemoryContext(workspace: desk)
    _ = try TutorMemory.modelMemoryManifest(workspace: desk)
    _ = try TutorMemory.shapePayload(payload: EngineJSON.null, expected: [])
    _ = try TutorMemory.applyTutorMemoryQueue(queueDirectory: desk, desk: desk, workspaceRootForRelativePaths: desk, learnerID: "", threadID: "",
                                              turnRunID: "", userMessageID: nil, isValidEvidenceRef: { _, _ in false })
    try TutorMemory.stageSession(desk: desk, learnerID: "", threadID: "", turnRunID: "", userMessageID: nil, latestUserText: "")
    _ = try TutorMemory.queueEmbeddedMemoryUpdate(desk: desk, turnRunID: "", payload: "")
    _ = try EngineJSON.parse("{}").serialized()
    _ = try EngineYAML.dump(.null)
    _ = EngineSHA256.hexDigest(Data())
}

final class EngineIsolationProbeTests: XCTestCase {
    func testProbeCompiles() {
        XCTAssertNotNil(engineIsolationProbe)
    }
}
