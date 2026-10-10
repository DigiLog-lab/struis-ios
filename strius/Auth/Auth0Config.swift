import Foundation

enum Auth0Config {
    /// Build-time policy. Unknown/missing values keep authentication enabled.
    static let authenticationRequired = authenticationRequired(
        for: Bundle.main.object(forInfoDictionaryKey: "StruisAuthRequired") as? String
    )

    nonisolated static func authenticationRequired(for value: String?) -> Bool {
        !["NO", "FALSE", "0"].contains(value?.uppercased() ?? "")
    }

    static var domain: String {
        value(for: "Auth0Domain", fallback: "auth-struis.digiloglab.com")
    }

    static var clientID: String {
        value(for: "Auth0ClientId", fallback: "B7gxMiozrYtBmsnrV1gfPj4d1bAMCf5x")
    }

    static var audience: String {
        value(for: "Auth0Audience", fallback: "https://api-struis.digiloglab.com")
    }

    private static func value(for key: String, fallback: String) -> String {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           !value.isEmpty,
           !value.hasPrefix("$(") {
            return value
        }

        return fallback
    }
}
