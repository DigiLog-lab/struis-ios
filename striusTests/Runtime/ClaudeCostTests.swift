import XCTest
@testable import strius

/// Claude の費用削減: 変換方式の版(キャッシュの印と TTL)、要求ごとの料金と記録、送り直しの理由。
/// 要求の本文の形(system・末尾の印・tools の順)は `ClaudeTurnRunnerTests` が模擬の Anthropic に届いた要求で確かめる。
final class ClaudeCostTests: XCTestCase {
    // MARK: - Translation versions

    func testTailTTLFollowsTheTaskGroupAndTheFixedInstructionsAreCachedForAnHour() {
        // 解答を考えて撮影する継続会話は 1 時間、一度で終わる処理は 5 分。
        XCTAssertEqual(ClaudeTranslation.tailCacheTTL(kind: "chat"), "1h")
        XCTAssertEqual(ClaudeTranslation.tailCacheTTL(kind: "thread_fork"), "1h")
        XCTAssertEqual(ClaudeTranslation.tailCacheTTL(kind: "workbook_grading"), "5m")
        XCTAssertEqual(ClaudeTranslation.tailCacheTTL(kind: "timeline_grading"), "5m")
        XCTAssertEqual(ClaudeTranslation.tailCacheTTL(kind: nil), "5m")
        // 5 分は既定なので ttl を書かない(書くと別の印になる)。
        XCTAssertEqual(ClaudeTranslation.cacheControl(ttl: "1h") as? [String: String], ["type": "ephemeral", "ttl": "1h"])
        XCTAssertEqual(ClaudeTranslation.cacheControl(ttl: "5m") as? [String: String], ["type": "ephemeral"])
        XCTAssertEqual(ClaudeTranslation.cacheControl(ttl: nil) as? [String: String], ["type": "ephemeral"])
        // system の印の TTL(実行監査の記録): 版 4 と版 2 は 1 時間、版 3 は末尾と同じ、版 1 は印なし。
        XCTAssertEqual(ClaudeTranslation.systemCacheTTL(translation: 4, tail: "5m"), "1h")
        XCTAssertEqual(ClaudeTranslation.systemCacheTTL(translation: 3, tail: "5m"), "5m")
        XCTAssertEqual(ClaudeTranslation.systemCacheTTL(translation: 2, tail: "5m"), "1h")
        XCTAssertNil(ClaudeTranslation.systemCacheTTL(translation: 1, tail: "5m"))
    }

