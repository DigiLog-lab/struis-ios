import Foundation
import OSLog

private let usageLog = Logger(subsystem: "com.digiloglab.strius", category: "usage")

/// 任意の使用量報告 (design §5.1 / §8-4)。既定はオフ。設定画面のトグルがオンのときだけ、
/// 終わったターンの `executions`（モデル・所要時間・トークン数などの統計）を
/// `POST /v1/device-runtime/usage` に送る。本文・ファイルは送らない。
@MainActor
final class UsageReporter {
    static let defaultsKey = "struis.usageReporting.enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Only statistics cross the device boundary. The local audit may also contain
    /// commands, paths, errors, and future fields, so a denylist is insufficient.
    nonisolated static let modelKeys: Set<String> = ["requested_model", "resolved_model", "actual_model"]
    nonisolated static let effortKeys: Set<String> = ["requested_effort", "resolved_effort", "actual_effort"]
    nonisolated static let efforts: Set<String> = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    nonisolated static let statuses: Set<String> = ["starting", "in_progress", "completed", "failed", "interrupted"]
    nonisolated static let taskTypes: Set<String> = ["chat", "workbook_grading", "workbook_set", "workbook_unit", "thread_fork", "thread_inject", "luna_lookup", "material_search", "fact_extraction"]
    nonisolated static let tokenKeys: Set<String> = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens", "inputTokens", "cachedInputTokens", "cacheWriteInputTokens", "outputTokens", "reasoningOutputTokens", "totalTokens", "modelContextWindow"]
    nonisolated static let finishedStatuses: Set<String> = ["completed", "failed", "interrupted"]

    private let ledger: Ledger
    private let client: APIClient
    private var observer: UUID?
    private var reported = Set<String>()

    init(ledger: Ledger, client: APIClient) {
        self.ledger = ledger
        self.client = client
    }

    func start() async {
        guard observer == nil else { return }
        observer = await ledger.observe { [weak self] events in
            let finished = events.filter { $0.entity == .turns && Self.finishedStatuses.contains($0.payload["status"]?.stringValue ?? "") }
            guard !finished.isEmpty else { return }
            Task { @MainActor [weak self] in
                for event in finished { await self?.report(turnID: event.entityID, turn: event.payload) }
            }
        }
    }

    private func report(turnID: String, turn: LedgerJSON) async {
        guard Auth0Config.authenticationRequired, Self.isEnabled, !reported.contains(turnID) else { return }
        let executions = Self.sanitized(turn["executions"]?.arrayValue ?? [])
        guard !executions.isEmpty else { return }
        reported.insert(turnID)
        do {
            let _: [String: Int] = try await client.send(
                APIEndpoint(method: .post, path: "/v1/device-runtime/usage"), body: Payload(executions: executions)
            )
        } catch {
            usageLog.error("usage report failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Preserve known scalar statistics and token counters; omit everything else,
    /// including unknown keys nested inside otherwise allowed usage objects.
    nonisolated static func sanitized(_ executions: [LedgerJSON]) -> [LedgerJSON] {
        func counter(_ value: LedgerJSON) -> LedgerJSON? {
            if case .null = value { return value }
            guard case .number(let number) = value, number.isFinite, number >= 0,
                  number <= 9_007_199_254_740_991, number.rounded(.towardZero) == number else { return nil }
            return value
        }
        func tokens(_ value: LedgerJSON, allowGroups: Bool) -> LedgerJSON? {
            if case .null = value { return value }
            guard let object = value.objectValue else { return nil }
            var result: [String: LedgerJSON] = [:]
            for (key, value) in object {
                if tokenKeys.contains(key) { result[key] = counter(value) }
                else if allowGroups && ["last", "total"].contains(key) {
                    result[key] = tokens(value, allowGroups: false)
                }
            }
            return .object(result)
        }
        return executions.prefix(50).compactMap { execution in
            guard let object = execution.objectValue else { return nil }
            var result: [String: LedgerJSON] = [:]
            for (key, value) in object {
                if modelKeys.contains(key) {
                    if case .null = value { result[key] = value }
                    else if let model = value.stringValue, model.count <= 128,
                            model.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*\\z", options: .regularExpression) != nil {
                        result[key] = value
                    }
                } else if effortKeys.contains(key) {
                    if case .null = value { result[key] = value }
                    else if let effort = value.stringValue, efforts.contains(effort) { result[key] = value }
                } else if key == "status", let status = value.stringValue, statuses.contains(status) {
                    result[key] = value
                } else if key == "task_type", let task = value.stringValue, taskTypes.contains(task) {
                    result[key] = value
                } else if key == "elapsed_ms" { result[key] = counter(value) }
                else if key == "usage" { result[key] = tokens(value, allowGroups: true) }
                else if key == "turn_tokens" { result[key] = counter(value) ?? tokens(value, allowGroups: false) }
            }
            return .object(result)
        }
    }

    private struct Payload: Encodable {
        let executions: [LedgerJSON]
    }
}
