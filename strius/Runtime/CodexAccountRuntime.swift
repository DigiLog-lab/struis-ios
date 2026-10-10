import Foundation
import OSLog

private let accountLog = Logger(subsystem: "com.digiloglab.strius", category: "codex-account")

/// Device-code login, account read, and logout against the on-device
/// `codex app-server` (design §6.2 `CodexAccountRuntime`). The learner's
/// ChatGPT credentials are kept in the runtime app group, separate from the Ledger.
nonisolated struct CodexLoginStart: Sendable, Equatable {
    let loginID: String
    let verificationURL: String
    let userCode: String
}

nonisolated struct CodexAccountSnapshot: Sendable, Equatable {
    enum Status: String, Sendable {
        case disconnected, connected, rateLimited = "rate_limited"
    }

    let status: Status
    let authMode: String?
    let planType: String?
    let email: String?
    let rateLimits: JSONObject
    let rateLimitResetsAt: Date?
    let syncedAt: Date

    static func == (lhs: CodexAccountSnapshot, rhs: CodexAccountSnapshot) -> Bool {
        lhs.status == rhs.status && lhs.authMode == rhs.authMode && lhs.planType == rhs.planType
            && lhs.email == rhs.email && lhs.rateLimitResetsAt == rhs.rateLimitResetsAt && lhs.syncedAt == rhs.syncedAt
            && NSDictionary(dictionary: lhs.rateLimits).isEqual(to: rhs.rateLimits)
    }
}

actor CodexAccountRuntime {
    private let session: CodexAppServerSession

    init(session: CodexAppServerSession) {
        self.session = session
    }

    func startDeviceLogin() async throws -> CodexLoginStart {
        let result = try await session.request("account/login/start", params: ["type": "chatgptDeviceCode"], timeout: .seconds(60))
        guard let loginID = result["loginId"] as? String, !loginID.isEmpty,
              let url = result["verificationUrl"] as? String, url.hasPrefix("https://"),
              let code = result["userCode"] as? String, !code.isEmpty
        else { throw CodexAppServerError.malformed("account/login/start") }
        return CodexLoginStart(loginID: loginID, verificationURL: url, userCode: code)
    }

    func cancelLogin(loginID: String) async {
        _ = try? await session.request("account/login/cancel", params: ["loginId": loginID], timeout: .seconds(20))
    }

    /// Resolves when the learner finishes the browser login (`account/login/completed`).
    func waitForLoginCompleted(loginID: String, timeout: Duration = .seconds(600), pollInterval: Duration = .seconds(3)) async throws {
        let clock = ActiveClock.shared
        let until = clock.now + timeout.timeInterval
        do {
            let (_, params) = try await session.waitForNotification(methods: ["account/login/completed"], timeout: timeout) { params in
                (params["loginId"] as? String ?? "") == loginID
            }
            guard params["success"] as? Bool == true else {
                throw CodexAppServerError.rpc(code: nil, message: params["error"] as? String ?? "Codex login failed")
            }
        } catch let error as CodexAppServerError where error.isConnectionLoss {
            // The learner was in the browser and the connection closed meanwhile (M1). The completion
            // went to the old connection; the login itself may have succeeded. Ask the server again.
            accountLog.info("login wait lost its connection; checking the account again")
            while clock.now < until {
                try Task.checkCancellation()
                if let result = try? await session.request("account/read", params: ["refreshToken": false], timeout: .seconds(30), critical: false),
                   result["account"] is JSONObject {
                    return
                }
                try await Task.sleep(for: pollInterval)
            }
            throw error
        }
    }

    func readAccount() async throws -> CodexAccountSnapshot {
        let result = try await session.request("account/read", params: ["refreshToken": false], timeout: .seconds(60))
        let account = result["account"] as? JSONObject
        var limits: JSONObject = [:]
        if account != nil {
            limits = (try? await session.request("account/rateLimits/read", params: [:], timeout: .seconds(60))) ?? [:]
        }
        let reached = Self.rateLimitReached(limits)
        let status: CodexAccountSnapshot.Status = reached ? .rateLimited : (account == nil ? .disconnected : .connected)
        return CodexAccountSnapshot(
            status: status,
            authMode: account?["type"] as? String,
            planType: (account?["planType"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            email: (account?["email"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            rateLimits: limits,
            rateLimitResetsAt: Self.rateLimitResetTime(limits),
            syncedAt: Date()
        )
    }

    func logout() async throws {
        _ = try await session.request("account/logout", params: [:], timeout: .seconds(60))
    }

    // MARK: - Rate limits (port of _rate_limit_reset_time / _rate_limit_reached)

    nonisolated static func rateLimitBuckets(_ limits: JSONObject) -> [JSONObject] {
        if let byID = limits["rateLimitsByLimitId"] as? JSONObject {
            return byID.values.compactMap { $0 as? JSONObject }
        }
        if let single = limits["rateLimits"] as? JSONObject { return [single] }
        return []
    }

    nonisolated static func rateLimitResetTime(_ limits: JSONObject) -> Date? {
        var resets: [Double] = []
        for bucket in rateLimitBuckets(limits) {
            if let primary = bucket["primary"] as? JSONObject, let value = primary["resetsAt"] as? NSNumber, !(value is Bool) {
                resets.append(value.doubleValue)
            }
        }
        guard let earliest = resets.min() else { return nil }
        return Date(timeIntervalSince1970: earliest)
    }

    nonisolated static func rateLimitReached(_ limits: JSONObject) -> Bool {
        rateLimitBuckets(limits).contains { bucket in
            if let value = bucket["rateLimitReachedType"], !(value is NSNull) {
                if let text = value as? String { return !text.isEmpty }
                return true
            }
            return false
        }
    }
}
