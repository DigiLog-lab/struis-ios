import GRDB
import XCTest
@testable import strius

/// 見える返事を書き終えて、後ろの記録(進み具合・記憶)だけを書いている返事の間の送信と「先に進む」(§13.13 の 3・5)。
/// 送っても記録は止めず、送った質問は記録が台帳に書き終わってから同じ Codex thread で答える。準備OKは記録を待たずに出す。
@MainActor
final class ReplyTailQueueTests: XCTestCase {
    /// 返事の本文を流した後、記録の途中で止まって待つランナー(本物のランナーが長い記録を書いている間の再現)。
    @MainActor final class TailGateRunner: TurnRunning {
        enum Gate { case none, beforeTail, inTail }
        private let gateFor: @Sendable (String) -> Gate
        private var gates: [String: CheckedContinuation<Void, Never>] = [:]
        private var interrupted: Set<String> = []
        private(set) var interrupts: [String] = []
        /// 走り始めた・終わったチャットのターン(plan id)の順。
        private(set) var events: [String] = []
        private(set) var codexThreads: [String] = []

        init(gateFor: @escaping @Sendable (String) -> Gate) { self.gateFor = gateFor }

        func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome {
            guard plan.kind == .chat else { return try await MockTurnRunner().run(plan, progress: progress) }
            events.append("start:\(plan.id)")
            codexThreads.append(plan.thread.codexThreadID ?? "")
            let text = MockTurnRunner.chat(plan)
            let gate = gateFor(plan.turn?.text ?? "")
            let split = text.range(of: "\n<struis_")!
            let visible = String(text[..<split.lowerBound])
            var tail = String(text[split.lowerBound...])
            // 準備OKを本文のすぐ後に書く(起動文の指示どおり)。
            let ready = "\n<struis_workbook_example_ready/>"
            var head = ""
            if let range = tail.range(of: ready) { tail.removeSubrange(range); head = ready }
            func delta(_ value: String) { progress(TurnProgressEvent(kind: .replyDelta(itemID: plan.id, text: value), label: "返事を書いています", progressID: nil, allowDuplicate: true)) }
            delta(visible)
            if gate == .beforeTail { await wait(plan.id) }
            if !head.isEmpty { delta(head) }
            let open = tail.range(of: "<struis_progress_update>").map { tail[..<$0.upperBound] } ?? Substring(tail)
            delta(String(open) + "\n{\"goals\": [{\"title\": \"頂点を求める")
            if gate == .inTail { await wait(plan.id) }
            events.append("end:\(plan.id)")
            let threadID = plan.thread.codexThreadID ?? "thr_tail_\(UUID().uuidString.prefix(8).lowercased())"
            if interrupted.contains(plan.id) {
                return TurnOutcome(planID: plan.id, round: plan.round, status: .interrupted, codexThreadID: threadID, codexTurnID: nil, finalText: "", executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: 1)
            }
            return TurnOutcome(
                planID: plan.id, round: plan.round, status: .completed, codexThreadID: threadID, codexTurnID: "turn_\(plan.id.prefix(6))",
                finalText: text, executions: [], rateLimits: nil, files: [], error: nil, elapsedMs: 1
            )
        }

        private func wait(_ id: String) async {
            await withCheckedContinuation { gates[id] = $0 }
        }

        func interrupt(planID: String) async {
            interrupts.append(planID)
            interrupted.insert(planID)
            gates.removeValue(forKey: planID)?.resume()
        }

        var waiting: [String] { Array(gates.keys) }

        func release(_ id: String) { gates.removeValue(forKey: id)?.resume() }
    }

