import Foundation

/// 本体のタイムアタックの送り口: タイムラインと同じ Claude の経路(実機は App Attest、DEBUG の Simulator は API キー)で、
/// 利用枠を確かめてから送り、使った金額を枠に数える。出題は新しい作業、読み取りは途中の答案の採点として扱う。
nonisolated struct AppTimeAttackTransport: TimeAttackTransport {
    var upstream = ClaudeUpstream()

    enum Failure: Error, LocalizedError {
        case usage(UsageDenial)
        case unavailable
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .usage(.consentRequired): "利用規約に同意すると、タイムアタックを使えます。"
            case .usage(.noPlan): "お試しを使い切りました。続けるにはプランを選んでください。"
            case .usage(.limitReached): "今週の利用枠を使い切りました。設定の「利用枠」で、戻る日時を確かめてください。"
            case .unavailable: "この端末では Claude を使えません。"
            case .http(let status, _): "Claude に送れませんでした(HTTP \(status))。少し時間をおいてもう一度試してください。"
            }
        }
    }

    func send(_ body: [String: Any], purpose: TimeAttackClaude.Purpose) async throws -> [String: Any] {
        let reading = purpose == .read
        if let denial = upstream.gate.denial(for: UsageRequest(kind: reading ? .timelineGrading : .timelineBatch, finishing: reading)) {
            throw Failure.usage(denial)
        }
        guard let route = upstream.route() else { throw Failure.unavailable }
        let data = try JSONSerialization.data(withJSONObject: body)
        for attempt in 0..<2 {
            var (request, bearer) = try await upstream.request(data: data, route: route)
            request.setValue("application/json", forHTTPHeaderField: "accept")
            request.timeoutInterval = 120
            let (reply, response) = try await upstream.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0, let bearer, case .appAttest(let clientID) = route {
                // token が切れていた: 捨てて取り直す。
                await upstream.attest.invalidate(token: bearer, clientID: clientID)
                continue
            }
            let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] ?? [:]
            upstream.gate.record(Self.usageRecord(json, status: status), requestBytes: data.count)
            guard (200..<300).contains(status) else {
                throw Failure.http(status, String(data: reply.prefix(300), encoding: .utf8) ?? "")
            }
            return json
        }
        throw Failure.http(401, "")
    }

    /// 枠に数える記録(`UsageRules.charge` が読む `estimated_cost_usd`)。拒まれた要求は課金されない。
    static func usageRecord(_ json: [String: Any], status: Int) -> [String: Any] {
        guard let usage = json["usage"] as? [String: Any], !usage.isEmpty else {
            return ["cost_status": status >= 400 ? "not_billed" : "usage_unavailable"]
        }
        let model = json["model"] as? String ?? TimeAttack.model
        guard let cost = ClaudePricing.cost(model: model, tokens: ClaudePricing.Tokens(usage: usage)) else {
            return ["cost_status": "unknown_model"]
        }
        return ["estimated_cost_usd": cost.usd, "cost_status": "estimated", "reason": "time_attack"]
    }
}
