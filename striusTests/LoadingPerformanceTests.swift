import Foundation
import Testing
import UIKit
@testable import strius

@Suite(.serialized) @MainActor
struct LoadingPerformanceTests {
    private func client() -> (APIClient, StubTokenProvider) {
        LoadingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LoadingProtocol.self]
        let api = APIClient(session: URLSession(configuration: config))
        let provider = StubTokenProvider()
        api.setTokenProvider(provider)
        return (api, provider)
    }

    @Test func duplicateAssetsAreCoalescedAndClearedForNextSession() async throws {
        let (api, provider) = client()
        let endpoint = APIEndpoint.asset(relativePath: "test/a.png")
        LoadingProtocol.enqueue(endpoint.path, body: Data([1, 2]), delay: 0.1)
        async let a = api.fetchData(endpoint)
        async let b = api.fetchData(endpoint)
        let values = try await (a, b)
        #expect(values.0.data == values.1.data)
        _ = try await api.fetchData(endpoint)
        #expect(LoadingProtocol.count(endpoint.path) == 1)
        api.clearResourceCache()
        provider.currentToken = "next-session"
        LoadingProtocol.enqueue(endpoint.path, body: Data([3]))
        #expect(try await api.fetchData(endpoint).data == Data([3]))
        #expect(LoadingProtocol.count(endpoint.path) == 2)
        print("ASSET_CACHE: concurrent+repeat=1 request; session reset=2 requests, new bytes")
    }

    @Test func assetFinishingAfterSessionResetCannotRepopulateCache() async throws {
        let (api, provider) = client()
        let endpoint = APIEndpoint.asset(relativePath: "test/late.png")
        LoadingProtocol.enqueue(endpoint.path, body: Data([1]), delay: 0.2)
        let loading = Task { try await api.fetchData(endpoint) }
        try await Task.sleep(for: .milliseconds(40))
        api.clearResourceCache()
        do { _ = try await loading.value; Issue.record("終了したセッションの結果が返りました") } catch {}
        provider.currentToken = "new-session"
        LoadingProtocol.enqueue(endpoint.path, body: Data([2]))
        #expect(try await api.fetchData(endpoint).data == Data([2]))
        print("ASSET_RESET: in-flight result rejected; next session fetched new bytes")
    }

    /// The 質問 screen reads the device ledger (design §4): switching threads shows each
    /// thread's rows, a new ledger event reaches the open thread, and logout clears it.
    @Test func conversationFollowsLedgerAndClearsOnReset() async throws {
        let ledger = try Ledger.inMemory()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: MockTurnRunner())
        let store = ChatStore(ledger: ledger, turns: turns)
        let first = try await seedThread(ledger, n: 1, text: "最初の内容")
        let second = try await seedThread(ledger, n: 2, text: "別の内容")
        await store.adoptThread(first)
        #expect(store.loadState == .loaded)
        #expect(store.messages.first?.plainText == "最初の内容")
        await store.adoptThread(second)
        #expect(store.threadID == second.id && store.messages.first?.plainText == "別の内容")
        try await appendMessage(ledger, threadID: first.id, text: "最新の内容")
        await store.adoptThread(first)
        #expect(store.messages.last?.plainText == "最新の内容")
        store.reset()
        #expect(store.threadID == nil && store.messages.isEmpty && store.loadState == .idle)
        await store.adoptThread(first)
        #expect(store.messages.count == 2)
        print("CHAT_LEDGER: thread switch reads ledger rows; new rows visible; reset clears")
    }

    @Test func bootstrapWaitersShareOneRequest() async throws {
        let (api, provider) = client()
        _ = provider
        let store = BootstrapStore(client: api, useFixtures: false)
        let data = Data("""
        {"user":{"id":"11111111-2222-3333-4444-555555555555"},"threads":[],"trial":{"started_at":null,"ends_at":null},"streak":{"count":0,"last_solved_on":null},"unread_proposals":0}
        """.utf8)
        LoadingProtocol.enqueue("/v1/bootstrap", body: data, delay: 0.1)
        LoadingProtocol.enqueue("/v1/threads", body: Data("[]".utf8))
        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)
        #expect(store.loadState == .loaded && store.user != nil)
        #expect(LoadingProtocol.count("/v1/bootstrap") == 1)
        print("BOOTSTRAP: 2 waiters, 1 request, both return after data is ready")
    }

    @Test func mathLayoutCacheSeparatesWidthsAndClears() {
        KaTeXLayoutCache.clear()
        let key = KaTeXLayoutCache.renderKey(raw: "$x^2$", display: false, color: .black, fontSize: 15, fontWeight: 400)
        KaTeXLayoutCache.store(48, for: key, width: 300)
        #expect(KaTeXLayoutCache.height(for: key, width: 300) == 48)
        #expect(KaTeXLayoutCache.height(for: key, width: 200) == nil)
        let bigger = KaTeXLayoutCache.renderKey(raw: "$x^2$", display: false, color: .black, fontSize: 20, fontWeight: 400)
        #expect(KaTeXLayoutCache.height(for: bigger, width: 300) == nil)
        KaTeXLayoutCache.clear()
        #expect(KaTeXLayoutCache.height(for: key, width: 300) == nil)
        print("MATH_CACHE: width/font separated; clear removes measurements")
    }

    @Test func decodedImagesAreSharedAndFullResolutionIsPreserved() async throws {
        let (api, provider) = client()
        _ = provider
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        }
        let endpoint = APIEndpoint.asset(relativePath: "test/pixels.png")
        LoadingProtocol.enqueue(endpoint.path, body: bytes, delay: 0.05)
        async let first = api.image(for: endpoint, maxPixelSize: 120)
        async let second = api.image(for: endpoint, maxPixelSize: 120)
        let (a, b) = try await (first, second)
        #expect(a === b)
        #expect(a.cgImage?.width == 120 && a.cgImage?.height == 80)
        let original = try await api.image(for: endpoint, maxPixelSize: nil)
        #expect(original.cgImage?.width == 600 && original.cgImage?.height == 400)
        #expect(LoadingProtocol.count(endpoint.path) == 1)
        print("IMAGE_CACHE: same decoded instance; 120x80 thumbnail; 600x400 original; 1 HTTP request")
    }

    @Test func rotationStopsWhenHiddenOrMotionIsDisabled() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let mark = StruisLoadingUIView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        window.addSubview(mark)
        mark.layoutIfNeeded()
        let rotation = mark.layer.sublayers!.first!
        #expect(rotation.animation(forKey: "struis.rotation")?.duration == 3)
        mark.isAnimating = false
        #expect(rotation.animationKeys()?.isEmpty != false)
        mark.isAnimating = true
        #expect(rotation.animation(forKey: "struis.rotation") != nil)
        mark.removeFromSuperview()
        #expect(rotation.animationKeys()?.isEmpty != false)
        print("ROTATION: 3 second cycle; disabled and detached animations removed")
    }

    private func seedThread(_ ledger: Ledger, n: Int, text: String) async throws -> ThreadSummary {
        let id = String(format: "10000000-0000-0000-0000-%012d", n)
        let (thread, event) = ChatRepository.createThread(id: id, title: "会話\(n)")
        try await ledger.append([event])
        try await appendMessage(ledger, threadID: UUID(uuidString: id)!, text: text)
        return ChatRepository.summary(thread)
    }

    private func appendMessage(_ ledger: Ledger, threadID: UUID, text: String) async throws {
        try await Task.sleep(for: .milliseconds(2))
        let (_, event) = ChatRepository.createMessage(
            threadID: threadID.uuidString.lowercased(), role: "assistant", status: "completed",
            plainText: text, blocks: .emptyArray, metadata: .object([:])
        )
        try await ledger.append([event])
    }
}

private final class LoadingProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { let body: Data; let status: Int; let delay: TimeInterval }
    nonisolated(unsafe) private static var routes: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    private static let lock = NSLock()
    private let stateLock = NSLock()
    private var stopped = false
    static func reset() { lock.lock(); defer { lock.unlock() }; routes = [:]; counts = [:] }
    static func enqueue(_ path: String, body: Data, status: Int = 200, delay: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }; routes[path, default: []].append(Reply(body: body, status: status, delay: delay))
    }
    static func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path, default: 0] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock()
        Self.counts[path, default: 0] += 1
        let reply = Self.routes[path]?.isEmpty == false ? Self.routes[path]!.removeFirst() : Reply(body: Data("[]".utf8), status: 200, delay: 0)
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            stateLock.lock(); defer { stateLock.unlock() }
            guard !stopped else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}
