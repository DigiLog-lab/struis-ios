import Foundation

/// DEBUG + simulator の既定フィクスチャの共通ゲート。
/// `STRUIS_IOS_USE_FIXTURES=0` で無効。`STRUIS_API_BASE_URL` でバックエンドを指した起動では
/// 明示的に `STRUIS_IOS_USE_FIXTURES=1` を渡さない限り実経路を使う (固定データで実経路を偽らない)。
enum SimulatorFixtures {
    static var isEnabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        if environment["STRUIS_IOS_USE_FIXTURES"] == "0" {
            return false
        }
        if (environment["STRUIS_API_BASE_URL"] != nil || hasDebugAPIArgument), environment["STRUIS_IOS_USE_FIXTURES"] != "1" {
            return false
        }
        return true
        #else
        return false
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    private static var hasDebugAPIArgument: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-struis-api-base-url")
    }
    #else
    private static var hasDebugAPIArgument: Bool { false }
    #endif
}
