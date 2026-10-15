import CryptoKit
import XCTest
@testable import strius

/// Anthropic の App Attest の token 取得(チャレンジ → 登録 → 交換 → 取り直し)。Apple と Anthropic は模擬。
final class ClaudeAppAttestTests: XCTestCase {
    private struct FakeAttestation: AppAttestClient.Attestation {
        let keyID = Data(repeating: 7, count: 32).base64EncodedString()
        let log: Log
        var isSupported: Bool { true }
        func generateKey() async throws -> String { keyID }
        func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
            log.append("attest:\(clientDataHash.base64EncodedString())")
            return Data("attestation".utf8)
        }
        func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
            log.append("assert:\(clientDataHash.base64EncodedString())")
            return Data("assertion".utf8)
        }
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ item: String) { lock.withLock { items.append(item) } }
        var all: [String] { lock.withLock { items } }
    }

    private let challenge1 = Data(repeating: 1, count: 32)
    private let challenge2 = Data(repeating: 2, count: 32)

    override func setUp() {
        StubAnthropicAuth.requests = []
        StubAnthropicAuth.handler = nil
    }

    private func client(_ log: Log) -> AppAttestClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAnthropicAuth.self]
        return AppAttestClient(baseURL: URL(string: "https://auth.test")!, attestation: FakeAttestation(log: log),
                               session: URLSession(configuration: configuration), keychainService: "test.app-attest." + UUID().uuidString)
    }

    func testRegistersOnceThenMintsWithTheBoundAssertion() async throws {
        let log = Log()
        let attest = client(log)
        let keyID = Data(repeating: 7, count: 32).base64EncodedString()
        var minted = 0
        StubAnthropicAuth.handler = { [challenge1, challenge2] request, body in
            switch request.url?.path {
            case "/v1/oauth/app-attest/challenge":
                return (200, ["challenge": challenge1.base64EncodedString(), "expires_in": 300])
            case "/v1/oauth/app-attest/register":
                let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
                XCTAssertEqual(json["client_id"] as? String, "clid_test")
                XCTAssertEqual(json["key_id"] as? String, keyID)
                XCTAssertEqual(json["attestation_object"] as? String, Data("attestation".utf8).base64EncodedString())
                // 登録の応答は最初の token と、次に使えるチャレンジを返す。
                return (200, ["access_token": "token-1", "expires_in": 3600, "next_challenge": challenge2.base64EncodedString(), "next_challenge_expires_in": 300])
            case "/v1/oauth/token":
                minted += 1
                let form = String(decoding: body, as: UTF8.self)
                XCTAssertTrue(form.contains("grant_type=urn%3Aanthropic%3Aparams%3Aoauth%3Agrant-type%3Aapp-attest"))
                XCTAssertTrue(form.contains("client_id=clid_test"))
                return (200, ["access_token": "token-2", "expires_in": 3600])
            default:
                return (404, [:])
            }
        }

        let first = try await attest.currentToken(clientID: "clid_test")
        XCTAssertEqual(first, "token-1")
        // 期限内は通信しない。
        let cached = try await attest.currentToken(clientID: "clid_test")
        XCTAssertEqual(cached, "token-1")
        XCTAssertEqual(StubAnthropicAuth.requests, ["/v1/oauth/app-attest/challenge", "/v1/oauth/app-attest/register"])
        // 登録の attestation は SHA256(challenge) に対するもの。
        XCTAssertEqual(log.all.first, "attest:" + Data(SHA256.hash(data: challenge1)).base64EncodedString())

        // Messages API が 401 を返した token を捨てると、登録済みの鍵の assertion で取り直す(渡されていたチャレンジを使う)。
        await attest.invalidate(token: "token-1", clientID: "clid_test")
        let second = try await attest.currentToken(clientID: "clid_test")
        XCTAssertEqual(second, "token-2")
        XCTAssertEqual(minted, 1)
        XCTAssertEqual(StubAnthropicAuth.requests.last, "/v1/oauth/token")
        XCTAssertFalse(StubAnthropicAuth.requests.dropFirst(2).contains("/v1/oauth/app-attest/challenge"))
        let expected = AppAttestClient.assertionClientDataHash(challenge: challenge2, clientID: "clid_test", keyID: Data(repeating: 7, count: 32))
        XCTAssertEqual(log.all.last, "assert:" + expected.base64EncodedString())
    }

    func testAssertionBindingMatchesTheVersionedLayout() {
        var hash = SHA256()
        hash.update(data: Data("anthropic-app-attest-token-v1".utf8))
        hash.update(data: challenge1)
        hash.update(data: Data("clid_x".utf8))
        hash.update(data: Data(repeating: 9, count: 32))
        XCTAssertEqual(AppAttestClient.assertionClientDataHash(challenge: challenge1, clientID: "clid_x", keyID: Data(repeating: 9, count: 32)), Data(hash.finalize()))
        XCTAssertEqual(AppAttestClient.formEncode(["b": "a+b=", "a": "x y"]), "a=x%20y&b=a%2Bb%3D")
        XCTAssertEqual(AppAttestClient.decodeBase64Loose("-_8"), Data([0xfb, 0xff]))
    }

    func testUpstreamSendsTheBearerTokenToAnthropic() async throws {
        let log = Log()
        let attest = client(log)
        StubAnthropicAuth.handler = { [challenge1] request, _ in
            switch request.url?.path {
            case "/v1/oauth/app-attest/challenge": return (200, ["challenge": challenge1.base64EncodedString(), "expires_in": 300])
            case "/v1/oauth/app-attest/register": return (200, ["access_token": "token-1", "expires_in": 3600])
            default: return (404, [:])
            }
        }
        let upstream = ClaudeUpstream(route: { .appAttest(clientID: "clid_test") }, attest: attest, session: nil)
        let (request, bearer) = try await upstream.request(body: ["model": "claude-opus-5-5"], route: .appAttest(clientID: "clid_test"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(bearer, "token-1")
    }
}

/// Anthropic の OAuth エンドポイントの代わり。
final class StubAnthropicAuth: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, [String: Any]))?
    nonisolated(unsafe) static var requests: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.requests.append(request.url?.path ?? "")
        let (status, json) = Self.handler?(request, body) ?? (500, [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
