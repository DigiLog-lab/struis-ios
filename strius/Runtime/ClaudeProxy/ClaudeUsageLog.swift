import CryptoKit
import Foundation

/// Claude の料金表(USD / 100 万トークン)。料金は要求ごとに、応答で実際に使われたモデルで計算する。
///
/// Haiku 5.5 は 1 回の要求の入力の合計(通常入力・キャッシュ読み込み・書き込み)が 10 万を超えると、その要求の
/// 単価がすべて高い側になる。ターンの合計ではなく要求ごとに段階を選び、計算してから足す。
nonisolated enum ClaudePricing {
    /// 料金表の版。単価を変えたら上げる(台帳に残した概算がどの単価で計算されたかを後から追えるように)。
    static let version = "anthropic-2026-10-13"

    nonisolated struct Rates: Equatable, Sendable {
        let input: Double
        let cacheWrite5m: Double
        let cacheWrite1h: Double
        let cacheRead: Double
        let output: Double
    }

    nonisolated struct Table: Sendable {
        let base: Rates
        /// 入力の合計がこれを超えた要求に使う単価(nil: 段階なし)。
        let longContext: (threshold: Int, rates: Rates)?
    }

    static let tables: [String: Table] = [
        "claude-opus-5-5": Table(base: Rates(input: 4, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.20, output: 20), longContext: nil),
        "claude-sonnet-5-5": Table(base: Rates(input: 2, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.10, output: 10), longContext: nil),
        "claude-haiku-5-5": Table(base: Rates(input: 0.10, cacheWrite5m: 0.125, cacheWrite1h: 0.20, cacheRead: 0.01, output: 0.50),
                                  longContext: (100_000, Rates(input: 0.50, cacheWrite5m: 0.625, cacheWrite1h: 1, cacheRead: 0.05, output: 2.50))),
    ]

    /// Anthropic の `usage` を、料金の計算に使う形に分ける。
    nonisolated struct Tokens: Equatable, Sendable {
        var input = 0
        var cacheRead = 0
        var cacheWrite5m = 0
        var cacheWrite1h = 0
        var output = 0
        /// `cache_creation` の内訳が無かった(書き込みの TTL を要求した側から推定した)。
        var writeSplitEstimated = false

        var promptTotal: Int { input + cacheRead + cacheWrite5m + cacheWrite1h }

        /// `cache_creation` の内訳が無い時は、要求した TTL(`assumedWriteTTL`)の書き込みとして数える。
        init(usage: [String: Any], assumedWriteTTL: String = "5m") {
            input = Self.int(usage["input_tokens"])
            cacheRead = Self.int(usage["cache_read_input_tokens"])
            output = Self.int(usage["output_tokens"])
            let written = Self.int(usage["cache_creation_input_tokens"])
            if let split = usage["cache_creation"] as? [String: Any] {
                cacheWrite5m = Self.int(split["ephemeral_5m_input_tokens"])
                cacheWrite1h = Self.int(split["ephemeral_1h_input_tokens"])
            } else if written > 0 {
                writeSplitEstimated = true
                if assumedWriteTTL == "1h" { cacheWrite1h = written } else { cacheWrite5m = written }
            }
        }

        init() {}

        static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? (value as? Int) ?? 0 }
    }

    /// 1 回の要求の概算料金。料金表に無いモデルは nil。100 万分の 1 ドルに丸める。
    /// `tiered: false` は段階を選ばない(1 回ごとの入力量が分からない、この版より前のターンの合計の見直し用)。
    static func cost(model: String, tokens: Tokens, tiered: Bool = true) -> (usd: Double, tier: String)? {
        guard let table = tables[model] else { return nil }
        var rates = table.base
        var tier = "base"
        if tiered, let long = table.longContext, tokens.promptTotal > long.threshold {
            rates = long.rates
            tier = "over_\(long.threshold)"
        }
        let micro = Double(tokens.input) * rates.input + Double(tokens.cacheRead) * rates.cacheRead
            + Double(tokens.cacheWrite5m) * rates.cacheWrite5m + Double(tokens.cacheWrite1h) * rates.cacheWrite1h
            + Double(tokens.output) * rates.output
        return ((micro).rounded() / 1_000_000, tier)
    }
}