    private func waitUntil(_ message: String, timeout: Int = 400, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<timeout {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("timed out: \(message)")
    }

    private func rows(_ ledger: Ledger, _ threadID: String) async throws -> [MessageRecord] {
        try await ledger.read { db in try ChatRepository.messages(db, threadID: threadID) }
    }

    private func makeThread(_ ledger: Ledger) async throws -> String {
        let threadID = UUID().uuidString.lowercased()
        try await ledger.append([ChatRepository.createThread(id: threadID, title: "記録中の送信").1])
        return threadID
    }

    /// 記録だけを書いている間に送る: 前の返事は止めずに出来上がり、送った質問は後から同じ Codex thread で答える。
    func testSendDuringPrivateTailQueuesWithoutStoppingTheRecord() async throws {
        let ledger = try Ledger.inMemory()
        let runner = TailGateRunner { text in text.contains("最初の質問") ? .inTail : .none }
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: runner)
        let threadID = try await makeThread(ledger)
        let store = ChatStore(ledger: ledger, turns: turns)
        await store.adoptThread(id: try XCTUnwrap(UUID(uuidString: threadID)))

        let firstAccepted = await store.send(text: "最初の質問")
        XCTAssertTrue(firstAccepted)
        try await waitUntil("first reply reaches the private record") { !(runner.waiting.isEmpty) }
        await store.refreshCurrentThread()
        try await waitUntil("board sees the private tail") { store.replyFinishingInBackground }
        XCTAssertTrue(store.isSending)
        XCTAssertFalse(store.isReplyBusy, "記録だけを書いている間は入力欄を停止ボタンにしない")

        let queuedAccepted = await store.send(text: "なんですかこれ")
        XCTAssertTrue(queuedAccepted, "記録の間でも送れる")
        var current = try await rows(ledger, threadID)
        XCTAssertEqual(current.filter { $0.role == "user" }.map(\.plainText), ["最初の質問", "なんですかこれ"], "送った質問はすぐ吹き出しに出る")
        XCTAssertEqual(current.filter { $0.role == "assistant" }.map(\.status), ["pending", "pending"])
        XCTAssertTrue(store.isReplyBusy, "並べた質問の返事を待つ間は、いつもの返事待ち")
        let firstPlan = try XCTUnwrap(runner.waiting.first)
        XCTAssertEqual(runner.events, ["start:\(firstPlan)"], "並べた質問は、前の返事の記録が終わるまで始めない")

        runner.release(firstPlan)
        try await waitUntil("both replies finish") {
            let replies = try await self.rows(ledger, threadID).filter { $0.role == "assistant" }
            let running = await turns.isChatRunning(threadID: threadID)
            return replies.allSatisfy { $0.status == "completed" } && !running
        }
        XCTAssertEqual(runner.interrupts, [], "記録中の返事は止めない")
        let events = runner.events
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(Array(events.prefix(2)), ["start:\(firstPlan)", "end:\(firstPlan)"], "前の返事が終わってから次が始まる")
        let threads = runner.codexThreads
        XCTAssertEqual(threads.first, "", "最初のターンは新しい Codex thread")
        current = try await rows(ledger, threadID)
        let mapped = try await ledger.read { db in try CodexThreadRecord.fetchOne(db, key: threadID)?.codexThreadId }
        XCTAssertEqual(threads.last, mapped, "並べた質問は前の返事と同じ Codex thread で答える")
        let progress = try await ledger.read { db in try ChatRepository.progressState(db) }
        XCTAssertEqual(progress.revision, 2, "前の返事の記録も、並べた質問の記録も、両方とも残る")
        XCTAssertNil(current.first { $0.metadata["folded"]?.boolValue == true }, "前の返事は「停止しました」にならない")
    }

