import Foundation

/// Anthropic の Messages API への送信。実機は App Attest の access token で端末から直接送る(API キーも中継サーバーも
/// 使わない)。App Attest が使えない DEBUG の Simulator(開発中の検証)とテストだけ、API キーで送る。
nonisolated struct ClaudeUpstream: Sendable {
    /// Anthropic へ送る要求本文の上限(勉強を止めない仕組み 3.6)。Anthropic 側の上限(32 MB)より手前で止め、
    /// 超えた要求は送らずに記録する(`status: oversized`、ターンの記録として台帳に入る)。
    /// 272k トークンの文脈でも本文は 1〜2 MB、写真は長辺 2048px の JPEG(base64 で 1 枚 1〜2 MB)なので、
    /// ふつうのターンはこの 1/4 以下。超えるのは履歴や写真が膨らんだ異常な要求。
    static let maxRequestBytes: Int = 20 * 1024 * 1024

    static func requestTooLarge(_ byteCount: Int) -> Bool {
        byteCount > maxRequestBytes
    }

    enum Route: Sendable {
        /// API キーで(DEBUG の Simulator・テストだけ)。
        case apiKey(baseURL: URL, key: String)
        /// App Attest で受け取った token で(実機)。
        case appAttest(clientID: String)
    }

    var route: @Sendable () -> Route?
    var attest: AppAttestClient
    var session: URLSession
    /// 利用枠の判定(#62)。送る前に確かめ、料金が分かったら記録する。
    var gate: any UsageGate
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
    init(baseURL: URL, apiKey: @escaping @Sendable () -> String?, session: URLSession? = nil, gate: any UsageGate = DeviceUsageGate()) {
        self.init(route: { apiKey().map { .apiKey(baseURL: baseURL, key: $0) } }, session: session, gate: gate)
    }

    init(route: @escaping @Sendable () -> Route?, attest: AppAttestClient = .shared, session: URLSession?, gate: any UsageGate = DeviceUsageGate()) {
        self.route = route
        self.attest = attest
        self.gate = gate
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // 長い thinking の間も ping が来る。止まったストリームはランナーの見張り(`streamIdle`)で切る。
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

/// 1 回の要求の記録(実行監査の `requests[]`)。
nonisolated struct ClaudeRequestAttempt {
    var record: [String: Any]
    let started = Date()

    /// 直前の応答と比べる cache diagnostics を頼んだか。
    let compared: Bool

    init(reason: ClaudeRequestReason, model: String, translation: Int, tailTTL: String, options: ClaudeRequestOptions) {
        compared = translation >= 2 && options.includeDiagnostics && options.previousResponseID != nil
        record = [
            "reason": reason.rawValue, "requested_model": model, "translation": translation,
            "cache_ttl": ["system": ClaudeTranslation.systemCacheTTL(translation: translation, tail: tailTTL).map { $0 as Any } ?? NSNull(), "tail": translation >= 2 ? tailTTL : "5m"],
            "thinking_stripped": options.stripThinking, "schema_in_instructions": options.schemaInInstructions,
            "pricing_version": ClaudePricing.version, "started_at": LedgerClock.iso(Date()),
        ]
    }

    mutating func finish(status: String, translator: ClaudeStreamStatus?, httpStatus: Int?, error: (type: String?, message: String)?) -> [String: Any] {
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
        let ttl = record["cache_ttl"] as? [String: Any]
        // 書き込みの内訳が無い時: 版 4 は書き込みの大半が system の 1 時間の印なので 1 時間として数える。
        let assumed = (record["translation"] as? Int ?? 0) >= 4 ? ttl?["system"] as? String ?? "1h" : ttl?["tail"] as? String ?? "5m"
        let tokens = ClaudePricing.Tokens(usage: usage, assumedWriteTTL: assumed)
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

    /// 応答の止まり方を、要求の記録の `status` にする。
    static func status(stopReason: String?) -> String {
        switch stopReason {
        case "max_tokens": "max_tokens"
        case "refusal": "refusal"
        case "model_context_window_exceeded": "context_window_exceeded"
        case "pause_turn": "paused"
        default: "completed"
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
