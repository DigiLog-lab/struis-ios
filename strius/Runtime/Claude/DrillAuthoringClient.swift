import Foundation

/// 「問題の型」を書かせる送り口(Messages API に 1 回送って、応答の JSON を返す)。テストでは差し替える。
nonisolated protocol DrillAuthoringTransport: Sendable {
    func send(_ body: [String: Any]) async throws -> [String: Any]
}

/// 点ごとの「問題の型」を AI に 1 つ書かせる(Issue #155)。返事は端末で点検し(`DrillAuthoringSession`)、
/// 落ちたら理由を返して 1 回だけ書き直させる。結論(型・対象外)は `DrillTemplateStore` に保存する。
/// 1 点につき 1 回だけ頼み、その後は端末だけで問題を作り続ける(戻った時の計算練習は AI を待たない)。
nonisolated enum DrillAuthoringClient {
    enum Failure: Error, LocalizedError, Equatable {
        case noReply
        var errorDescription: String? { "問題の型の返事を読めませんでした。" }
    }

    /// 1 回で返させる上限(型の JSON は数千トークン。考える分を足しても余る大きさ)。
    static let maxTokens: Int = 16_000

    /// 送る本文(最初の 1 回)。
    static func body(request: DrillAuthoringRequest, instructions: String, replySchema: String, model: TurnModel,
                     history: [[String: Any]] = []) throws -> [String: Any] {
        let input: String = try DrillAuthoring.input(for: request)
        let schema: Any = (try? JSONSerialization.jsonObject(with: Data(replySchema.utf8))) ?? [:]
        var messages: [[String: Any]] = [["role": "user", "content": [["type": "text", "text": input]]]]
        messages += history
        var output: [String: Any] = ["format": ["type": "json_schema", "schema": ClaudeSchema.sanitize(schema)]]
        if let effort = ClaudeRequestFormat.effort(model.effort) { output["effort"] = effort }
        return [
            "model": model.model, "max_tokens": maxTokens,
            "system": instructions,
            "thinking": ["type": "adaptive"],
            "messages": messages,
            "output_config": output,
        ]
    }

    /// 応答の本文(text のブロックをつないだもの)。
    static func replyText(_ response: [String: Any]) -> String? {
        guard let content = response["content"] as? [[String: Any]] else { return nil }
        let text: String = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    /// 型を 1 つ書かせて、結論を返す(最初の 1 回と、点検に落ちた時の書き直しの 1 回)。
    static func author(request: DrillAuthoringRequest, instructions: String, replySchema: String, model: TurnModel,
                       transport: any DrillAuthoringTransport, validator: DrillValidator = DrillValidator()) async throws -> DrillAuthoringOutcome {
        var session = DrillAuthoringSession(request: request, validator: validator)
        var history: [[String: Any]] = []
        while true {
            let sent = try body(request: request, instructions: instructions, replySchema: replySchema, model: model, history: history)
            let response: [String: Any] = try await transport.send(sent)
            guard let reply = replyText(response) else { throw Failure.noReply }
            switch session.receive(reply: reply) {
            case .finished(let outcome):
                return outcome
            case .retry(let message):
                history.append(["role": "assistant", "content": [["type": "text", "text": reply]]])
                history.append(["role": "user", "content": [["type": "text", "text": message]]])
            }
        }
    }

    /// その点で実際に解いた問題(新しい順に 3 問。○ の問題を先に)。型の数の大きさと手順を写させる。
    static func solvedExamples(skillID: String, timeline: TimelineMachine, limit: Int = 3) -> [DrillSolvedExample] {
        var seen: Set<String> = []
        let attempts = timeline.orderedAttempts.reversed().filter { $0.verdict == "correct" || $0.verdict == "wrong" }
        let ordered = attempts.filter { $0.verdict == "correct" } + attempts.filter { $0.verdict == "wrong" }
        var out: [DrillSolvedExample] = []
        for attempt in ordered {
            guard let card = timeline.cards[attempt.cardId], card.kind == "solve", card.origin != TimelineWarmup.origin,
                  card.skills.contains(skillID) || timeline.skillMarks(attempt).contains(where: { $0.skill == skillID }),
                  !card.prompt.isEmpty || !card.math.isEmpty, seen.insert(card.id).inserted else { continue }
            out.append(DrillSolvedExample(prompt: card.prompt, math: card.math, answer: card.answerKey))
            if out.count >= limit { break }
        }
        return out
    }
}

/// 本体の送り口: タイムラインと同じ Claude の経路(実機は App Attest、DEBUG の Simulator は API キー)で、
/// 新しい作業として利用枠を確かめてから送り、使った金額を枠に数える。
nonisolated struct AppDrillAuthoringTransport: DrillAuthoringTransport {
    var upstream = ClaudeUpstream()

    enum Failure: Error, LocalizedError {
        case usage(UsageDenial)
        case unavailable
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .usage: "利用枠のため、問題の型を頼みませんでした。"
            case .unavailable: "この端末では Claude を使えません。"
            case .http(let status): "問題の型を頼めませんでした(HTTP \(status))。"
            }
        }
    }

    func send(_ body: [String: Any]) async throws -> [String: Any] {
        if let denial = upstream.gate.denial(for: UsageRequest(kind: .timelineBatch, finishing: false)) { throw Failure.usage(denial) }
        guard let route = upstream.route() else { throw Failure.unavailable }
        let data = try JSONSerialization.data(withJSONObject: body)
        for attempt in 0..<2 {
            var (request, bearer) = try await upstream.request(data: data, route: route)
            request.setValue("application/json", forHTTPHeaderField: "accept")
            request.timeoutInterval = 180
            let (reply, response) = try await upstream.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0, let bearer, case .appAttest(let clientID) = route {
                // token が切れていた: 捨てて取り直す。
                await upstream.attest.invalidate(token: bearer, clientID: clientID)
                continue
            }
            let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] ?? [:]
            upstream.gate.record(Self.usageRecord(json, status: status, model: body["model"] as? String ?? ""), requestBytes: data.count)
            guard (200..<300).contains(status) else { throw Failure.http(status) }
            return json
        }
        throw Failure.http(401)
    }

    /// 枠に数える記録(`UsageRules.charge` が読む `estimated_cost_usd`)。拒まれた要求は課金されない。
    static func usageRecord(_ json: [String: Any], status: Int, model fallback: String) -> [String: Any] {
        guard let usage = json["usage"] as? [String: Any], !usage.isEmpty else {
            return ["cost_status": status >= 400 ? "not_billed" : "usage_unavailable"]
        }
        let model = json["model"] as? String ?? fallback
        guard let cost = ClaudePricing.cost(model: model, tokens: ClaudePricing.Tokens(usage: usage)) else {
            return ["cost_status": "unknown_model"]
        }
        return ["estimated_cost_usd": cost.usd, "cost_status": "estimated", "reason": "drill_template"]
    }
}
