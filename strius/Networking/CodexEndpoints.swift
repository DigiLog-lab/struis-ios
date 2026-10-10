import Foundation

extension APIEndpoint {
    static let codexAccount = APIEndpoint(method: .get, path: "/v1/codex/account")
    static let codexAccountLogin = APIEndpoint(method: .post, path: "/v1/codex/account/login/device-code")
    static let codexAccountSync = APIEndpoint(method: .post, path: "/v1/codex/account/sync")
    static let codexAccountLogout = APIEndpoint(method: .post, path: "/v1/codex/account/logout")
    static let codexPromptVersions = APIEndpoint(method: .get, path: "/v1/codex/prompt-versions")
}
