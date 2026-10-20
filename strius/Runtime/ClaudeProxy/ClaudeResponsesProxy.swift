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

    /// Anthropic へ送る要求本文の上限(勉強を止めない仕組み 3.6)。Anthropic 側の上限(32 MB)より手前で止め、
    /// 超えた要求は送らずに記録(`status: oversized`、ターンの記録として台帳に入る)して Codex に 400 を返す。
    /// 272k トークンの文脈でも本文は 1〜2 MB、写真は長辺 2048px の JPEG(base64 で 1 枚 1〜2 MB)なので、
    /// ふつうのターンはこの 1/4 以下。超えるのは履歴や写真が膨らんだ異常な要求。
    nonisolated static let maxRequestBytes = 20 * 1024 * 1024

    nonisolated static func requestTooLarge(_ byteCount: Int) -> Bool {
        byteCount > maxRequestBytes
    }

    /// 大きすぎる要求に返す状態。413 ではなく 400: Codex は 413 を一時的な失敗として同じ本文を送り直す
    /// (`codexStatus` が上流の 413 を 400 に直しているのと同じ理由)。送り直しが無いので失敗はすぐ学習者に届く。
    nonisolated static let oversizedStatus = 400

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
        try await request(data: try JSONSerialization.data(withJSONObject: body), route: route)
    }

    func request(data: Data, route: Route) async throws -> (URLRequest, bearer: String?) {
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
        request.httpBody = data
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
                respond(status: ClaudeResponsesProxy.oversizedStatus, json: ["error": ["message": "request too large", "type": "invalid_request_error", "code": "request_too_large"]])
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

/// 1 つの Responses 要求を Claude に送り、応答を変換して返す。送った要求は 1 回ごとに `ClaudeRequestLog` に記録する。
nonisolated private struct ClaudeRelay {
    let upstream: ClaudeUpstream
    let writer: ProxyConnection
    var log: ClaudeRequestLog = .shared
    var contexts: ThreadContextStore = .shared

    /// 1 回の要求の記録(実行監査の `requests[]`)。
    private struct Attempt {
        var record: [String: Any]
        let started = Date()

        /// 直前の応答と比べる cache diagnostics を頼んだか。
        let compared: Bool

        init(reason: ClaudeRequestReason, model: String, translation: Int, tailTTL: String, options: ClaudeRequestTranslator.Options) {
            compared = translation >= 2 && options.includeDiagnostics && options.previousResponseID != nil
            record = [
                "reason": reason.rawValue, "requested_model": model, "translation": translation,
                "cache_ttl": ["system": translation >= 2 ? "1h" : NSNull(), "tail": translation >= 2 ? tailTTL : "5m"],
                "thinking_stripped": options.stripThinking, "schema_in_instructions": options.schemaInInstructions,
                "pricing_version": ClaudePricing.version, "started_at": LedgerClock.iso(Date()),
            ]
        }

        mutating func finish(status: String, translator: ClaudeStreamTranslator?, httpStatus: Int?, error: (type: String?, message: String)?) -> [String: Any] {
            record["status"] = status
            record["elapsed_ms"] = Int((Date().timeIntervalSince(started) * 1000).rounded())
            if let httpStatus { record["http_status"] = httpStatus }
            if let error {
                record["error_type"] = error.type ?? NSNull()
                record["error"] = String(error.message.prefix(500))
            }
            let usage = translator?.rawUsage ?? [:]
            record["response_id"] = translator?.messageID ?? NSNull()
            record["actual_model"] = translator?.model ?? NSNull()
            record["stop_reason"] = translator?.stopReason ?? NSNull()
            record["usage"] = usage.isEmpty ? NSNull() : usage
            // 出力のうち thinking の分(`output_tokens_details.thinking_tokens`)。返らなければ 0 ではなく内訳なしとする。
            if let thinking = (usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"] as? Int {
                record["thinking_tokens"] = thinking
                record["thinking_breakdown"] = "reported"
            } else {
                record["thinking_tokens"] = NSNull()
                record["thinking_breakdown"] = "unavailable"
            }
            var diagnosis: String?
            if compared, let translator, translator.messageID != nil {
                let summary = ClaudeCacheDiagnosis.summarize(translator.diagnostics ?? NSNull())
                record["cache_diagnostics"] = summary
                diagnosis = (summary as? [String: Any])?["result"] as? String
            }
            if usage.isEmpty {
                // 拒まれた要求(4xx)は課金されない。届いたのに使用量が読めなかった要求は「不明」として残す(0 にしない)。
                let unbilled = translator?.messageID == nil && (httpStatus.map { $0 >= 400 } ?? true)
                record["estimated_cost_usd"] = NSNull()
                record["cost_status"] = unbilled ? "not_billed" : "usage_unavailable"
                return record
            }
            // 料金は応答で実際に使われたモデルで計算する。
            let model = translator?.model ?? record["requested_model"] as? String ?? ""
            let tail = (record["cache_ttl"] as? [String: Any])?["tail"] as? String ?? "5m"
            let tokens = ClaudePricing.Tokens(usage: usage, assumedWriteTTL: tail)
            record["tokens"] = [
                "input": tokens.input, "cache_read": tokens.cacheRead, "cache_write_5m": tokens.cacheWrite5m,
                "cache_write_1h": tokens.cacheWrite1h, "output": tokens.output, "prompt_total": tokens.promptTotal,
                "write_split": tokens.writeSplitEstimated ? "estimated" : "reported",
            ]
            record["cache_state"] = ClaudeCacheDiagnosis.state(diagnosis: diagnosis, tokens: tokens)
            if let cost = ClaudePricing.cost(model: model, tokens: tokens) {
                record["estimated_cost_usd"] = cost.usd
                record["pricing_tier"] = cost.tier
                record["cost_status"] = "estimated"
            } else {
                record["estimated_cost_usd"] = NSNull()
                record["cost_status"] = "unknown_model"
            }
            return record
        }
    }

    func run(_ request: [String: Any]) async {
        let classified = log.classify(request: request)
        let threadID = classified.key?.threadID
        let model = request["model"] as? String ?? ""
        guard let route = upstream.route() else {
            writer.respond(status: 401, json: ["error": [
                "message": ModelProviderError.claudeUnavailable.localizedDescription,
                "type": "invalid_request_error", "code": "claude_unavailable",
            ]])
            return
        }
        let entry = threadID.flatMap { contexts.entry($0) }
        var options = ClaudeRequestTranslator.Options()
        options.translation = ThreadContextStore.claudeTranslation(entry)
        options.tailCacheTTL = entry?.profile?.cacheTTL ?? ClaudeTranslation.tailCacheTTL(kind: entry?.profile?.kind)
        // 一度署名の不整合で thinking を外した会話は、以後も外して送る(毎ターン拒まれて送り直さない)。
        options.stripThinking = entry?.thinkingStripped == true
        options.previousResponseID = threadID.flatMap { log.previousResponseID(threadID: $0) } ?? entry?.lastClaudeMessageID
        var reason = classified.reason
        var retriedToken = false
        for _ in 0..<5 {
            let translation: ClaudeRequestTranslator.Translation
            let data: Data
            do {
                translation = try ClaudeRequestTranslator.translate(request, options: options)
                data = try translation.data()
            } catch {
                writer.respond(status: 400, json: ["error": ["message": error.localizedDescription, "type": "invalid_request_error"]])
                return
            }
            ClaudeProxyDiagnostics.dump(request: request, translated: translation.body)
            var attempt = Attempt(reason: reason, model: model, translation: options.translation, tailTTL: options.tailCacheTTL, options: options)
            if ClaudeResponsesProxy.requestTooLarge(data.count) {
                let message = "request body \(data.count) bytes exceeds \(ClaudeResponsesProxy.maxRequestBytes)"
                proxyLog.error("\(message, privacy: .public); not sent")
                log.append(attempt.finish(status: "oversized", translator: nil, httpStatus: nil, error: ("request_too_large", message)), key: classified.key)
                // 400 で返す: Codex は 413 を一時的な失敗として同じ本文を送り直す(`codexStatus` が上流の 413 を 400 に
                // 直しているのと同じ理由)。送り直されると記録が重なり、学習者には同じ失敗が遅れて届く。
                writer.respond(status: ClaudeResponsesProxy.oversizedStatus, json: ["error": [
                    "message": "送る内容が大きすぎます(\(data.count / (1024 * 1024)) MB)。写真の枚数を減らすか、新しい会話で送ってください。",
                    "type": "invalid_request_error", "code": "request_too_large",
                ]])
                return
            }
            var translator: ClaudeStreamTranslator?
            do {
                let (urlRequest, bearer) = try await upstream.request(data: data, route: route)
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
                    log.append(attempt.finish(status: "http_error", translator: nil, httpStatus: status, error: (error?["type"] as? String, message)), key: classified.key)
                    // cache diagnostics を受け付けない経路では外して送り直す(診断は無くても要求は通す)。
                    if status == 400, options.includeDiagnostics, translation.body["diagnostics"] != nil,
                       message.localizedCaseInsensitiveContains("diagnostics") {
                        proxyLog.error("diagnostics rejected, retrying without them")
                        options.includeDiagnostics = false
                        reason = .diagnosticsRetry
                        continue
                    }
                    // 署名の合わない thinking(履歴の編集・別モデルの履歴)は外して 1 回だけ送り直す。
                    if status == 400, !options.stripThinking, message.localizedCaseInsensitiveContains("thinking") {
                        let kind = ClaudeThinkingRejection.classify(message)
                        proxyLog.error("thinking rejected (\(kind.rawValue, privacy: .public)), retrying without thinking blocks")
                        options.stripThinking = true
                        reason = .thinkingStripRetry
                        if kind == .signatureMismatch, let threadID {
                            // 同じ不整合を毎ターン繰り返さない。以後この会話は thinking を外して送る。
                            contexts.update(threadID) { $0.thinkingStripped = true }
                        }
                        continue
                    }
                    // App Attest の token が失効・取り消された: 捨てて取り直し、1 回だけ送り直す。
                    if status == 401, case .appAttest(let clientID) = route, let bearer, !retriedToken {
                        proxyLog.error("claude rejected the app attest token, minting a new one")
                        retriedToken = true
                        reason = .authRetry
                        await upstream.attest.invalidate(token: bearer, clientID: clientID)
                        continue
                    }
                    // structured outputs の文法が大きすぎる schema は、指示文で渡して送り直す。
                    if status == 400, translation.structured, !options.schemaInInstructions,
                       message.localizedCaseInsensitiveContains("grammar") || message.localizedCaseInsensitiveContains("schema") {
                        proxyLog.error("output schema rejected, retrying with the schema in the instructions")
                        options.schemaInInstructions = true
                        reason = .schemaRetry
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
                let streamTranslator = ClaudeStreamTranslator(tools: translation.tools)
                translator = streamTranslator
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                    let out = streamTranslator.consume(event)
                    if streamTranslator.isFinished {
                        // Codex に終わりを渡す前に記録する(ターンの終わりで実行監査に移すため)。
                        let status = streamTranslator.errorType != nil ? "stream_error" : Self.status(stopReason: streamTranslator.stopReason)
                        log.append(attempt.finish(status: status, translator: streamTranslator, httpStatus: 200,
                                                  error: streamTranslator.errorType.map { ($0, "stream error") }), key: classified.key)
                        if let threadID, let id = streamTranslator.messageID {
                            log.setPreviousResponseID(id, threadID: threadID)
                            // 再起動の後も比べられるよう、控えのあるスレッドには残す(下調べの子などの控えは作らない)。
                            if entry != nil { contexts.update(threadID) { $0.lastClaudeMessageID = id } }
                        }
                    }
                    for event in out { try await writer.sendEvent(event) }
                    if streamTranslator.isFinished { break }
                }
                if !streamTranslator.isFinished {
                    log.append(attempt.finish(status: "stream_ended", translator: streamTranslator, httpStatus: 200, error: (nil, "stream ended early")), key: classified.key)
                }
                for out in streamTranslator.streamEnded() { try await writer.sendEvent(out) }
                writer.endStream()
                return
            } catch is CancellationError {
                if translator?.isFinished != true {
                    log.append(attempt.finish(status: "cancelled", translator: translator, httpStatus: nil, error: nil), key: classified.key)
                }
                return
            } catch {
                if translator?.isFinished != true {
                    log.append(attempt.finish(status: Task.isCancelled ? "cancelled" : "failed", translator: translator, httpStatus: nil,
                                              error: (nil, String(describing: error))), key: classified.key)
                }
                if Task.isCancelled { return }
                proxyLog.error("upstream failed: \(String(describing: error), privacy: .public)")
                if let failure = error as? AppAttestClient.Failure {
                    // 端末の確認ができない時は再試行しても変わらない。Codex が再試行しないのは 400(InvalidRequest)で、
                    // 401・5xx は request_max_retries × stream_max_retries 回(15 回)送り直す(2026-10-16 の台帳)。混雑は 429。
                    writer.respond(status: failure == .rateLimited ? 429 : 400,
                                   json: ["error": ["message": failure.localizedDescription, "type": "invalid_request_error", "code": "app_attest"]])
                } else if (error as NSError).domain == "com.apple.devicecheck.error" {
                    // App Attest の端末側の失敗(鍵の作成・attestation)。再試行しても変わらない。
                    writer.respond(status: 400, json: ["error": ["message": "この端末の確認(App Attest)に失敗しました(DeviceCheck \((error as NSError).code))。アプリを開き直してもう一度試してください。",
                                                                "type": "invalid_request_error", "code": "app_attest"]])
                } else {
                    writer.respond(status: 502, json: ["error": ["message": "Claude に接続できませんでした", "type": "api_error"]])
                }
                return
            }
        }
    }

    static func status(stopReason: String?) -> String {
        switch stopReason {
        case "max_tokens": "max_tokens"
        case "refusal": "refusal"
        case "model_context_window_exceeded": "context_window_exceeded"
        case "pause_turn": "paused"
        default: "completed"
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

/// thinking を含む要求が 400 で拒まれた理由。外して送り直すかどうかと、以後も外すかどうかを分ける。
nonisolated enum ClaudeThinkingRejection: String, Sendable {
    /// 履歴の thinking の署名が合わない(履歴の編集・別の会話・別のモデルの thinking)。
    case signatureMismatch = "signature_mismatch"
    /// それ以外(thinking の設定など)。外して送り直しても次のターンでまた起こるとは限らない。
    case other

    static func classify(_ message: String) -> ClaudeThinkingRejection {
        let lowered = message.lowercased()
        if lowered.contains("signature") || lowered.contains("bound to a different conversation") { return .signatureMismatch }
        return .other
    }
}

/// cache diagnostics の結果を、実行監査に残す形にする。`*_changed` は指示・tools・履歴・モデルの変更、
/// 変更が無いのに読み込みが無ければ期限切れ(`ClaudeRequestLog` の利用側で usage と合わせて判断する)。
nonisolated enum ClaudeCacheDiagnosis {
    static func summarize(_ diagnostics: Any) -> Any {
        guard let object = diagnostics as? [String: Any] else { return ["result": "no_divergence"] }
        guard let reason = object["cache_miss_reason"] as? [String: Any] else { return ["result": "pending"] }
        var summary: [String: Any] = ["result": reason["type"] as? String ?? "unknown"]
        if let missed = reason["cache_missed_input_tokens"] { summary["cache_missed_input_tokens"] = missed }
        return summary
    }

    /// キャッシュの状態: 読めた(`hit`)・要求が変わった(`*_changed`)・同じ要求なのに読めなかった(期限切れ・追い出し)。
    static func state(diagnosis: String?, tokens: ClaudePricing.Tokens) -> String {
        if let diagnosis, diagnosis.hasSuffix("_changed") { return diagnosis }
        if tokens.cacheRead > 0 { return tokens.input + tokens.cacheWrite5m + tokens.cacheWrite1h > 0 ? "partial_hit" : "hit" }
        if diagnosis == "no_divergence" { return "expired" }
        return diagnosis == nil ? "cold" : "miss_" + diagnosis!
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
