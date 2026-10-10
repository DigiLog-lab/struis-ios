import Foundation

enum RealtimeEvent: Sendable, Hashable {
    case threadMessageCompleted(threadID: UUID, messageID: UUID)
    case attemptUpdated(threadID: UUID?, attemptID: UUID)
    case workbookCaptureUpdated(captureID: String, status: String)
    case workbookSetUpdated(setID: String, status: String)
    case workbookProposalUpdated(proposalID: String, status: String)
    case unknown(type: String)
    case pong

    static func decode(from text: String) -> RealtimeEvent? {
        if text == "pong" { return .pong }
        guard let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            return nil
        }
        switch envelope.type {
        case "thread.message.completed":
            guard let threadID = envelope.data?["thread_id"]?.stringValue.flatMap(UUID.init),
                  let messageID = envelope.data?["message_id"]?.stringValue.flatMap(UUID.init)
            else { return .unknown(type: envelope.type) }
            return .threadMessageCompleted(threadID: threadID, messageID: messageID)
        case "attempt.updated":
            guard let attemptID = envelope.data?["attempt_id"]?.stringValue.flatMap(UUID.init)
            else { return .unknown(type: envelope.type) }
            let threadID = envelope.data?["thread_id"]?.stringValue.flatMap(UUID.init)
            return .attemptUpdated(threadID: threadID, attemptID: attemptID)
        case "workbook.capture.updated":
            guard let captureID = envelope.data?["capture_id"]?.stringValue else { return .unknown(type: envelope.type) }
            return .workbookCaptureUpdated(captureID: captureID, status: envelope.data?["status"]?.stringValue ?? "")
        case "workbook.set.updated":
            guard let setID = envelope.data?["set_id"]?.stringValue else { return .unknown(type: envelope.type) }
            return .workbookSetUpdated(setID: setID, status: envelope.data?["status"]?.stringValue ?? "")
        case "workbook.proposal.updated":
            guard let proposalID = envelope.data?["proposal_id"]?.stringValue else { return .unknown(type: envelope.type) }
            return .workbookProposalUpdated(proposalID: proposalID, status: envelope.data?["status"]?.stringValue ?? "")
        default:
            return .unknown(type: envelope.type)
        }
    }

    private struct Envelope: Decodable {
        let type: String
        let data: [String: AnyJSONValue]?
    }
}
