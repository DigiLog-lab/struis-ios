import XCTest
@testable import strius

/// Claude の費用削減: 変換方式の版(キャッシュ・キー順)、要求ごとの料金と記録、送り直しの理由。
final class ClaudeCostTests: XCTestCase {
    private func request(input: [[String: Any]], threadID: String = "thr_1", turnID: String = "turn_1", kind: String? = nil) -> [String: Any] {
        var metadata: [String: Any] = ["thread_id": threadID, "turn_id": turnID, "session_id": threadID]
        if let kind { metadata["request_kind"] = kind }
        return [
            "model": "claude-opus-5-5", "instructions": "BASE", "input": input, "tool_choice": "auto", "parallel_tool_calls": false,
            "reasoning": ["effort": "medium", "summary": "auto"], "store": false, "stream": true, "client_metadata": metadata,
            "tools": [["type": "function", "name": "zeta", "parameters": ["type": "object", "properties": ["b": ["type": "string"], "a": ["type": "string"]]]],
                      ["type": "function", "name": "alpha", "parameters": ["type": "object", "properties": [String: Any]()]]],
        ]
    }

    private let userTurn: [[String: Any]] = [
        ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "DEV"]]],
        ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hello"]]],
        ["type": "function_call", "name": "zeta", "arguments": "{\"b\":\"2\",\"a\":\"1\"}", "call_id": "toolu_1"],
        ["type": "function_call_output", "call_id": "toolu_1", "output": "ok"],
    ]

    // MARK: - Translation versions

    func testVersionTwoCachesTheFixedInstructionsForAnHourAndTheTailByTaskGroup() throws {
        var options = ClaudeRequestTranslator.Options()
        options.tailCacheTTL = ClaudeTranslation.tailCacheTTL(kind: "chat")
        options.previousResponseID = "msg_prev"
        let body = try ClaudeRequestTranslator.translate(request(input: userTurn), options: options).body
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(system[0]["text"] as? String, "BASE\n\nDEV")
        XCTAssertEqual(system[0]["cache_control"] as? [String: String], ["type": "ephemeral", "ttl": "1h"])
        XCTAssertEqual(body["cache_control"] as? [String: String], ["type": "ephemeral", "ttl": "1h"])
        XCTAssertEqual((body["diagnostics"] as? [String: Any])?["previous_message_id"] as? String, "msg_prev")

        // 一度で終わる処理の固有の入力は 5 分(既定)で書く。
        options.tailCacheTTL = ClaudeTranslation.tailCacheTTL(kind: "workbook_grading")
        options.previousResponseID = nil
        let oneShot = try ClaudeRequestTranslator.translate(request(input: userTurn), options: options).body
        XCTAssertEqual(oneShot["cache_control"] as? [String: String], ["type": "ephemeral"])
        XCTAssertTrue((oneShot["diagnostics"] as? [String: Any])?["previous_message_id"] is NSNull)
    }

    func testVersionOneKeepsTheShapeExistingThreadsWereSentWith() throws {
        let body = try ClaudeRequestTranslator.translate(request(input: userTurn), options: .init(translation: 1)).body
        XCTAssertEqual(body["system"] as? String, "BASE\n\nDEV")
        XCTAssertEqual(body["cache_control"] as? [String: String], ["type": "ephemeral"])
        XCTAssertNil(body["diagnostics"])
    }

    func testVersionTwoSendsTheSameBytesForTheSameContent() throws {
        // 同じ内容でもキーの入れ方が違う(再起動後の辞書の順など)要求から、同じバイト列を作る。
        var reordered = request(input: userTurn)
        reordered["tools"] = Array(((reordered["tools"] as? [[String: Any]]) ?? []).reversed())
        let first = try ClaudeRequestTranslator.translate(request(input: userTurn)).data()
        let second = try ClaudeRequestTranslator.translate(reordered).data()
        XCTAssertEqual(first, second)
        let text = String(decoding: first, as: UTF8.self)
        // tool の引数もキーの順に並ぶ。
        XCTAssertTrue(text.contains("\"input\":{\"a\":\"1\",\"b\":\"2\"}"), text)
    }

    func testThreadsStartedBeforeTheProfileStayOnVersionOne() {
        XCTAssertEqual(ThreadContextStore.claudeTranslation(nil), ClaudeTranslation.current)
        XCTAssertEqual(ThreadContextStore.claudeTranslation(.init(provider: .anthropic)), 1)
        var entry = ThreadContextStore.Entry(provider: .anthropic)
        entry.profile = .init(kind: "chat", translation: 2, cacheTTL: "1h")
        XCTAssertEqual(ThreadContextStore.claudeTranslation(entry), 2)
    }

    // MARK: - Pricing

    func testPricingSplitsCacheWritesByTTLAndUsesTheModelThatAnswered() throws {
        let usage: [String: Any] = [
            "input_tokens": 1_000, "cache_read_input_tokens": 10_000, "cache_creation_input_tokens": 3_000, "output_tokens": 500,
            "cache_creation": ["ephemeral_5m_input_tokens": 1_000, "ephemeral_1h_input_tokens": 2_000],
        ]
        let tokens = ClaudePricing.Tokens(usage: usage)
        XCTAssertEqual(tokens.cacheWrite5m, 1_000)
        XCTAssertEqual(tokens.cacheWrite1h, 2_000)
        XCTAssertFalse(tokens.writeSplitEstimated)
        // Opus: 1000×4 + 10000×0.20 + 1000×5 + 2000×8 + 500×20 = 37,000 / 1e6
        XCTAssertEqual(ClaudePricing.cost(model: "claude-opus-5-5", tokens: tokens)?.usd ?? -1, 0.037, accuracy: 1e-9)
        // Sonnet の読み込みは $0.10。1000×2 + 10000×0.10 + 1000×2.5 + 2000×4 + 500×10 = 18,500
        XCTAssertEqual(ClaudePricing.cost(model: "claude-sonnet-5-5", tokens: tokens)?.usd ?? -1, 0.0185, accuracy: 1e-9)
        XCTAssertNil(ClaudePricing.cost(model: "gpt-6.1-sol", tokens: tokens))
        // 内訳が無い時は要求した TTL の書き込みとして数え、推定だと分かるようにする。
        let estimated = ClaudePricing.Tokens(usage: ["cache_creation_input_tokens": 3_000], assumedWriteTTL: "1h")
        XCTAssertEqual(estimated.cacheWrite1h, 3_000)
        XCTAssertTrue(estimated.writeSplitEstimated)
    }

    func testHaikuTierIsChosenPerRequestFromTheWholePrompt() throws {
        // 入力の合計 = 通常 1,000 + 読み込み 99,000 + 書き込み 1,000 = 101,000 > 100,000 → 全単価が高い側。
        let over = ClaudePricing.Tokens(usage: ["input_tokens": 1_000, "cache_read_input_tokens": 99_000, "cache_creation_input_tokens": 1_000,
                                                "cache_creation": ["ephemeral_5m_input_tokens": 1_000], "output_tokens": 100])
        let overCost = try XCTUnwrap(ClaudePricing.cost(model: "claude-haiku-5-5", tokens: over))
        XCTAssertEqual(overCost.tier, "over_100000")
        XCTAssertEqual(overCost.usd, (1_000 * 0.50 + 99_000 * 0.05 + 1_000 * 0.625 + 100 * 2.50) / 1e6, accuracy: 1e-9)
        // ちょうど 10 万までは低い側。
        let at = ClaudePricing.Tokens(usage: ["input_tokens": 100_000, "output_tokens": 100])
        let atCost = try XCTUnwrap(ClaudePricing.cost(model: "claude-haiku-5-5", tokens: at))
        XCTAssertEqual(atCost.tier, "base")
        XCTAssertEqual(atCost.usd, (100_000 * 0.10 + 100 * 0.50) / 1e6, accuracy: 1e-9)
    }

    func testTurnCostSumsRequestsAndDoesNotTreatMissingCostsAsZero() {
        let complete = ClaudeRequestLog.turnCost([["estimated_cost_usd": 0.01], ["estimated_cost_usd": 0.02], ["cost_status": "not_billed"]])
        XCTAssertEqual(complete.usd ?? -1, 0.03, accuracy: 1e-9)
        XCTAssertEqual(complete.status, "complete")
        let partial = ClaudeRequestLog.turnCost([["estimated_cost_usd": 0.01], ["cost_status": "usage_unavailable"]])
        XCTAssertEqual(partial.status, "partial")
        let unknown = ClaudeRequestLog.turnCost([["cost_status": "usage_unavailable"]])
        XCTAssertNil(unknown.usd)
        XCTAssertEqual(unknown.status, "unavailable")
    }

    // MARK: - Request log

    func testRequestsAreGroupedPerTurnAndClassified() {
        let log = ClaudeRequestLog()
        let first = request(input: Array(userTurn.prefix(2)))
        XCTAssertEqual(log.classify(request: first).reason, .turnStart)
        // tool の結果を受けた続き。
        XCTAssertEqual(log.classify(request: request(input: userTurn)).reason, .continuation)
        // Codex が同じ入力を送り直した。
        XCTAssertEqual(log.classify(request: request(input: userTurn)).reason, .codexRetry)
        XCTAssertEqual(log.classify(request: request(input: userTurn, kind: "compaction")).reason, .compaction)
        // 別のターンは最初から。
        let next = log.classify(request: request(input: userTurn, turnID: "turn_2"))
        XCTAssertEqual(next.reason, .turnStart)
        XCTAssertEqual(next.key, .init(threadID: "thr_1", turnID: "turn_2"))

        log.append(["reason": "turn_start", "estimated_cost_usd": 0.01], key: .init(threadID: "thr_1", turnID: "turn_1"))
        log.append(["reason": "continuation", "estimated_cost_usd": 0.02], key: .init(threadID: "thr_1", turnID: "turn_1"))
        XCTAssertEqual(log.take(threadID: "thr_1", turnID: "turn_1").map { $0["reason"] as? String }, ["turn_start", "continuation"])
        XCTAssertTrue(log.take(threadID: "thr_1", turnID: "turn_1").isEmpty)
    }

    func testThinkingRejectionsSeparateSignatureMismatchFromOtherErrors() {
        XCTAssertEqual(ClaudeThinkingRejection.classify("messages.3.content.0: Invalid `signature` in `thinking` block."), .signatureMismatch)
        XCTAssertEqual(ClaudeThinkingRejection.classify("The block is bound to a different conversation."), .signatureMismatch)
        XCTAssertEqual(ClaudeThinkingRejection.classify("thinking.type: Input should be 'adaptive'"), .other)
    }

    func testCacheStateSeparatesExpiryFromChangedRequests() {
        var hit = ClaudePricing.Tokens()
        hit.cacheRead = 900
        XCTAssertEqual(ClaudeCacheDiagnosis.state(diagnosis: "no_divergence", tokens: hit), "hit")
        var cold = ClaudePricing.Tokens()
        cold.cacheWrite1h = 900
        XCTAssertEqual(ClaudeCacheDiagnosis.state(diagnosis: "no_divergence", tokens: cold), "expired")
        XCTAssertEqual(ClaudeCacheDiagnosis.state(diagnosis: "tools_changed", tokens: cold), "tools_changed")
        XCTAssertEqual(ClaudeCacheDiagnosis.state(diagnosis: nil, tokens: cold), "cold")
        XCTAssertEqual(ClaudeCacheDiagnosis.summarize(["cache_miss_reason": ["type": "system_changed", "cache_missed_input_tokens": 12]]) as? [String: AnyHashable],
                       ["result": "system_changed", "cache_missed_input_tokens": 12])
        XCTAssertEqual(ClaudeCacheDiagnosis.summarize(["cache_miss_reason": NSNull()]) as? [String: String], ["result": "pending"])
    }

    func testThinkingTokensArePassedOnlyWhenClaudeReportsThem() throws {
        func completed(_ deltaUsage: [String: Any]) -> [String: Any]? {
            let translator = ClaudeStreamTranslator(tools: ClaudeToolNames(responsesTools: []), responseID: "resp_t")
            var out: [[String: Any]] = []
            out += translator.consume(["type": "message_start", "message": ["id": "msg_1", "model": "claude-opus-5-5",
                                                                           "usage": ["input_tokens": 10, "cache_creation": ["ephemeral_1h_input_tokens": 5]]]])
            out += translator.consume(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])
            out += translator.consume(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "hi"]])
            out += translator.consume(["type": "content_block_stop", "index": 0])
            out += translator.consume(["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": deltaUsage])
            out += translator.consume(["type": "message_stop"])
            XCTAssertEqual(translator.messageID, "msg_1")
            // message_start の内訳(TTL ごとの書き込み)は、message_delta の後も残る。
            XCTAssertNotNil(translator.rawUsage["cache_creation"])
            return (out.first { $0["type"] as? String == "response.completed" }?["response"] as? [String: Any])?["usage"] as? [String: Any]
        }
        let reported = try XCTUnwrap(completed(["output_tokens": 30, "output_tokens_details": ["thinking_tokens": 12]]))
        XCTAssertEqual((reported["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int, 12)
        let missing = try XCTUnwrap(completed(["output_tokens": 30]))
        XCTAssertNil(missing["output_tokens_details"], "内訳が無い時に 0 を入れない")
    }

    // MARK: - Ledger summary

    func testSummaryUsesPerRequestCostsAndTheModelThatAnswered() {
        let turns: [LedgerJSON] = [LedgerJSON(any: [[
            "execution_id": "a", "requested_model": "claude-opus-5-5", "turn_tokens": ["input_tokens": 999, "output_tokens": 9],
            "requests": [
                ["reason": "turn_start", "requested_model": "claude-opus-5-5", "actual_model": "claude-opus-5-5", "estimated_cost_usd": 0.01,
                 "tokens": ["input": 100, "cache_read": 1_000, "cache_write_5m": 0, "cache_write_1h": 500, "output": 50]],
                ["reason": "validation_repair", "requested_model": "claude-opus-5-5", "actual_model": "claude-opus-5-5", "estimated_cost_usd": 0.002,
                 "tokens": ["input": 10, "cache_read": 1_500, "cache_write_5m": 0, "cache_write_1h": 60, "output": 20]],
                ["reason": "auth_retry", "requested_model": "claude-opus-5-5", "cost_status": "not_billed"],
                ["reason": "continuation", "requested_model": "claude-opus-5-5", "cost_status": "usage_unavailable"],
            ],
        ]])]
        let summary = TokenUsageSummary.summarize(turns)
        let opus = summary.models[0]
        XCTAssertEqual(opus.model, "claude-opus-5-5")
        XCTAssertEqual(opus.executions, 1)
        XCTAssertEqual(opus.requests, 4)
        XCTAssertEqual(opus.extraRequests, 3)
        XCTAssertEqual(opus.inputTokens, 100 + 1_000 + 500 + 10 + 1_500 + 60)
        XCTAssertEqual(opus.cachedInputTokens, 2_500)
        XCTAssertEqual(opus.cacheWrite1hTokens, 560)
        XCTAssertEqual(opus.outputTokens, 70)
        XCTAssertEqual(opus.estimatedCostUSD ?? -1, 0.012, accuracy: 1e-9)
        XCTAssertTrue(opus.costIncomplete)
    }
}
