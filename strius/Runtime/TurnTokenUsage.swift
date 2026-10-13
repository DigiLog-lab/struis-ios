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

    /// Claude の料金(USD / 100 万トークン)。入力・出力・キャッシュ読み出し・キャッシュ書き込み(5 分)。
    /// GPT は ChatGPT のプランの枠で動くため料金を出さない。
    nonisolated struct Rates: Sendable {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
    }

    static let claudeRates: [String: Rates] = [
        "claude-opus-5-5": Rates(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5),
        "claude-sonnet-5-5": Rates(input: 2, output: 10, cacheRead: 0.20, cacheWrite: 2.5),
        "claude-haiku-5-5": Rates(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125),
    ]

    /// 概算料金。料金表に無いモデルは nil。100 万分の 1 ドル単位に丸める。
    static func estimatedCostUSD(model: String, tokens: JSONObject) -> Double? {
        guard let rates = claudeRates[model] else { return nil }
        let input = number(tokens["input_tokens"])
        let cached = number(tokens["cached_input_tokens"])
        let written = number(tokens["cache_write_input_tokens"])
        let uncached = max(0, input - cached - written)
        let cost = (Double(uncached) * rates.input + Double(cached) * rates.cacheRead + Double(written) * rates.cacheWrite
            + Double(number(tokens["output_tokens"])) * rates.output) / 1_000_000
        return (cost * 1_000_000).rounded() / 1_000_000
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
        var estimatedCostUSD: Double?
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
