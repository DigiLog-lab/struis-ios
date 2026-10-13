import GRDB
import XCTest
@testable import strius

/// 要点・例題をモデルが始める(§13.13)と単元づくりの起動(§13.12)。起動メッセージは学習者に見せず、
/// 段ごとに台帳で冪等。段階 2 の例題は `<struis_workbook_example>` から台帳へ入る。
final class ChatKickoffTests: XCTestCase {
    private func makeCoordinator() throws -> (Ledger, TurnCoordinator, String) {
        let ledger = try Ledger.inMemory()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: MockTurnRunner())
        return (ledger, turns, "")
    }

    private func seedSubunit(_ ledger: Ledger, stage: Int) async throws -> String {
        try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let unitID = machine.createUnit(title: "二次関数", outcome: "", source: "consult", subunits: [.init(title: "頂点", outcome: "頂点を求める", n: 5)], firstStage: stage)
            return (machine.events, machine.orderedSubunits(unitID: unitID)[0].id)
        }
    }

    private func waitForReply(_ ledger: Ledger, turns: TurnCoordinator, threadID: String, count: Int = 1) async throws -> [MessageRecord] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        var lastRows: [MessageRecord] = []
        while clock.now < deadline {
            let rows = try await ledger.read { db in try ChatRepository.messages(db, threadID: threadID) }
            lastRows = rows
            let done = rows.filter { $0.role == "assistant" && $0.status != "pending" }
            if done.count >= count, !rows.contains(where: { $0.status == "pending" }),
               !(await turns.isChatRunning(threadID: threadID)) { return rows }
            try await Task.sleep(for: .milliseconds(25))
        }
        let running = await turns.isChatRunning(threadID: threadID)
        let states = lastRows.map { "\($0.role):\($0.status)" }.joined(separator: ", ")
        throw LedgerError.invalid("reply did not finish in 30s (running=\(running), expected=\(count), messages=[\(states)])")
    }

    /// Model the real interval after reply commit and before reservation release without
    /// adding a production pause hook or depending on a scheduler winning a race.
    @MainActor func testCompletedReplyKeepsConversationBusyUntilReservationReleased() async throws {
        do {
            let (ledger, turns, _) = try makeCoordinator()
            let thread = UUID()
            let threadID = thread.uuidString.lowercased()
            let (_, threadEvent) = ChatRepository.createThread(id: threadID, title: "completion fixture")
            let (_, replyEvent) = ChatRepository.createMessage(
                threadID: threadID, role: "assistant", status: "completed", plainText: "saved reply",
                blocks: .emptyArray, metadata: .emptyObject
            )
            try await ledger.append([threadEvent, replyEvent])
            let activeTurnID = LedgerID.make()
            await turns.registerChat(turnID: activeTurnID, threadID: threadID)
            let acquired = await turns.acquireChatSlot(turnID: activeTurnID)
            XCTAssertTrue(acquired)
            let store = ChatStore(ledger: ledger, turns: turns)
            await store.adoptThread(id: thread)
            XCTAssertTrue(store.isSending,
                          "A completed reply does not release the coordinator reservation")

            await turns.finishedChat(turnID: activeTurnID, threadID: threadID)
            let terminal = TurnCoordinator.Notice(turnID: activeTurnID, kind: .chat, targetID: threadID, status: "completed")
            await store.handleTurnNotice(terminal)
            XCTAssertFalse(store.isSending)

            // Delay the old notice until after another turn has reserved this thread.
            let replacementTurnID = LedgerID.make()
            await turns.registerChat(turnID: replacementTurnID, threadID: threadID)
            let replacementAcquired = await turns.acquireChatSlot(turnID: replacementTurnID)
            XCTAssertTrue(replacementAcquired)
            await store.handleTurnNotice(terminal)
            XCTAssertTrue(store.isSending,
                          "A late terminal notice cannot enable sending during the next turn")
            await turns.finishedChat(turnID: replacementTurnID, threadID: threadID)
            await store.handleTurnNotice(.init(turnID: replacementTurnID, kind: .chat, targetID: threadID, status: "completed"))
            XCTAssertFalse(store.isSending)
            let accepted = await store.send(text: "next question")
            XCTAssertTrue(accepted, "When the UI enables sending, the coordinator accepts it")
            let rows = try await waitForReply(ledger, turns: turns, threadID: threadID, count: 2)
            XCTAssertEqual(rows.filter { $0.role == "user" }.count, 1, "No automatic replay or duplicate send")
        }
    }

    @MainActor func testFailureReleasesConversationBeforeAnotherSend() async throws {
        let ledger = try Ledger.inMemory()
        let turns = TurnCoordinator(ledger: ledger, assets: AssetCache(lenient: true), runner: ChatFailingRunner())
        let threadID = LedgerID.make()
        try await ledger.append([ChatRepository.createThread(id: threadID, title: "failure fixture").1])
        let store = ChatStore(ledger: ledger, turns: turns)
        await store.adoptThread(id: try XCTUnwrap(UUID(uuidString: threadID)))
        let firstAccepted = await store.send(text: "first question")
        XCTAssertTrue(firstAccepted)
        let firstRows = try await waitForReply(ledger, turns: turns, threadID: threadID)
        XCTAssertEqual(firstRows.last { $0.role == "assistant" }?.status, "failed")
        await store.refreshCurrentThread()
        XCTAssertFalse(store.isSending)
        let nextAccepted = await store.send(text: "next question")
        XCTAssertTrue(nextAccepted)
        _ = try await waitForReply(ledger, turns: turns, threadID: threadID, count: 2)
    }

    func testStoppedBeforeChatSlotReleasesOnlyItsOwnReservation() async throws {
        let (ledger, turns, _) = try makeCoordinator()
        let threadID = LedgerID.make()
        try await ledger.append([ChatRepository.createThread(id: threadID, title: "queued fixture").1])
        // Hold the single chat slot so the learner's turn is stopped before runner execution.
        let blockerID = LedgerID.make()
        let acquired = await turns.acquireChatSlot(turnID: blockerID)
        XCTAssertTrue(acquired)
        let first = try await turns.sendChat(.init(threadID: threadID, text: "queued question", attachments: [], workbookView: nil))
        await turns.stopChat(turnID: first.turnID)
        let stoppedRows = try await waitForReply(ledger, turns: turns, threadID: threadID)
        XCTAssertEqual(stoppedRows.last { $0.role == "assistant" }?.status, "failed")
        let stopped = try await ledger.read { db in try TurnRecord.fetchOne(db, key: first.turnID) }
        XCTAssertEqual(stopped?.status, "interrupted")
        await turns.release(turnID: blockerID, kind: .chat, acquired: true)
        _ = try await turns.sendChat(.init(threadID: threadID, text: "next question", attachments: [], workbookView: nil))
        let rows = try await waitForReply(ledger, turns: turns, threadID: threadID, count: 2)
        XCTAssertEqual(rows.last { $0.role == "assistant" }?.status, "completed")
    }

    func testStage1KickoffStartsOnceWithHiddenMessage() async throws {
        let (ledger, turns, _) = try makeCoordinator()
        let subunitID = try await seedSubunit(ledger, stage: 1)
        let first = await turns.kickoffSubunit(subunitID: subunitID)
        XCTAssertEqual(first, .started)
        let second = await turns.kickoffSubunit(subunitID: subunitID)
        XCTAssertTrue(second == .alreadyStarted || second == .busy, "二重タップで重複しない: \(second)")
        let threadID = try await turns.subunitThread(subunitID: subunitID)
        let rows = try await waitForReply(ledger, turns: turns, threadID: threadID)
        let kickoff = await turns.kickoffSubunit(subunitID: subunitID)
        XCTAssertEqual(kickoff, .alreadyStarted, "開き直しで重複しない")
        let users = rows.filter { $0.role == "user" }
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users[0].metadata["hidden"]?.boolValue, true, "起動メッセージは学習者に見せない")
        XCTAssertEqual(rows.filter { $0.role == "assistant" }.first?.status, "completed")
        let thread = try await ledger.read { db in try ThreadRecord.fetchOne(db, key: threadID) }
        XCTAssertEqual(thread?.source, "subunit", "小単元ごとの会話")
    }

    func testStage2KickoffPinsExampleAndReturnStartsNewRound() async throws {
        var phase = "setup"
        do {
            let (ledger, turns, _) = try makeCoordinator()
            let subunitID = try await seedSubunit(ledger, stage: 2)
            let kickoff = await turns.kickoffSubunit(subunitID: subunitID)
            XCTAssertEqual(kickoff, .started)
            let threadID = try await turns.subunitThread(subunitID: subunitID)
            let rows = try await waitForReply(ledger, turns: turns, threadID: threadID)
            let reply = try XCTUnwrap(rows.last { $0.role == "assistant" })
            XCTAssertFalse((reply.plainText ?? "").contains("struis_workbook_example"), "block は本文から剥がす")
            phase = "read_initial_summary"
            print("KICKOFF_STAGE2 phase=\(phase)")
            var summary = try await ledger.read { db in try WorkbookMachine(loading: db).subunitSummary(id: subunitID) }
            XCTAssertEqual(summary.exampleProblem, "y = x^2 - 4x + 3 の頂点の座標を求めよ")
            XCTAssertEqual(summary.exampleReady, false, "例題を出しただけでは「先に進む」を出さない")

            // 学習者の答えへの返事で準備OKが出る(起動の返事以外でも受ける)。
            phase = "send_learner_answer"
            print("KICKOFF_STAGE2 phase=\(phase)")
            _ = try await turns.sendChat(TurnCoordinator.ChatSend(threadID: threadID, text: "できた", attachments: [], workbookView: nil))
            phase = "wait_learner_reply"
            print("KICKOFF_STAGE2 phase=\(phase)")
            let afterAnswer = try await waitForReply(ledger, turns: turns, threadID: threadID, count: 2)
            let readyReply = try XCTUnwrap(afterAnswer.last { $0.role == "assistant" })
            XCTAssertFalse((readyReply.plainText ?? "").contains("struis_workbook_example_ready"), "準備OKの block は本文から剥がす")
            phase = "read_ready_summary"
            print("KICKOFF_STAGE2 phase=\(phase)")
            summary = try await ledger.read { db in try WorkbookMachine(loading: db).subunitSummary(id: subunitID) }
            XCTAssertEqual(summary.exampleReady, true)

            // 類題へ → 例題に戻る → 新しい回の起動が起きる。
            phase = "advance_and_return"
            print("KICKOFF_STAGE2 phase=\(phase)")
            _ = try await ledger.commit { db in
                var machine = try WorkbookMachine(loading: db)
                _ = try machine.advance(subunitID: subunitID)
                _ = try machine.returnToExample(subunitID: subunitID)
                return (machine.events, ())
            }
            summary = try await ledger.read { db in try WorkbookMachine(loading: db).subunitSummary(id: subunitID) }
            XCTAssertNil(summary.exampleProblem, "前の回の例題は出さない")
            XCTAssertEqual(summary.kickoffKey, "2:1")
            XCTAssertNil(summary.kickoffMessageId)
            phase = "restart_example"
            print("KICKOFF_STAGE2 phase=\(phase)")
            let restarted = await turns.kickoffSubunit(subunitID: subunitID)
            XCTAssertEqual(restarted, .started)
            let again = try await waitForReply(ledger, turns: turns, threadID: threadID, count: 2)
            XCTAssertEqual(again.filter { $0.metadata["hidden"]?.boolValue == true }.count, 2)
            let kickoffText = again.filter { $0.metadata["hidden"]?.boolValue == true }.last?.plainText ?? ""
            XCTAssertTrue(kickoffText.contains("自分で例題に戻ってきました"), "戻ってきたことと誤りの種類を渡す")
        } catch {
            print("KICKOFF_STAGE2_ERROR phase=\(phase) error=\(String(reflecting: error))")
            throw error
        }
    }

    /// 単元づくり(待ち時間の体験 §3.3): 最初の問いはアプリが待ちなしで出し、モデルは答えがそろってから動いて全体像の提案まで進む。
    func testUnitCreationAsksScriptedQuestionsThenProposes() async throws {
        let (ledger, turns, _) = try makeCoordinator()
        let profile = OnboardingProfile(grade: "中学3年", currentFocus: "定期テスト", subject: "数学", confusion: "式を作れない", studyStyle: "紙のノート", materialName: nil)
        let threadID = try await turns.startUnitCreation(existingThreadID: nil, profile: profile, attachments: [])
        var rows = try await ledger.read { db in try ChatRepository.messages(db, threadID: threadID) }
        XCTAssertEqual(rows.count, 1, "最初の問いだけ(モデルは動かない)")
        XCTAssertEqual(rows[0].role, "assistant")
        XCTAssertEqual(rows[0].status, "completed", "待ちなしで出す")
        XCTAssertEqual(rows[0].plainText, TurnCoordinator.unitCreationQuestions[0].text)
        let turnCount = try await ledger.read { db in try TurnRecord.fetchCount(db) }
        XCTAssertEqual(turnCount, 0, "問いにはモデルのターンを使わない")

        let reopened = try await turns.startUnitCreation(existingThreadID: threadID, profile: profile, attachments: [])
        XCTAssertEqual(reopened, threadID, "作りかけの会話を開き直す")
        rows = try await ledger.read { db in try ChatRepository.messages(db, threadID: threadID) }
        XCTAssertEqual(rows.count, 1, "開き直しで問いを重ねない")

        let answers = ["中3で二次関数をやってる", "10月15日に期末テスト", "判別式のところがよくわからない"]
        for (index, answer) in answers.enumerated() {
            let result = try await turns.sendChatHandlingUnitQuestions(TurnCoordinator.ChatSend(threadID: threadID, text: answer, attachments: [], workbookView: nil))
            if index < answers.count - 1 {
                XCTAssertNil(result, "途中の答えではモデルを起こさない")
                rows = try await ledger.read { db in try ChatRepository.messages(db, threadID: threadID) }
                XCTAssertEqual(rows.last?.plainText, TurnCoordinator.unitCreationQuestions[index + 1].text, "次の問いをすぐ出す")
            } else {
                XCTAssertNotNil(result, "最後の答えでモデルのターンを起こす")
            }
        }
        rows = try await waitForReply(ledger, turns: turns, threadID: threadID, count: 4)
        let lastUser = try XCTUnwrap(rows.last { $0.role == "user" })
        XCTAssertEqual(lastUser.plainText, answers[2], "吹き出しは学習者の言葉のまま")
        XCTAssertEqual(lastUser.metadata["answers_question"]?.stringValue, "stumble")
        let modelText = lastUser.metadata["model_text"]?.stringValue ?? ""
        for answer in answers { XCTAssertTrue(modelText.contains(answer), "問いと答えをまとめてモデルに渡す: \(answer)") }
        XCTAssertTrue(modelText.contains("学年: 中学3年"), "オンボーディングの回答を文脈として渡す")
        let reply = try XCTUnwrap(rows.last { $0.role == "assistant" })
        XCTAssertEqual(reply.status, "completed")
        XCTAssertNotNil(reply.metadata["workbook_proposal_id"]?.stringValue, "答えがそろったら全体像の提案まで進む: \(reply.plainText ?? "")")
        let questionTurns = try await ledger.read { db in try TurnRecord.filter(Column("kind") == "chat").fetchCount(db) }
        XCTAssertEqual(questionTurns, 1, "モデルのターンは答えがそろってからの 1 回だけ")
    }

    /// 要点の起動ターンが走っている間に、別の会話で質問を送っても、進行の版の衝突で失敗しない。
    func testQuestionQueuedBehindKickoffDoesNotConflict() async throws {
        let (ledger, turns, _) = try makeCoordinator()
        let subunitID = try await seedSubunit(ledger, stage: 1)
        let kickoff = await turns.kickoffSubunit(subunitID: subunitID)
        XCTAssertEqual(kickoff, .started)
        let questionThread = LedgerID.make()
        try await ledger.append([ChatRepository.createThread(id: questionThread, title: "質問").1])
        _ = try await turns.sendChat(TurnCoordinator.ChatSend(threadID: questionThread, text: "さっきの話の続きを教えて", attachments: [], workbookView: nil))
        let subunitThread = try await turns.subunitThread(subunitID: subunitID)
        _ = try await waitForReply(ledger, turns: turns, threadID: subunitThread)
        let rows = try await waitForReply(ledger, turns: turns, threadID: questionThread)
        let reply = try XCTUnwrap(rows.last { $0.role == "assistant" })
        XCTAssertEqual(reply.status, "completed", "進行の版の衝突で失敗した: \(reply.plainText ?? "")")
    }

    func testExampleBlockExtraction() {
        let (text, prompt) = LearnerText.extractWorkbookExample("解こう。\n<struis_workbook_example>{\"prompt\": \"x+1=2 を解け\"}</struis_workbook_example>")
        XCTAssertEqual(text, "解こう。")
        XCTAssertEqual(prompt, "x+1=2 を解け")
        XCTAssertEqual(LearnerText.extractWorkbookExample("そのまま").text, "そのまま")
    }

    func testExampleReadyBlockExtraction() {
        let (text, ready) = LearnerText.extractWorkbookExampleReady("類題へ進もう。\n<struis_workbook_example_ready/>")
        XCTAssertEqual(text, "類題へ進もう。")
        XCTAssertTrue(ready)
        XCTAssertTrue(LearnerText.extractWorkbookExampleReady("進もう。<struis_workbook_example_ready></struis_workbook_example_ready>").ready)
        XCTAssertTrue(LearnerText.extractWorkbookExampleReady("進もう。<STRUIS_WORKBOOK_EXAMPLE_READY />").ready)
        let plain = LearnerText.extractWorkbookExampleReady("もう一度書いてみて")
        XCTAssertEqual(plain.text, "もう一度書いてみて")
        XCTAssertFalse(plain.ready)
    }

    func testMarkdownBulletsBecomeBullets() {
        XCTAssertEqual(ChatTextReadability.bulletize("要点:\n- 全体像\n  - 細部\n* 例"), "要点:\n• 全体像\n\u{3000}• 細部\n• 例")
        XCTAssertEqual(ChatTextReadability.bulletize("x - 1 = 0"), "x - 1 = 0")
        // 行頭の演算子で始まる式の行は、そのまま残す。
        XCTAssertEqual(ChatTextReadability.bulletize("2x = 6\n- 3x + 6 = 0\n+ 2\n* 4"), "2x = 6\n- 3x + 6 = 0\n+ 2\n* 4")
        XCTAssertEqual(ChatTextReadability.bulletize("- sin x\n+ log y\n- alpha beta"), "- sin x\n+ log y\n- alpha beta")
        XCTAssertEqual(ChatTextReadability.bulletize("x^2\n- x\n+ y\n* a"), "x^2\n- x\n+ y\n* a")
        XCTAssertEqual(ChatTextReadability.bulletize("θ\n- α\n+ θ\n- x₁"), "θ\n- α\n+ θ\n- x₁")
        XCTAssertEqual(ChatTextReadability.bulletize("- 全体像を見る"), "• 全体像を見る")
        // 式で始まる行は、後ろに日本語の説明があっても符号を残す。
        XCTAssertEqual(ChatTextReadability.bulletize("- x は 3 より小さい\n+ 2 を両辺に足す"), "- x は 3 より小さい\n+ 2 を両辺に足す")
    }

    func testTriageDropsCandidatesTheGraderRejected() {
        XCTAssertTrue(WorkbookMachine.reasonSaysMismatch("問題文が一致しません"))
        XCTAssertFalse(WorkbookMachine.reasonSaysMismatch("同じ形の式"))
        // 違いを述べた上で一致と結論している講評は候補に残す。
        XCTAssertFalse(WorkbookMachine.reasonSaysMismatch("表記は異なるが、内容は一致します"))
        XCTAssertTrue(WorkbookMachine.reasonSaysMismatch("係数が異なり、別の問題です"))
        XCTAssertTrue(WorkbookMachine.reasonSaysMismatch("同じ問題ではありません"))
        XCTAssertTrue(WorkbookMachine.reasonSaysMismatch("同じ問題ではない"))
    }

    func testRelativeTimeNeverFuture() {
        let now = Date()
        XCTAssertEqual(WorkbookFormatting.relative(now.addingTimeInterval(5), now: now), "たった今")
        XCTAssertEqual(WorkbookFormatting.relative(now.addingTimeInterval(-10), now: now), "たった今")
        XCTAssertFalse(WorkbookFormatting.relative(now.addingTimeInterval(-600), now: now).contains("後"))
    }
}

/// Transport failure fixture; no native/model success is inferred from this runner.
@MainActor private final class ChatFailingRunner: TurnRunning {
    func run(_ plan: TurnPlan, progress: @escaping @Sendable (TurnProgressEvent) -> Void) async throws -> TurnOutcome {
        throw CocoaError(.fileReadUnknown)
    }
    func interrupt(planID: String) async {}
}
