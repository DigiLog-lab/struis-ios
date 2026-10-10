import Foundation
import OSLog

nonisolated private let sessionLog = Logger(subsystem: "com.digiloglab.strius", category: "codex-app-server")

typealias JSONObject = [String: Any]

nonisolated enum CodexAppServerError: Error, LocalizedError, Sendable {
    case notRunning
    case rpc(code: Int?, message: String)
    case timeout(String)
    /// A request the app-server never answered within its limit (the process is wedged).
    case unanswered(String)
    case closed(String)
    case malformed(String)
    case interrupted
    case turnFailed(String)

    /// Codex runs in the app process and cannot be started twice; after its server stops,
    /// only relaunching the app recovers it.
    static let inProcessStoppedDetail = "in-process Codex server stopped"

    /// Learner-facing text: one fixed Japanese sentence per case (design: 学習者に見せるエラーは
    /// 日本語の一言だけ). Method names, RPC messages and guest details never reach the screen;
    /// they are logged through `detail`.
    var errorDescription: String? {
        switch self {
        case .notRunning: "AI を起動できませんでした。もう一度送ってください。"
        case .rpc: "AI がこの依頼を受け付けませんでした。もう一度送ってください。"
        case .timeout, .unanswered: "AI の返事が止まりました。もう一度送ってください。"
        case .closed(let detail) where detail.hasPrefix(CodexAppServerError.inProcessStoppedDetail):
            "AI を再開できません。アプリを一度終了して、開き直してください。"
        case .closed: "AI が途中で止まりました。もう一度送ってください。"
        case .malformed: "AI の返事を読み取れませんでした。もう一度送ってください。"
        case .interrupted: "停止しました。"
        case .turnFailed(let detail):
            detail.localizedCaseInsensitiveContains("usage limit")
                ? "ChatGPT の利用上限に達しました。時間をおいてもう一度送ってください。"
                : "AI が返事を作れませんでした。もう一度送ってください。"
        }
    }

    /// Diagnostic text for os_log and the execution audit. Never shown to the learner.
    var detail: String {
        switch self {
        case .notRunning: "not running"
        case .rpc(let code, let message): "rpc \(code.map(String.init) ?? "-"): \(message)"
        case .timeout(let method): "timeout \(method)"
        case .unanswered(let method): "no answer to \(method)"
        case .closed(let detail): "closed \(detail)"
        case .malformed(let detail): "malformed \(detail)"
        case .interrupted: "interrupted"
        case .turnFailed(let detail): "turn failed: \(detail)"
        }
    }
}

/// Thread-safe handle around the Objective-C guest process. Tests build one from
/// closures so the session can be driven by a fake app-server.
nonisolated final class GuestProcessHandle: @unchecked Sendable {
    let pid: Int32
    private let write: @Sendable (String) -> Void
    private let close: @Sendable () -> Void
    private let kill: @Sendable () -> Void
    let exitDiagnostic: @Sendable () -> String?

    init(
        pid: Int32, writeLine: @escaping @Sendable (String) -> Void,
        closeInput: @escaping @Sendable () -> Void = {}, terminate: @escaping @Sendable () -> Void = {},
        exitDiagnostic: @escaping @Sendable () -> String? = { nil }
    ) {
        self.pid = pid
        write = writeLine
        close = closeInput
        kill = terminate
        self.exitDiagnostic = exitDiagnostic
    }

    func writeLine(_ line: String) { write(line) }
    func closeInput() { close() }
    func terminate() { kill() }
}

