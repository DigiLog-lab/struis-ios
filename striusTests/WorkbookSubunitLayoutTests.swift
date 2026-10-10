import XCTest
@testable import strius

/// 例題の段のレイアウト(2026-09-25、関連する画面・動作 §7.2・§13.13)の画面の決まりごと。
/// 進捗バーの初期状態と開閉の保存先、例題バーの開閉、段が変わった直後の送り先、ホームの単元カードの進み。
@MainActor
final class WorkbookSubunitLayoutTests: XCTestCase {
    private func subunit(
        stage: Int, status: WorkbookSubunitDTO.Status = .active, n: Int = 5,
        windowTiles: [WorkbookProblemTileDTO.State]? = nil, exampleProblem: String? = nil, kickoffKey: String? = nil
    ) -> WorkbookSubunitDTO {
        let tiles = windowTiles?.enumerated().map { index, state in
            WorkbookProblemTileDTO(
                id: "p\(index)", position: index, prompt: "", source: "generated", state: state,
                attemptCount: 1, assisted: false, errorTag: "", hintGiven: false, lastAttemptAt: nil
            )
        }
        return WorkbookSubunitDTO(
            id: "sub-1", unitId: "unit-1", unitTitle: "二次関数", title: "頂点の座標が求められる", outcome: "平方完成で頂点を求める",
            position: 0, stage: stage, stageLabel: WorkbookStage(rawValue: stage)?.label ?? "", status: status, n: n, threshold: 0.8,
            scoringUnit: "1問ごとに正誤",
            window: WorkbookWindowDTO(n: n, threshold: 0.8, count: tiles?.count ?? 0, correct: 0, score: nil, passed: false, requiredCorrect: 4),
            tiles: [], openSetId: nil, lastResult: nil, canAdvance: true, updatedAt: "2026-09-25T00:00:00Z",
            windowTiles: tiles, exampleProblem: exampleProblem, kickoffKey: kickoffKey
        )
    }

    // MARK: 進捗バー

    func testProgressBarIsTapOnlyAndRebuiltPerStageInExampleStage() {
        let intro = subunit(stage: 1, kickoffKey: "1:0")
        XCTAssertFalse(WorkbookSubunitHeader.opensByTapOnly(intro), "要点はスワイプでも開閉できる(今までと同じ)")

        let example = subunit(stage: 2, kickoffKey: "2:0")
        XCTAssertTrue(WorkbookSubunitHeader.opensByTapOnly(example), "例題の段はタップでだけ開閉する")
        XCTAssertNotEqual(WorkbookSubunitHeader.identity(example), WorkbookSubunitHeader.identity(intro), "「先に進む」で例題に入ると、畳んだ 1 行から始め直す")

        let returned = subunit(stage: 2, kickoffKey: "2:1")
        XCTAssertNotEqual(
            WorkbookSubunitHeader.identity(returned), WorkbookSubunitHeader.identity(example),
            "例題に戻った新しい回も、前の回で開いたままでも畳んだ 1 行から始める"
        )
        XCTAssertEqual(WorkbookSubunitHeader.collapsedHeight, 40)
    }

    // MARK: 例題バー

    func testExampleBarCollapsesOnLearnerActivityAndReopensByTap() {
        for activity in [ChatLearnerActivity.scrolled, .focusedComposer, .sent] {
            var bar = WorkbookExampleBarState()
            XCTAssertFalse(bar.isCollapsed, "入った直後は全文")
            let first = bar.learnerActed(activity, hasPrompt: true)
            XCTAssertTrue(first, "\(activity) でしまわない")
            XCTAssertTrue(bar.isCollapsed)
            let again = bar.learnerActed(activity, hasPrompt: true)
            XCTAssertFalse(again, "しまった後は変わらない")
            bar.toggled()
            XCTAssertFalse(bar.isCollapsed, "1 行のタップで全文に戻らない")
            let afterTap = bar.learnerActed(.scrolled, hasPrompt: true)
            XCTAssertFalse(afterTap, "手で全文に戻した後は、会話を動かしてもしまわない")
            XCTAssertFalse(bar.isCollapsed)
        }
    }

