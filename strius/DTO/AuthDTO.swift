import Foundation

struct AppleExchangeRequest: Encodable {
    let identityToken: String
    var displayName: String? = nil
    var nonce: String? = nil
}

struct AppleExchangeResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let userId: UUID
    let trialStartedAt: Date
    let trialEndsAt: Date
}

struct RefreshRequest: Encodable {
    let refreshToken: String
}

struct RefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String
}

struct RealtimeTicketResponse: Decodable {
    let token: String
    let expiresAt: Int
}
