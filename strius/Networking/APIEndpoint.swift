import Foundation

struct APIEndpoint {
    enum Method: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    let method: Method
    let path: String
    var requiresAuth: Bool = true
    var queryItems: [URLQueryItem] = []
    var deliveryAppKey: String?

    static let appleExchange = APIEndpoint(method: .post, path: "/v1/auth/apple/exchange", requiresAuth: false)
    static let refresh = APIEndpoint(method: .post, path: "/v1/auth/refresh", requiresAuth: false)
    static let realtimeTicket = APIEndpoint(method: .post, path: "/v1/auth/realtime-ticket")
    static let bootstrap = APIEndpoint(method: .get, path: "/v1/bootstrap")
    static let listThreads = APIEndpoint(method: .get, path: "/v1/threads")
    static let createThread = APIEndpoint(method: .post, path: "/v1/threads")
    static let learningFeedV2Prefetch = APIEndpoint(method: .post, path: "/v1/learning-feed/v2/prefetch")
    static let experienceLaunch = APIEndpoint(method: .post, path: "/v1/experience/launch")

    static func experienceLaunchResolve(decisionID: UUID) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/experience/launch/\(decisionID.uuidString)/resolve")
    }

    static func learningFeedV2Activate(sessionID: UUID) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/learning-feed/v2/sessions/\(sessionID.uuidString)/activate")
    }

    static func learningFeedV2EventsBatch(sessionID: UUID) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/learning-feed/v2/sessions/\(sessionID.uuidString)/events/batch")
    }

    static func learningFeedV2Snapshot(sessionID: UUID) -> APIEndpoint {
        APIEndpoint(method: .get, path: "/v1/learning-feed/v2/sessions/\(sessionID.uuidString)")
    }

    static func learningFeedV2Complete(sessionID: UUID) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/learning-feed/v2/sessions/\(sessionID.uuidString)/complete")
    }

    static func learningFeedV2Close(sessionID: UUID) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/learning-feed/v2/sessions/\(sessionID.uuidString)/close")
    }

    static func asset(relativePath: String, page: Int? = nil) -> APIEndpoint {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        let encodedPath = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
            }
            .joined(separator: "/")
        var endpoint = APIEndpoint(method: .get, path: "/v1/assets/\(encodedPath)")
        if let page {
            endpoint.queryItems = [URLQueryItem(name: "page", value: String(page))]
        }
        return endpoint
    }

    static func listMessages(threadID: String) -> APIEndpoint {
        APIEndpoint(method: .get, path: "/v1/threads/\(threadID)/messages")
    }
    static func learningProgress(threadID: UUID, messageID: UUID) -> APIEndpoint {
        APIEndpoint(method: .get, path: "/v1/threads/\(threadID.uuidString)/messages/\(messageID.uuidString)/learning-progress")
    }
    static func latestAttempt(threadID: String) -> APIEndpoint {
        APIEndpoint(method: .get, path: "/v1/threads/\(threadID)/attempts/latest")
    }
    static func postMessage(threadID: String) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/threads/\(threadID)/messages")
    }
    static func listBranches(stemThreadID: UUID) -> APIEndpoint {
        APIEndpoint(method: .get, path: "/v1/threads/\(stemThreadID.uuidString)/branches")
    }
    static func createBranch(stemThreadID: UUID) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/threads/\(stemThreadID.uuidString)/branches")
    }
    static func retryFirstBranchTurn(branchID: UUID) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/branches/\(branchID.uuidString)/retry-first-turn")
    }
    static func resumeBranch(branchID: UUID) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/branches/\(branchID.uuidString)/resume")
    }
    static func returnFromBranch(branchID: UUID) -> APIEndpoint {
        APIEndpoint(method: .post, path: "/v1/branches/\(branchID.uuidString)/return")
    }
}