    func testExampleBarCanBeCollapsedAndExpandedByHand() {
        var bar = WorkbookExampleBarState()
        bar.toggled()
        XCTAssertTrue(bar.isCollapsed, "全文の見出しの行のタップで 1 行にしまわない")
        let scrolled = bar.learnerActed(.scrolled, hasPrompt: true)
        XCTAssertFalse(scrolled)
        XCTAssertTrue(bar.isCollapsed, "手でしまった後、会話の操作で開いた")
        bar.toggled()
        XCTAssertFalse(bar.isCollapsed, "1 行のタップで全文に戻らない")
        bar.learnerActed(.sent, hasPrompt: true)
        XCTAssertFalse(bar.isCollapsed, "手で開いた全文を送信でしまった")
        bar.enteredNewRound()
        XCTAssertFalse(bar.isCollapsed)
        bar.learnerActed(.scrolled, hasPrompt: true)
        XCTAssertTrue(bar.isCollapsed, "新しい回は、また会話の操作でしまう")
    }

    func testExampleBarStaysOpenWhilePreparingAndNewRoundStartsOpen() {
        var bar = WorkbookExampleBarState()
        let preparing = bar.learnerActed(.scrolled, hasPrompt: false)
        XCTAssertFalse(preparing, "問題文がまだ無い間はしまわない")
        XCTAssertFalse(bar.isCollapsed)
        bar.learnerActed(.sent, hasPrompt: true)
        XCTAssertTrue(bar.isCollapsed)
        bar.enteredNewRound()
        XCTAssertFalse(bar.isCollapsed, "新しい回の例題は全文から")
    }

    func testExampleHeadlineIsOneLineWithoutMathDelimiters() {
        XCTAssertEqual(WorkbookExampleCard.headline("$y = x^2 - 4x + 3$ の頂点の座標を\n求めよ"), "y = x^2 - 4x + 3 の頂点の座標を 求めよ")
        XCTAssertEqual(WorkbookExampleCard.headline("\\(x + y = 12\\)  と  $$x - y = 4$$"), "x + y = 12 と x - y = 4")
        XCTAssertEqual(WorkbookExampleCard.headline("りんごとみかんが合わせて12個あります。"), "りんごとみかんが合わせて12個あります。")
    }

    // MARK: 段が変わった直後

    private func message(_ role: MessageRole, _ status: MessageStatus) -> ChatMessage {
        ChatMessage(id: UUID(), role: role, status: status, plainText: "", blocks: [], metadata: nil, createdAt: Date(), completedAt: nil)
    }

    func testFollowTokenIsTheStageReplyAfterTheKickoff() {
        let kickoff = message(.user, .completed)
        let reply = message(.assistant, .pending)
        let earlier = message(.assistant, .completed)
        XCTAssertEqual(
            WorkbookSubunitView.kickoffReplyID(messages: [earlier, kickoff, reply], kickoffMessageID: kickoff.id.uuidString), reply.id,
            "起動メッセージの次の返事(作られている最中でも)へ送る"
        )
        XCTAssertNil(WorkbookSubunitView.kickoffReplyID(messages: [earlier, kickoff], kickoffMessageID: kickoff.id.uuidString), "返事がまだ無ければ送らない")
        XCTAssertNil(WorkbookSubunitView.kickoffReplyID(messages: [earlier], kickoffMessageID: nil), "その段をまだ起こしていなければ送らない")
    }

    // MARK: 「先に進む」を押せる時

    func testAdvanceIsHiddenInExampleStageUntilModelMarksReady() {
        XCTAssertTrue(WorkbookSubunitView.showsAdvance(stage: .introduction, exampleReady: false), "要点は今のまま")
        XCTAssertFalse(WorkbookSubunitView.showsAdvance(stage: .jointExample, exampleReady: false), "例題は準備OKまで出さない")
        XCTAssertTrue(WorkbookSubunitView.showsAdvance(stage: .jointExample, exampleReady: true))
    }

    func testKickoffIsDoneWhenAFollowUpReplyCompletes() {
        XCTAssertEqual(WorkbookSubunitView.kickoffState(replies: [.pending], isSending: true), .waiting)
        XCTAssertEqual(WorkbookSubunitView.kickoffState(replies: [.completed], isSending: false), .done)
        XCTAssertEqual(WorkbookSubunitView.kickoffState(replies: [.completed], isSending: true), .waiting, "次の返事を作っている間は押せない")
        XCTAssertEqual(WorkbookSubunitView.kickoffState(replies: [.failed], isSending: false), .failed, "起こせなかった時は「もう一度始める」")
        // 説明の途中で質問して最初の返事が止まっても、その後の返事が出来上がれば「先に進む」が押せる。
        XCTAssertEqual(WorkbookSubunitView.kickoffState(replies: [.failed, .completed], isSending: false), .done)
        XCTAssertEqual(WorkbookSubunitView.kickoffState(replies: [.failed, .pending], isSending: true), .waiting)
        XCTAssertEqual(WorkbookSubunitView.kickoffState(replies: [], isSending: false), .waiting)
        // 例題の段で例題が保存されないまま返事が出来上がったら、先へ進ませずに起動をやり直させる。
        XCTAssertEqual(WorkbookSubunitView.kickoffState(replies: [.failed, .completed], isSending: false, missingExample: true), .failed)
        XCTAssertEqual(WorkbookSubunitView.kickoffState(replies: [.pending], isSending: true, missingExample: true), .waiting)
    }