    /// 見える本文を書いている間は、これまでどおり返事待ち(停止ボタン)で、並べずに断る。
    func testVisibleWritingStaysBusy() async throws {
        let ledger = try Ledger.inMemory()
        let runner = TailGateRunner { text in text.contains("最初の質問") ? .beforeTail : .none }
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: runner)
        let threadID = try await makeThread(ledger)
        let store = ChatStore(ledger: ledger, turns: turns)
        await store.adoptThread(id: try XCTUnwrap(UUID(uuidString: threadID)))
        let firstAccepted = await store.send(text: "最初の質問")
        XCTAssertTrue(firstAccepted)
        try await waitUntil("first reply writes its visible text") { !(runner.waiting.isEmpty) }
        await store.refreshCurrentThread()
        try await waitUntil("board has the visible text") {
            let reply = store.allMessages.last { $0.role == .assistant }
            return reply.flatMap { TurnActivityBoard.shared.activity(TurnActivityKey.reply($0.id)) }.map { !$0.visibleReply.isEmpty } ?? false
        }
        XCTAssertFalse(store.replyFinishingInBackground)
        XCTAssertTrue(store.isReplyBusy, "本文を書いている間は停止ボタン")
        let interruptAccepted = await store.send(text: "割り込み")
        XCTAssertFalse(interruptAccepted, "本文の途中は、並べずに断る(例題の段は止めてから送る)")
        // 協調側は、並べる指定(画面が記録中だと判断した時だけ付ける)が無い送信を断る。
        do {
            _ = try await turns.sendChat(TurnCoordinator.ChatSend(threadID: threadID, text: "並べない", attachments: [], workbookView: nil))
            XCTFail("並べる指定の無い送信は断る")
        } catch let error as LedgerError {
            XCTAssertEqual(error.code, "codex_turn_in_progress")
        }
        runner.release(try XCTUnwrap(runner.waiting.first))
        try await waitUntil("released turn waits again in tail or finishes") {
            !(await turns.isChatRunning(threadID: threadID))
        }
    }

    /// 並べた質問だけを止める: 前の返事の記録は止まらず、並べた質問の返事は「停止しました」。
    func testStoppingQueuedSendLeavesTheRecordRunning() async throws {
        let ledger = try Ledger.inMemory()
        let runner = TailGateRunner { text in text.contains("最初の質問") ? .inTail : .none }
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: runner)
        let threadID = try await makeThread(ledger)
        _ = try await turns.sendChat(.init(threadID: threadID, text: "最初の質問", attachments: [], workbookView: nil))
        try await waitUntil("first reply reaches the private record") { !(runner.waiting.isEmpty) }
        var send = TurnCoordinator.ChatSend(threadID: threadID, text: "やっぱりいい", attachments: [], workbookView: nil)
        send.queuesBehindReply = true
        let queued = try await turns.sendChat(send)
        let recording = try XCTUnwrap(runner.waiting.first)
        await turns.interruptChat(threadID: threadID)
        try await waitUntil("queued reply stops") {
            try await self.rows(ledger, threadID).first { $0.id == queued.assistantMessageID }?.status == "failed"
        }
        XCTAssertFalse(runner.interrupts.contains(recording), "記録中の返事には停止を送らない")
        let stillRecording = await turns.isChatRunning(threadID: threadID)
        XCTAssertTrue(stillRecording, "並べた質問を止めても、前の返事が記録を書いている間は会話は動いている")
        XCTAssertEqual(runner.waiting, [recording])
        runner.release(recording)
        try await waitUntil("record finishes") { !(await turns.isChatRunning(threadID: threadID)) }
        let first = try await rows(ledger, threadID).first { $0.role == "assistant" }
        XCTAssertEqual(first?.status, "completed")
        let queuedTurn = try await ledger.read { db in try TurnRecord.fetchOne(db, key: queued.turnID) }
        XCTAssertEqual(queuedTurn?.status, "interrupted")
    }

    /// 段階 2: 準備OKは、返事の記録が終わるのを待たずに小単元に記録する(「先に進む」がすぐ出る)。先回りの一枚は 1 つだけ。
    func testExampleReadyIsRecordedBeforeTheTailFinishes() async throws {
        let ledger = try Ledger.inMemory()
        let runner = TailGateRunner { text in text.contains("できた") ? .inTail : .none }
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: runner)
        let subunitID = try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let unitID = machine.createUnit(title: "二次関数", outcome: "", source: "consult", subunits: [.init(title: "頂点", outcome: "頂点を求める", n: 5)], firstStage: 2)
            return (machine.events, machine.orderedSubunits(unitID: unitID)[0].id)
        }
        let kickoff = await turns.kickoffSubunit(subunitID: subunitID)
        XCTAssertEqual(kickoff, .started)
        let threadID = try await turns.subunitThread(subunitID: subunitID)
        try await waitUntil("example kickoff finishes") { !(await turns.isChatRunning(threadID: threadID)) }
        var summary = try await ledger.read { db in try WorkbookMachine(loading: db).subunitSummary(id: subunitID) }
        XCTAssertNotNil(summary.exampleProblem)
        XCTAssertEqual(summary.exampleReady, false)

        _ = try await turns.sendChat(.init(threadID: threadID, text: "できた", attachments: [], workbookView: nil))
        try await waitUntil("ready reply reaches the private record") { !(runner.waiting.isEmpty) }
        try await waitUntil("ready recorded while the record is still being written") {
            try await ledger.read { db in try WorkbookMachine(loading: db).subunitSummary(id: subunitID) }.exampleReady == true
        }
        let stillRunning = await turns.isChatRunning(threadID: threadID)
        XCTAssertTrue(stillRunning, "返事(記録)はまだ動いている")
        // 記録の間に「先に進む」を押せる(段は台帳の規則どおり進む)。
        summary = try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let advanced = try machine.advance(subunitID: subunitID)
            return (machine.events, advanced)
        }
        XCTAssertEqual(summary.stage, 3)

        runner.release(try XCTUnwrap(runner.waiting.first))
        try await waitUntil("ready reply finishes") { !(await turns.isChatRunning(threadID: threadID)) }
        let reply = try await rows(ledger, threadID).last { $0.role == "assistant" }
        XCTAssertEqual(reply?.status, "completed", "先に進んだ後でも、返事の記録は最後まで書かれる")
        let prefetched = try await ledger.read { db in
            try WorkbookMachine(loading: db).sets.values.filter { $0.subunitId == subunitID && $0.gate["prefetched"]?.boolValue == true }.count
        }
        XCTAssertEqual(prefetched, 1, "行き先の一枚は 1 回だけ先回りで組む")
        let row = try await ledger.read { db in try WorkbookMachine(loading: db).subunits[subunitID] }
        XCTAssertEqual(row?.metadata["example_ready"]?["message_id"]?.stringValue, reply?.id)
    }
}
