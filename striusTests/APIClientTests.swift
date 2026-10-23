import Foundation
import Testing
@testable import strius

@Suite(.serialized)
@MainActor
struct APIClientTests {
    @Test func usageReportingIsOffWhenNothingIsSaved() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: UsageReporter.defaultsKey)
        defer {
            if let saved { defaults.set(saved, forKey: UsageReporter.defaultsKey) } else { defaults.removeObject(forKey: UsageReporter.defaultsKey) }
        }
        defaults.removeObject(forKey: UsageReporter.defaultsKey)
        #expect(defaults.object(forKey: UsageReporter.defaultsKey) == nil)
        #expect(UsageReporter.isEnabled == false)
        #expect(SettingsStore(runtime: nil).usageReportingEnabled == false)
    }

    @Test func usageOptInSendsOnlyStatisticsFromCompletedLedgerTurn() async throws {
        StubURLProtocol.reset()
        let path = "/v1/device-runtime/usage"
        StubURLProtocol.register(path: path, sequence: [.status(200, body: Data("{\"accepted\":1}".utf8))])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let provider = StubTokenProvider()
        client.setTokenProvider(provider)
        let ledger = try Ledger.inMemory()
        let reporter = UsageReporter(ledger: ledger, client: client)
        let wasEnabled = UsageReporter.isEnabled
        defer { UsageReporter.isEnabled = wasEnabled }
        UsageReporter.isEnabled = false
        await reporter.start()
        let execution: LedgerJSON = .object([
            "execution_id": .string("SECRET-ID"), "requested_model": .string("gpt-6-astra"),
            "status": .string("completed"), "task_type": .string("chat"), "elapsed_ms": .number(250),
            "lookup_commands": .array([.object(["command": .string("SECRET-COMMAND"), "cwd": .string("SECRET-PATH")])]),
            "error": .string("SECRET-ERROR"), "future_field": .string("SECRET-FUTURE"),
            "usage": .object(["last": .object(["inputTokens": .number(10), "outputTokens": .number(3),
                                               "unknown": .string("SECRET-NESTED")])]),
        ])
        var turn = TurnRecord(id: "usage-off", kind: "chat", status: "completed", round: 1,
            plan: .emptyObject, executions: .array([execution]), createdAt: LedgerClock.now())
        try await ledger.append([.upsert("turn.completed", turn)])
        try await Task.sleep(for: .milliseconds(100))
        #expect(StubURLProtocol.recordedPaths().isEmpty)
        UsageReporter.isEnabled = true
        turn.id = "usage-on"
        try await ledger.append([.upsert("turn.completed", turn)])
        if !Auth0Config.authenticationRequired {
            try await Task.sleep(for: .milliseconds(100))
            #expect(StubURLProtocol.recordedPaths().isEmpty, "認証なしでユーザー使用量を送らない")
            return
        }
        for _ in 0..<100 {
            if !StubURLProtocol.recordedBodies().isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(StubURLProtocol.recordedPaths() == [path])
        let body = try #require(StubURLProtocol.recordedBodies().first)
        #expect(!String(decoding: body, as: UTF8.self).contains("SECRET"))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try #require((payload["executions"] as? [[String: Any]])?.first)
        #expect(sent["requested_model"] as? String == "gpt-6-astra")
        #expect(sent["elapsed_ms"] as? Int == 250)
        let usage = try #require(sent["usage"] as? [String: Any])
        let last = try #require(usage["last"] as? [String: Any])
        #expect(last["inputTokens"] as? Int == 10)
        #expect(last["outputTokens"] as? Int == 3)
    }

    @Test func chunkRetryPreservesOriginalBytesAndPostsOnlyOnce() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.register(path: "*", sequence: [
            .failure(URLError(.networkConnectionLost)),
            .status(200, body: Data("{}".utf8)), .status(200, body: Data("{}".utf8)),
            .status(200, body: Data("{}".utf8)), .status(202, body: Data("{}".utf8))
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let provider = StubTokenProvider()
        client.setTokenProvider(provider)
        let original = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0) })
        let _: EmptyResponse = try await client.sendMultipart(.postMessage(threadID: "upload-test"),
            fields: ["text": "分割確認", "attachment_source": "camera"],
            files: [MultipartFile(fieldName: "files", filename: "photo.jpg", contentType: "image/jpeg", data: original)])
        let requests = StubURLProtocol.recordedRequests()
        let bodies = StubURLProtocol.recordedBodies()
        #expect(requests.count == 5)
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(requests[0].url == requests[1].url)
        let firstChunk = try #require(JSONSerialization.jsonObject(with: bodies[0]) as? NSDictionary)
        let retriedChunk = try #require(JSONSerialization.jsonObject(with: bodies[1]) as? NSDictionary)
        #expect(firstChunk == retriedChunk)
        var restored = Data()
        for body in bodies.dropFirst().dropLast() {
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let chunk = try #require(Data(base64Encoded: object["data"] as! String))
            #expect(chunk.count <= 256 * 1024)
            restored.append(chunk)
        }
        #expect(restored == original)
        let final = try #require(JSONSerialization.jsonObject(with: bodies.last!) as? [String: Any])
        #expect(final["text"] as? String == "分割確認")
        #expect((final["uploaded_files"] as? [String])?.count == 1)
    }

    @Test func chunkRetryIsBoundedAndDoesNotSubmitIncompleteMessage() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.register(path: "*", sequence: Array(repeating: .failure(URLError(.timedOut)), count: 4))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let provider = StubTokenProvider()
        client.setTokenProvider(provider)
        do {
            let _: EmptyResponse = try await client.sendMultipart(.postMessage(threadID: "upload-test"), fields: [:],
                files: [MultipartFile(fieldName: "files", filename: "photo.jpg", contentType: "image/jpeg",
                                      data: Data(repeating: 1, count: 300_000))])
            Issue.record("未完了の画像を成功として扱った")
        } catch APIError.transport(let error) { #expect(error.code == .timedOut) }
        #expect(StubURLProtocol.recordedRequests().count == 3)
        #expect(StubURLProtocol.recordedRequests().allSatisfy { $0.httpMethod == "PUT" })
    }

    @Test func multipartUploadSurvivesInvalidatedReadSession() async throws {
        StubURLProtocol.reset()
        let path = "/v1/threads/upload-test/messages"
        StubURLProtocol.register(path: path, sequence: [.status(202, body: Data("{}".utf8))])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let readSession = URLSession(configuration: configuration)
        let client = APIClient(session: readSession)
        let provider = StubTokenProvider()
        client.setTokenProvider(provider)
        readSession.invalidateAndCancel()

        let _: EmptyResponse = try await client.sendMultipart(
            .postMessage(threadID: "upload-test"), fields: ["text": "確認"],
            files: [MultipartFile(fieldName: "files", filename: "photo.jpg", contentType: "image/jpeg", data: Data([0xff, 0xd8, 0xff, 0xd9]))]
        )
        #expect(StubURLProtocol.recordedPaths() == [path])
        #expect(StubURLProtocol.recordedRequests().first?.value(forHTTPHeaderField: "Authorization") == "Bearer initial-access-token")
        let body = try #require(StubURLProtocol.recordedBodies().first)
        #expect(body.range(of: Data("確認".utf8)) != nil)
        #expect(body.range(of: Data([0xff, 0xd8, 0xff, 0xd9])) != nil)
    }

    @Test func multipartRefreshKeepsImageAndText() async throws {
        StubURLProtocol.reset()
        let path = "/v1/threads/upload-test/messages"
        StubURLProtocol.register(path: path, sequence: [
            .status(401, body: Data()), .status(202, body: Data("{}".utf8))
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let provider = StubTokenProvider()
        client.setTokenProvider(provider)
        let image = Data([0xff, 0xd8, 0x12, 0x34, 0xff, 0xd9])
        let _: EmptyResponse = try await client.sendMultipart(
            .postMessage(threadID: "upload-test"), fields: ["text": "添付確認"],
            files: [MultipartFile(fieldName: "files", filename: "photo.jpg", contentType: "image/jpeg", data: image)]
        )
        #expect(provider.refreshCallCount == 1)
        #expect(StubURLProtocol.recordedPaths() == [path, path])
        #expect(StubURLProtocol.recordedRequests().last?.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-access-token")
        #expect(StubURLProtocol.recordedBodies().count == 2)
        for body in StubURLProtocol.recordedBodies() {
            #expect(body.range(of: image) != nil)
            #expect(body.range(of: Data("添付確認".utf8)) != nil)
        }
    }

    @Test func multipartTransportFailureIsNotRetried() async throws {
        StubURLProtocol.reset()
        let path = "/v1/threads/upload-test/messages"
        StubURLProtocol.register(path: path, sequence: [
            .failure(URLError(.networkConnectionLost)), .status(202, body: Data("{}".utf8))
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let provider = StubTokenProvider()
        client.setTokenProvider(provider)
        do {
            let _: EmptyResponse = try await client.sendMultipart(
                .postMessage(threadID: "upload-test"), fields: [:],
                files: [MultipartFile(fieldName: "files", filename: "photo.jpg", contentType: "image/jpeg", data: Data([1, 2, 3]))]
            )
            Issue.record("通信失敗を成功として扱った")
        } catch APIError.transport(let error) {
            #expect(error.code == .networkConnectionLost)
        }
        #expect(StubURLProtocol.recordedPaths() == [path], "受付状態が不明なPOSTを再送しない")
        #expect(provider.refreshCallCount == 0)
    }

    @Test func refreshFlowOn401() async throws {
        StubURLProtocol.reset()

        // Any bootstrap call first returns 401, then 200 after the retry.
        StubURLProtocol.register(path: "/v1/bootstrap", sequence: [
            .status(401, body: Data()),
            .status(200, body: Self.bootstrapBody)
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let client = APIClient(session: session)
        let provider = StubTokenProvider()
        client.setTokenProvider(provider)

        let response: BootstrapResponse = try await client.send(.bootstrap)
        #expect(response.threads.isEmpty)
        #expect(provider.refreshCallCount == 1, "refresh() should have been invoked exactly once")

        // The APIClient itself doesn't issue the refresh HTTP call (AuthStore does),
        // so at the protocol level we only see two bootstrap requests — the initial
        // 401 and the successful retry after refresh returned true.
        let recorded = StubURLProtocol.recordedPaths()
        #expect(recorded == [
            "/v1/bootstrap",
            "/v1/bootstrap"
        ], "retry sequence should be initial → retry, got \(recorded)")
    }

    @Test func restoresAccessTokenBeforeAuthenticatedRequest() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.register(path: "/v1/bootstrap", sequence: [
            .status(200, body: Self.bootstrapBody)
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let client = APIClient(session: session)
        let provider = StubTokenProvider()
        provider.currentToken = nil
        client.setTokenProvider(provider)

        let response: BootstrapResponse = try await client.send(.bootstrap)
        #expect(response.user.id.uuidString == "11111111-2222-3333-4444-555555555555")
        #expect(provider.refreshCallCount == 1, "missing access token should trigger refresh() once")
        #expect(StubURLProtocol.recordedPaths() == ["/v1/bootstrap"])
    }

    @Test func optionalResponseReturnsNilFor204() async throws {
        StubURLProtocol.reset()
        let path = "/v1/threads/22222222-0000-0000-0000-000000000000/attempts/latest"
        StubURLProtocol.register(path: path, sequence: [
            .status(204, body: Data())
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let provider = StubTokenProvider()
        client.setTokenProvider(provider)

        let response: AttemptViewV1? = try await client.sendOptional(
            .latestAttempt(threadID: "22222222-0000-0000-0000-000000000000")
        )
        #expect(response == nil)
        #expect(StubURLProtocol.recordedPaths() == [path])
    }

    @Test func optionalResponseDecodesLatestAttempt() async throws {
        StubURLProtocol.reset()
        let path = "/v1/threads/22222222-0000-0000-0000-000000000000/attempts/latest"
        StubURLProtocol.register(path: path, sequence: [
            .status(200, body: Self.attemptBody)
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let provider = StubTokenProvider()
        client.setTokenProvider(provider)

        let response: AttemptViewV1? = try await client.sendOptional(
            .latestAttempt(threadID: "22222222-0000-0000-0000-000000000000")
        )
        #expect(response?.attemptID.uuidString == "44444444-0000-0000-0000-000000000001")
        #expect(response?.content?.text == "x = 2")
    }

    @Test func authenticatedAssetPageRequestIncludesQuery() async throws {
        StubURLProtocol.reset()
        let path = "/v1/assets/attempts/user/notes.pdf"
        StubURLProtocol.register(path: path, sequence: [
            .status(200, body: Data([0x89, 0x50, 0x4e, 0x47]))
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let provider = StubTokenProvider()
        client.setTokenProvider(provider)

        let response = try await client.fetchData(
            .asset(relativePath: "attempts/user/notes.pdf", page: 3)
        )
        let request = try #require(StubURLProtocol.recordedRequests().first)
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))

        #expect(response.data == Data([0x89, 0x50, 0x4e, 0x47]))
        #expect(components.queryItems == [URLQueryItem(name: "page", value: "3")])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer initial-access-token")
    }

    @Test func workspaceListingUsesAuthenticatedPathQueryAndDecodesEntries() async throws {
        StubURLProtocol.reset()
        let path = "/v1/workspace"
        let body = """
        {
          "available": true,
          "path": "tutor_desk",
          "entries": [{
            "name": "learner.yaml",
            "path": "tutor_desk/learner.yaml",
            "kind": "file",
            "category": "struis_managed",
            "size_bytes": 12,
            "modified_at": "2026-09-04T01:00:00Z",
            "content_type": "text/plain; charset=utf-8",
            "preview_kind": "text",
            "downloadable": true
          }],
          "truncated": false
        }
        """.data(using: .utf8)!
        StubURLProtocol.register(path: path, sequence: [.status(200, body: body)])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let provider = StubTokenProvider()
        client.setTokenProvider(provider)

        let response: WorkspaceListingDTO = try await client.send(.workspaceListing(path: "tutor_desk"))
        let request = try #require(StubURLProtocol.recordedRequests().first)
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))

        #expect(response.entries.first?.category == .struisManaged)
        #expect(response.entries.first?.previewKind == .text)
        #expect(components.queryItems == [URLQueryItem(name: "path", value: "tutor_desk")])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer initial-access-token")
    }

    @Test func deliveryUsesAppKeyWithoutAUserAndNeverSendsItToPrivateAPIs() async throws {
        StubURLProtocol.reset()
        let manifestPath = "/v1/device-runtime/manifest"
        let assetPath = "/v1/device-runtime/assets/prompt:base"
        let body = Data("{\"codex_version\":\"0.153.4\",\"rootfs_min_version\":1,\"models\":{},\"assets\":{}}".utf8)
        StubURLProtocol.register(path: manifestPath, sequence: [.status(200, body: body)])
        StubURLProtocol.register(path: assetPath, sequence: [.status(200, body: Data("配信本文".utf8))])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let provider = StubTokenProvider()
        if Auth0Config.authenticationRequired { client.setTokenProvider(provider) }
        let source = ServerAssetSource(client: client)
        _ = try await source.fetchManifest()
        #expect(try await source.fetchAsset("prompt:base") == Data("配信本文".utf8))
        for request in StubURLProtocol.recordedRequests() {
            if Auth0Config.authenticationRequired {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer initial-access-token")
                #expect(request.value(forHTTPHeaderField: "X-Struis-App-Key") == nil)
            } else {
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(request.value(forHTTPHeaderField: "X-Struis-App-Key") == ServerConfig.deliveryAppKey)
            }
        }
        client.setTokenProvider(provider)
        StubURLProtocol.register(path: "/v1/bootstrap", sequence: [.status(200, body: Self.bootstrapBody)])
        let _: BootstrapResponse = try await client.send(.bootstrap)
        #expect(StubURLProtocol.recordedRequests().last?.value(forHTTPHeaderField: "X-Struis-App-Key") == nil)
    }

    @Test func authPolicyKeepsUnknownValuesAuthenticated() {
        for value in [nil, "", "YES", "TRUE", "1", "unexpected", "$(STRUIS_AUTH_REQUIRED)"] {
            #expect(Auth0Config.authenticationRequired(for: value))
        }
        for value in ["NO", "FALSE", "0", "no"] {
            #expect(!Auth0Config.authenticationRequired(for: value))
        }
    }

    @Test func noAuthStartupDoesNotCreateASignedInUserOrFetchBootstrap() async throws {
        guard !Auth0Config.authenticationRequired else { return }
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let auth = AuthStore(client: client)
        let store = BootstrapStore(client: client, ledger: try Ledger.inMemory(), useFixtures: false)
        await store.refresh()
        #expect(auth.canUseApp)
        #expect(!auth.isSignedIn)
        #expect(!auth.isRestoring)
        #expect(store.user == nil)
        #expect(store.loadState == .loaded)
        #expect(StubURLProtocol.recordedPaths().isEmpty)
    }

    private static let bootstrapBody: Data = {
        let json = """
        {
          "user": {"id": "11111111-2222-3333-4444-555555555555", "display_name": null, "email": null},
          "trial": {"started_at": null, "ends_at": null},
          "streak": {"count": 0, "last_solved_on": null},
          "threads": [],
          "unread_proposals": 0,
          "latest_re_evaluation": null
        }
        """
        return json.data(using: .utf8)!
    }()

    private static let attemptBody: Data = {
        let json = """
        {
          "schema_version": 1,
          "attempt_id": "44444444-0000-0000-0000-000000000001",
          "status": "completed",
          "result": "correct",
          "input_mode": "text",
          "content": {"kind": "text", "text": "x = 2", "assets": [], "steps": []},
          "annotations": [],
          "created_at": "2026-07-14T01:00:00Z",
          "completed_at": "2026-07-14T01:00:02Z"
        }
        """
        return json.data(using: .utf8)!
    }()

}

// MARK: - Stubs

@MainActor
final class StubTokenProvider: TokenProviding {
    var currentToken: String? = "initial-access-token"
    var refreshCallCount = 0

    func currentAccessToken() async -> String? { currentToken }

    func refreshIfPossible() async -> Bool {
        refreshCallCount += 1
        currentToken = "refreshed-access-token"
        return true
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stubbed {
        let status: Int
        let body: Data
        var error: URLError? = nil
        static func status(_ code: Int, body: Data) -> Stubbed { Stubbed(status: code, body: body) }
        static func failure(_ error: URLError) -> Stubbed { Stubbed(status: 0, body: Data(), error: error) }
    }

    private nonisolated(unsafe) static var _stubs: [String: [Stubbed]] = [:]
    private nonisolated(unsafe) static var _recorded: [String] = []
    private nonisolated(unsafe) static var _requests: [URLRequest] = []
    private nonisolated(unsafe) static var _bodies: [Data] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _stubs.removeAll()
        _recorded.removeAll()
        _requests.removeAll()
        _bodies.removeAll()
    }

    static func register(path: String, sequence: [Stubbed]) {
        lock.lock(); defer { lock.unlock() }
        _stubs[path] = sequence
    }

    static func recordedPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return _recorded
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static func recordedBodies() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return _bodies
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock()
        Self._recorded.append(path)
        Self._requests.append(request)
        Self._bodies.append(body)
        let next: Stubbed?
        let key = Self._stubs[path] == nil ? "*" : path
        if var queue = Self._stubs[key], !queue.isEmpty {
            next = queue.removeFirst()
            Self._stubs[key] = queue
        } else {
            next = nil
        }
        Self.lock.unlock()

        guard let next else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let error = next.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
