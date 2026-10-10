import Auth0
import Foundation
import OSLog

private let authLog = Logger(subsystem: "com.digiloglab.strius", category: "auth")

@Observable
@MainActor
final class AuthStore {
    enum Status: Equatable {
        case restoring
        case signedOut
        case signingIn
        case signedIn
        case restoreFailed(String)
        case failed(String)
    }

    private(set) var status: Status = .restoring {
        didSet { if status == .signedIn, oldValue != .signedIn { sessionGeneration += 1 } }
    }

    /// サインインのたびと、サインアウト・セッション終了を始めた時(`status` が変わる前)に増える。
    /// 待っている間に学習者が変わったかを確かめるのに使う(旧学習者のデータを後から書き込まない)。
    private(set) var sessionGeneration = 0

    /// セッションが切れた理由。TestFlight のように Xcode ログを見られない環境でも
    /// 「なぜまたログインを求められたのか」を画面上で切り分けられるようにする。
    private(set) var sessionDiagnostic: String?

    var onSessionEnded: (@MainActor () -> Void)?

    /// サインアウト・セッション終了を始めた時(主スレッドで同期に出す)。アプリの `ChatStore` だけでなく、
    /// 小単元ごとに作る `ChatStore` もこれで片づけ、送信の途中の処理が前の学習者の会話へ書かないようにする。
    nonisolated static let sessionEndedNotification = Notification.Name("StruisAuthSessionEnded")

    private let credentialsManager: CredentialsManager?
    private var tokenProviderBox: (any TokenProviding)?
    private weak var signOutDataCleaner: (any LearningFeedSignOutClearing)?

    init(client: APIClient) {
        guard Auth0Config.authenticationRequired else {
            credentialsManager = nil
            status = .signedOut
            return
        }
        if Self.usesSimulatorAuthBypass {
            let simulatorProvider = SimulatorProvider()
            self.credentialsManager = CredentialsManager(
                authentication: Auth0.authentication(
                    clientId: Auth0Config.clientID,
                    domain: Auth0Config.domain
                ),
                maxRetries: 2
            )
            self.tokenProviderBox = simulatorProvider
            client.setTokenProvider(simulatorProvider)
            status = .signedIn
            return
        }

        let authentication = Auth0.authentication(
            clientId: Auth0Config.clientID,
            domain: Auth0Config.domain
        )
        self.credentialsManager = CredentialsManager(
            authentication: authentication,
            maxRetries: 2
        )

        let provider = Provider()
        self.tokenProviderBox = provider
        provider.store = self
        client.setTokenProvider(provider)

        Task { await restoreStoredSession() }
    }

    var canUseApp: Bool { !Auth0Config.authenticationRequired || isSignedIn }

    var isSignedIn: Bool {
        if case .signedIn = status { return true }
        return false
    }

    var isRestoring: Bool {
        if case .restoring = status { return true }
        return false
    }

    func setSignOutDataCleaner(_ cleaner: any LearningFeedSignOutClearing) {
        signOutDataCleaner = cleaner
    }

    func login(screenHint: String? = nil) async {
        guard let credentialsManager else { return }
        status = .signingIn
        do {
            var webAuth = Auth0
                .webAuth(clientId: Auth0Config.clientID, domain: Auth0Config.domain)
                .audience(Auth0Config.audience)
                .scope("openid profile email offline_access")
            if let screenHint {
                webAuth = webAuth.parameters(["screen_hint": screenHint])
            }
            let credentials = try await webAuth.start()
            if credentials.refreshToken == nil {
                // refresh token が無いと access token の寿命（既定 24 時間）でセッションが終わる。
                // Auth0 側で API の Allow Offline Access か Application の refresh_token grant が
                // 無効なときにここへ来る。アプリ側では回復できないので必ず記録する。
                authLog.error("Auth0 issued no refresh token; the session will end when the access token expires")
                sessionDiagnostic = "更新トークンが発行されていません（Auth0 の Allow Offline Access を確認してください）"
            } else {
                sessionDiagnostic = nil
            }
            guard credentialsManager.store(credentials: credentials) else {
                status = .failed("認証情報の保存に失敗しました")
                return
            }
            status = .signedIn
        } catch {
            authLog.error("Auth0 login failed: \(String(describing: error), privacy: .public)")
            status = .failed("ログインに失敗しました: \(Self.message(for: error))")
        }
    }