    func testTimelineThreadsStartOnVersionFourAndMarkTheTailOnlyAfterATool() {
        XCTAssertEqual(ClaudeTranslation.version(kind: "chat"), ClaudeTranslation.current)
        XCTAssertEqual(ClaudeTranslation.version(kind: "workbook_set"), 2)
        for kind in ["timeline_batch", "timeline_grading", "timeline_review"] {
            XCTAssertEqual(ClaudeTranslation.version(kind: kind), ClaudeTranslation.tutor, kind)
        }
        let first: [[String: Any]] = [["role": "user", "content": [["type": "text", "text": "今日の分"]]]]
        let afterTool: [[String: Any]] = first + [
            ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_1", "name": "view_image", "input": [String: Any]()]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"]]],
        ]
        // 版 4 の最初の要求は末尾に印を置かない(依頼をまたいで残す先頭は system の 1 時間の印)。
        XCTAssertFalse(ClaudeTranslation.marksTail(translation: 4, messages: first))
        XCTAssertTrue(ClaudeTranslation.marksTail(translation: 4, messages: afterTool))
        XCTAssertFalse(ClaudeTranslation.marksTail(translation: 4, messages: []))
        // 版 2 以前は毎回置く。
        XCTAssertTrue(ClaudeTranslation.marksTail(translation: 2, messages: first))
        // cache diagnostics は、タイムラインの依頼どうし(同じモデル)で比べる。
        XCTAssertEqual(ClaudeTranslation.diagnosticsKey(threadID: "t1", kind: "chat", model: "claude-opus-5-5"), "t1")
        XCTAssertEqual(ClaudeTranslation.diagnosticsKey(threadID: "t1", kind: "timeline_grading", model: "claude-opus-5-5"), "timeline-tutor:claude-opus-5-5")
        XCTAssertEqual(ClaudeTranslation.diagnosticsKey(threadID: "t2", kind: "timeline_review"), "timeline-tutor")
    }

    func testSchemaInstructionWritesTheSchemaWithSortedKeys() {
        let schema: [String: Any] = ["type": "object", "required": ["ok"], "properties": ["ok": ["type": "boolean"]]]
        XCTAssertEqual(ClaudeTranslation.schemaInstruction(schema),
                       "Answer with exactly one JSON object and nothing else. It must validate against this JSON Schema:\n"
                       + #"{"properties":{"ok":{"type":"boolean"}},"required":["ok"],"type":"object"}"#)
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

    func testRequestsAreGroupedPerTurnAndTakenOnce() {
        let log: ClaudeRequestLog = ClaudeRequestLog()
        log.append(["reason": ClaudeRequestReason.turnStart.rawValue, "estimated_cost_usd": 0.01], key: .init(threadID: "thr_1", turnID: "turn_1"))
        log.append(["reason": ClaudeRequestReason.retry.rawValue], key: .init(threadID: "thr_1", turnID: "turn_2"))
        log.append(["reason": ClaudeRequestReason.continuation.rawValue, "estimated_cost_usd": 0.02], key: .init(threadID: "thr_1", turnID: "turn_1"))
        log.append(["reason": "ignored"], key: nil)
        XCTAssertEqual(log.take(threadID: "thr_1", turnID: "turn_1").map { $0["reason"] as? String }, ["turn_start", "continuation"])
        XCTAssertTrue(log.take(threadID: "thr_1", turnID: "turn_1").isEmpty)
        XCTAssertEqual(log.take(threadID: "thr_1", turnID: "turn_2").map { $0["reason"] as? String }, ["retry"])
        log.setPreviousResponseID("msg_1", threadID: "thr_1")
        XCTAssertEqual(log.previousResponseID(threadID: "thr_1"), "msg_1")
        XCTAssertNil(log.previousResponseID(threadID: "thr_2"))
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

    func testThinkingTokensAreRecordedOnlyWhenClaudeReportsThem() throws {
        func finished(_ deltaUsage: [String: Any]) -> [String: Any] {
            let status: ClaudeStreamStatus = ClaudeStreamStatus()
            status.consume(["type": "message_start", "message": ["id": "msg_1", "model": "claude-opus-5-5",
                                                                 "usage": ["input_tokens": 10, "cache_creation": ["ephemeral_1h_input_tokens": 5]]]])
            status.consume(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])
            status.consume(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "hi"]])
            status.consume(["type": "content_block_stop", "index": 0])
            status.consume(["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": deltaUsage])
            XCTAssertFalse(status.isFinished)
            status.consume(["type": "message_stop"])
            XCTAssertTrue(status.isFinished)
            XCTAssertEqual(status.messageID, "msg_1")
            XCTAssertEqual(status.model, "claude-opus-5-5")
            XCTAssertEqual(status.stopReason, "end_turn")
            XCTAssertNil(status.errorType)
            // message_start の内訳(TTL ごとの書き込み)は、message_delta の後も残る。
            XCTAssertNotNil(status.rawUsage["cache_creation"])
            var attempt: ClaudeRequestAttempt = ClaudeRequestAttempt(reason: .turnStart, model: "claude-opus-5-5", translation: 2, tailTTL: "1h",
                                                                     options: ClaudeRequestOptions())
            return attempt.finish(status: "completed", translator: status, httpStatus: 200, error: nil)
        }
        let reported: [String: Any] = finished(["output_tokens": 30, "output_tokens_details": ["thinking_tokens": 12]])
        XCTAssertEqual(reported["thinking_tokens"] as? Int, 12)
        XCTAssertEqual(reported["thinking_breakdown"] as? String, "reported")
        XCTAssertEqual((reported["tokens"] as? [String: Any])?["cache_write_1h"] as? Int, 5)
        XCTAssertEqual(reported["cost_status"] as? String, "estimated")
        let missing: [String: Any] = finished(["output_tokens": 30])
        XCTAssertTrue(missing["thinking_tokens"] is NSNull, "内訳が無い時に 0 を入れない")
        XCTAssertEqual(missing["thinking_breakdown"] as? String, "unavailable")
    }

    func testStreamErrorsAndRejectedRequestsAreNotBilled() {
        let status: ClaudeStreamStatus = ClaudeStreamStatus()
        status.consume(["type": "error", "error": ["type": "overloaded_error", "message": "busy"]])
        XCTAssertTrue(status.isFinished)
        XCTAssertEqual(status.errorType, "overloaded_error")
        // 拒まれた要求(4xx)は課金されない。
        var rejected: ClaudeRequestAttempt = ClaudeRequestAttempt(reason: .retry, model: "claude-opus-5-5", translation: 2, tailTTL: "5m",
                                                                  options: ClaudeRequestOptions())
        let record: [String: Any] = rejected.finish(status: "http_error", translator: nil, httpStatus: 400, error: ("invalid_request_error", "bad"))
        XCTAssertEqual(record["reason"] as? String, "retry")
        XCTAssertEqual(record["cost_status"] as? String, "not_billed")
        XCTAssertTrue(record["estimated_cost_usd"] is NSNull)
        XCTAssertEqual(ClaudeRequestAttempt.status(stopReason: "refusal"), "refusal")
        XCTAssertEqual(ClaudeRequestAttempt.status(stopReason: "model_context_window_exceeded"), "context_window_exceeded")
        XCTAssertEqual(ClaudeRequestAttempt.status(stopReason: "end_turn"), "completed")
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