    // MARK: 古いリザルトの次の行動

    func testStaleResultKeepsOnlyNavigationActions() {
        let active4 = subunit(stage: 4)
        XCTAssertEqual(WorkbookVerdictView.currentActions([.retry, .returnToExample, .ask], stageAfter: 4, subunit: active4), [.retry, .returnToExample, .ask], "今の段の結果はそのまま")
        XCTAssertEqual(WorkbookVerdictView.currentActions([.retry, .returnToExample, .ask], stageAfter: 3, subunit: active4), [.ask], "類題の結果を演習の段で開いたら、やり直す・例題に戻るは出さない")
        let passed = subunit(stage: 4, status: .passed)
        XCTAssertEqual(WorkbookVerdictView.currentActions([.nextSubunit, .ask], stageAfter: 4, subunit: passed), [.nextSubunit, .ask], "合格の結果の行き先は残す")
        XCTAssertEqual(WorkbookVerdictView.currentActions([.retry, .ask], stageAfter: 4, subunit: passed), [.ask])
        XCTAssertEqual(WorkbookVerdictView.currentActions([.practice, .ask], stageAfter: 4, subunit: nil), [.practice, .ask], "小単元が読めない時はそのまま")
    }

    // MARK: ホームの単元カード

    func testRemainingToPassCountsEmptySlotsAndDisplacedResults() {
        // 11 問すべて正解・n = 15・合格 12: 正解数だけなら 1 問だが、窓を埋めるのにあと 4 問要る。
        let open = WorkbookWindowDTO(n: 15, threshold: 0.8, count: 11, correct: 11, score: nil, passed: false, requiredCorrect: 12)
        XCTAssertEqual(WorkbookVerdictView.remainingToPass(window: open, tiles: Array(repeating: .correct, count: 11)), 4)
        // 埋まった窓(5 問・合格 4)で古い順に ○○××○: 次の正解で先頭の ○ が押し出されるので、2 問では足りず 3 問。
        let full = WorkbookWindowDTO(n: 5, threshold: 0.8, count: 5, correct: 3, score: nil, passed: false, requiredCorrect: 4)
        XCTAssertEqual(WorkbookVerdictView.remainingToPass(window: full, tiles: [.correct, .correct, .wrong, .wrong, .correct]), 3)
        // 古い方が × なら、押し出されて 1 問で届く。
        XCTAssertEqual(WorkbookVerdictView.remainingToPass(window: full, tiles: [.wrong, .correct, .correct, .correct, .wrong]), 1)
    }

    func testUnitCardProgressIsCorrectOverN() throws {
        let progress = try XCTUnwrap(WorkbookSubunitProgress(subunit(stage: 4, n: 15, windowTiles: [.correct, .wrong, .correct, .correct])))
        XCTAssertEqual(progress.label, "3 / 15")
        XCTAssertEqual(progress.fraction, 3.0 / 15.0, accuracy: 0.0001)
        XCTAssertFalse(progress.passed)

        let passed = try XCTUnwrap(WorkbookSubunitProgress(subunit(stage: 4, status: .passed, n: 5, windowTiles: [.correct, .correct, .wrong, .correct, .correct])))
        XCTAssertEqual(passed.label, "4 / 5")
        XCTAssertTrue(passed.passed, "合格した小単元は合格の色")
    }

    func testUnitCardShowsNothingForUntouchedSubunit() {
        XCTAssertNil(WorkbookSubunitProgress(subunit(stage: 1)), "まだ手をつけていない小単元には何も出さない")
        XCTAssertNil(WorkbookSubunitProgress(subunit(stage: 3, windowTiles: [])), "演習の答えが無ければ何も出さない")
        XCTAssertNil(WorkbookSubunitProgress(subunit(stage: 1, status: .pending)))
    }

    func testUnitCardCountsOnlyTheLatestN() throws {
        // 窓は直近 n 問。古い答えは数えない。
        let progress = try XCTUnwrap(WorkbookSubunitProgress(subunit(stage: 4, n: 3, windowTiles: [.correct, .correct, .wrong, .wrong, .correct])))
        XCTAssertEqual(progress.label, "1 / 3")
    }
}