    func logout() {
        guard let credentialsManager else { return }
        sessionGeneration += 1
        NotificationCenter.default.post(name: Self.sessionEndedNotification, object: self)
        onSessionEnded?()
        OnboardingProfile.clear()
        Task {
            await signOutDataCleaner?.clearLearningFeedDataForSignOut()
            try? await Auth0
                .webAuth(clientId: Auth0Config.clientID, domain: Auth0Config.domain)
                .clearSession()
            _ = credentialsManager.clear()
            onSessionEnded?()
            sessionDiagnostic = nil
            status = .signedOut
        }
    }

    func retrySessionRestore() async {
        guard credentialsManager != nil else { return }
        status = .restoring
        await restoreStoredSession()
    }

    /// 起動時のセッション復元。
    ///
    /// 判定の順序が体験を決める。access token がまだ生きているうちは通信せずに復帰し、
    /// 通信が必要な場合も「一時的な失敗」と「本当にセッションが終わった」を区別する。
    /// 一時的な失敗で `signedOut` にしてしまうと、ログイン画面に落ちて再ログインを強いる。
    private func restoreStoredSession() async {
        guard let credentialsManager else { return }
        if credentialsManager.hasValid(minTTL: Self.minimumAccessTokenTTL) {
            // 保存済みの access token がまだ有効。オフラインでも起動できる。
            status = .signedIn
            return
        }

        do {
            _ = try await credentialsManager.credentials(minTTL: Self.minimumAccessTokenTTL)
            sessionDiagnostic = nil
            status = .signedIn
        } catch CredentialsManagerError.noCredentials {
            // 一度もログインしていない、またはログアウト済み。想定どおりのサインイン画面。
            sessionDiagnostic = nil
            status = .signedOut
        } catch CredentialsManagerError.noRefreshToken {
            authLog.error("stored credentials have no refresh token; session cannot outlive the access token")
            await endSession(diagnostic: "更新トークンが保存されていないため、ログイン状態を保持できませんでした")
        } catch let error where Self.isRefreshTokenRejected(error) {
            authLog.error("Auth0 rejected the stored refresh token: \(String(describing: error), privacy: .public)")
            await endSession(diagnostic: "セッションの有効期限が切れました")
        } catch {
            // 通信断・5xx など。保存済みのセッションは捨てずに再試行できる状態にする。
            authLog.error("Auth0 session restore failed: \(String(describing: error), privacy: .public)")
            status = .restoreFailed("ログイン状態を確認できませんでした")
        }
    }

    fileprivate func currentToken() async -> String? {
        guard let credentialsManager else { return nil }
        do {
            return try await credentialsManager.credentials(minTTL: Self.minimumAccessTokenTTL).accessToken
        } catch {
            return nil
        }
    }

