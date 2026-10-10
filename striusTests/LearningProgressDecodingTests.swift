import Foundation
import Testing
@testable import strius

@MainActor
struct LearningProgressDecodingTests {
    @Test func recordWithoutProgressRemainsExplicitAndCopiesValidJSON() throws {
        let json = """
        {"schema_version":1,"message_id":"11111111-1111-1111-1111-111111111111","revision":0,"save_status":"not_recorded","summary":{"current_goal":null,"current_stage":null,"completed_actions":[],"next_action":null,"wait_reason":null},"ancestors":[],"evidence":[],"trials":[],"before":{"current_goal":null,"current_stage":null,"next_action":null,"wait_reason":null},"after":{"current_goal":null,"current_stage":null,"next_action":null,"wait_reason":null},"conditions":[],"issues":[]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let record = try decoder.decode(LearningProgressRecord.self, from: Data(json.utf8))
        #expect(record.saveStatus == "not_recorded")
        #expect(record.summary.currentGoal == nil)
        let copied = try record.verificationText()
        let decoded = try decoder.decode(LearningProgressRecord.self, from: Data(copied.utf8))
        #expect(decoded.messageId == record.messageId)
        #expect(decoded.saveStatus == "not_recorded")
        #expect(copied.contains("schema_version"))
    }

    @Test func endpointBindsBothThreadAndMessageAndRequiresAuthentication() {
        let thread = UUID()
        let message = UUID()
        let endpoint = APIEndpoint.learningProgress(threadID: thread, messageID: message)
        #expect(endpoint.requiresAuth)
        #expect(endpoint.method == .get)
        #expect(endpoint.path == "/v1/threads/\(thread.uuidString)/messages/\(message.uuidString)/learning-progress")
    }
}
