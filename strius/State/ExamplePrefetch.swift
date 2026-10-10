import Foundation
import GRDB
import OSLog

private let prefetchLog = Logger(subsystem: "com.digiloglab.strius", category: "example-prefetch")

/// 先回りで作る例題(待ち時間の体験 §3.1)。段階 1(要点)の説明が出終わって会話が止まっている間に、
/// 小単元の Codex thread をその時点で分岐し(`thread/fork`)、段階 2 の起動ターンを分岐の上で回しておく。
/// 台帳には書かない(学習者には見えない)。「先に進む」の時に分岐の時点から会話が進んでいなければ、
/// 進める・起動を記録する・例題と解説を書く・会話を分岐先の thread へ付け替える、を 1 つのトランザクションで行う。
/// 会話が進んでいた・進行が更新されていた時は捨てて、ふつうに起こす(§6 の待ちになる)。
nonisolated struct ExamplePrefetch: Sendable {
    let subunitID: String
    let threadID: String
    /// 例題の回(`example_round`)と、起動の記録に使うキー。
    let round: Int
    let kickoffKey: String
    /// 分岐の元(小単元の会話の Codex thread と、その最後のターン)。
    let baseCodexThreadID: String
    let baseLastTurnID: String
    let kickoffText: String
    let startedAt: String
    var completedAt: String?
    var state: ChatTurns.State
    var plan: TurnPlan?
    var ready = false
}