/// JSON-RPC over the stdio of one `codex app-server` guest process
/// (port of `_StdioSession` in `codex_app_server.py`). One resident process per
/// app; `initialize` is sent once per process, and a process that exits is
/// restarted by the next request.
actor CodexAppServerSession {
    /// `codex app-server` with the background work that spawns child processes turned off.
    /// Under hyotan a child spawned from the multi-threaded app-server can corrupt the
    /// parent (observed as exit 139 at thread start); the shell snapshot runs a login shell on
    /// every thread start and is not needed because turns pass the environment explicitly.
    nonisolated static let appServerArguments = ["-c", "features.shell_snapshot=false", "app-server"]

    typealias Notification = (method: String, params: JSONObject)

    /// Starts the guest process and returns the handle. Injected so the session
    /// can be driven by the real runtime or by tests.
    typealias Launcher = @Sendable (
        _ onLine: @escaping @Sendable (String, Bool) -> Void,
        _ onExit: @escaping @Sendable (Int32) -> Void
    ) async throws -> GuestProcessHandle

    let nativeTools = NativeToolRouter()
    private let launcher: Launcher
    private let clientVersion: String
    private var process: GuestProcessHandle?
    private var initialized = false
    private var starting: Task<Void, Error>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONObject, Error>] = [:]
    /// Owner tag of each pending request (the plan id), so a stop can release them.
    private var pendingTags: [Int: String] = [:]
    private var waiters: [Waiter] = []
    /// Tags the learner stopped; later requests and waits with the tag end as `.interrupted`.
    private var abortedTags: Set<String> = []
    /// Health (design: 次の送信の前にセッションの状態を確かめる). A request that timed out, a
    /// request released by a stop that the server never answered, or a turn that never reported
    /// `turn/completed` after it was stopped or timed out means the app-server is wedged.
    private var unresponsive = false
    private var abandonedRequests: Set<Int> = []
    private var abandonedTurns: Set<String> = []
    nonisolated let serverOutlivesConnection: Bool
    /// Turns this connection saw start and not complete: turn ID -> thread ID.
    private var liveTurns: [String: String] = [:]
    /// Completions seen on this connection, so a late `turn/start` reply cannot revive one.
    private var completedTurnIDs: Set<String> = []
    /// Turns a closed connection left running on a server that outlives it.
    private var staleTurns: [String: String] = [:]
    private let staleTurnStopTimeout: Duration
    /// Turns a runner is still waiting for (P4-5, H1). When the connection closes they are not
    /// interrupted: the runner subscribes again on the next connection and keeps waiting for them.
    private var awaitedTurns: [String: String] = [:]
    /// Stale turns whose interrupt went unanswered (M5): thread ID -> turn ID. Only these threads
    /// wait; the rest of the server is used as usual, and the next turn on the thread retries the stop.
    private var unsettledTurns: [String: String] = [:]
    /// How long a stop or an abandoned turn may take to report its end before the connection is
    /// rebuilt (H4: a stop followed by an immediate send no longer tears down parallel turns).
    private let abandonGrace: Duration
    private(set) var restartCount = 0
    private var backlog: [Notification] = []
    private var stderrTail: [String] = []
    /// Recent request methods, for diagnosing a guest crash.
    private var lastMethods: [String] = []
    private var deltaCount = 0
    private(set) var generation = 0
    /// Approval requests from the server are answered by policy (approvalPolicy is `never`).
    var serverRequestHandler: (@Sendable (String, JSONObject) -> JSONObject?)?

    static let backlogLimit = 500
    static let defaultTimeout: Duration = .seconds(180)

    private struct Waiter {
        let id: UUID
        let tag: String?
        let methods: Set<String>
        let predicate: @Sendable (JSONObject) -> Bool
        let continuation: CheckedContinuation<Notification, Error>
    }

    /// `serverOutlivesConnection`: the app-server keeps running when its connection closes (Codex in
    /// the app process), so closing no longer stops the turns it was running.
    init(clientVersion: String, launcher: @escaping Launcher, serverOutlivesConnection: Bool = false,
         staleTurnStopTimeout: Duration = .seconds(15), abandonGrace: Duration = .seconds(15)) {
        self.clientVersion = clientVersion
        self.launcher = launcher
        self.serverOutlivesConnection = serverOutlivesConnection
        self.staleTurnStopTimeout = staleTurnStopTimeout
        self.abandonGrace = abandonGrace
    }

    var isRunning: Bool { process != nil && initialized }

    // MARK: - Lifecycle

    func start() async throws {
        if process != nil, initialized { return }
        if let starting {
            try await starting.value
            return
        }
        let task = Task { try await self.launch() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launch() async throws {
        generation += 1
        lastMethods.removeAll()
        let generation = generation
        // A new process starts healthy; marks left by the previous one do not carry over.
        unresponsive = false
        abandonedRequests.removeAll()
        abandonedTurns.removeAll()
        let handle = try await launcher({ [weak self] line, isError in
            guard let self else { return }
            Task { await self.receive(line: line, isError: isError, generation: generation) }
        }, { [weak self] code in
            guard let self else { return }
            Task { await self.processExited(code: code, generation: generation) }
        })
        process = handle
        initialized = false
        do {
            _ = try await request("initialize", params: [
                "clientInfo": ["name": "struis_ios", "title": "Struis", "version": clientVersion],
                "capabilities": ["experimentalApi": true],
            ], timeout: Self.defaultTimeout, allowUninitialized: true)
            try notify("initialized", params: [:])
            // Other callers wait on `starting` until the old turns have stopped.
            try await stopStaleTurns()
            initialized = true
        } catch {
            handle.terminate()
            process = nil
            initialized = false
            throw error
        }
    }

    func close() {
        process?.closeInput()
        process?.terminate()
        process = nil
        initialized = false
        // Late output and the exit callback of the closed process must not touch the next one.
        generation += 1
        fail(all: CodexAppServerError.closed("closed"))
        unresponsive = false
        abandonedRequests.removeAll()
        abandonedTurns.removeAll()
        retainStaleTurns()
    }

    private func retainStaleTurns() {
        if serverOutlivesConnection { staleTurns.merge(liveTurns) { current, _ in current } }
        liveTurns.removeAll()
        completedTurnIDs.removeAll()
    }

    /// The server keeps a closed connection's turns running. Turns a runner still waits for are
    /// left running: the runner subscribes again and keeps waiting (H1, no rerun). The others are
    /// interrupted before this connection is used; the reply arrives only after the turn has
    /// aborted, so a retried turn cannot overlap it. An interrupt left unanswered no longer stops
    /// the whole server (M5): only that thread waits, and its next turn retries the stop.
    private func stopStaleTurns() async throws {
        // Not a snapshot: a stale reply recorded while an interrupt is awaited is stopped too.
        while let (turnID, threadID) = staleTurns.first {
            staleTurns[turnID] = nil
            if awaitedTurns[turnID] != nil { continue }
            do {
                _ = try await request("turn/interrupt", params: ["threadId": threadID, "turnId": turnID],
                                      timeout: staleTurnStopTimeout, allowUninitialized: true, critical: false)
                noteStoppedByStruis(threadID: threadID)
            } catch CodexAppServerError.rpc {
                // No active turn: it already finished.
            } catch CodexAppServerError.timeout {
                sessionLog.error("stale turn \(turnID, privacy: .public) did not stop in time; only its thread waits")
                unsettledTurns[threadID] = turnID
            }
        }
    }

    /// Before a turn starts on `threadID`: a stale turn whose stop went unanswered is stopped again
    /// (M5). Other threads never wait for it. Throws `.timeout` while it still does not stop.
    func settle(threadID: String) async throws {
        guard let turnID = unsettledTurns[threadID] else { return }
        do {
            _ = try await request("turn/interrupt", params: ["threadId": threadID, "turnId": turnID],
                                  timeout: staleTurnStopTimeout, allowUninitialized: false, critical: false)
        } catch CodexAppServerError.rpc {
            // No active turn: it finished meanwhile.
        }
        unsettledTurns[threadID] = nil
        noteStoppedByStruis(threadID: threadID)
    }

    /// Codex records an interrupted turn as stopped by the user. Struis stopped it, so the next turn
    /// on the thread tells the model (C2).
    private func noteStoppedByStruis(threadID: String) {
        ThreadContextStore.shared.addNotice(threadID, CodexTurnRunner.connectionStopNotice)
    }

    /// The runner waits for this turn; a closed connection must leave it running (H1).
    func watch(turnID: String, threadID: String) { awaitedTurns[turnID] = threadID }

    /// The runner stopped waiting. A turn that did not finish and that this connection does not
    /// know (it was re-entered after a reconnect, or lost with a connection) is stopped at the next
    /// connection like any other stale turn, so a retry cannot overlap it.
    func unwatch(turnID: String, finished: Bool) {
        guard let threadID = awaitedTurns.removeValue(forKey: turnID) else { return }
        if !finished, serverOutlivesConnection, liveTurns[turnID] == nil, !completedTurnIDs.contains(turnID) {
            staleTurns[turnID] = threadID
        }
    }

    /// False once the running app-server has stopped answering (see `unresponsive`,
    /// `abandonedRequests`, `abandonedTurns`). No new wait limit is involved: the state
    /// comes from limits that already exist and from the learner's stop.
    var isHealthy: Bool {
        !unresponsive && abandonedRequests.isEmpty && abandonedTurns.isEmpty
    }

    /// Before a new turn: rebuild the app-server if the current one is wedged, then make
    /// sure one is running. Turns still running on the old process fail as `.closed` and
    /// are retried by the runner on the new one.
    func ensureHealthy() async throws {
        if process != nil, !isHealthy, !unresponsive {
            // Only a stop or an abandoned turn is outstanding: give the guest a moment to report its
            // end instead of rebuilding the connection under the turns running in parallel (H4).
            let clock = ActiveClock.shared
            let until = clock.now + abandonGrace.timeInterval
            while process != nil, !isHealthy, !unresponsive, clock.now < until {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        if process != nil, !isHealthy {
            sessionLog.error("codex app-server unhealthy (unresponsive=\(self.unresponsive, privacy: .public) requests=\(self.abandonedRequests.count, privacy: .public) turns=\(self.abandonedTurns.count, privacy: .public)); restarting")
            await restart()
        }
        try await start()
    }

    /// Terminate the guest app-server and start a fresh one (no app relaunch needed).
    func restart() async {
        restartCount += 1
        close()
        do {
            try await start()
        } catch {
            sessionLog.error("codex app-server restart failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func processExited(code: Int32, generation: Int) {
        guard generation == self.generation else { return }
        sessionLog.error("codex app-server exited (\(code)) after \(self.lastMethods.joined(separator: ","), privacy: .public)")
        for line in stderrTail.suffix(20) { sessionLog.error("stderr: \(line, privacy: .public)") }
        #if DEBUG
        let report = (["exit \(code) after \(lastMethods.joined(separator: ","))"] + stderrTail).joined(separator: "\n")
        try? report.write(to: HyotanBoot.root.appendingPathComponent("last-app-server-exit.txt"), atomically: true, encoding: .utf8)
        #endif
        let transport = process?.exitDiagnostic() ?? "worker_interruption code=\(code)"
        let method = Self.diagnosticMethod(lastMethods.last)
        let diagnostic = transport + " rpc_stage=\(method)"
        process = nil
        initialized = false
        fail(all: CodexAppServerError.closed(diagnostic))
        unresponsive = false
        abandonedRequests.removeAll()
        abandonedTurns.removeAll()
        retainStaleTurns()
    }

    /// Only fixed protocol labels may enter exported diagnostics.
    nonisolated static func diagnosticMethod(_ method: String?) -> String {
        switch method {
        case "initialize", "account/read", "account/rateLimits/read", "thread/start",
             "thread/resume", "thread/fork", "thread/inject_items", "thread/read",
             "turn/start", "turn/interrupt": return method!
        case nil: return "none"
        default: return "other"
        }
    }

    private func fail(all error: Error) {
        let continuations = pending.values
        pending.removeAll()
        pendingTags.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
        let outstanding = waiters
        waiters.removeAll()
        for waiter in outstanding { waiter.continuation.resume(throwing: error) }
        backlog.removeAll()
    }

    // MARK: - Requests

    /// `tag` names the owner (a plan id); `abort(tag:)` releases the request when the learner stops.
    /// `critical: false` marks a request whose time-out says nothing about the server's health
    /// (rate limits, interrupts, unsubscribe, turn listing): it fails as `.timeout` and the
    /// connection is kept (H4).
    func request(_ method: String, params: JSONObject, timeout: Duration = CodexAppServerSession.defaultTimeout, tag: String? = nil,
                 critical: Bool = true) async throws -> JSONObject {
        let sent = generation
        let result = try await request(method, params: params, timeout: timeout, allowUninitialized: false, tag: tag, critical: critical)
        // Also from the reply: a `turn/started` notification may be missed or arrive late. A reply
        // whose connection has meanwhile closed belongs to the stale turns, not the new connection.
        if serverOutlivesConnection, method == "turn/start", let threadID = params["threadId"] as? String,
           let turnID = (result["turn"] as? JSONObject)?["id"] as? String {
            if sent != generation { staleTurns[turnID] = threadID }
            else if !completedTurnIDs.contains(turnID) { liveTurns[turnID] = threadID }
        }
        return result
    }

    private func request(_ method: String, params: JSONObject, timeout: Duration, allowUninitialized: Bool, tag: String? = nil,
                         critical: Bool = true) async throws -> JSONObject {
        if isAborted(tag) { throw CodexAppServerError.interrupted }
        if !allowUninitialized { try await start() }
        if isAborted(tag) { throw CodexAppServerError.interrupted }
        guard let process else { throw CodexAppServerError.notRunning }
        let id = nextID
        nextID += 1
        let line = try Self.encode(["id": id, "method": method, "params": params])
        lastMethods.append(method)
        if lastMethods.count > 8 { lastMethods.removeFirst(lastMethods.count - 8) }
        sessionLog.debug("→ \(method, privacy: .public) #\(id)")
        // Time the app spent suspended does not count (P4-3, E2).
        let timeoutTask = Task { [weak self] in
            try await ActiveClock.shared.sleep(for: timeout)
            await self?.timeOut(id: id, method: method, critical: critical)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            if let tag { pendingTags[id] = tag }
            process.writeLine(line)
        }
    }

    private func timeOut(id: Int, method: String, critical: Bool) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        pendingTags[id] = nil
        guard critical else {
            sessionLog.info("codex app-server did not answer \(method, privacy: .public) #\(id) in time; connection kept")
            continuation.resume(throwing: CodexAppServerError.timeout(method))
            return
        }
        // An existing limit expired without an answer: the process is wedged (E2E H1 saw
        // `thread/resume` time out after a stalled turn). The next turn rebuilds it.
        unresponsive = true
        sessionLog.error("codex app-server did not answer \(method, privacy: .public) #\(id); marked unresponsive")
        continuation.resume(throwing: CodexAppServerError.unanswered(method))
    }

    // MARK: - Stop

    private func isAborted(_ tag: String?) -> Bool {
        abortedTags.contains { matches(tag, $0) }
    }

    private func matches(_ tag: String?, _ aborted: String) -> Bool {
        guard let tag else { return false }
        return tag == aborted || tag.hasPrefix(aborted + ":")
    }

    /// The learner pressed 停止: release every request and wait owned by `tag` (and its
    /// `tag:*` children) right away with `.interrupted`, without waiting for the guest.
    /// `turnID` is the Codex turn that was running; if it does not report `turn/completed`
    /// before the next turn starts, the app-server is rebuilt.
    func abort(tag: String, turnID: String?) {
        abortedTags.insert(tag)
        if let turnID { abandon(turnID: turnID) }
        for (id, owner) in pendingTags where matches(owner, tag) {
            pendingTags[id] = nil
            guard let continuation = pending.removeValue(forKey: id) else { continue }
            abandonedRequests.insert(id)
            continuation.resume(throwing: CodexAppServerError.interrupted)
        }
        let released = waiters.filter { matches($0.tag, tag) }
        waiters.removeAll { matches($0.tag, tag) }
        for waiter in released { waiter.continuation.resume(throwing: CodexAppServerError.interrupted) }
    }

    /// Forget a stop once its turn has ended.
    func clearAbort(tag: String) {
        abortedTags.remove(tag)
    }

    /// A turn the client stopped waiting for. Cleared when its `turn/completed` arrives.
    func abandon(turnID: String) {
        let completed = backlog.contains { notification in
            notification.method == "turn/completed" && Self.turnID(of: notification.params) == turnID
        }
        if !completed { abandonedTurns.insert(turnID) }
    }

    nonisolated private static func turnID(of params: JSONObject) -> String? {
        (params["turn"] as? JSONObject)?["id"] as? String ?? params["turnId"] as? String
    }

    func notify(_ method: String, params: JSONObject) throws {
        guard let process else { throw CodexAppServerError.notRunning }
        process.writeLine(try Self.encode(["method": method, "params": params]))
    }

    private func respond(id: Any, result: JSONObject?, error: JSONObject?) {
        guard let process else { return }
        var envelope: JSONObject = ["id": id]
        if let result { envelope["result"] = result }
        if let error { envelope["error"] = error }
        if let line = try? Self.encode(envelope) { process.writeLine(line) }
    }

    // MARK: - Notifications

    /// Wait for the first notification whose method is in `methods` and whose
    /// params satisfy `predicate`, checking the bounded backlog first.
    func waitForNotification(
        methods: Set<String>,
        timeout: Duration = CodexAppServerSession.defaultTimeout,
        tag: String? = nil,
        predicate: @escaping @Sendable (JSONObject) -> Bool = { _ in true }
    ) async throws -> Notification {
        if isAborted(tag) { throw CodexAppServerError.interrupted }
        try await start()
        if let index = backlog.firstIndex(where: { methods.contains($0.method) && predicate($0.params) }) {
            return backlog.remove(at: index)
        }
        if isAborted(tag) { throw CodexAppServerError.interrupted }
        let id = UUID()
        let timeoutTask = Task { [weak self] in
            try await ActiveClock.shared.sleep(for: timeout)
            await self?.timeOutWaiter(id: id, methods: methods)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, tag: tag, methods: methods, predicate: predicate, continuation: continuation))
        }
    }

    private func timeOutWaiter(id: UUID, methods: Set<String>) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CodexAppServerError.timeout(methods.sorted().joined(separator: ",")))
    }

    /// Drop buffered notifications for a thread once its turn is over.
    func discardBacklog(where predicate: (Notification) -> Bool) {
        backlog.removeAll(where: predicate)
    }

    private func receive(line: String, isError: Bool, generation: Int) {
        guard generation == self.generation else { return }
        if isError {
            stderrTail.append(line)
            if stderrTail.count > 40 { stderrTail.removeFirst(stderrTail.count - 40) }
            return
        }
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? JSONObject
        else {
            sessionLog.debug("non-JSON line from app-server ignored")
            return
        }
        let method = message["method"] as? String
        let params = message["params"] as? JSONObject ?? [:]
        if let method, let id = message["id"], !(id is NSNull) {
            // Server → client request (approvals, user input). approvalPolicy is never,
            // so answer by policy without involving the learner.
            if method == "item/tool/call" {
                Task {
                    do {
                        let (reply, execution) = try await nativeTools.handle(params)
                        guard generation == self.generation else { return }
                        if let execution { handleNotification(method: "item/completed", params: execution) }
                        respond(id: id, result: reply, error: nil)
                    } catch {
                        guard generation == self.generation else { return }
                        respond(id: id, result: ["success": false, "contentItems": [["type": "inputText", "text": String(describing: error)]]], error: nil)
                    }
                }
            } else if let reply = serverRequestHandler?(method, params) {
                respond(id: id, result: reply, error: nil)
            } else {
                respond(id: id, result: nil, error: ["code": -32601, "message": "unsupported server request \(method)"])
            }
            return
        }
        if let method {
            handleNotification(method: method, params: params)
            return
        }
        guard let rawID = message["id"] else { return }
        let id = (rawID as? Int) ?? Int((rawID as? NSNumber)?.intValue ?? -1)
        guard let continuation = pending.removeValue(forKey: id) else {
            // A late answer to a request released by a stop: the server is still responsive.
            abandonedRequests.remove(id)
            // A late `turn/start` answer means the guest started a turn nobody observes. Keep the
            // session unhealthy until that turn completes, so the next turn rebuilds instead of colliding.
            if let result = message["result"] as? JSONObject, let turnID = Self.turnID(of: result) {
                abandon(turnID: turnID)
            }
            return
        }
        pendingTags[id] = nil
        if let error = message["error"] as? JSONObject {
            let text = error["message"] as? String ?? String(describing: error)
            continuation.resume(throwing: CodexAppServerError.rpc(code: error["code"] as? Int, message: text))
        } else {
            continuation.resume(returning: message["result"] as? JSONObject ?? [:])
        }
    }

    private func handleNotification(method: String, params: JSONObject) {
        if method.hasSuffix("/delta") || method.contains("Delta") {
            deltaCount += 1
            if deltaCount % 200 == 0 { sessionLog.debug("← \(self.deltaCount, privacy: .public) deltas (\(method, privacy: .public))") }
        } else {
            let itemObject = params["item"] as? JSONObject
            var item = itemObject?["type"] as? String
            if item == "commandExecution", let itemObject {
                let command = String(describing: itemObject["command"] ?? "")
                let output = String(describing: itemObject["aggregatedOutput"] ?? "").prefix(400)
                item = "commandExecution status=\(itemObject["status"] ?? "") exit=\(itemObject["exitCode"] ?? "") cmd=\(command.prefix(200)) out=\(output)"
            }
            let detail = item ?? ((params["error"] as? JSONObject)?["message"] as? String).map { String($0.prefix(300)) } ?? ""
            sessionLog.debug("← \(method, privacy: .public) \(detail, privacy: .public)")
        }
        if method == "turn/completed", let turnID = Self.turnID(of: params) {
            abandonedTurns.remove(turnID)
            liveTurns[turnID] = nil
            if serverOutlivesConnection { completedTurnIDs.insert(turnID) }
        }
        if method == "turn/started", let turnID = Self.turnID(of: params), let threadID = params["threadId"] as? String,
           !completedTurnIDs.contains(turnID) {
            liveTurns[turnID] = threadID
        }
        if let index = waiters.firstIndex(where: { $0.methods.contains(method) && $0.predicate(params) }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: (method, params))
            return
        }
        backlog.append((method, params))
        if backlog.count > Self.backlogLimit {
            backlog.removeFirst(backlog.count - Self.backlogLimit)
        }
    }

    var recentStderr: [String] { stderrTail }

    // MARK: - Encoding

    nonisolated static func encode(_ object: JSONObject) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexAppServerError.malformed("request is not JSON")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else { throw CodexAppServerError.malformed("utf8") }
        return text
    }
}
