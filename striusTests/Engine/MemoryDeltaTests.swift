import XCTest
@testable import strius

/// 記憶の再送: 時刻だけの変更では送らず、変わったファイルだけを末尾に足す(送信済みの入力は書き換えない)。
final class MemoryDeltaTests: XCTestCase {
    private func workspace() throws -> (workspace: URL, desk: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-delta-" + UUID().uuidString, isDirectory: true)
        let desk = root.appendingPathComponent("tutor_desk", isDirectory: true)
        try FileManager.default.createDirectory(at: desk, withIntermediateDirectories: true)
        _ = try TutorMemory.ensureTutorMemoryFiles(desk: desk, learnerID: "learner")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, desk)
    }

    private func stage(_ desk: URL, at date: Date) throws {
        try TutorMemory.stageSession(desk: desk, learnerID: "learner", threadID: "t", turnRunID: UUID().uuidString, userMessageID: "m",
                                     latestUserText: "hi", stagedAt: date)
    }

    func testStagingTimeAloneDoesNotChangeWhatTheModelSees() throws {
        let (workspace, desk) = try workspace()
        try stage(desk, at: Date(timeIntervalSince1970: 1_000))
        let first = try TutorMemory.tutorMemorySections(workspace: workspace, excluding: ["current/session.yaml"])
        try stage(desk, at: Date(timeIntervalSince1970: 9_000))
        let second = try TutorMemory.tutorMemorySections(workspace: workspace, excluding: ["current/session.yaml"])
        XCTAssertEqual(first, second)
        let task = try XCTUnwrap(second.first { $0.path == "tutor_desk/current/task.yaml" })
        XCTAssertFalse(task.body.contains("staged_at"))
        // 保存用のファイルには時刻を残す。
        XCTAssertTrue(try String(contentsOf: desk.appendingPathComponent("current/task.yaml"), encoding: .utf8).contains("staged_at"))
        let update = ChatTurns.MemoryUpdate(sections: second, delivered: ChatTurns.MemoryUpdate(sections: first, delivered: nil).delivered.files)
        XCTAssertEqual(update.mode, .unchanged)
    }

    func testChangedAndRemovedFilesAreAppendedAsAnUpdate() throws {
        let (workspace, desk) = try workspace()
        try stage(desk, at: Date())
        let interventions = desk.appendingPathComponent("interventions", isDirectory: true)
        try FileManager.default.createDirectory(at: interventions, withIntermediateDirectories: true)
        try "note: old\n".write(to: interventions.appendingPathComponent("a.yaml"), atomically: true, encoding: .utf8)
        let before = try TutorMemory.tutorMemorySections(workspace: workspace, excluding: ["current/session.yaml"])
        let delivered = ChatTurns.MemoryUpdate(sections: before, delivered: nil)
        XCTAssertEqual(delivered.mode, .full)
        XCTAssertTrue(delivered.lines(sessionContext: "S").joined(separator: "\n").contains("tutor_desk/interventions/a.yaml"))

        // 苦手の記録が変わり、介入の記録が消えた。
        try "learner_id: learner\nweak_points:\n- 符号\n".write(to: desk.appendingPathComponent("learner/profile.yaml"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: interventions.appendingPathComponent("a.yaml"))
        let after = try TutorMemory.tutorMemorySections(workspace: workspace, excluding: ["current/session.yaml"])
        let update = ChatTurns.MemoryUpdate(sections: after, delivered: delivered.delivered.files)
        guard case .changes(let changed, let removed) = update.mode else { return XCTFail("\(update.mode)") }
        XCTAssertEqual(changed.map(\.path), ["tutor_desk/learner/profile.yaml"])
        XCTAssertEqual(removed, ["tutor_desk/interventions/a.yaml"])
        let text = update.lines(sessionContext: "S").joined(separator: "\n")
        XCTAssertTrue(text.contains("符号"))
        XCTAssertTrue(text.contains("No longer part of the memory evidence"))
        XCTAssertFalse(text.contains("--- tutor_desk/goals/current.yaml ---"), "unchanged files are not sent again")
    }

    func testCompactionOrForkMakesTheNextTurnSendEverything() {
        let store = ThreadContextStore(url: nil)
        store.recordMemory("thr", DeliveredMemory(files: ["a": "1"]))
        XCTAssertEqual(store.entry("thr")?.memoryFiles, ["a": "1"])
        XCTAssertNotNil(store.entry("thr")?.memory)
        store.forgetMemory("thr")
        XCTAssertNil(store.entry("thr")?.memoryFiles)
        // 記憶の削除(学習者の操作)は、すべての会話に次のターンで渡し直す。
        store.recordMemory("thr", DeliveredMemory(files: ["a": "1"]))
        store.remove(["other"])
        XCTAssertNil(store.entry("thr")?.memoryFiles)
    }

    func testProfileAndRecordsSurviveRelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thread-context-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = ThreadContextStore(url: url)
        store.update("thr") {
            $0.provider = .anthropic
            $0.profile = .init(kind: "chat", model: "claude-opus-5-5", translation: 2, cacheTTL: "1h")
        }
        store.recordMemory("thr", DeliveredMemory(files: ["tutor_desk/learner/profile.yaml": "x"]))
        let reopened = ThreadContextStore(url: url)
        XCTAssertEqual(reopened.entry("thr")?.profile?.translation, 2)
        XCTAssertEqual(reopened.entry("thr")?.memoryFiles, ["tutor_desk/learner/profile.yaml": "x"])
    }
}
