import Foundation

enum ServerConfig {
    static let deliveryAppKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "StruisDeliveryAppKey") as? String,
              !key.hasPrefix("$(") else { return "" }
        return key
    }()

    private static let productionURL = URL(string: "https://api-struis.digiloglab.com")!

    /// Base URL for the Struis backend.
    /// Set `STRUIS_API_BASE_URL` in the Xcode scheme's environment variables
    /// (e.g. `http://127.0.0.1:4040` when running the local docker compose
    /// stack) to override the production URL at launch.
    static let baseURL: URL = {
        if let raw = ProcessInfo.processInfo.environment["STRUIS_API_BASE_URL"] ?? debugLaunchArgument("-struis-api-base-url"),
           let url = URL(string: raw) {
            return url
        }
        return productionURL
    }()

    #if DEBUG && targetEnvironment(simulator)
    /// XcodeBuildMCPの起動経路向けのSimulator専用検証引数。リリース・実機には含めない。
    private static func debugLaunchArgument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.index(after: index) < arguments.endIndex else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }
    #else
    private static func debugLaunchArgument(_ name: String) -> String? { nil }
    #endif

    static var realtimeURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/realtime"
        return components.url!
    }

    /// Stable seeded problem bundle for local E2E smoke testing.
    /// Matches `BUNDLE_ID` in `backend/scripts/seed_problems.py`.
    static let debugSeededBundleID = UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!
}
