import Foundation
import GRDB
import OSLog

private let turnLog = Logger(subsystem: "com.digiloglab.strius", category: "turns")

/// Owns the queue of on-device turns (design §3.6): one chat turn at a time,
/// up to two structured turns in parallel, every turn persisted in `turns`
/// before it starts so a relaunch can re-run what was left `running`.
actor TurnCoordinator {
    nonisolated struct Notice: Sendable {
        let turnID: String
        let kind: TurnPlan.Kind
        let targetID: String?
        let status: String
    }

    let ledger: Ledger
    let assets: AssetCache
    let runner: any TurnRunning
    private var running: [String: Task<Void, Never>] = [:]
    /// Chat turns in flight, by thread (the newest one when a send is queued behind a reply).
    private var chatTurns: [String: String] = [:]
    /// 終わっていない会話のターンとその会話(前の返事の後ろに並んだ送信が、その終わりを待つ)。
    private var liveChats: [String: String] = [:]
    private var structuredActive = 0
    private var chatActive = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// 枠を待っている間に学習者が止めた構造化ターン。
    private var stoppedBeforeStart: Set<String> = []
    /// 枠を取らないまま止められた会話のターン(終わる時に枠を返さない)。
    private var unacquiredChats: Set<String> = []
    /// 送信を組んでいる最中(まだターンを登録していない)の会話と、その間に「停止」されたもの。
    private var composingChats: Set<String> = []
    /// このプロセスで作った・送り直している返事(起動時の後始末で「止まりました」にしない)。
    private var liveChatReplies: Set<String> = []
    private var stoppedComposingChats: Set<String> = []
    /// ターンを組んでいる最中(台帳にまだターンの行が無い)の答案・一枚と、その間に止められたもの。
    private var composingTargets: Set<String> = []
    private var stoppedWhileComposing: Set<String> = []

    private struct StoppedBeforeLaunch: Error {}
    private var progressHandlers: [String: @Sendable (TurnProgressEvent) -> Void] = [:]
    private var noticeHandlers: [UUID: @Sendable (Notice) -> Void] = [:]

    /// 先回りのターン(待ち時間の体験 §3.1)。学習者が今待っている処理(判定・学習者が求めた一枚・質問の返事)を
    /// 先に通す: 先回りは同時に 1 つまで、学習者の処理が枠を待っている間は始めず、枠が足りなければ止めて譲る
    /// (止めた先回りは後で組み直す)。質問の返事は別の枠なので、先回りに待たされない。
    var prefetchTurns: Set<String> = []
    private var prefetchTargets: [String: String] = [:]
    private var runningPrefetches: Set<String> = []
    private var preemptedPrefetches: Set<String> = []
    private var learnerWaiting = 0
    /// 先回りで作っている / 作った例題(小単元 → 例題)。
    var examplePrefetches: [String: ExamplePrefetch] = [:]
    var examplePrefetchTasks: [String: Task<Void, Never>] = [:]
    /// 先回りの例題ができるのを待っている小単元(段階 2 に進んだが、まだ作っている最中)。
    var adoptionWaits: Set<String> = []
    /// 返事の中で書き終わった全体像の提案から、先に組み始めた全体像(A12。返事の assistant メッセージ → 先回り)。
    var unitPrefetches: [String: UnitPrefetch] = [:]

    static let structuredLimit = 2
    static let chatLimit = 1
    static let prefetchLimit = 1

    /// 構造化ターンの上限(前面にいた時間だけを数える)。超えたら `run` の終わりを待たずに失敗として返す
    /// (2026-10-24: 返らないターンで採点・グラフ・会話が全部止まった)。会話と単元ホームの判定は今のまま(上限なし)。
    static let defaultTimeLimits: [String: Duration] = [
        TurnPlan.Kind.timelineGrading.rawValue: .seconds(90),
        TurnPlan.Kind.timelineBatch.rawValue: .seconds(180),
        TurnPlan.Kind.timelineGraph.rawValue: .seconds(180),
        "graph_descend": .seconds(120),
    ]
    private var timeLimits = TurnCoordinator.defaultTimeLimits
    private let clock: ActiveClock

    /// テスト用: 上限を差し替える。
    func setTimeLimits(_ limits: [String: Duration]) { timeLimits = limits }

    init(ledger: Ledger, assets: AssetCache, runner: any TurnRunning, clock: ActiveClock = .shared) {
        self.ledger = ledger
        self.assets = assets
        self.runner = runner
        self.clock = clock
    }

    private var deletingUnits: Set<String> = []

    func deleteUnit(id: String) async throws -> UnitDeletion.Fact {
        guard deletingUnits.insert(id).inserted else { throw LedgerError.conflict("単元を削除しています") }
        defer { deletingUnits.remove(id) }
        let scope = try await ledger.deletionScope(unitID: id)
        var codexIDs = scope.codexIDs
        let turnIDs = scope.ids[LedgerEntity.turns.rawValue] ?? []
        let tasks = turnIDs.compactMap { running[$0] }
        for turnID in turnIDs {
            stoppedBeforeStart.insert(turnID)
            await runner.interrupt(planID: turnID)
        }
        wakeWaiters()
        for subunit in scope.ids[LedgerEntity.workbookSubunits.rawValue] ?? [] {
            if let prefetch = examplePrefetches[subunit] {
                await runner.interrupt(planID: prefetch.state.turnID)
                if let task = examplePrefetchTasks[subunit] { await task.value }
                if let id = examplePrefetches[subunit]?.state.codexThreadID, id != prefetch.baseCodexThreadID { codexIDs.insert(id) }
                discardExamplePrefetch(subunitID: subunit)
                examplePrefetchTasks[subunit] = nil
                adoptionWaits.remove(subunit)
            }
        }
        for message in scope.ids[LedgerEntity.messages.rawValue] ?? [] { await discardUnitPrefetch(messageID: message) }
        for task in tasks { await task.value }
        let unrelatedChats = liveChats.keys.filter { !turnIDs.contains($0) }.compactMap { running[$0] }
        for task in unrelatedChats { await task.value }
        let settledScope = try await ledger.deletionScope(unitID: id)
        codexIDs = settledScope.codexIDs.union(codexIDs.subtracting(scope.codexIDs))
        try await runner.forgetThreads(codexIDs)
        let fact = try await ledger.deleteUnit(id: id, extraCodexIDs: codexIDs)
        ThreadContextStore.shared.remove(codexIDs)
        return fact
    }

    var composer: TurnComposer { TurnComposer(assets: assets) }

    func observe(_ handler: @escaping @Sendable (Notice) -> Void) -> UUID {
        let id = UUID()
        noticeHandlers[id] = handler
        return id
    }

    func setProgressHandler(turnID: String, _ handler: (@Sendable (TurnProgressEvent) -> Void)?) {
        progressHandlers[turnID] = handler
    }

    func unobserve(_ id: UUID) {
        noticeHandlers[id] = nil
    }

    private func notify(_ notice: Notice) {
        for handler in noticeHandlers.values { handler(notice) }
    }

    func notifyNotice(_ notice: Notice) { notify(notice) }

    // MARK: - Chat bookkeeping (used by ChatTurnCoordinator)

    /// 返事が動いている、または送信を組んでいる最中(同じ会話で二重に送らない)。
    func isChatRunning(threadID: String) -> Bool { chatTurns[threadID] != nil || composingChats.contains(threadID) }
    func chatTurnID(threadID: String) -> String? { chatTurns[threadID] }
    func registerChat(turnID: String, threadID: String) {
        chatTurns[threadID] = turnID
        liveChats[turnID] = threadID
    }

    /// 見える返事を書き終えて記録だけを書いている返事の後ろに、送信を並べられるか。並べる先(今のターン)を返す。
    /// 送信を組んでいる最中(まだターンを登録していない)なら並べない。
    func queueableChat(threadID: String) -> String? {
        guard !composingChats.contains(threadID) else { return nil }
        return chatTurns[threadID]
    }

    /// 前のターンが終わる(台帳に書き終えて枠を返す)まで待つ。待っている間に止められたら、すぐ戻る
    /// (この後の `acquireChatSlot` が止めた印を見て、走らせずに終わらせる)。
    func waitForChat(_ predecessor: String, turnID: String) async {
        while liveChats[predecessor] != nil, !stoppedBeforeStart.contains(turnID) {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
    func registerChatTask(turnID: String, task: Task<Void, Never>) { running[turnID] = task }
    /// 枠を返した後まで残る登録を外す(先回りの全体像を結んだ時の「止める」用の登録)。
    func clearRunning(turnID: String) { running[turnID] = nil }
    /// 枠を取れたら true。待っている間に止められたら false(枠は取らない)。
    func acquireChatSlot(turnID: String) async -> Bool {
        let acquired = await acquire(kind: .chat, turnID: turnID)
        if !acquired { unacquiredChats.insert(turnID) }
        return acquired
    }

    /// 送信を組み始めた(台帳に書いてターンを登録するまで)。
    /// この返事はこのプロセスが受け持つ(前のプロセスが残したものではない)。
    func markChatReplyLive(_ assistantMessageID: String) { liveChatReplies.insert(assistantMessageID) }
    func isChatReplyLive(_ assistantMessageID: String) -> Bool { liveChatReplies.contains(assistantMessageID) }

    func beginComposingChat(threadID: String) {
        composingChats.insert(threadID)
        stoppedComposingChats.remove(threadID)
    }

    /// 送信を組み終えた。組んでいる間に「停止」されていたら true。
    func endComposingChat(threadID: String) -> Bool {
        composingChats.remove(threadID)
        return stoppedComposingChats.remove(threadID) != nil
    }

    /// 登録する前に止められたターンに印を付ける(`acquire` が見て、走らせずに終わらせる)。
    func markStoppedBeforeStart(turnID: String) {
        stoppedBeforeStart.insert(turnID)
    }

    /// まだターンが登録されていない会話の「停止」。組んでいる最中なら覚えておく。
    func stopComposingChat(threadID: String) {
        if composingChats.contains(threadID) { stoppedComposingChats.insert(threadID) }
    }

    /// 会話のターンを止める。枠を待っているなら、待たずにその場で終わらせる。
    func stopChat(turnID: String) async {
        stoppedBeforeStart.insert(turnID)
        await runner.interrupt(planID: turnID)
        wakeWaiters()
    }
    func forwardChatProgress(turnID: String, event: TurnProgressEvent) { progressHandlers[turnID]?(event) }

    func finishedChat(turnID: String, threadID: String) {
        liveChats[turnID] = nil
        // 並べた送信が先に終わった(止められた)時は、まだ記録を書いている前の返事をこの会話の返事に戻す。
        if chatTurns[threadID] == turnID { chatTurns[threadID] = liveChats.first { $0.value == threadID }?.key }
        finished(turnID: turnID, kind: .chat, releasesSlot: unacquiredChats.remove(turnID) == nil)
    }

    // MARK: - Structured turns (design §6.4 / §13.10〜13.12)

    /// 撮った紙の判定を起こす。
    func startGrading(captureID: String) async {
        await start(kind: .workbookGrading, targetID: captureID)
    }

    func startSetGeneration(setID: String) async {
        await start(kind: .workbookSet, targetID: setID)
    }

    /// 次に要る一枚を先回りで組む(学習者が待っている処理より後)。
    func startPrefetchedSet(setID: String) async {
        await start(kind: .workbookSet, targetID: setID, prefetch: true)
    }

    /// 学習者がその一枚を求めた(開いた・「演習へ」を押した・その段に来た): 先回りの扱いをやめ、普通に通す。
    func promote(targetID: String) {
        guard let turnID = prefetchTargets.removeValue(forKey: targetID) else { return }
        prefetchTurns.remove(turnID)
        wakeWaiters()
    }

    func startUnitGeneration(proposalID: String) async {
        await start(kind: .workbookUnit, targetID: proposalID)
    }

    /// 学習タイムライン(Issue #46): 次の5枚・採点・知識グラフ。5枚は学習者が待っていない先回り(1枚目は手元から出す)。
    func startTimeline(kind: TurnPlan.Kind, targetID: String, prefetch: Bool = false) async {
        await start(kind: kind, targetID: targetID, prefetch: prefetch)
    }

    private func start(kind: TurnPlan.Kind, targetID: String, prefetch: Bool = false) async {
        let turnID = LedgerID.make()
        if prefetch {
            prefetchTurns.insert(turnID)
            prefetchTargets[targetID] = turnID
        }
        composingTargets.insert(targetID)
        do {
            let composed = try await compose(kind: kind, turnID: turnID, targetID: targetID)
            // 組んでいる間に「止める」が押された: 走らせずに、答案・一枚を「判定し直す」「作り直す」にする。
            if stoppedWhileComposing.remove(targetID) != nil { throw StoppedBeforeLaunch() }
            let (plan, context) = composed
            try await ledger.append([.upsert("turn.queued", TurnRecord(
                id: turnID, kind: kind.rawValue, targetId: targetID, threadId: nil, status: "queued", round: 1, plan: plan.json,
                outcome: nil, codexThreadId: nil, codexTurnId: nil, executions: .emptyArray, error: nil,
                createdAt: LedgerClock.now(), startedAt: nil, completedAt: nil
            ))])
            composingTargets.remove(targetID)
            // 行を書いている間に止められた: 枠を取らずに「止めた」として終わらせる(`acquire` が見る印)。
            if stoppedWhileComposing.remove(targetID) != nil { stoppedBeforeStart.insert(turnID) }
            launch(turnID: turnID, plan: plan, context: context)
        } catch {
            composingTargets.remove(targetID)
            stoppedWhileComposing.remove(targetID)
            turnLog.error("compose \(kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            if TimelineTurns.isTimeline(kind) {
                try? await ledger.commit { db in (try TimelineTurns.fail(kind: kind, targetID: targetID, error: String(describing: error), db: db), ()) }
                notify(Notice(turnID: turnID, kind: kind, targetID: targetID, status: "failed"))
                return
            }
            try? await ledger.commit { db in
                var machine = try WorkbookMachine(loading: db)
                switch kind {
                // 学習者に見せるのは日本語の一言だけ。詳細は上のログに残した。
                case .workbookGrading: machine.failCapture(id: targetID, error: TurnApplier.gradingFailure)
                case .workbookSet: machine.failSet(setID: targetID, error: TurnApplier.setFailure)
                case .workbookUnit: machine.failProposal(id: targetID, error: TurnApplier.unitFailure)
                default: break
                }
                return (machine.events, ())
            }
            notify(Notice(turnID: turnID, kind: kind, targetID: targetID, status: "failed"))
        }
    }

    private func compose(kind: TurnPlan.Kind, turnID: String, targetID: String) async throws -> (TurnPlan, WorkbookMachine.GradingContext?) {
        let machine = try await ledger.read { db in try WorkbookMachine(loading: db) }
        switch kind {
        case .workbookGrading:
            let (plan, context) = try await composer.grading(planID: turnID, machine: machine, captureID: targetID)
            return (plan, context)
        case .workbookSet:
            let avoid = try await conversationExpressions(machine: machine, setID: targetID)
            return (try await composer.set(planID: turnID, machine: machine, setID: targetID, avoidExpressions: avoid), nil)
        case .workbookUnit:
            return (try await composer.unit(planID: turnID, machine: machine, proposalID: targetID), nil)
        case .timelineBatch, .timelineGrading, .timelineGraph:
            let timeline = try await ledger.read { db in try TimelineMachine(loading: db) }
            let composer = self.composer
            switch kind {
            case .timelineBatch: return (try await TimelineTurns.batch(composer: composer, planID: turnID, batchID: targetID, workbook: machine, timeline: timeline), nil)
            case .timelineGrading: return (try await TimelineTurns.grading(composer: composer, planID: turnID, attemptID: targetID, workbook: machine, timeline: timeline), nil)
            default: return (try await TimelineTurns.graph(composer: composer, planID: turnID, batchID: targetID, workbook: machine, timeline: timeline), nil)
            }
        default:
            throw LedgerError.invalid("unsupported turn kind \(kind.rawValue)")
        }
    }

    /// 一枚の小単元の会話に出た式(D14)。読めなければ空(一枚の生成は止めない)。
    private func conversationExpressions(machine: WorkbookMachine, setID: String) async throws -> [String] {
        let threadID = ConversationExpressions.threadID(machine: machine, setID: setID)
        guard threadID != nil else { return [] }
        return (try? await ledger.read { db in try ConversationExpressions.inThread(db: db, threadID: threadID) }) ?? []
    }

    private func launch(turnID: String, plan: TurnPlan, context: WorkbookMachine.GradingContext?) {
        running[turnID] = Task { [weak self] in
            guard let self else { return }
            let acquired = await self.execute(turnID: turnID, plan: plan, context: context)
            await self.finished(turnID: turnID, kind: plan.kind, releasesSlot: acquired)
        }
    }

    /// 枠が空くまで待つ。待っている間に学習者が止めたら false(枠は取らない)。
    /// 先回り(`prefetchTurns`)は、学習者の処理が待っていない時だけ、同時に 1 つまで始める。学習者の処理が枠を
    /// 待つ時は、走っている先回りを止めて枠を空ける。
    func acquire(kind: TurnPlan.Kind, turnID: String) async -> Bool {
        var waiting = false
        defer { if waiting { learnerWaiting -= 1 } }
        while true {
            if stoppedBeforeStart.contains(turnID) { return false }
            if kind == .chat {
                if chatActive < Self.chatLimit { chatActive += 1; return true }
            } else if prefetchTurns.contains(turnID) {
                if structuredActive < Self.structuredLimit, runningPrefetches.count < Self.prefetchLimit, learnerWaiting == 0 {
                    structuredActive += 1
                    runningPrefetches.insert(turnID)
                    return true
                }
            } else {
                if structuredActive < Self.structuredLimit { structuredActive += 1; return true }
                if let victim = runningPrefetches.first(where: { prefetchTurns.contains($0) && !preemptedPrefetches.contains($0) }) {
                    turnLog.info("prefetch \(victim, privacy: .public) yields to \(turnID, privacy: .public)")
                    preemptedPrefetches.insert(victim)
                    let runner = self.runner
                    Task { await runner.interrupt(planID: victim) }
                }
                if !waiting { waiting = true; learnerWaiting += 1 }
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// 先回りのターンが止められて枠を譲ったか(一度だけ true)。
    func takePreempted(_ turnID: String) -> Bool {
        preemptedPrefetches.remove(turnID) != nil
    }

    /// 枠を返す(先回りの例題など、`turns` の行を持たないターン)。
    func release(turnID: String, kind: TurnPlan.Kind, acquired: Bool) {
        finished(turnID: turnID, kind: kind, releasesSlot: acquired)
    }

    /// 待っている全員を起こして、枠と止めた印を見直させる。
    private func wakeWaiters() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    private func finished(turnID: String, kind: TurnPlan.Kind, releasesSlot: Bool) {
        running[turnID] = nil
        progressHandlers[turnID] = nil
        stoppedBeforeStart.remove(turnID)
        runningPrefetches.remove(turnID)
        prefetchTurns.remove(turnID)
        preemptedPrefetches.remove(turnID)
        for (target, id) in prefetchTargets where id == turnID { prefetchTargets[target] = nil }
        if releasesSlot {
            if kind == .chat { chatActive -= 1 } else { structuredActive -= 1 }
        }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    /// このターンの上限(無ければ nil)。1段下りるグラフの依頼は短い。
    private func timeLimit(kind: TurnPlan.Kind, targetID: String?) async -> Duration? {
        if kind == .timelineGraph, let targetID,
           let purpose = try? await ledger.read({ db in try TimelineBatchRecord.fetchOne(db, key: targetID)?.purpose }), purpose == "graph_descend" {
            return timeLimits["graph_descend"] ?? timeLimits[kind.rawValue]
        }
        return timeLimits[kind.rawValue]
    }

    /// `runner.run` と上限の競争。上限が先なら、ターンを止めて接続を作り直させ、遅れて来た結果は捨てる。
    /// 段階(`TurnStage`)は台帳のターンの行に書く。
    private func runBounded(turnID: String, plan: TurnPlan, limit: Duration?, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async -> TurnOutcome {
        let runner = self.runner
        let started = Date()
        let first = TurnRace<Result<TurnOutcome, Error>?>()
        let ledger = self.ledger
        let sink: @Sendable (String) -> Void = { stage in
            let at = LedgerClock.now()
            Task { await TurnCoordinator.recordStage(ledger: ledger, turnID: turnID, stage: stage, at: at) }
        }
        let work = TurnStage.$sink.withValue(sink) {
            Task {
                do { first.finish(.success(try await runner.run(plan, progress: progress))) } catch { first.finish(.failure(error)) }
            }
        }
        var timer: Task<Void, Never>?
        if let limit {
            let clock = self.clock
            timer = Task {
                do { try await clock.sleep(for: limit) } catch { return }
                first.finish(nil)
            }
        }
        let result = await first.result
        timer?.cancel()
        switch result {
        case .success(let outcome)?:
            return outcome
        case .failure(let error)?:
            return TurnOutcome(
                planID: plan.id, round: plan.round, status: .failed, codexThreadID: plan.thread.codexThreadID, codexTurnID: nil,
                finalText: "", executions: [], rateLimits: nil, files: [], error: error.localizedDescription,
                elapsedMs: Int(Date().timeIntervalSince(started) * 1000)
            )
        case nil:
            let seconds = Int((limit ?? .zero).timeInterval)
            turnLog.error("turn \(turnID, privacy: .public) (\(plan.kind.rawValue, privacy: .public)) exceeded \(seconds, privacy: .public)s; giving up and rebuilding the connection")
            work.cancel()
            await runner.interrupt(planID: plan.id)
            await runner.resetConnection()
            return TurnOutcome(
                planID: plan.id, round: plan.round, status: .failed, codexThreadID: plan.thread.codexThreadID, codexTurnID: nil,
                finalText: "", executions: [.object(["type": .string("time_limit"), "seconds": .number(Double(seconds)), "at": .string(LedgerClock.now())])],
                rateLimits: nil, files: [], error: "time limit \(seconds)s", elapsedMs: Int(Date().timeIntervalSince(started) * 1000)
            )
        }
    }

    /// ターンの段階を行の `executions` に足す(`turn.stage`)。
    static func recordStage(ledger: Ledger, turnID: String, stage: String, at: String) async {
        try? await ledger.commit { db in
            guard var turn = try TurnRecord.fetchOne(db, key: turnID) else { return ([], ()) }
            turn.executions = .array((turn.executions.arrayValue ?? []) + [.object(["type": .string("stage"), "stage": .string(stage), "at": .string(at)])])
            return ([.upsert("turn.stage", turn)], ())
        }
    }

    /// 完了時の `executions`: 段階の記録は残し、その後ろに結果の記録を並べる。
    static func mergedExecutions(_ existing: LedgerJSON, _ outcome: [LedgerJSON]) -> LedgerJSON {
        .array((existing.arrayValue ?? []).filter { $0["type"]?.stringValue == "stage" } + outcome)
    }

    /// 枠を取って走らせたら true。
    private func execute(turnID: String, plan: TurnPlan, context: WorkbookMachine.GradingContext?) async -> Bool {
        // 保存(ledger.commit)が終わるまで裏で動く許可を持つ(2026-10-24: run の中で返していたため、保存の途中で
        // iOS に 18 分止められた)。run の中の begin/end は数える仕組みなので二重でよい。
        BackgroundTurnActivity.begin()
        defer { BackgroundTurnActivity.end() }
        // 待ちの画面へ、このターンで実際に起きた出来事を流す(信頼性計画 P2)。対象(答案・一枚・全体像)ごとに 1 本。
        let activity = await targetID(of: turnID).map { TurnActivityBoard.sink(TurnActivityKey.target($0)) }
        defer { activity?.finish() }
        let acquired = await acquire(kind: plan.kind, turnID: turnID)
        var outcome: TurnOutcome
        if !acquired {
            // 枠が空く前に止められた: 走らせずに「止めた」結果として反映する(答案・一枚は「判定し直す」「作り直す」へ)。
            outcome = TurnOutcome(
                planID: plan.id, round: plan.round, status: .interrupted, codexThreadID: plan.thread.codexThreadID, codexTurnID: nil,
                finalText: "", executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: 0
            )
        } else {
        await mark(turnID: turnID, status: "running")
        notify(Notice(turnID: turnID, kind: plan.kind, targetID: plan.kind == .chat ? plan.thread.codexThreadID : nil, status: "running"))
        let limit = await timeLimit(kind: plan.kind, targetID: await targetID(of: turnID))
        outcome = await runBounded(turnID: turnID, plan: plan, limit: limit) { [weak self] event in
            activity?.send(event)
            guard let self else { return }
            Task { await self.forwardProgress(turnID: turnID, event: event) }
        }
        }
        var followUp = TurnApplier.FollowUp()
        let targetID = await targetID(of: turnID)
        let wasPrefetch = prefetchTurns.contains(turnID)
        // 学習者の処理に枠を譲って止まった先回り: 結果は反映せず(一枚は組んでいるまま)、後で組み直す。
        if outcome.status == .interrupted, takePreempted(turnID), let targetID {
            try? await ledger.commit { db in
                guard var turn = try TurnRecord.fetchOne(db, key: turnID) else { return ([], ()) }
                turn.status = "interrupted"
                turn.error = "yielded to a learner turn"
                turn.completedAt = LedgerClock.now()
                return ([.upsert("turn.interrupted", turn)], ())
            }
            WorkspaceStager.cleanup(plan: plan)
            await start(kind: plan.kind, targetID: targetID, prefetch: true)
            return acquired
        }
        do {
            followUp = try await ledger.commit { db in
                guard try TurnRecord.fetchOne(db, key: turnID) != nil else { return ([], TurnApplier.FollowUp()) }
                if TimelineTurns.isTimeline(plan.kind) {
                    let applied = try TimelineTurns.apply(kind: plan.kind, targetID: targetID ?? "", outcome: outcome, model: plan.thread.model, db: db)
                    var events = applied.events
                    if var turn = try TurnRecord.fetchOne(db, key: turnID) {
                        turn.status = outcome.status.rawValue
                        turn.outcome = outcome.json
                        turn.codexThreadId = outcome.codexThreadID
                        turn.codexTurnId = outcome.codexTurnID
                        turn.executions = Self.mergedExecutions(turn.executions, outcome.executions)
                        turn.error = outcome.error
                        turn.completedAt = LedgerClock.now()
                        events.append(.upsert("turn.\(outcome.status.rawValue)", turn))
                    }
                    return (events, TurnApplier.FollowUp(retryTimeline: applied.followUp.retry, nextTimelineGraph: applied.followUp.nextGraph))
                }
                var machine = try WorkbookMachine(loading: db)
                switch plan.kind {
                case .workbookGrading: guard let targetID, machine.captures[targetID] != nil else { return ([], TurnApplier.FollowUp()) }
                case .workbookSet: guard let targetID, machine.sets[targetID] != nil else { return ([], TurnApplier.FollowUp()) }
                case .workbookUnit: guard let targetID, machine.proposals[targetID] != nil else { return ([], TurnApplier.FollowUp()) }
                default: break
                }
                var followUp = TurnApplier.FollowUp()
                switch plan.kind {
                case .workbookGrading:
                    followUp = TurnApplier.grading(machine: &machine, captureID: targetID ?? "", outcome: outcome, context: context ?? WorkbookMachine.GradingContext(scope: .emptyObject, subunits: []))
                case .workbookSet:
                    let threadID = ConversationExpressions.threadID(machine: machine, setID: targetID ?? "")
                    let avoid = (try? ConversationExpressions.inThread(db: db, threadID: threadID)) ?? []
                    followUp = TurnApplier.set(machine: &machine, setID: targetID ?? "", outcome: outcome, avoidExpressions: avoid)
                case .workbookUnit:
                    TurnApplier.unit(machine: &machine, proposalID: targetID ?? "", outcome: outcome)
                default:
                    break
                }
                var events = machine.events
                if var turn = try TurnRecord.fetchOne(db, key: turnID) {
                    turn.status = outcome.status.rawValue
                    turn.outcome = outcome.json
                    turn.codexThreadId = outcome.codexThreadID
                    turn.codexTurnId = outcome.codexTurnID
                    turn.executions = Self.mergedExecutions(turn.executions, outcome.executions)
                    turn.error = outcome.error
                    turn.completedAt = LedgerClock.now()
                    events.append(.upsert("turn.\(outcome.status.rawValue)", turn))
                }
                return (events, followUp)
            }
        } catch {
            turnLog.error("apply \(plan.kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        WorkspaceStager.cleanup(plan: plan)
        notify(Notice(turnID: turnID, kind: plan.kind, targetID: targetID, status: outcome.status.rawValue))
        if TimelineTurns.isTimeline(plan.kind) {
            // 受け取りを断った(skills の ID・段の上限・検算・グラフの点検): 1 回だけ作り直させる。
            if followUp.retryTimeline, let targetID { await start(kind: plan.kind, targetID: targetID, prefetch: wasPrefetch) }
            // 次の段・よくある勘違い・1段下りる: 学習者が待っていない先回りとして続けて頼む。
            if let next = followUp.nextTimelineGraph { await start(kind: .timelineGraph, targetID: next, prefetch: true) }
            return acquired
        }
        if let setID = followUp.setIDToGenerate {
            // 一枚の残り(§3.2)。先回りで組んでいた一枚は、学習者が求めるまで先回りのまま。
            await start(kind: .workbookSet, targetID: setID, prefetch: wasPrefetch && plan.kind == .workbookSet && prefetchTargets[setID] == turnID)
        }
        if let setID = followUp.prefetchSetID {
            await startPrefetchedSet(setID: setID)
        }
        if plan.kind == .workbookGrading, outcome.status == .completed, let targetID {
            // 誤りがあれば「例題に戻る」の先の例題を先回りで作る(A13)。
            await prefetchReturnExampleIfWrong(captureID: targetID)
        }
        return acquired
    }

    private func forwardProgress(turnID: String, event: TurnProgressEvent) {
        progressHandlers[turnID]?(event)
    }

    private func mark(turnID: String, status: String) async {
        try? await ledger.commit { db in
            guard var turn = try TurnRecord.fetchOne(db, key: turnID) else { return ([], ()) }
            turn.status = status
            if status == "running" { turn.startedAt = LedgerClock.now() }
            return ([.upsert("turn.\(status)", turn)], ())
        }
    }

    private func targetID(of turnID: String) async -> String? {
        try? await ledger.read { db in try TurnRecord.fetchOne(db, key: turnID)?.targetId }
    }

    func interrupt(turnID: String) async {
        await runner.interrupt(planID: turnID)
    }

    /// 一枚の生成・判定を学習者が止める(返事の待ち時間に区切りは無く、止めるかは学習者が決める)。
    /// 止まった答案と一枚は、失敗と同じく「判定し直す」「作り直す」になる。
    func interrupt(targetID: String) async {
        // 組んでいる最中なら、台帳を読む前(待つ前)に印を付ける。読んでいる間に組み終えて走り出したターンも、
        // 組み終えた所でこの印を見て止まる。
        if composingTargets.contains(targetID) { stoppedWhileComposing.insert(targetID) }
        let turnIDs = (try? await ledger.read { db in
            try TurnRecord.filter(sql: "status IN ('queued', 'running')").fetchAll(db)
                .filter { $0.targetId == targetID && $0.kind != TurnPlan.Kind.chat.rawValue }
                .map(\.id)
        }) ?? []
        for turnID in turnIDs where running[turnID] != nil {
            // まだ枠を待っているターンは、枠を待たずにその場で終わらせる。走っているターンは runner で止める。
            stoppedBeforeStart.insert(turnID)
            await runner.interrupt(planID: turnID)
        }
        wakeWaiters()
    }

    /// Re-run turns left `queued`/`running` by a previous process (design §3.6).
    func resumeUnfinished() async {
        let unfinished = (try? await ledger.read { db in
            try TurnRecord.filter(sql: "status IN ('queued', 'running')").fetchAll(db)
        }) ?? []
        var abandonedChats: [TurnRecord] = []
        for turn in unfinished {
            guard running[turn.id] == nil else { continue }  // still running in this process
            if turn.kind == TurnPlan.Kind.chat.rawValue {
                abandonedChats.append(turn)  // no task survives a relaunch: 「止まりました」+「送り直す」
                continue
            }
            guard let plan = try? TurnPlan.from(turn.plan), let kind = TurnPlan.Kind(rawValue: turn.kind) else { continue }
            if kind == .workbookGrading, let captureID = turn.targetId {
                let machine = try? await ledger.read { db in try WorkbookMachine(loading: db) }
                guard let machine, let capture = machine.captures[captureID] else { continue }
                launch(turnID: turn.id, plan: plan, context: machine.gradingContext(capture: capture))
            } else {
                launch(turnID: turn.id, plan: plan, context: nil)
            }
        }
        await recoverAbandonedChats(abandonedChats)
    }
}
