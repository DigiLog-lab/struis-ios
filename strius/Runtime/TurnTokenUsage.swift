import Foundation

/// 1 ターンのトークン数と、Claude の概算料金(実行監査 `turns.executions` の `turn_tokens`・`estimated_cost_usd`)。
///
/// Codex の `thread/tokenUsage/updated` はスレッドの累計(`total`)と直前の 1 回の要求(`last`)を送る。ターンの最初の通知の
/// 時点の累計から、そのターンの最初の要求分を引いたものがターン前の累計なので、
/// ターンの使用量 = 最新の累計 − (最初の通知の累計 − 最初の通知の last)。同じ通知が重なっても二重に数えない。
nonisolated enum TurnTokenUsage {
    /// 記録するトークンの種類(`input_tokens` は cached・cache write を含む)。
    static let fields: [(key: String, wire: String)] = [
        ("input_tokens", "inputTokens"),
        ("cached_input_tokens", "cachedInputTokens"),
        ("cache_write_input_tokens", "cacheWriteInputTokens"),
        ("output_tokens", "outputTokens"),
        ("reasoning_output_tokens", "reasoningOutputTokens"),
        ("total_tokens", "totalTokens"),
    ]

    static func turnTokens(first: JSONObject, latest: JSONObject) -> JSONObject {
        let firstTotal = first["total"] as? JSONObject ?? [:]
        let firstLast = first["last"] as? JSONObject ?? [:]
        let latestTotal = latest["total"] as? JSONObject ?? [:]
        var result: JSONObject = [:]
        for field in fields {
            let value = number(latestTotal[field.wire]) - number(firstTotal[field.wire]) + number(firstLast[field.wire])
            result[field.key] = max(0, value)
        }
        return result
    }

    /// ターンの合計からの概算(要求ごとの記録が無い、この版より前の記録の見直し用)。書き込みは 5 分として数え、
    /// Haiku の段階は選ばない(段階は要求 1 回の入力量で決まり、ターンの合計からは分からない)。
    /// 料金表に無いモデル(GPT は ChatGPT のプランの枠で動く)は nil。要求ごとの料金は `ClaudePricing` で計算する。
    static func estimatedCostUSD(model: String, tokens: JSONObject) -> Double? {
        let input = number(tokens["input_tokens"])
        let cached = number(tokens["cached_input_tokens"])
        let written = number(tokens["cache_write_input_tokens"])
        var split = ClaudePricing.Tokens()
        split.input = max(0, input - cached - written)
        split.cacheRead = cached
        split.cacheWrite5m = written
        split.output = number(tokens["output_tokens"])
        return ClaudePricing.cost(model: model, tokens: split, tiered: false)?.usd
    }

    private static func number(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? (value as? Int) ?? 0
    }
}

/// 設定の「トークン使用量」: 台帳のターンの実行監査を、モデルごとに足し合わせる。
nonisolated struct TokenUsageSummary: Equatable, Sendable {
    nonisolated struct Model: Equatable, Sendable, Identifiable {
        var model: String
        var executions = 0
        var inputTokens = 0
        var cachedInputTokens = 0
        var cacheWriteInputTokens = 0
        var outputTokens = 0
        /// 要求ごとの記録がある実行の、キャッシュ書き込みの TTL ごとの内訳。
        var cacheWrite5mTokens = 0
        var cacheWrite1hTokens = 0
        /// Claude への要求の数と、そのうち最初の要求以外(検証修正・処理継続・再試行など)の数。
        var requests = 0
        var extraRequests = 0
        var estimatedCostUSD: Double?
        /// 料金を出せなかった実行・要求がある(合計は少なめに出ている)。
        var costIncomplete = false
        var id: String { model }
    }

    var models: [Model]
    var estimatedCostUSD: Double? { models.compactMap(\.estimatedCostUSD).isEmpty ? nil : models.compactMap(\.estimatedCostUSD).reduce(0, +) }

    static func summarize(_ turns: [LedgerJSON]) -> TokenUsageSummary {
        var byModel: [String: Model] = [:]
        for executions in turns {
            // 同じ実行は進行中・完了の順に記録される。実行ごとに最後の記録だけを数える。
            var latest: [String: LedgerJSON] = [:]
            var order: [String] = []
            for (index, execution) in (executions.arrayValue ?? []).enumerated() {
                let id = execution["execution_id"]?.stringValue ?? "#\(index)"
                if latest[id] == nil { order.append(id) }
                latest[id] = execution
            }
            for execution in order.compactMap({ latest[$0] }) {
                if let requests = execution["requests"]?.arrayValue, !requests.isEmpty {
                    // 要求ごとの記録: 応答で実際に使われたモデルごとに、要求の料金を足す。
                    for request in requests {
                        let name = request["actual_model"]?.stringValue ?? request["requested_model"]?.stringValue ?? "unknown"
                        var model = byModel[name] ?? Model(model: name)
                        model.requests += 1
                        if let reason = request["reason"]?.stringValue, reason != ClaudeRequestReason.turnStart.rawValue { model.extraRequests += 1 }
                        if let tokens = request["tokens"]?.objectValue {
                            let read = tokens["cache_read"]?.intValue ?? 0
                            let write5m = tokens["cache_write_5m"]?.intValue ?? 0
                            let write1h = tokens["cache_write_1h"]?.intValue ?? 0
                            model.inputTokens += (tokens["input"]?.intValue ?? 0) + read + write5m + write1h
                            model.cachedInputTokens += read
                            model.cacheWriteInputTokens += write5m + write1h
                            model.cacheWrite5mTokens += write5m
                            model.cacheWrite1hTokens += write1h
                            model.outputTokens += tokens["output"]?.intValue ?? 0
                        }
                        if case .number(let cost)? = request["estimated_cost_usd"] {
                            model.estimatedCostUSD = (model.estimatedCostUSD ?? 0) + cost
                        } else if request["cost_status"]?.stringValue != "not_billed" {
                            model.costIncomplete = true
                        }
                        byModel[name] = model
                    }
                    let name = execution["actual_model"]?.stringValue ?? execution["requested_model"]?.stringValue ?? "unknown"
                    byModel[name, default: Model(model: name)].executions += 1
                    continue
                }
                guard let tokens = execution["turn_tokens"]?.objectValue else { continue }
                let name = execution["actual_model"]?.stringValue ?? execution["requested_model"]?.stringValue ?? "unknown"
                var model = byModel[name] ?? Model(model: name)
                model.executions += 1
                model.inputTokens += tokens["input_tokens"]?.intValue ?? 0
                model.cachedInputTokens += tokens["cached_input_tokens"]?.intValue ?? 0
                model.cacheWriteInputTokens += tokens["cache_write_input_tokens"]?.intValue ?? 0
                model.outputTokens += tokens["output_tokens"]?.intValue ?? 0
                if case .number(let cost)? = execution["estimated_cost_usd"] { model.estimatedCostUSD = (model.estimatedCostUSD ?? 0) + cost }
                byModel[name] = model
            }
        }
        return TokenUsageSummary(models: byModel.values.sorted { $0.inputTokens + $0.outputTokens > $1.inputTokens + $1.outputTokens })
    }
}
