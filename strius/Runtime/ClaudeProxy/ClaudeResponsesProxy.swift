import Foundation
import Network
import OSLog

nonisolated private let proxyLog = Logger(subsystem: "com.digiloglab.strius", category: "claude-proxy")

/// 端末内の Codex App Server が Claude を使うための localhost の provider。
///
/// Codex は Responses API しか話さない(`wire_api = "responses"`)。このプロキシは 127.0.0.1 だけで待ち受け、
/// 起動ごとのランダムな Bearer token を持つ要求だけを受けて、Anthropic の Messages API に変換して送る。
/// API キーは Keychain から要求ごとに読み、Codex の設定やスレッドには渡さない。
actor ClaudeResponsesProxy {
    static let shared = ClaudeResponsesProxy()

    nonisolated struct Endpoint: Sendable, Equatable {
        let baseURL: String
        let token: String
    }

    enum ProxyError: Error, LocalizedError {
        case listenerFailed(String)
        var errorDescription: String? {
            switch self {
            case .listenerFailed: "Claude への接続の準備に失敗しました。アプリを開き直してください"
            }
        }
    }

    private var listener: NWListener?
    private var endpoint: Endpoint?
    private let queue = DispatchQueue(label: "com.digiloglab.strius.claude-proxy")
    private let upstream: ClaudeUpstream

    init(upstream: ClaudeUpstream = ClaudeUpstream()) {
        self.upstream = upstream
    }

    /// 待ち受けを用意して、Codex に渡す base URL と token を返す。止まっていたら作り直す(port は変わり得る)。
    func start() async throws -> Endpoint {
        if let endpoint, let listener, listener.state == .ready { return endpoint }
        listener?.cancel()
        listener = nil
        let token = Self.randomToken()
        let parameters = NWParameters.tcp
        // 127.0.0.1 にだけ bind する(他の端末からは届かない)。`acceptLocalOnly` は Simulator で
        // 127.0.0.1 からの接続まで「ローカルでない」として捨てるため使わない。
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let created: NWListener
        do {
            created = try NWListener(using: parameters)
        } catch {
            throw ProxyError.listenerFailed(String(describing: error))
        }
        let upstream = self.upstream
        let queue = self.queue
        created.newConnectionHandler = { connection in
            ProxyConnection(connection: connection, token: token, upstream: upstream, queue: queue).start()
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            created.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume(returning: created.port?.rawValue ?? 0) }
                case .failed(let error):
                    proxyLog.error("listener failed: \(String(describing: error), privacy: .public)")
                    if once.take() { continuation.resume(throwing: ProxyError.listenerFailed(String(describing: error))) }
                case .cancelled:
                    if once.take() { continuation.resume(throwing: ProxyError.listenerFailed("cancelled")) }
                default:
                    break
                }
            }
            created.start(queue: queue)
        }
        guard port != 0 else { throw ProxyError.listenerFailed("no port") }
        listener = created
        let started = Endpoint(baseURL: "http://127.0.0.1:\(port)/v1", token: token)
        endpoint = started
        proxyLog.info("listening on 127.0.0.1:\(port, privacy: .public)")
        return started
    }

    func stop() {
        listener?.cancel()
        listener = nil
        endpoint = nil
    }

    nonisolated static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Codex の thread/start・thread/resume に渡す provider の設定(`config` の上書き)。
    nonisolated static func providerConfig(_ endpoint: Endpoint) -> [String: Any] {
        [
            "name": "Claude (Struis)",
            "base_url": endpoint.baseURL,
            "wire_api": "responses",
            "experimental_bearer_token": endpoint.token,
            "requires_openai_auth": false,
            "supports_websockets": false,
            // 再試行は Codex に任せる(プロキシは 1 回だけ送る)。
            "request_max_retries": 4,
            "stream_max_retries": 2,
            "stream_idle_timeout_ms": 300_000,
        ]
    }
}

/// `stateUpdateHandler` が何度呼ばれても continuation を一度だけ再開する。
nonisolated private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}

