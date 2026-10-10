import Foundation

/// Mirrors `CodexAccountResponse` in `web/src/lib/types.ts`. The
struct CodexAccount: Decodable, Hashable, Sendable {
    enum Status: String, Decodable, Sendable {
        case disconnected
        case connecting
        case connected
        case rateLimited = "rate_limited"
        case error
    }

    let id: String?
    let status: Status
    let authMode: String?
    let planType: String?
    let accountEmail: String?
    let rateLimitStatus: AnyJSON?
    let rateLimitResetsAt: Date?
    let lastSyncedAt: Date?
    let error: String?
    let loginID: String?
    let verificationURL: String?
    let userCode: String?

    var isConnected: Bool {
        status == .connected || status == .rateLimited
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case authMode
        case planType
        case accountEmail
        case rateLimitStatus
        case rateLimitResetsAt
        case lastSyncedAt
        case error
        case loginID = "loginId"
        case verificationURL = "verificationUrl"
        case userCode
    }
}

struct PromptVersion: Decodable, Hashable, Sendable {
    let family: String
    let sha256: String
    let version: String
    let updatedAt: String
}

struct CodexPromptVersions: Decodable, Hashable, Sendable {
    let base: PromptVersion
    let developerInstructions: PromptVersion
    let agents: PromptVersion
}