/// 追加の要求が送られた理由(実行監査 `requests[].reason`)。
nonisolated enum ClaudeRequestReason: String, Sendable {
    /// ターンの最初の要求。
    case turnStart = "turn_start"
    /// Struis の検証で返事の約束事を直させる回(進捗・記憶・出題データの修正)の最初の要求。
    case validationRepair = "validation_repair"
    /// 同じターンの中で、モデルの作業(tool の結果を受けた続き)が残っている。
    case continuation
    /// App Attest の token を取り直して送り直した。
    case authRetry = "auth_retry"
    /// 署名の合わない thinking を外して送り直した。
    case thinkingStripRetry = "thinking_strip_retry"
    /// schema を指示文に移して送り直した。
    case schemaRetry = "schema_retry"
    /// cache diagnostics の指定を外して送り直した。
    case diagnosticsRetry = "diagnostics_retry"
    /// Codex が同じ入力をもう一度送った(通信・ストリームの再試行)。
    case codexRetry = "codex_retry"
    /// Codex の自動要約(compaction)。
    case compaction
}

/// Claude への要求 1 回ごとの記録。端末内のプロキシが書き、ターンの終わりに `CodexTurnRunner` が実行監査に移す。
///
/// Codex は Responses の要求の `client_metadata` に `thread_id`・`turn_id` を入れて送るので、それで束ねる。
nonisolated final class ClaudeRequestLog: @unchecked Sendable {
    static let shared = ClaudeRequestLog()

    nonisolated struct Key: Hashable, Sendable {
        let threadID: String
        let turnID: String
    }

    private let lock = NSLock()
    private var records: [Key: [AnySendable]] = [:]
    private var order: [Key] = []
    /// 同じターンの直前の要求の入力(Codex の再試行を見分ける)。
    private var lastInput: [Key: String] = [:]
    /// スレッドごとの直前の応答 ID(cache diagnostics の `previous_message_id`)。
    private var lastResponse: [String: String] = [:]
    static let keptTurns = 200

    /// Codex の要求から、記録の束ね先と、この要求を送った理由を決める。
    func classify(request: [String: Any]) -> (key: Key?, reason: ClaudeRequestReason) {
        let metadata = request["client_metadata"] as? [String: Any] ?? [:]
        let thread = metadata["thread_id"] as? String
        let turn = metadata["turn_id"] as? String
        if metadata["request_kind"] as? String == "compaction" {
            return (thread.map { Key(threadID: $0, turnID: turn ?? "") }, .compaction)
        }
        guard let thread else { return (nil, .turnStart) }
        let key = Key(threadID: thread, turnID: turn ?? "")
        let fingerprint = Self.fingerprint(request["input"])
        return lock.withLock {
            defer { lastInput[key] = fingerprint }
            guard let previous = lastInput[key] else { return (key, .turnStart) }
            return (key, previous == fingerprint ? .codexRetry : .continuation)
        }
    }

    func append(_ record: [String: Any], key: Key?) {
        guard let key else { return }
        lock.withLock {
            if records[key] == nil {
                order.append(key)
                if order.count > Self.keptTurns {
                    let dropped = order.removeFirst()
                    records[dropped] = nil
                    lastInput[dropped] = nil
                }
            }
            records[key, default: []].append(AnySendable(record))
        }
    }

    /// そのターンの記録を取り出す(取り出したら消える)。
    func take(threadID: String, turnID: String) -> [[String: Any]] {
        let key = Key(threadID: threadID, turnID: turnID)
        return lock.withLock {
            let taken = records.removeValue(forKey: key) ?? []
            order.removeAll { $0 == key }
            lastInput[key] = nil
            return taken.compactMap { $0.value as? [String: Any] }
        }
    }

    func previousResponseID(threadID: String) -> String? { lock.withLock { lastResponse[threadID] } }

    func setPreviousResponseID(_ id: String?, threadID: String) {
        lock.withLock { lastResponse[threadID] = id }
    }

    static func fingerprint(_ input: Any?) -> String {
        guard let input, JSONSerialization.isValidJSONObject(["i": input]),
              let data = try? JSONSerialization.data(withJSONObject: ["i": input], options: [.sortedKeys]) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 実行監査の要求ごとの記録から、ターンの料金を足す。料金を出せない要求(料金表に無いモデル・使用量の無い失敗)が
    /// あれば `partial`、1 つも出せなければ `unavailable`(0 ドルとは扱わない)。
    static func turnCost(_ requests: [[String: Any]]) -> (usd: Double?, status: String) {
        var total = 0.0
        var priced = 0
        var unpriced = 0
        for request in requests {
            if let cost = request["estimated_cost_usd"] as? Double {
                total += cost
                priced += 1
            } else if request["cost_status"] as? String != "not_billed" {
                unpriced += 1
            }
        }
        if priced == 0 { return (unpriced == 0 ? 0 : nil, unpriced == 0 ? "no_billed_requests" : "unavailable") }
        return ((total * 1_000_000).rounded() / 1_000_000, unpriced == 0 ? "complete" : "partial")
    }
}
