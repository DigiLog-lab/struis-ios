import XCTest
@testable import strius

/// ターンごとのトークン数(Codex の累計からの差分)と、Claude の概算料金・設定の集計。
final class TurnTokenUsageTests: XCTestCase {
    private func usage(total: [String: Int], last: [String: Int]) -> JSONObject {
        ["total": total, "last": last, "modelContextWindow": 272_000]
    }

    func testTurnTokensSubtractTheThreadTotalBeforeTheTurn() {
        // 前のターンまでの累計: input 1000 / cached 800 / output 100。このターンの要求は 2 回。
        let first = usage(total: ["inputTokens": 1500, "cachedInputTokens": 1200, "cacheWriteInputTokens": 200, "outputTokens": 150, "reasoningOutputTokens": 0, "totalTokens": 1650],
                          last: ["inputTokens": 500, "cachedInputTokens": 400, "cacheWriteInputTokens": 50, "outputTokens": 50, "reasoningOutputTokens": 0, "totalTokens": 550])
        let latest = usage(total: ["inputTokens": 2200, "cachedInputTokens": 1800, "cacheWriteInputTokens": 300, "outputTokens": 230, "reasoningOutputTokens": 0, "totalTokens": 2430],
                           last: ["inputTokens": 700, "cachedInputTokens": 600, "cacheWriteInputTokens": 100, "outputTokens": 80, "reasoningOutputTokens": 0, "totalTokens": 780])
        let tokens = TurnTokenUsage.turnTokens(first: first, latest: latest)
        XCTAssertEqual(tokens["input_tokens"] as? Int, 1200)
        XCTAssertEqual(tokens["cached_input_tokens"] as? Int, 1000)
        XCTAssertEqual(tokens["cache_write_input_tokens"] as? Int, 150)
        XCTAssertEqual(tokens["output_tokens"] as? Int, 130)
        XCTAssertEqual(tokens["total_tokens"] as? Int, 1330)
        // 同じ通知が重なっても変わらない。
        XCTAssertEqual(TurnTokenUsage.turnTokens(first: first, latest: first)["input_tokens"] as? Int, 500)
    }

    func testEstimatedCostUsesClaudeRatesAndSkipsGPT() {
        let tokens: JSONObject = ["input_tokens": 1_000_000, "cached_input_tokens": 600_000, "cache_write_input_tokens": 100_000, "output_tokens": 100_000]
        // 未キャッシュ 30 万 × $4 + 読み出し 60 万 × $0.20 + 書き込み 10 万 × $5 + 出力 10 万 × $20
        XCTAssertEqual(TurnTokenUsage.estimatedCostUSD(model: "claude-opus-5-5", tokens: tokens)!, 1.2 + 0.12 + 0.5 + 2.0, accuracy: 1e-9)
        XCTAssertEqual(TurnTokenUsage.estimatedCostUSD(model: "claude-haiku-5-5", tokens: tokens)!, 0.03 + 0.006 + 0.0125 + 0.05, accuracy: 1e-9)
        XCTAssertNil(TurnTokenUsage.estimatedCostUSD(model: "gpt-6.1-sol", tokens: tokens))
    }

    func testSummaryAddsTurnsPerModel() {
        let turns: [LedgerJSON] = [
            LedgerJSON(any: [["execution_id": "a", "requested_model": "claude-opus-5-5", "turn_tokens": ["input_tokens": 60, "output_tokens": 5], "estimated_cost_usd": 0.0005],
                             ["execution_id": "a", "requested_model": "claude-opus-5-5", "actual_model": NSNull(), "turn_tokens": ["input_tokens": 100, "cached_input_tokens": 50, "output_tokens": 10], "estimated_cost_usd": 0.001],
                             ["requested_model": "claude-haiku-5-5", "turn_tokens": ["input_tokens": 20, "output_tokens": 5], "estimated_cost_usd": 0.0001]]),
            LedgerJSON(any: [["requested_model": "claude-opus-5-5", "turn_tokens": ["input_tokens": 300, "output_tokens": 30], "estimated_cost_usd": 0.002],
                             ["requested_model": "gpt-6.1-sol", "turn_tokens": ["input_tokens": 40, "output_tokens": 4], "estimated_cost_usd": NSNull()],
                             ["requested_model": "claude-opus-5-5", "turn_tokens": NSNull()]]),
        ]
        let summary = TokenUsageSummary.summarize(turns)
        XCTAssertEqual(summary.models.map(\.model), ["claude-opus-5-5", "gpt-6.1-sol", "claude-haiku-5-5"])
        XCTAssertEqual(summary.models[0].executions, 2)
        XCTAssertEqual(summary.models[0].inputTokens, 400)
        XCTAssertEqual(summary.models[0].cachedInputTokens, 50)
        XCTAssertNil(summary.models[1].estimatedCostUSD)
        XCTAssertEqual(summary.estimatedCostUSD!, 0.0031, accuracy: 1e-9)
    }

    /// タイムラインの出題・採点・見直しの料金を、実際に使われたモデルごとに足して、そのモデルで採点した答案の数で割る。
    func testTimelineCostIsComparedPerAnswerForEachModel() {
        func request(_ model: String, _ cost: Double?) -> [String: Any] {
            ["requested_model": model, "actual_model": model, "estimated_cost_usd": cost.map { $0 as Any } ?? NSNull(), "cost_status": cost == nil ? "unknown_model" : "estimated"]
        }
        func execution(_ model: String, _ requests: [[String: Any]]) -> LedgerJSON {
            LedgerJSON(any: [["execution_id": "x", "requested_model": model, "actual_model": model, "requests": requests]])
        }
        let sonnet = "claude-sonnet-5-5", haiku = "claude-haiku-5-5"
        let turns: [TimelineCostSummary.Turn] = [
            .init(kind: "timeline_batch", targetID: "b1", status: "completed", executions: execution(sonnet, [request(sonnet, 0.02)])),
            .init(kind: "timeline_grading", targetID: "a1", status: "completed", executions: execution(sonnet, [request(sonnet, 0.03), request(sonnet, 0.01)])),
            .init(kind: "timeline_review", targetID: "a1", status: "completed", executions: execution(sonnet, [request(sonnet, 0.04)])),
            .init(kind: "timeline_grading", targetID: "a2", status: "completed", executions: execution(sonnet, [request(sonnet, 0.02)])),
            // 切り替えた後の答案。失敗した採点は答案に数えない(料金は数える)。
            .init(kind: "timeline_grading", targetID: "a3", status: "completed", executions: execution(haiku, [request(haiku, 0.002)])),
            .init(kind: "timeline_grading", targetID: "a4", status: "failed", executions: execution(haiku, [request(haiku, 0.001)])),
            // 知識グラフと会話は入れない。
            .init(kind: "timeline_graph", targetID: "g1", status: "completed", executions: execution("claude-opus-5-5", [request("claude-opus-5-5", 0.5)])),
            .init(kind: "chat", targetID: "c1", status: "completed", executions: execution(sonnet, [request(sonnet, 0.5)])),
        ]
        let summary = TimelineCostSummary.summarize(turns)
        XCTAssertEqual(summary.models.map(\.model), [haiku, sonnet])
        XCTAssertEqual(summary.models[1].answers, 2)
        XCTAssertEqual(summary.models[1].perAnswerUSD!, 0.12 / 2, accuracy: 1e-9)
        XCTAssertEqual(summary.models[0].answers, 1)
        XCTAssertEqual(summary.models[0].perAnswerUSD!, 0.003, accuracy: 1e-9)
        XCTAssertFalse(summary.models[0].costIncomplete)
    }
}
