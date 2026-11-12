import Foundation

/// App Clip の送り口: 本体と同じ Claude Console の App integration で、App Attest の token を受け取って Messages API に直接送る。
/// App Clip の App Attest の鍵は本体と共有され、RP ID は本体の ID になる(Apple の資料)。DEBUG の Simulator だけ API キーで送る。
nonisolated struct ClipTransport: TimeAttackTransport {
    enum Failure: Error, LocalizedError {
        case unavailable
        case notConsented
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unavailable: "この端末では採点を使えません。"
            case .notConsented: "写真を送る同意がないので、AI の採点は使えません。"
            case .http(let status): "採点を頼めませんでした(HTTP \(status))。少し時間をおいてもう一度試してください。"
            }
        }
    }

    var session: URLSession = .shared

    func send(_ body: [String: Any], purpose: TimeAttackClaude.Purpose) async throws -> [String: Any] {
        // 今の規約に同意し、16歳以上と分かった時だけ送る(画面の側でも撮らせないが、送り口でも止める)。
        guard TimeAttackLocal().clipGrading(termsVersion: LegalVersion.terms) == .ai else { throw Failure.notConsented }
        let data = try JSONSerialization.data(withJSONObject: body)
        for attempt in 0..<2 {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("application/json", forHTTPHeaderField: "accept")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = data
            var bearer: (token: String, clientID: String)?
            if let key = Self.debugAPIKey {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            } else {
                guard AppAttestClient.isSupported, let clientID = ClaudeAppAttestConfig.clientID else { throw Failure.unavailable }
                let token = try await AppAttestClient.shared.currentToken(clientID: clientID)
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                bearer = (token, clientID)
            }
            let (reply, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0, let bearer {
                await AppAttestClient.shared.invalidate(token: bearer.token, clientID: bearer.clientID)
                continue
            }
            guard (200..<300).contains(status) else { throw Failure.http(status) }
            return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] ?? [:]
        }
        throw Failure.http(401)
    }

    /// DEBUG の Simulator の検証用(`STRUIS_DEBUG_ANTHROPIC_KEY_FILE` の 0600 のファイル)。
    private static var debugAPIKey: String? {
        #if DEBUG && targetEnvironment(simulator)
        if let path = ProcessInfo.processInfo.environment["STRUIS_DEBUG_ANTHROPIC_KEY_FILE"], !path.isEmpty,
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }
        #endif
        return nil
    }
}