extension TurnCoordinator {
    /// 段階 1 の小単元で会話が止まっていれば、段階 2 の例題を先回りで作り始める。作っている・作ってある(まだ使える)なら何もしない。
    func prefetchExampleIfNeeded(subunitID: String) async {
        guard examplePrefetchTasks[subunitID] == nil else { return }
        let profile = OnboardingProfile.load()?.promptSummary
        let learnerID = ledger.deviceID
        let info: (threadID: String, round: Int, key: String, text: String, view: LedgerJSON?, codexThreadID: String, lastTurnID: String, progress: ProgressState)?
        do {
            info = try await ledger.read { db in
                let machine = try WorkbookMachine(loading: db)
                // 段階 1(「先に進む」の先)と、類題・演習で誤答した後(「例題に戻る」の先。A13)。
                guard let row = machine.subunits[subunitID], row.status == "active", [1, 3, 4].contains(row.stage),
                      let threadID = row.metadata["thread_id"]?.stringValue,
                      row.metadata["kickoffs"]?["1:0"] != nil,
                      let mapping = try CodexThreadRecord.fetchOne(db, key: threadID), let lastTurnID = mapping.lastTurnId,
                      let last = try ChatRepository.messages(db, threadID: threadID).last, last.role == "assistant", last.status == "completed"
                else { return nil }
                var ahead = machine
                if row.stage == 1 {
                    ahead.subunits[subunitID]?.stage = 2
                } else {
                    // 学習者が「例題に戻る」を押した後と同じ状態を、台帳には書かずに作る(戻る前の段・誤りの種類・例題の回)。
                    guard (try? ahead.returnToExample(subunitID: subunitID)) != nil else { return nil }
                }
                guard let aheadRow = ahead.subunits[subunitID] else { return nil }
                let round = aheadRow.metadata["example_round"]?.intValue ?? 0
                let key = "2:\(round)"
                guard row.metadata["kickoffs"]?[key] == nil else { return nil }
                let text = Self.subunitKickoffText(machine: ahead, row: aheadRow, profile: profile)
                return (threadID, round, key, text, ahead.currentViewContext(subunitID: subunitID, setID: nil), mapping.codexThreadId, lastTurnID, try ChatRepository.progressState(db))
            }
        } catch {
            prefetchLog.error("prefetch read failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard let info, !isChatRunning(threadID: info.threadID) else { return }
        if let existing = examplePrefetches[subunitID] {
            // 同じ時点から作ったものがまだ使える。
            if existing.baseLastTurnID == info.lastTurnID, existing.round == info.round { return }
            discardExamplePrefetch(subunitID: subunitID)
        }
        let turnID = LedgerID.make()
        let state = ChatTurns.State(
            turnID: turnID, threadID: info.threadID, userMessageID: LedgerID.make(), assistantMessageID: LedgerID.make(),
            learnerID: learnerID, text: info.text, attachments: [], workbookView: info.view, codexThreadID: nil,
            progressBefore: info.progress, progressAfter: info.progress, subunitID: subunitID, expectsExample: true
        )
        let prefetch = ExamplePrefetch(
            subunitID: subunitID, threadID: info.threadID, round: info.round, kickoffKey: info.key,
            baseCodexThreadID: info.codexThreadID, baseLastTurnID: info.lastTurnID, kickoffText: info.text,
            startedAt: LedgerClock.now(), state: state
        )
        examplePrefetches[subunitID] = prefetch
        prefetchTurns.insert(turnID)
        prefetchLog.info("prefetching example for \(subunitID, privacy: .public)")
        examplePrefetchTasks[subunitID] = Task { [weak self] in
            await self?.runExamplePrefetch(prefetch)
        }
    }

    private func runExamplePrefetch(_ initial: ExamplePrefetch) async {
        var prefetch = initial
        let subunitID = prefetch.subunitID
        let turnID = prefetch.state.turnID
        // 先回りが間に合わず学習者が待っている時に、例題の待ちへ実際の出来事を出す(信頼性計画 P2)。
        let activity = TurnActivityBoard.sink(TurnActivityKey.examplePrefetch(subunitID: subunitID))
        defer { activity.finish() }
        let acquired = await acquire(kind: .workbookSet, turnID: turnID)
        defer {
            release(turnID: turnID, kind: .workbookSet, acquired: acquired)
            examplePrefetchTasks[subunitID] = nil
        }
        guard acquired, examplePrefetches[subunitID]?.state.turnID == turnID else { return }
        var state = prefetch.state
        var succeeded = false
        do {
            state.codexThreadID = try await forkCodexThread(from: (prefetch.baseCodexThreadID, prefetch.baseLastTurnID))
            var roundText: String?
            while true {
                let plan = try await ChatTurns.compose(ledger: ledger, assets: assets, state: &state, roundText: roundText)
                prefetch.plan = plan
                let outcome = try await runner.run(plan) { event in activity.send(event) }
                let applied = await ChatTurns.applyRound(ledger: ledger, state: &state, outcome: outcome)
                if case .again(let text) = applied {
                    roundText = text
                    continue
                }
                if case .done = applied { succeeded = state.exampleProblem != nil }
                break
            }
        } catch {
            prefetchLog.error("example prefetch failed: \(String(describing: error), privacy: .public)")
        }
        let yielded = takePreempted(turnID)
        guard succeeded, !yielded, examplePrefetches[subunitID]?.state.turnID == turnID else {
            if let plan = prefetch.plan { WorkspaceStager.cleanup(plan: plan) }
            if examplePrefetches[subunitID]?.state.turnID == turnID { examplePrefetches[subunitID] = nil }
            prefetchLog.info("example prefetch for \(subunitID, privacy: .public) dropped (yielded=\(yielded, privacy: .public))")
            return
        }
        prefetch.state = state
        prefetch.completedAt = LedgerClock.now()
        prefetch.ready = true
        examplePrefetches[subunitID] = prefetch
        prefetchLog.info("example prefetch for \(subunitID, privacy: .public) ready")
    }

    /// 作りかけ・作ってある先回りの例題を捨てる(会話が進んだ・段が変わった)。
    func discardExamplePrefetch(subunitID: String) {
        guard let prefetch = examplePrefetches.removeValue(forKey: subunitID) else { return }
        if examplePrefetchTasks[subunitID] != nil {
            let runner = self.runner
            let planID = prefetch.state.turnID
            Task { await runner.interrupt(planID: planID) }
        }
        if let plan = prefetch.plan { WorkspaceStager.cleanup(plan: plan) }
    }

    /// 会話 thread の先回りの例題を捨てる(その会話で学習者が送った時)。
    func discardExamplePrefetch(threadID: String) {
        for (subunitID, prefetch) in examplePrefetches where prefetch.threadID == threadID {
            discardExamplePrefetch(subunitID: subunitID)
        }
    }

    /// 先回りの例題を使う。`advancing` は「先に進む」(段階 1→2 を同じトランザクションで進める)。false は、もう段階 2 に
    /// 進んでいて、その回の起動がまだ無い時(先回りが間に合わなかった時、でき次第使う)。
    /// 分岐の時点から会話も進行も動いていなければ、進める・起動の記録・起動メッセージと例題の返事・例題の保存・
    /// 会話の付け替えを 1 つのトランザクションで行う。使えなければ nil(呼び手はふつうにモデルのターンを起こす)。
    func adoptPrefetchedExample(subunitID: String, advancing: Bool) async -> WorkbookSubunitDTO? {
        guard let prefetch = examplePrefetches[subunitID], prefetch.ready, !isChatRunning(threadID: prefetch.threadID) else { return nil }
        let state = prefetch.state
        let memory = await ChatTurns.applyMemory(ledger: ledger, state: state)
        do {
            let (summary, prefetchSetID): (WorkbookSubunitDTO, String?) = try await ledger.commit { db in
                var machine = try WorkbookMachine(loading: db)
                guard let row = machine.subunits[subunitID], row.stage == (advancing ? 1 : 2), row.status == "active",
                      row.metadata["kickoffs"]?[prefetch.kickoffKey] == nil,
                      (row.metadata["example_round"]?.intValue ?? 0) == prefetch.round,
                      let mapping = try CodexThreadRecord.fetchOne(db, key: prefetch.threadID),
                      mapping.codexThreadId == prefetch.baseCodexThreadID, mapping.lastTurnId == prefetch.baseLastTurnID,
                      (try ChatRepository.latestProgress(db)?.revision ?? 0) == state.progressBefore.revision,
                      let thread = try ThreadRecord.fetchOne(db, key: prefetch.threadID)
                else { throw LedgerError.rejected(code: "prefetch_stale", message: "stale") }
                // 起動の記録(小単元の metadata.kickoffs)と同じく、同じ回の例題を二重に書かない。
                if advancing { _ = try machine.advance(subunitID: subunitID) }
                guard machine.recordKickoff(subunitID: subunitID, key: prefetch.kickoffKey, messageID: state.userMessageID) else {
                    throw LedgerError.rejected(code: "kickoff_exists", message: "already started")
                }
                let (_, userEvent) = ChatRepository.createMessage(
                    id: state.userMessageID, threadID: prefetch.threadID, role: "user", status: "completed", plainText: prefetch.kickoffText,
                    blocks: .array([.object(["kind": .string("text"), "payload": .object(["text": .string(prefetch.kickoffText)])])]),
                    metadata: .object([
                        "handled_as": .string("codex_app_server"), "source": .string("struis_kickoff"), "attachments": .emptyArray,
                        "hidden": .bool(true), "prefetched": .bool(true),
                    ])
                )
                let (pending, _) = ChatRepository.createMessage(
                    id: state.assistantMessageID, threadID: prefetch.threadID, role: "assistant", status: "pending", plainText: nil,
                    blocks: .emptyArray, metadata: .object(["handled_as": .string("codex_app_server"), "prefetched": .bool(true)])
                )
                let (events, finished) = try ChatTurns.finishEvents(db, state: state, memorySnapshot: memory, assistant: pending, machine: &machine)
                _ = thread
                let turn = TurnRecord(
                    id: state.turnID, kind: TurnPlan.Kind.chat.rawValue, targetId: state.assistantMessageID, threadId: prefetch.threadID,
                    status: "completed", round: state.round,
                    plan: .object(["chat": .object([
                        "thread_id": .string(prefetch.threadID), "user_message_id": .string(state.userMessageID),
                        "assistant_message_id": .string(state.assistantMessageID), "workbook_view": state.workbookView ?? .null,
                        "prefetched": .bool(true),
                    ])]),
                    outcome: nil, codexThreadId: state.codexThreadID, codexTurnId: state.codexTurnID, executions: .array(state.executions), error: nil,
                    createdAt: prefetch.startedAt, startedAt: prefetch.startedAt, completedAt: prefetch.completedAt ?? LedgerClock.now()
                )
                return ([userEvent] + machine.events + events + [.upsert("turn.completed", turn)], (try machine.subunitSummary(id: subunitID), finished.prefetchSetID))
            }
            examplePrefetches[subunitID] = nil
            if let codexThreadID = state.codexThreadID, let memory = state.deliveredMemory {
                ThreadContextStore.shared.update(codexThreadID) { $0.memory = memory }
            }
            if let prefetchSetID { await startPrefetchedSet(setID: prefetchSetID) }
            if let plan = prefetch.plan { WorkspaceStager.cleanup(plan: plan) }
            prefetchLog.info("adopted prefetched example for \(subunitID, privacy: .public)")
            return summary
        } catch {
            prefetchLog.info("prefetched example not used: \(String(describing: error), privacy: .public)")
            discardExamplePrefetch(subunitID: subunitID)
            return nil
        }
    }
}

extension TurnCoordinator {
    /// 段階 2 に進んだ時、先回りの例題が作っている最中なら、でき次第それを使う(使えなければふつうに起こす)。
    /// 起こす側(小単元の画面)は待たずに済むよう、待つのは裏の Task で行う。先回りが無ければ false。
    func adoptPrefetchWhenReady(subunitID: String) -> Bool {
        if let task = examplePrefetchTasks[subunitID] {
            guard !adoptionWaits.contains(subunitID) else { return true }
            adoptionWaits.insert(subunitID)
            Task {
                await task.value
                let adopted = await self.adoptPrefetchedExample(subunitID: subunitID, advancing: false)
                await self.endAdoptionWait(subunitID: subunitID)
                if adopted == nil { _ = await self.kickoffSubunit(subunitID: subunitID) }
            }
            return true
        }
        return false
    }

    func endAdoptionWait(subunitID: String) {
        adoptionWaits.remove(subunitID)
    }

    /// 類題・演習の判定に誤りがあった: 「例題に戻る」の先の例題を先回りで作り始める(A13)。
    /// 学習者が戻らなければ使われない(「先に進む」と同じく、会話や進行が動いていれば捨てる)。
    func prefetchReturnExampleIfWrong(captureID: String) async {
        let subunitID: String?? = try? await ledger.read { db -> String? in
            guard let capture = try WorkbookCaptureRecord.fetchOne(db, key: captureID), capture.status == "graded",
                  let subunitID = capture.subunitId
            else { return nil }
            let wrong = (capture.verdicts.arrayValue ?? []).contains { $0["verdict"]?.stringValue != "correct" }
            return wrong ? subunitID : nil
        }
        if let subunitID = subunitID ?? nil { await prefetchExampleIfNeeded(subunitID: subunitID) }
    }

    /// 返事が終わった会話が段階 1 の小単元の会話なら、例題を先回りで作り始める。
    func prefetchExampleIfSubunitThread(threadID: String) async {
        // 段階 1 の会話が止まった時だけ(類題・演習の「例題に戻る」の先は、判定に誤りがあった時に作る。A13)。
        // 返事が記録を書いている間に「先に進む」で段階 3 に進んでいても、その返事の終わりで作らない。
        let subunitID = try? await ledger.read { db -> String? in
            let machine = try WorkbookMachine(loading: db)
            guard let id = machine.subunitID(threadID: threadID), machine.subunits[id]?.stage == 1 else { return nil }
            return id
        }
        if let subunitID = subunitID ?? nil { await prefetchExampleIfNeeded(subunitID: subunitID) }
    }
}