/// Anthropic の Messages API への送信。実機は App Attest の access token で端末から直接送る(API キーも中継サーバーも
/// 使わない)。App Attest が使えない DEBUG の Simulator(開発中の検証)とテストだけ、API キーで送る。
nonisolated struct ClaudeUpstream: Sendable {
    enum Route: Sendable {
        /// API キーで(DEBUG の Simulator・テストだけ)。
        case apiKey(baseURL: URL, key: String)
        /// App Attest で受け取った token で(実機)。
        case appAttest(clientID: String)
    }

    var route: @Sendable () -> Route?
    var attest: AppAttestClient
    var session: URLSession
    static let anthropicBaseURL = URL(string: "https://api.anthropic.com")!

    /// 既定: DEBUG の Simulator で API キーがあればそれ、それ以外は App Attest。どちらも使えなければ nil。
    init(session: URLSession? = nil) {
        self.init(route: {
            if let key = AnthropicCredentials.debugAPIKey {
                var base = ClaudeUpstream.anthropicBaseURL
                #if DEBUG
                // Simulator の検証用(模擬の Anthropic サーバー)。
                if let override = ProcessInfo.processInfo.environment["STRUIS_ANTHROPIC_BASE_URL"].flatMap(URL.init(string:)) { base = override }
                #endif
                return .apiKey(baseURL: base, key: key)
            }
            guard AppAttestClient.isSupported, let clientID = ClaudeAppAttestConfig.clientID else { return nil }
            return .appAttest(clientID: clientID)
        }, session: session)
    }

    /// テスト用: 決まった送り先に API キーで送る。
    init(baseURL: URL, apiKey: @escaping @Sendable () -> String?, session: URLSession? = nil) {
        self.init(route: { apiKey().map { .apiKey(baseURL: baseURL, key: $0) } }, session: session)
    }

    init(route: @escaping @Sendable () -> Route?, attest: AppAttestClient = .shared, session: URLSession?) {
        self.route = route
        self.attest = attest
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // 長い thinking の間も ping が来る。止まったストリームは Codex の idle timeout でも切れる。
            configuration.timeoutIntervalForRequest = 600
            configuration.timeoutIntervalForResource = 3_600
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    /// 送る要求と、App Attest の時はその token(401 の時に捨てるため)。
    func request(body: [String: Any], route: Route) async throws -> (URLRequest, bearer: String?) {
        let base: URL
        switch route {
        case .apiKey(let url, _): base = url
        case .appAttest: base = Self.anthropicBaseURL
        }
        var request = URLRequest(url: base.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        switch route {
        case .apiKey(_, let key):
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            return (request, nil)
        case .appAttest(let clientID):
            let token = try await attest.currentToken(clientID: clientID)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            return (request, token)
        }
    }
}

/// 1 本の HTTP 接続。要求を読み、`/v1/responses` を Claude に中継して SSE で返す。返し終えたら閉じる。
nonisolated private final class ProxyConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let token: String
    private let upstream: ClaudeUpstream
    private let queue: DispatchQueue
    private var buffer = Data()
    private var task: Task<Void, Never>?

    init(connection: NWConnection, token: String, upstream: ClaudeUpstream, queue: DispatchQueue) {
        self.connection = connection
        self.token = token
        self.upstream = upstream
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled:
                // Codex が要求をやめた(止める・タイムアウト)。上流の送信も止める。
                task?.cancel()
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            if let request = HTTPRequestParser.parse(buffer) {
                handle(request)
                return
            }
            if complete || error != nil {
                connection.cancel()
                return
            }
            guard buffer.count < 64 * 1024 * 1024 else {
                respond(status: 413, json: ["error": ["message": "request too large", "type": "invalid_request_error"]])
                return
            }
            receive()
        }
    }

    private func handle(_ request: HTTPRequestParser.Request) {
        guard request.headers["authorization"] == "Bearer " + token else {
            respond(status: 401, json: ["error": ["message": "unauthorized", "type": "invalid_request_error"]])
            return
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        if request.method == "GET", path.hasSuffix("/models") {
            respond(status: 200, json: ["models": [Any](), "data": [Any]()])
            return
        }
        guard request.method == "POST", path.hasSuffix("/responses") else {
            respond(status: 404, json: ["error": ["message": "not found", "type": "invalid_request_error"]])
            return
        }
        guard let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            respond(status: 400, json: ["error": ["message": "invalid JSON", "type": "invalid_request_error"]])
            return
        }
        let upstream = self.upstream
        task = Task { [self] in
            await ClaudeRelay(upstream: upstream, writer: self).run(json)
        }
    }

    // MARK: - Writing

    func respond(status: Int, json: [String: Any], headers: [String: String] = [:]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        var head = "HTTP/1.1 \(status) \(HTTPRequestParser.reason(status))\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { [self] _ in
            connection.cancel()
        })
    }

    func beginStream() async throws {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        try await send(Data(head.utf8))
    }

    func sendEvent(_ event: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        let type = event["type"] as? String ?? "message"
        try await send(Data("event: \(type)\ndata: ".utf8) + data + Data("\n\n".utf8))
    }

    func endStream() {
        connection.send(content: nil, isComplete: true, completion: .contentProcessed { [self] _ in
            connection.cancel()
        })
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

/// 1 つの Responses 要求を Claude に送り、応答を変換して返す。
nonisolated private struct ClaudeRelay {
    let upstream: ClaudeUpstream
    let writer: ProxyConnection

    func run(_ request: [String: Any]) async {
        guard let route = upstream.route() else {
            writer.respond(status: 401, json: ["error": [
                "message": ModelProviderError.claudeUnavailable.localizedDescription,
                "type": "invalid_request_error", "code": "claude_unavailable",
            ]])
            return
        }
        var options = ClaudeRequestTranslator.Options()
        var retriedToken = false
        for _ in 0..<4 {
            let translation: ClaudeRequestTranslator.Translation
            do {
                translation = try ClaudeRequestTranslator.translate(request, options: options)
            } catch {
                writer.respond(status: 400, json: ["error": ["message": error.localizedDescription, "type": "invalid_request_error"]])
                return
            }
            ClaudeProxyDiagnostics.dump(request: request, translated: translation.body)
            do {
                let (urlRequest, bearer) = try await upstream.request(body: translation.body, route: route)
                let (bytes, response) = try await upstream.session.bytes(for: urlRequest)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    var collected = Data()
                    for try await byte in bytes {
                        collected.append(byte)
                        if collected.count > 256 * 1024 { break }
                    }
                    let error = ((try? JSONSerialization.jsonObject(with: collected)) as? [String: Any])?["error"] as? [String: Any]
                    let message = error?["message"] as? String ?? String(decoding: collected.prefix(2_000), as: UTF8.self)
                    // 署名の合わない thinking(履歴の編集・別モデルの履歴)は外して 1 回だけ送り直す。
                    if status == 400, !options.stripThinking, message.localizedCaseInsensitiveContains("thinking") {
                        proxyLog.error("thinking rejected, retrying without thinking blocks")
                        options.stripThinking = true
                        continue
                    }
                    // App Attest の token が失効・取り消された: 捨てて取り直し、1 回だけ送り直す。
                    if status == 401, case .appAttest(let clientID) = route, let bearer, !retriedToken {
                        proxyLog.error("claude rejected the app attest token, minting a new one")
                        retriedToken = true
                        await upstream.attest.invalidate(token: bearer, clientID: clientID)
                        continue
                    }
                    // structured outputs の文法が大きすぎる schema は、指示文で渡して送り直す。
                    if status == 400, translation.structured, !options.schemaInInstructions,
                       message.localizedCaseInsensitiveContains("grammar") || message.localizedCaseInsensitiveContains("schema") {
                        proxyLog.error("output schema rejected, retrying with the schema in the instructions")
                        options.schemaInInstructions = true
                        continue
                    }
                    proxyLog.error("upstream status \(status, privacy: .public): \(message, privacy: .public)")
                    let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")
                    writer.respond(status: Self.codexStatus(status), json: ["error": [
                        "message": message, "type": error?["type"] as? String ?? "api_error",
                        "code": ClaudeStreamTranslator.responsesErrorCode(anthropicType: error?["type"] as? String ?? ""),
                    ]], headers: retryAfter.map { ["Retry-After": $0] } ?? [:])
                    return
                }
                try await writer.beginStream()
                let translator = ClaudeStreamTranslator(tools: translation.tools)
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                    for out in translator.consume(event) { try await writer.sendEvent(out) }
                    if translator.isFinished { break }
                }
                for out in translator.streamEnded() { try await writer.sendEvent(out) }
                writer.endStream()
                return
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                proxyLog.error("upstream failed: \(String(describing: error), privacy: .public)")
                if let failure = error as? AppAttestClient.Failure {
                    // 端末の確認ができない時は再試行しても変わらない(Codex は 4xx を再試行しない)。混雑は 429 で再試行させる。
                    writer.respond(status: failure == .rateLimited ? 429 : 401,
                                   json: ["error": ["message": failure.localizedDescription, "type": "authentication_error", "code": "app_attest"]])
                } else {
                    writer.respond(status: 502, json: ["error": ["message": "Claude に接続できませんでした", "type": "api_error"]])
                }
                return
            }
        }
    }

    /// Codex は 429・5xx を再試行し、4xx はそのまま失敗にする。
    static func codexStatus(_ status: Int) -> Int {
        switch status {
        case 429: 429
        case 401, 403: 401
        case 400, 404, 413, 422: 400
        case 529, 500...599: 503
        default: 502
        }
    }
}

