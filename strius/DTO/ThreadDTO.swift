import Foundation

struct ThreadSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String?
    var source: String? = nil
    let latestPreview: String?
    let lastMessageAt: Date?
    var createdAt: Date? = nil
}

struct CreateThreadRequest: Encodable {
    var title: String? = nil
    var source: String = "user"
}

struct CreateThreadResponse: Decodable {
    let id: UUID
    let title: String?
    let source: String?
}

/// 没頭シーンからの文脈 chat 参照 (`immersion_scene_context`)。
/// クライアントは「どこにいるか」だけを名指しし、シーンの事実は backend が
/// 保存済みパッケージから解決する。
struct ImmersionSceneContext: Encodable {
    enum Prediction: Encodable {
        case number(Double)
        case text(String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let value): try container.encode(value)
            case .text(let value): try container.encode(value)
            }
        }
    }

    let sceneID: String
    let stage: String
    let prediction: Prediction?
}

struct CreateMessageRequest: Encodable {
    let text: String
    let learningFeedSessionID: UUID?
    let immersionSceneContext: ImmersionSceneContext?
    let workbookView: WorkbookViewRef?

    init(
        text: String,
        learningFeedSessionID: UUID? = nil,
        immersionSceneContext: ImmersionSceneContext? = nil,
        workbookView: WorkbookViewRef? = nil
    ) {
        self.text = text
        self.learningFeedSessionID = learningFeedSessionID
        self.immersionSceneContext = immersionSceneContext
        self.workbookView = workbookView
    }
}

struct OpenProblemThreadResponse: Decodable {
    let thread: ThreadSummary
}

struct CreateMessageResponse: Decodable {
    let userMessageId: UUID
    let assistantMessageId: UUID
    let workflowRunId: UUID?
    let codexTurnRunId: UUID?
    let handledAs: String?
}

struct ChatBranchSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let stemThreadId: UUID
    let threadId: UUID
    let anchorMessageId: UUID?
    let firstQuestionPreview: String
    let status: String
    let mergePending: Bool
    let createdAt: Date
    let updatedAt: Date
}

struct CreateChatBranchRequest: Encodable {
    let clientRequestId: UUID
    let message: String
    let anchorMessageId: UUID?
}

struct CreateChatBranchResponse: Decodable {
    let branch: ChatBranchSummary
    let created: Bool
    let userMessageId: UUID?
    let assistantMessageId: UUID?
    let codexTurnRunId: UUID?
}

struct RetryFirstBranchTurnResponse: Decodable {
    let branchId: UUID
    let codexTurnRunId: UUID
    let assistantMessageId: UUID
}

struct ResumeChatBranchResponse: Decodable {
    let branchId: UUID
    let resumed: Bool
}

struct ReturnFromChatBranchResponse: Decodable {
    let stemThreadId: UUID
    let merged: Bool
    let mergePending: Bool?
    let mergedMessageCount: Int?
}
