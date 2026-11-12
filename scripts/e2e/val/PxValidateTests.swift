import XCTest
@testable import strius

/// Dev Box だけで使う: 保存した返答(scripts/e2e/val/replies.json)を、チャットの 1 ラウンド目と同じ検証にかける。
final class PxValidateTests: XCTestCase {
    func testValidateSavedReplies() throws {
        let path: String = ProcessInfo.processInfo.environment["PX_REPLIES"] ?? ""
        let data: Data = try Data(contentsOf: URL(fileURLWithPath: path))
        let items: [[String: String]] = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        var lines: [String] = []
        for item in items {
            let label: String = item["label"] ?? "?"
            let text: String = item["text"] ?? ""
            do {
                let (afterProgress, raw) = try LearningProgress.extractUpdate(text.trimmingCharacters(in: .whitespacesAndNewlines))
                let (afterMemory, _, memoryError) = TutorMemory.extractEmbeddedMemoryUpdate(afterProgress)
                let (afterExampleProblem, _) = LearnerText.extractWorkbookExample(afterMemory)
                let (afterExample, _) = LearnerText.extractWorkbookExampleReady(afterExampleProblem)
                let (afterBlocks, _, _) = LearnerText.extractWorkbookBlocks(afterExample)
                let candidate: String = LearnerText.sanitizeLearnerFacingText(afterBlocks)
                let user: String = item["user"] ?? ""
                _ = try LearningProgress.applyUpdate(
                    before: LearningProgress.emptyState(), raw: raw, reply: candidate, userMessageID: user,
                    assistantMessageID: item["assistant"] ?? "", sourceMessages: [user: (role: "user", plainText: item["learner"] ?? "")]
                )
                lines.append("OK \(label) memory=\(memoryError.map { String(describing: $0) } ?? "-")")
            } catch {
                lines.append("NG \(label) \(String(String(describing: error).prefix(160)))")
            }
        }
        try lines.joined(separator: "\n").write(toFile: path + ".out", atomically: true, encoding: .utf8)
    }
}