    fileprivate func refresh() async -> Bool {
        guard let credentialsManager else { return false }
        do {
            _ = try await credentialsManager.credentials(minTTL: Self.minimumAccessTokenTTL)
            return true
        } catch CredentialsManagerError.noCredentials {
            await endSession(diagnostic: nil)
            return false
        } catch CredentialsManagerError.noRefreshToken {
            authLog.error("token refresh impossible: stored credentials have no refresh token")
            await endSession(diagnostic: "更新トークンが保存されていないため、ログイン状態を保持できませんでした")
            return false
        } catch let error where Self.isRefreshTokenRejected(error) {
            authLog.error("Auth0 rejected the stored refresh token: \(String(describing: error), privacy: .public)")
            await endSession(diagnostic: "セッションの有効期限が切れました")
            return false
        } catch {
            // 一時的な失敗ではサインアウトさせない。次のリクエストで再試行される。
            authLog.error("Auth0 token refresh failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// 復帰不能と確定したときだけサインイン画面へ戻す。
    ///
    /// `logout()` と同じ後始末（保存済み認証情報のクリアと学習フィードのユーザーデータ破棄）を行う。
    /// これを省くと `LearningFeedRuntimeServices` が旧ユーザーの `currentUserID` やキューを
    /// 保持し続け、次のアカウントでログインした後もそのキューを新しい資格情報で処理してしまう。
    private func endSession(diagnostic: String?) async {
        sessionGeneration += 1
        NotificationCenter.default.post(name: Self.sessionEndedNotification, object: self)
        onSessionEnded?()
        // 自動でセッションが終わった時(refresh token の失効など)も、ログアウトと同じく消す。
        OnboardingProfile.clear()
        _ = credentialsManager?.clear()
        await signOutDataCleaner?.clearLearningFeedDataForSignOut()
        sessionDiagnostic = diagnostic
        status = .signedOut
    }

    /// refresh token が Auth0 側で失効・剥奪された場合のみ true。
    /// 通信エラーはここに含めない（含めると圏外で再ログインを強いることになる）。
    private static func isRefreshTokenRejected(_ error: Error) -> Bool {
        guard let managerError = error as? CredentialsManagerError,
              CredentialsManagerError.renewFailed ~= managerError,
              let cause = managerError.cause as? AuthenticationError
        else { return false }
        return cause.isRefreshTokenDeleted
    }

    /// 期限ぎりぎりのトークンで復帰して直後に 401 になるのを避けるための余白（秒）。
    private static let minimumAccessTokenTTL = 60

    private final class Provider: TokenProviding, @unchecked Sendable {
        weak var store: AuthStore?

        func currentAccessToken() async -> String? {
            await store?.currentToken()
        }

        func refreshIfPossible() async -> Bool {
            guard let store else { return false }
            return await store.refresh()
        }
    }

    private actor SimulatorProvider: TokenProviding {
        private var cachedAccessToken: String?

        func currentAccessToken() async -> String? {
            if let configuredToken = ProcessInfo.processInfo.environment["STRUIS_DEV_ACCESS_TOKEN"],
               !configuredToken.isEmpty {
                return configuredToken
            }
            #if DEBUG && targetEnvironment(simulator)
            if let configuredToken = Self.debugLaunchArgument("-struis-dev-access-token"),
               !configuredToken.isEmpty {
                return configuredToken
            }
            #endif
            if let cachedAccessToken {
                return cachedAccessToken
            }
            guard Self.isLocalAPI else {
                return "simulator-preview-token"
            }
            return await exchangeLocalIdentityToken()
        }

        func refreshIfPossible() async -> Bool {
            if let configuredToken = ProcessInfo.processInfo.environment["STRUIS_DEV_ACCESS_TOKEN"],
               !configuredToken.isEmpty {
                return true
            }
            #if DEBUG && targetEnvironment(simulator)
            if let configuredToken = Self.debugLaunchArgument("-struis-dev-access-token"),
               !configuredToken.isEmpty {
                return true
            }
            #endif
            guard Self.isLocalAPI else { return true }
            cachedAccessToken = nil
            return await exchangeLocalIdentityToken() != nil
        }

        #if DEBUG && targetEnvironment(simulator)
        private static func debugLaunchArgument(_ name: String) -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: name), arguments.index(after: index) < arguments.endIndex else {
                return nil
            }
            return arguments[arguments.index(after: index)]
        }
        #endif

        private func exchangeLocalIdentityToken() async -> String? {
            let identityToken = ProcessInfo.processInfo.environment["STRUIS_DEV_IDENTITY_TOKEN"]
                ?? "struis-local-dev-identity-token"
            let endpoint = ServerConfig.baseURL.appendingPathComponent("/v1/auth/apple/exchange")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            do {
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                request.httpBody = try encoder.encode(
                    SimulatorExchangeRequest(
                        identityToken: identityToken,
                        displayName: "Struis Dev",
                        deviceName: "iOS Simulator"
                    )
                )
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    authLog.error("local simulator auth exchange failed")
                    return nil
                }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let result = try decoder.decode(SimulatorExchangeResponse.self, from: data)
                cachedAccessToken = result.accessToken
                return result.accessToken
            } catch {
                authLog.error("local simulator auth exchange failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }

        private static var isLocalAPI: Bool {
            guard let host = ServerConfig.baseURL.host?.lowercased() else { return false }
            return host == "127.0.0.1" || host == "localhost"
        }
    }

    private struct SimulatorExchangeRequest: Encodable {
        let identityToken: String
        let displayName: String
        let deviceName: String
    }

    private struct SimulatorExchangeResponse: Decodable {
        let accessToken: String
    }

    private static func message(for error: Error) -> String {
        let message = error.localizedDescription
        if message.isEmpty { return String(describing: error) }
        return message
    }

    private static var usesSimulatorAuthBypass: Bool {
        #if DEBUG && targetEnvironment(simulator)
        SimulatorFixtures.isEnabled || ProcessInfo.processInfo.environment["STRUIS_DEV_AUTH_BYPASS"] == "1"
        #else
        false
        #endif
    }
}
