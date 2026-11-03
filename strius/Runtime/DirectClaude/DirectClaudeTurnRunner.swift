import Foundation
import OSLog

nonisolated private let directLog = Logger(subsystem: "com.digiloglab.strius", category: "direct-claude")

/// Codex を通さず、Claude の Messages API を端末から直接呼んでタイムラインのターンを回す試作。
///
/// 今の経路は「`CodexTurnRunner` → 端末内の Codex → `ClaudeResponsesProxy` → Anthropic」。Codex が持っている仕事のうち、
/// 1 回で終わるタイムラインのターンに要るのはモデルと道具の往復と再試行だけなので、ここで直接持つ。
/// 道具は同じ `NativeToolRouter`、要求ごとの記録は同じ `ClaudeRequestAttempt`・`ClaudeRequestLog`、作業フォルダは同じ
/// `WorkspaceStager` を使う。`handles` に当たらないターンは `fallback`(Codex)へ渡す。
///
/// 再試行の回数は Codex の経路に合わせる(`docs/integration-review.md` の表 3)。比較は `RunnerComparisonLiveTests`。
actor DirectClaudeTurnRunner: TurnRunning {
    nonisolated struct Timeouts: Sendable {
        var minimumTurnS = 300
        /// 答えを書き始めた後にこれだけ何も届かなければ、ストリームが止まったとみなす(`CodexTurnRunner` と同じ)。
        var messageStall: Duration = .seconds(120)
        /// 何も届かないまま待てる長さ(Codex の `stream_idle_timeout_ms`)。
        var streamIdle: Duration = .seconds(300)
        /// 5xx・通信の失敗を送り直す回数(`request_max_retries`)。
        var requestRetries = 4
        /// ストリームが途中で切れた時に送り直す回数(`stream_max_retries`)。
        var streamRetries = 2
    }

    private let assets: AssetCache
    private let upstream: ClaudeUpstream
    private let tools: NativeToolRouter
    private let timeouts: Timeouts
    private let fallback: (any TurnRunning)?
    private let prepareCommands: @Sendable () async throws -> Void
    private var liveTurns: [String: Task<(TurnOutcome, retry: Bool), Never>] = [:]

    /// `prepareCommands`: 作業フォルダとコマンド worker の用意。Codex は起動しない。
    init(assets: AssetCache, upstream: ClaudeUpstream = ClaudeUpstream(), tools: NativeToolRouter = NativeToolRouter(),
         timeouts: Timeouts = Timeouts(), fallback: (any TurnRunning)? = nil,
         prepareCommands: @escaping @Sendable () async throws -> Void) {
        self.assets = assets
        self.upstream = upstream
        self.tools = tools
        self.timeouts = timeouts
        self.fallback = fallback
        self.prepareCommands = prepareCommands
    }

    /// 直結で回すターン。今はタイムラインの採点・出題・見直し・赤ペンだけ(すべて 1 回で終わるスレッド)。
    nonisolated static func handles(_ plan: TurnPlan) -> Bool {
        plan.thread.provider == .anthropic && plan.thread.mode == .start && plan.thread.ephemeral
            && ClaudeTranslation.tutorKinds.contains(plan.kind.rawValue)
    }

    func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome {
        guard Self.handles(plan) else {
            guard let fallback else { throw CodexAppServerError.malformed("direct runner cannot run \(plan.kind.rawValue)") }
            return try await fallback.run(plan, progress: progress)
        }
        let deadline = TurnDeadline(limitSeconds: max(timeouts.minimumTurnS, plan.limits.turnTimeoutS))
        BackgroundTurnActivity.begin()
        defer { BackgroundTurnActivity.end() }
        let first = await attempt(plan, deadline: deadline, progress: progress)
        // 止まった答えは、同じ依頼をもう一度送る(1 回で終わるスレッドなので履歴は無い)。
        guard first.outcome.status == .failed, first.retry, deadline.remaining > 0 else { return first.outcome }
        directLog.error("turn \(plan.id, privacy: .public): the answer stalled, retrying once")
        let second = await attempt(plan, deadline: deadline, progress: progress).outcome
        return TurnOutcome(
            planID: second.planID, round: second.round, status: second.status, codexThreadID: second.codexThreadID,
            codexTurnID: second.codexTurnID, finalText: second.finalText, executions: first.outcome.executions + second.executions,
            rateLimits: nil, files: second.files, error: second.error, elapsedMs: first.outcome.elapsedMs + second.elapsedMs,
            errorDetail: second.errorDetail ?? first.outcome.errorDetail
        )
    }

    private func attempt(_ plan: TurnPlan, deadline: TurnDeadline, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async -> (outcome: TurnOutcome, retry: Bool) {
        let turn = DirectClaudeTurn(plan: plan, assets: assets, upstream: upstream, tools: tools, timeouts: timeouts,
                                    deadline: deadline, prepareCommands: prepareCommands, progress: progress)
        let task = Task { await turn.run() }
        liveTurns[plan.id] = task
        let result = await task.value
        liveTurns[plan.id] = nil
        return (result.0, result.retry)
    }

    func interrupt(planID: String) async {
        liveTurns[planID]?.cancel()
        await tools.cancel(planID: planID)
        await fallback?.interrupt(planID: planID)
    }

    func warmUp() async {
        try? await prepareCommands()
        await fallback?.warmUp()
    }

    func forgetThreads(_ ids: Set<String>) async throws {
        try await fallback?.forgetThreads(ids)
    }

    func resetConnection() async {
        await fallback?.resetConnection()
    }
}

/// 1 回のターン。モデルに聞く → 道具を使う → 結果を足してまた聞く、を答えが出るまで繰り返す。
nonisolated private final class DirectClaudeTurn: @unchecked Sendable {
    private let plan: TurnPlan
    private let assets: AssetCache
    private let upstream: ClaudeUpstream
    private let tools: NativeToolRouter
    private let timeouts: DirectClaudeTurnRunner.Timeouts
    private let deadline: TurnDeadline
    private let prepareCommands: @Sendable () async throws -> Void
    private let progress: @Sendable (TurnProgressEvent) -> Void
    private let log = ClaudeRequestLog.shared

    private let threadID = "direct-" + UUID().uuidString.lowercased()
    private let turnID = "turn-" + UUID().uuidString.lowercased()
    private let started = Date()
    private var key: ClaudeRequestLog.Key { ClaudeRequestLog.Key(threadID: threadID, turnID: turnID) }

    private var messages: [[String: Any]] = []
    private var system: [[String: Any]] = []
    private var toolNames = ClaudeToolNames(responsesTools: [])
    private var stripThinking = false
    private var includeDiagnostics = true
    private var audit: [String: Any] = [:]
    private var executions: [LedgerJSON] = []
    private var captureViews: [Any] = []
    /// 待ちの表示: 構造化ターンの JSON は見せず、書き出しの始まりと、書き終わった部分の数だけを流す。
    private var announcedWriting = false
    private var partialDone = -1
    private var structuredText: [String: String] = [:]
    private var reasoning: [String: String] = [:]
    private var skills = SkillWaiting()

    init(plan: TurnPlan, assets: AssetCache, upstream: ClaudeUpstream, tools: NativeToolRouter, timeouts: DirectClaudeTurnRunner.Timeouts,
         deadline: TurnDeadline, prepareCommands: @escaping @Sendable () async throws -> Void, progress: @escaping @Sendable (TurnProgressEvent) -> Void) {
        self.plan = plan
        self.assets = assets
        self.upstream = upstream
        self.tools = tools
        self.timeouts = timeouts
        self.deadline = deadline
        self.prepareCommands = prepareCommands
        self.progress = progress
    }

    func run() async -> (TurnOutcome, retry: Bool) {
        TurnStage.report("startup")
        var registration: UUID?
        do {
            try await prepareCommands()
            TurnStage.report("runtime_ready")
            guard ClaudeAccess.isAvailable else { throw ModelProviderError.claudeUnavailable }
            guard let turn = plan.turn else { throw CodexAppServerError.malformed("plan has no turn") }
            try await configure(turn)
            TurnStage.report("thread_configured")
            try WorkspaceStager.prepare(plan: plan, assets: assets)
            skills = await CodexTurnRunner.skillWaiting(plan: plan, assets: assets)
            messages = [["role": "user", "content": try userContent(turn)]]
            let id = await tools.register(threadID: threadID, planID: plan.id, cwd: plan.hostWorkspace.path, delegate: nil)
            registration = id
            await tools.setTurn(threadID: threadID, turnID: turnID, registration: id)
            deadline.start()
            startAudit()
            TurnStage.report("turn_started")
            let text = try await loop()
            await unregister(registration)
            finishAudit(status: "completed", error: nil)
            return (TurnOutcome(
                planID: plan.id, round: plan.round, status: .completed, codexThreadID: threadID, codexTurnID: turnID, finalText: text,
                executions: executions, rateLimits: nil, files: try WorkspaceStager.collect(plan: plan), error: nil, elapsedMs: elapsed
            ), false)
        } catch {
            await unregister(registration)
            return fail(error)
        }
    }

    private func unregister(_ registration: UUID?) async {
        guard let registration else { return }
        await tools.unregister(threadID: threadID, registration: registration)
    }

    private var elapsed: Int { CodexTurnRunner.elapsed(started) }

    private func fail(_ error: Error) -> (TurnOutcome, retry: Bool) {
        let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            || (error as? CodexAppServerError) == .interrupted
        if cancelled {
            if !audit.isEmpty {
                audit["stopped_by"] = "learner"
                finishAudit(status: "interrupted", error: nil)
            }
            return (TurnOutcome(planID: plan.id, round: plan.round, status: .interrupted, codexThreadID: threadID, codexTurnID: nil, finalText: "",
                                executions: executions, rateLimits: nil, files: [], error: nil, elapsedMs: elapsed), false)
        }
        let appError = error as? CodexAppServerError
        let timedOut = appError == .timeout(CodexTurnRunner.deadlineDetail)
        if !audit.isEmpty {
            if timedOut {
                audit["stopped_by"] = "deadline"
                audit["deadline_s"] = deadline.limitSeconds
            }
            finishAudit(status: timedOut ? "timed_out" : "failed", error: CodexTurnRunner.describe(error))
        }
        directLog.error("turn \(self.plan.id, privacy: .public) failed: \(CodexTurnRunner.describe(error), privacy: .public)")
        return (TurnOutcome(planID: plan.id, round: plan.round, status: .failed, codexThreadID: threadID, codexTurnID: nil, finalText: "",
                            executions: executions, rateLimits: nil, files: [], error: error.localizedDescription, elapsedMs: elapsed,
                            errorDetail: CodexTurnRunner.describe(error)),
                appError == .timeout(CodexTurnRunner.messageStallDetail))
    }

    // MARK: - 要求の組み立て

    private func configure(_ turn: TurnPlan.TurnSpec) async throws {
        let spec = plan.thread
        let base = try await assets.text(spec.baseInstructions)
        let developer: String
        if let ref = spec.developerInstructions {
            developer = try await assets.text(ref)
        } else {
            developer = spec.developerText ?? "Answer only with one JSON object matching the supplied output schema."
        }
        let schema = turn.outputSchema.map { ClaudeTranslation.schemaInstruction($0.any) }
        system = ClaudeTranslation.tutorSystem(parts: [base, developer], schema: schema)
        toolNames = ClaudeToolNames(responsesTools: NativeToolRouter.definitions(for: plan.kind) + [Self.viewImageTool], sorted: true)
    }

    /// Codex の組み込みの `view_image`(Codex が足す定義と同じ文面)。`request_user_input` は Plan モード専用なので足さない。
    private static let viewImageTool: [String: Any] = [
        "type": "function", "name": "view_image",
        "description": "View a local image file from the filesystem when visual inspection is needed. Use this for images already available on disk.",
        "parameters": [
            "type": "object", "additionalProperties": false, "required": ["path"],
            "properties": ["path": ["type": "string", "description": "Local filesystem path to an image file."]],
        ] as [String: Any],
    ]

    private func userContent(_ turn: TurnPlan.TurnSpec) throws -> [[String: Any]] {
        var content: [[String: Any]] = [["type": "text", "text": turn.text]]
        for (number, image) in turn.images.enumerated() {
            let url = plan.hostWorkspace.appendingPathComponent(image.path)
            // Codex と同じく、画像の前後に名前と場所の印を付ける(モデルが道具で同じ画像を指せるように)。
            content.append(["type": "text", "text": "<image name=[Image #\(number + 1)] path=\"\(url.path)\">"])
            content.append(Self.imageBlock(try Data(contentsOf: url)) ?? ["type": "text", "text": "[An attached image could not be sent to the model.]"])
            content.append(["type": "text", "text": "</image>"])
        }
        return content
    }

    private static func imageBlock(_ data: Data) -> [String: Any]? {
        ClaudeRequestTranslator.imageBlock("data:\(mediaType(data));base64,\(data.base64EncodedString())", maxBytes: ClaudeRequestTranslator.Options().maxImageBytes)
    }

    private static func mediaType(_ data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if head.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if head.count >= 12, head[0...3] == [0x52, 0x49, 0x46, 0x46], head[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return "image/jpeg"
    }

    private func body(previousResponseID: String?) -> [String: Any] {
        var sent = messages
        if stripThinking {
            sent = sent.map { message in
                guard message["role"] as? String == "assistant", let content = message["content"] as? [[String: Any]] else { return message }
                var message = message
                message["content"] = content.filter { !["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
                return message
            }
        }
        var body: [String: Any] = [
            "model": plan.thread.model, "max_tokens": ClaudeRequestTranslator.Options().maxTokens, "stream": true, "messages": sent,
            "system": system, "thinking": ["type": "adaptive", "display": "summarized"],
        ]
        if ClaudeTranslation.marksTail(translation: ClaudeTranslation.tutor, messages: sent) {
            body["cache_control"] = ClaudeTranslation.cacheControl(ttl: nil)
        }
        if includeDiagnostics {
            body["diagnostics"] = ["previous_message_id": previousResponseID.map { $0 as Any } ?? NSNull()]
        }
        let claudeTools = toolNames.claudeTools
        if !claudeTools.isEmpty {
            body["tools"] = claudeTools
            body["tool_choice"] = ["type": "auto"]
        }
        if let effort = ClaudeRequestTranslator.effort(plan.thread.effort) { body["output_config"] = ["effort": effort] }
        return body
    }

    // MARK: - モデルと道具の往復

    private func loop() async throws -> String {
        var reason: ClaudeRequestReason = plan.round > 1 ? .validationRepair : .turnStart
        while true {
            let reader = try await ask(reason: reason)
            let content = reader.content
            let toolUses = reader.toolUses
            guard !toolUses.isEmpty else {
                let text = reader.finalText
                guard !text.isEmpty else { throw CodexAppServerError.turnFailed("Completed turn returned no final answer") }
                return text
            }
            messages.append(["role": "assistant", "content": content])
            for text in reader.commentary {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { progress(TurnProgressEvent(kind: .commentary, label: String(trimmed.prefix(120)), progressID: nil, allowDuplicate: false)) }
            }
            var results: [[String: Any]] = []
            for use in toolUses { results.append(try await callTool(use)) }
            messages.append(["role": "user", "content": results])
            reason = .continuation
        }
    }

    private func callTool(_ use: [String: Any]) async throws -> [String: Any] {
        let id = use["id"] as? String ?? ""
        let claudeName = use["name"] as? String ?? ""
        let name = toolNames.entry(claudeName: claudeName)?.name ?? claudeName
        let arguments = use["input"] as? [String: Any] ?? [:]
        let item: JSONObject = ["type": "dynamicToolCall", "id": id, "tool": name, "arguments": arguments]
        if let event = CodexTurnRunner.startedItemEvent(item, skills: skills) { progress(event) }
        var reply: JSONObject
        do {
            if name == "view_image" { return viewImage(id: id, path: arguments["path"] as? String ?? "", item: item) }
            let (answer, execution) = try await tools.handle(["threadId": threadID, "turnId": turnID, "tool": name, "arguments": arguments, "callId": id])
            reply = answer
            if let view = execution?["item"] as? JSONObject, view["type"] as? String == "captureView" {
                var view = view
                view["type"] = nil
                captureViews.append(view)
                audit["capture_views"] = captureViews
            }
        } catch CodexAppServerError.interrupted {
            throw CodexAppServerError.interrupted
        } catch {
            reply = ["success": false, "contentItems": [["type": "inputText", "text": String(describing: error)]]]
        }
        if let event = CodexTurnRunner.completedItemEvent(item, phase: "", skills: skills) { progress(event) }
        var result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": Self.toolContent(reply["contentItems"] as? [JSONObject] ?? [])]
        if reply["success"] as? Bool == false { result["is_error"] = true }
        return result
    }

    /// `view_image`: 作業フォルダの中の画像だけを読んで、画像のまま返す。
    private func viewImage(id: String, path: String, item: JSONObject) -> [String: Any] {
        defer { if let event = CodexTurnRunner.completedItemEvent(item, phase: "", skills: skills) { progress(event) } }
        let root = plan.hostWorkspace.standardizedFileURL.resolvingSymlinksInPath().path
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : plan.hostWorkspace.appendingPathComponent(path)).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path == root || url.path.hasPrefix(root + "/") else {
            return ["type": "tool_result", "tool_use_id": id, "content": "unable to locate image at `\(path)`: outside the workspace", "is_error": true]
        }
        guard let data = try? Data(contentsOf: url), let block = Self.imageBlock(data) else {
            return ["type": "tool_result", "tool_use_id": id, "content": "unable to locate image at `\(path)`", "is_error": true]
        }
        return ["type": "tool_result", "tool_use_id": id, "content": [block]]
    }

    private static func toolContent(_ items: [JSONObject]) -> Any {
        var blocks: [[String: Any]] = []
        for item in items {
            switch item["type"] as? String {
            case "inputText":
                if let text = item["text"] as? String { blocks.append(["type": "text", "text": text]) }
            case "inputImage":
                if let url = (item["imageUrl"] ?? item["image_url"]) as? String,
                   let image = ClaudeRequestTranslator.imageBlock(url, maxBytes: ClaudeRequestTranslator.Options().maxImageBytes) {
                    blocks.append(image)
                }
            default:
                break
            }
        }
        if blocks.count == 1, let text = blocks[0]["text"] as? String { return text.isEmpty ? "(no output)" : text }
        return blocks.isEmpty ? "(no output)" : blocks
    }

    // MARK: - 1 回の要求と再試行

    private enum Exchange: @unchecked Sendable {
        case finished(DirectClaudeMessageReader, ClaudeStreamTranslator)
        case ended(ClaudeStreamTranslator)
        case rejected(status: Int, type: String?, message: String, retryAfter: TimeInterval?, bearer: String?)
    }

    private func ask(reason first: ClaudeRequestReason) async throws -> DirectClaudeMessageReader {
        guard let route = upstream.route() else { throw ModelProviderError.claudeUnavailable }
        var reason = first
        var requestRetries = 0
        var streamRetries = 0
        var retriedToken = false
        let diagnosticsKey = ClaudeTranslation.diagnosticsKey(threadID: threadID, kind: plan.kind.rawValue, model: plan.thread.model)
        while true {
            try Task.checkCancellation()
            guard upstream.gate.admit() else { throw CodexAppServerError.turnFailed(UsageLimitResponse.message) }
            var options = ClaudeRequestTranslator.Options()
            options.translation = ClaudeTranslation.tutor
            options.tailCacheTTL = ClaudeTranslation.tailCacheTTL(kind: plan.kind.rawValue)
            options.schemaInInstructions = true
            options.stripThinking = stripThinking
            options.includeDiagnostics = includeDiagnostics
            options.previousResponseID = log.previousResponseID(threadID: diagnosticsKey)
            let body = body(previousResponseID: options.previousResponseID)
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
            var attempt = ClaudeRequestAttempt(reason: reason, model: plan.thread.model, translation: options.translation, tailTTL: options.tailCacheTTL, options: options)
            if body["cache_control"] == nil, var ttl = attempt.record["cache_ttl"] as? [String: Any] {
                ttl["tail"] = NSNull()
                attempt.record["cache_ttl"] = ttl
            }
            if ClaudeResponsesProxy.requestTooLarge(data.count) {
                let message = "request body \(data.count) bytes exceeds \(ClaudeResponsesProxy.maxRequestBytes)"
                settle(bytes: data.count, attempt.finish(status: "oversized", translator: nil, httpStatus: nil, error: ("request_too_large", message)))
                throw CodexAppServerError.turnFailed("送る内容が大きすぎます(\(data.count / (1024 * 1024)) MB)。写真の枚数を減らすか、新しい会話で送ってください。")
            }
            let translator = ClaudeStreamTranslator(tools: toolNames)
            let reader = DirectClaudeMessageReader()
            let exchange: Exchange
            do {
                let (request, bearer) = try await upstream.request(data: data, route: route)
                exchange = try await send(request, bearer: bearer, translator: translator, reader: reader)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    settle(bytes: data.count, attempt.finish(status: "cancelled", translator: translator, httpStatus: nil, error: nil))
                    throw CodexAppServerError.interrupted
                }
                if case CodexAppServerError.timeout = error {
                    settle(bytes: data.count, attempt.finish(status: "failed", translator: translator, httpStatus: nil, error: (nil, String(describing: error))))
                    throw error
                }
                settle(bytes: data.count, attempt.finish(status: "failed", translator: translator, httpStatus: nil, error: (nil, String(describing: error))))
                if error is AppAttestClient.Failure || (error as NSError).domain == "com.apple.devicecheck.error" { throw error }
                // 通信の失敗は同じ要求を送り直す。
                guard requestRetries < timeouts.requestRetries else { throw CodexAppServerError.turnFailed("Claude に接続できませんでした") }
                requestRetries += 1
                reason = .codexRetry
                try await Self.backoff(requestRetries, retryAfter: nil)
                continue
            }
            switch exchange {
            case .finished(let reader, let translator):
                let status = translator.errorType != nil ? "stream_error" : ClaudeRequestAttempt.status(stopReason: translator.stopReason)
                settle(bytes: data.count, attempt.finish(status: status, translator: translator, httpStatus: 200, error: translator.errorType.map { ($0, "stream error") }))
                if let id = translator.messageID { log.setPreviousResponseID(id, threadID: diagnosticsKey) }
                if let type = translator.errorType {
                    // 混み合いは送り直さない(`server_is_overloaded` は Codex も再試行しない)。それ以外は送り直す。
                    guard type != "overloaded_error", streamRetries < timeouts.streamRetries else { throw CodexAppServerError.turnFailed("Claude stream error: \(type)") }
                    streamRetries += 1
                    reason = .codexRetry
                    try await Self.backoff(streamRetries, retryAfter: nil)
                    continue
                }
                switch translator.stopReason {
                case "refusal": throw CodexAppServerError.turnFailed("Claude declined to answer this request.")
                case "max_tokens": throw CodexAppServerError.turnFailed("Incomplete response returned, reason: max_output_tokens")
                case "model_context_window_exceeded": throw CodexAppServerError.turnFailed("The conversation is longer than the model's context window.")
                default: return reader
                }
            case .ended(let translator):
                settle(bytes: data.count, attempt.finish(status: "stream_ended", translator: translator, httpStatus: 200, error: (nil, "stream ended early")))
                guard streamRetries < timeouts.streamRetries else { throw CodexAppServerError.turnFailed("Claude stream ended before the message was complete") }
                streamRetries += 1
                reason = .codexRetry
                try await Self.backoff(streamRetries, retryAfter: nil)
                continue
            case .rejected(let status, let type, let message, let retryAfter, let bearer):
                settle(bytes: data.count, attempt.finish(status: "http_error", translator: nil, httpStatus: status, error: (type, message)))
                if status == 400, includeDiagnostics, body["diagnostics"] != nil, message.localizedCaseInsensitiveContains("diagnostics") {
                    includeDiagnostics = false
                    reason = .diagnosticsRetry
                    continue
                }
                if status == 400, !stripThinking, message.localizedCaseInsensitiveContains("thinking") {
                    stripThinking = true
                    reason = .thinkingStripRetry
                    continue
                }
                if status == 401, case .appAttest(let clientID) = route, let bearer, !retriedToken {
                    retriedToken = true
                    reason = .authRetry
                    await upstream.attest.invalidate(token: bearer, clientID: clientID)
                    continue
                }
                if status == 529 || (500...599).contains(status), requestRetries < timeouts.requestRetries {
                    requestRetries += 1
                    reason = .codexRetry
                    try await Self.backoff(requestRetries, retryAfter: retryAfter)
                    continue
                }
                throw CodexAppServerError.turnFailed(message)
            }
        }
    }

    /// Codex の既定の待ち(200ms から倍々、前後 10% のゆらぎ)。`Retry-After` があればそれを優先する。
    private static func backoff(_ attempt: Int, retryAfter: TimeInterval?) async throws {
        let base = 0.2 * pow(2, Double(attempt - 1)) * Double.random(in: 0.9...1.1)
        try await Task.sleep(for: .seconds(retryAfter ?? base))
    }

    private func settle(bytes: Int, _ record: [String: Any]) {
        log.append(record, key: key)
        upstream.gate.record(record, requestBytes: bytes)
    }

    /// 要求を送って応答を読み切る。読む処理と見張りを並べ、期限や停止が先に来たら読む処理を止める。
    private func send(_ request: URLRequest, bearer: String?, translator: ClaudeStreamTranslator, reader: DirectClaudeMessageReader) async throws -> Exchange {
        let watch = DirectClaudeStreamWatch()
        return try await withThrowingTaskGroup(of: Exchange?.self) { group in
            group.addTask { [self] in try await exchange(request, bearer: bearer, translator: translator, reader: reader, watch: watch) }
            group.addTask { [self] in
                try await watchStream(watch)
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let result { return result }
            }
            throw CodexAppServerError.interrupted
        }
    }

    private func exchange(_ request: URLRequest, bearer: String?, translator: ClaudeStreamTranslator, reader: DirectClaudeMessageReader, watch: DirectClaudeStreamWatch) async throws -> Exchange {
        let (bytes, response) = try await upstream.session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var collected = Data()
            for try await byte in bytes {
                collected.append(byte)
                if collected.count > 256 * 1024 { break }
            }
            let error = ((try? JSONSerialization.jsonObject(with: collected)) as? [String: Any])?["error"] as? [String: Any]
            let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            return .rejected(status: status, type: error?["type"] as? String, message: error?["message"] as? String ?? String(decoding: collected.prefix(2_000), as: UTF8.self),
                             retryAfter: retryAfter, bearer: bearer)
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
            watch.touch()
            _ = translator.consume(event)
            for output in reader.consume(event) { show(output, watch: watch) }
            if translator.isFinished { return .finished(reader, translator) }
        }
        return .ended(translator)
    }

    private func watchStream(_ watch: DirectClaudeStreamWatch) async throws {
        let clock = ActiveClock.shared
        var lastNotice = 0
        while true {
            try await Task.sleep(for: .milliseconds(250))
            guard deadline.remaining > 0 else { throw CodexAppServerError.timeout(CodexTurnRunner.deadlineDetail) }
            let silent = clock.now - watch.lastEventAt
            if watch.answering, silent >= timeouts.messageStall.timeInterval { throw CodexAppServerError.timeout(CodexTurnRunner.messageStallDetail) }
            if silent >= timeouts.streamIdle.timeInterval { throw URLError(.timedOut) }
            let ticks = Int(silent / CodexTurnRunner.silenceTick)
            if ticks > lastNotice {
                lastNotice = ticks
                progress(TurnProgressEvent(kind: .waitingForModel(seconds: Int(silent)), label: "", progressID: nil, allowDuplicate: true))
            } else if ticks == 0 {
                lastNotice = 0
            }
        }
    }

    private func show(_ output: DirectClaudeMessageReader.Output, watch: DirectClaudeStreamWatch) {
        switch output {
        case .thinking(let itemID, let delta):
            reasoning[itemID, default: ""] += delta
            let headline = TurnActivityLabels.reasoningHeadline(reasoning[itemID] ?? "")
            progress(TurnProgressEvent(kind: .reasoningSummary, label: headline ?? "", progressID: itemID, allowDuplicate: true))
        case .text(let itemID, let delta):
            watch.startAnswer()
            if audit["first_text_ms"] == nil { audit["first_text_ms"] = elapsed }
            if !announcedWriting {
                announcedWriting = true
                progress(TurnProgressEvent(label: "結果を書き出しています", progressID: itemID, allowDuplicate: false))
            }
            structuredText[itemID, default: ""] += delta
            if delta.contains("}") || delta.contains("\""),
               let partial = TurnActivityLabels.structuredPartial(taskType: plan.kind.rawValue, text: structuredText[itemID] ?? ""),
               partial.done != partialDone {
                partialDone = partial.done
                progress(TurnProgressEvent(kind: .partialResult(done: partial.done, total: nil), label: partial.label, progressID: itemID, allowDuplicate: false, items: partial.items))
            }
        }
        if audit["first_event_ms"] == nil {
            audit["first_event_ms"] = elapsed
            TurnStage.report("first_event")
        }
    }

    // MARK: - 実行監査(`CodexTurnRunner.observeTurn` と同じ形)

    private func startAudit() {
        audit = [
            "execution_id": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "thread_id": threadID, "turn_id": turnID, "parent_thread_id": NSNull(), "parent_turn_id": NSNull(),
            "task_type": plan.kind.rawValue, "requested_model": plan.thread.model, "requested_effort": plan.thread.effort,
            "resolved_model": plan.thread.model, "resolved_effort": plan.thread.effort, "configuration_evidence": "direct_messages",
            "actual_model": NSNull(), "actual_effort": NSNull(), "reroutes": [Any](), "lookup_commands": NSNull(), "usage": NSNull(),
            "turn_tokens": NSNull(), "estimated_cost_usd": NSNull(), "status": "in_progress", "elapsed_ms": NSNull(),
            "billing_source": ModelProvider.anthropic.billingSource, "actual_charge": NSNull(),
            "round_reason": plan.round > 1 ? ClaudeRequestReason.validationRepair.rawValue : ClaudeRequestReason.turnStart.rawValue,
        ]
        executions.append(LedgerJSON(any: audit))
    }

    private func finishAudit(status: String, error: String?) {
        audit["status"] = status
        audit["elapsed_ms"] = elapsed
        if let error { audit["error"] = String(error.prefix(2000)) }
        let requests = log.take(threadID: threadID, turnID: turnID)
        audit["requests"] = requests
        var reasons: [String: Int] = [:]
        for request in requests { reasons[request["reason"] as? String ?? "unknown", default: 0] += 1 }
        audit["request_reasons"] = reasons
        let cost = ClaudeRequestLog.turnCost(requests)
        audit["estimated_cost_usd"] = cost.usd ?? NSNull()
        audit["cost_status"] = cost.status
        audit["pricing_version"] = ClaudePricing.version
        if let actual = requests.last(where: { $0["actual_model"] is String })?["actual_model"] { audit["actual_model"] = actual }
        audit["turn_tokens"] = Self.turnTokens(requests)
        executions.append(LedgerJSON(any: audit))
    }

    /// 要求ごとの記録の合計(`input_tokens` はキャッシュの読み書きを含む)。thinking の内訳は全部の要求が返した時だけ足す。
    private static func turnTokens(_ requests: [[String: Any]]) -> Any {
        let billed = requests.filter { $0["usage"] is [String: Any] }
        guard !billed.isEmpty else { return NSNull() }
        var input = 0, cached = 0, written = 0, output = 0
        for request in billed {
            let tokens = request["tokens"] as? [String: Any] ?? [:]
            let read = tokens["cache_read"] as? Int ?? 0
            let write = (tokens["cache_write_5m"] as? Int ?? 0) + (tokens["cache_write_1h"] as? Int ?? 0)
            input += (tokens["input"] as? Int ?? 0) + read + write
            cached += read
            written += write
            output += tokens["output"] as? Int ?? 0
        }
        let thinking = billed.compactMap { $0["thinking_tokens"] as? Int }
        return [
            "input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": written, "output_tokens": output,
            "reasoning_output_tokens": thinking.count == billed.count ? thinking.reduce(0, +) as Any : NSNull(), "total_tokens": input + output,
        ] as [String: Any]
    }
}

/// ストリームの見張りと読む処理の間で共有する、最後に何か届いた時刻と、答えを書き始めたか。
nonisolated private final class DirectClaudeStreamWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ActiveClock.shared.now
    private var started = false

    func touch() { lock.withLock { last = ActiveClock.shared.now } }
    func startAnswer() { lock.withLock { started = true } }
    var lastEventAt: TimeInterval { lock.withLock { last } }
    var answering: Bool { lock.withLock { started } }
}
