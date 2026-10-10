import Foundation

struct BootstrapResponse: Decodable {
    let user: User
    let trial: Trial
    let streak: Streak
    let threads: [ThreadSummary]

    struct User: Decodable {
        let id: UUID
        let displayName: String?
        let email: String?
    }

    struct Trial: Decodable {
        let startedAt: Date?
        let endsAt: Date?
    }

    struct Streak: Decodable {
        let count: Int
        let lastSolvedOn: String?
    }

}
