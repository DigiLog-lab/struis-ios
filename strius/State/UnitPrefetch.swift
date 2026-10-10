import Foundation
import GRDB
import OSLog

private let unitPrefetchLog = Logger(subsystem: "com.digiloglab.strius", category: "unit-prefetch")

/// 全体像の先回り(信頼性計画 P2 の 5、A12)。単元づくり・範囲の作り直しの返事が `<struis_workbook_proposal>` を
/// 書き終えた時点で、返事の残り(記録・記憶のブロック、検証の差し戻し)を待たずに、同じ依頼文で全体像のターンを始める。
/// 台帳には返事が確定して提案の行ができた時に結ぶ(依頼文が同じ時だけ)。違えば捨てて、ふつうに組む。
nonisolated struct UnitPrefetch: Sendable {
    let turnID: String
    let request: String
    let plan: TurnPlan
    let task: Task<TurnOutcome, Never>
}

/// 返事の本文の差分を、届いた順に組み立てる(ランナーは 1 つのターンの通知を順に呼ぶ)。
nonisolated final class ReplyStreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var itemID = ""
    private var text = ""
    private var proposalSeen = false

    /// 差分を足し、書き終わった提案の依頼文が初めて現れたらそれを返す。
    func append(itemID: String, delta: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if itemID != self.itemID {
            self.itemID = itemID
            text = ""
        }
        text += delta
        guard !proposalSeen, delta.contains(">"), text.range(of: "</struis_workbook_proposal>", options: .caseInsensitive) != nil else { return nil }
        let (_, proposal, _) = LearnerText.extractWorkbookBlocks(text)
        guard let request = (proposal?["request"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !request.isEmpty else { return nil }
        proposalSeen = true
        return request
    }
}

extension TurnCoordinator {
    /// 返事の中で提案が書き終わった: 全体像のターンを先に始める(返事 1 つにつき 1 回)。
    func prefetchUnit(messageID: String, request: String) async {
        guard unitPrefetches[messageID] == nil else { return }
        let turnID = LedgerID.make()
        let plan: TurnPlan
        do {
            let machine = try await ledger.read { db in try WorkbookMachine(loading: db) }
            plan = try await composer.unit(planID: turnID, machine: machine, request: request)
        } catch {
            unitPrefetchLog.error("unit prefetch compose failed: \(String(describing: error), privacy: .public)")
            return
        }
        let runner = self.runner
        let key = TurnActivityKey.unitPrefetch(messageID: messageID)
        let task = Task<TurnOutcome, Never> { [weak self] in
            guard let self else {
                return TurnOutcome(planID: plan.id, round: plan.round, status: .interrupted, codexThreadID: nil, codexTurnID: nil, finalText: "", executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: 0)
            }
            let activity = TurnActivityBoard.sink(key)
            defer { activity.finish() }
            let acquired = await self.acquire(kind: .workbookUnit, turnID: turnID)
            let started = Date()
            var outcome = TurnOutcome(planID: plan.id, round: plan.round, status: .interrupted, codexThreadID: nil, codexTurnID: nil, finalText: "", executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: 0)
            if acquired {
                do {
                    outcome = try await runner.run(plan) { event in activity.send(event) }
                } catch {
                    outcome = TurnOutcome(planID: plan.id, round: plan.round, status: .failed, codexThreadID: nil, codexTurnID: nil, finalText: "", executions: [], rateLimits: nil, files: [], error: error.localizedDescription, elapsedMs: Int(Date().timeIntervalSince(started) * 1000))
                }
            }
            await self.release(turnID: turnID, kind: .workbookUnit, acquired: acquired)
            return outcome
        }
        unitPrefetches[messageID] = UnitPrefetch(turnID: turnID, request: request, plan: plan, task: task)
        unitPrefetchLog.info("prefetching unit for reply \(messageID, privacy: .public)")
    }

    /// 返事が失敗した・止まった: 先回りの全体像を捨てる。
    func discardUnitPrefetch(messageID: String) async {
        guard let prefetch = unitPrefetches.removeValue(forKey: messageID) else { return }
        await runner.interrupt(planID: prefetch.turnID)
        _ = await prefetch.task.value
        WorkspaceStager.cleanup(plan: prefetch.plan)
    }

    /// 提案の行ができた: 同じ依頼文の先回りがあれば、それをこの提案の全体像のターンとして結ぶ。無ければ false。
    /// 結んだ時点でターンの行を `running` で書く(起動し直した時は、ふつうのターンと同じく組み直される)。
    func adoptUnitPrefetch(proposalID: String, messageID: String) async -> Bool {
        guard let prefetch = unitPrefetches.removeValue(forKey: messageID) else { return false }
        let request = (try? await ledger.read { db in try WorkbookMachine(loading: db).proposals[proposalID]?.request }) ?? nil
        guard let request, request.trimmingCharacters(in: .whitespacesAndNewlines) == prefetch.request else {
            unitPrefetchLog.info("unit prefetch for \(messageID, privacy: .public) dropped: request changed")
            await runner.interrupt(planID: prefetch.turnID)
            _ = await prefetch.task.value
            WorkspaceStager.cleanup(plan: prefetch.plan)
            return false
        }
        let turnID = prefetch.turnID
        let now = LedgerClock.now()
        try? await ledger.append([.upsert("turn.running", TurnRecord(
            id: turnID, kind: TurnPlan.Kind.workbookUnit.rawValue, targetId: proposalID, threadId: nil, status: "running", round: 1,
            plan: prefetch.plan.json, outcome: nil, codexThreadId: nil, codexTurnId: nil, executions: .emptyArray, error: nil,
            createdAt: now, startedAt: now, completedAt: nil
        ))])
        // 「止める」(`interrupt(targetID:)`)が、このターンも見つけて止められるように登録する。
        registerChatTask(turnID: turnID, task: Task { _ = await prefetch.task.value })
        Task { await self.applyUnitPrefetch(prefetch, proposalID: proposalID) }
        unitPrefetchLog.info("adopted unit prefetch for proposal \(proposalID, privacy: .public)")
        return true
    }

    private func applyUnitPrefetch(_ prefetch: UnitPrefetch, proposalID: String) async {
        let outcome = await prefetch.task.value
        let turnID = prefetch.turnID
        try? await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            guard machine.proposals[proposalID] != nil, try TurnRecord.fetchOne(db, key: turnID) != nil else { return ([], ()) }
            TurnApplier.unit(machine: &machine, proposalID: proposalID, outcome: outcome)
            var events = machine.events
            if var turn = try TurnRecord.fetchOne(db, key: turnID) {
                turn.status = outcome.status.rawValue
                turn.outcome = outcome.json
                turn.codexThreadId = outcome.codexThreadID
                turn.codexTurnId = outcome.codexTurnID
                turn.executions = .array(outcome.executions)
                turn.error = outcome.error
                turn.completedAt = LedgerClock.now()
                events.append(.upsert("turn.\(outcome.status.rawValue)", turn))
            }
            return (events, ())
        }
        WorkspaceStager.cleanup(plan: prefetch.plan)
        clearRunning(turnID: turnID)
        notifyNotice(Notice(turnID: turnID, kind: .workbookUnit, targetID: proposalID, status: outcome.status.rawValue))
    }
}