/// HTTP/1.1 の要求を 1 つ読む(Content-Length か chunked)。足りなければ nil。
nonisolated enum HTTPRequestParser {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = data[headerEnd.upperBound...]
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = dechunk(Data(rest)) else { return nil }
            body = decoded
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard rest.count >= length else { return nil }
            body = Data(rest.prefix(length))
        }
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }

    /// chunked の本文を戻す。終わりの 0 チャンクまで届いていなければ nil。
    static func dechunk(_ data: Data) -> Data? {
        var output = Data()
        var index = data.startIndex
        while true {
            guard let lineEnd = data[index...].range(of: Data("\r\n".utf8)) else { return nil }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            let start = lineEnd.upperBound
            if size == 0 { return output }
            guard data.distance(from: start, to: data.endIndex) >= size + 2 else { return nil }
            let end = data.index(start, offsetBy: size)
            output.append(data[start..<end])
            index = data.index(end, offsetBy: 2)
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}

/// Simulator の検証用: `STRUIS_CLAUDE_PROXY_DUMP_DIR` に Codex の要求と変換後の要求を書き出す(画像は省く)。
nonisolated enum ClaudeProxyDiagnostics {
    static func dump(request: [String: Any], translated: [String: Any]) {
        #if DEBUG && targetEnvironment(simulator)
        guard let path = ProcessInfo.processInfo.environment["STRUIS_CLAUDE_PROXY_DUMP_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        func write(_ object: Any, _ name: String) {
            let scrubbed = scrubImages(object)
            guard let data = try? JSONSerialization.data(withJSONObject: scrubbed, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: directory.appendingPathComponent("\(stamp)-\(name).json"))
        }
        write(request, "responses")
        write(translated, "messages")
        #endif
    }

    private static func scrubImages(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(scrubImages) }
        guard var object = value as? [String: Any] else {
            if let text = value as? String, text.hasPrefix("data:image/") { return "data:image/…(\(text.count) chars)" }
            return value
        }
        if object["type"] as? String == "base64", let data = object["data"] as? String { object["data"] = "…(\(data.count) chars)" }
        for (key, inner) in object where key != "data" { object[key] = scrubImages(inner) }
        return object
    }
}
