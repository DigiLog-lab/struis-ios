import XCTest

/// 返事が見える本文を書き終えて、後ろの記録(進み具合)だけを書いている間(関連する画面・動作 §13.13 の 3・5)。
/// モックは本文を流した後、記録を書いている時間(`STRUIS_MOCK_TAIL_DELAY_MS`)だけ待つ。
/// 入力欄は停止ボタンにならず、送った質問は記録を止めずに後から答える。例題の段の「先に進む」は記録を待たずに出る。
final class ReplyTailUITests: XCTestCase {
    private static let recordingText = "学習の進み具合を記録しています"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func launch(_ arguments: [String], tailMs: String) -> XCUIApplication {
        let app = UITestSupport.deviceApp(arguments: arguments)
        app.launchEnvironment["STRUIS_MOCK_TAIL_DELAY_MS"] = tailMs
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func wait(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 15) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func text(_ app: XCUIApplication, containing fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    @MainActor
    private func sendButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "送信", "chat-page")).firstMatch
    }

    @MainActor
    private func stopButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "停止")).firstMatch
    }

    @MainActor
    private func type(_ app: XCUIApplication, _ value: String) {
        let input = app.textViews.matching(identifier: "chat-page").firstMatch
        XCTAssertTrue(input.appears(timeout: 15), "入力欄が無い")
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        input.typeText(value)
    }

    @MainActor
    private func screenSummary(_ app: XCUIApplication) -> String {
        let lines = app.debugDescription.split(separator: "\n")
            .filter { $0.contains("label:") || $0.contains("identifier: 'workbook-") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return String(lines.joined(separator: " | ").prefix(3000))
    }

    /// 質問シート: 記録を書いている間も送信ボタンのまま送れる。送った質問は記録が終わってから答え、前の返事は止まらない。
    @MainActor
    func testQuestionSheetSendsWhileReplyIsRecording() throws {
        // 1 つ目の返事の記録は、本文が出てから 2 つ目の質問を打って送るまで(Simulator で 12〜17 秒)より十分長くする。
        // 12 秒では送る前に記録が終わり、並べる場面にならなかった。並べた質問の返事の記録は短くし、後の待ちは延ばさない。
        let app = launch(["-skip-onboarding"], tailMs: "40000,3000")
        XCTAssertTrue(app.openQuestionSheet())
        type(app, "最初の質問です")
        let send = sendButton(app)
        XCTAssertTrue(wait(send, "exists == true AND enabled == true"))
        send.press(forDuration: 0.15)

        // 本文が出て、後ろの記録を書いている。
        XCTAssertTrue(text(app, containing: "自信がある行").appears(timeout: 20), "返事の本文が流れない")
        XCTAssertTrue(text(app, containing: Self.recordingText).appears(timeout: 10), "記録の言葉が出ない: \(screenSummary(app))")
        attach(app, "1-recording-composer-is-send")
        XCTAssertFalse(stopButton(app).exists, "記録だけを書いている間に入力欄が停止ボタンになっている")

        type(app, "なんですかこれ")
        XCTAssertTrue(wait(send, "exists == true AND enabled == true", timeout: 5), "記録の間に送信ボタンが押せない")
        send.press(forDuration: 0.15)
        XCTAssertTrue(text(app, containing: "なんですかこれ").appears(timeout: 10), "送った質問が吹き出しに出ない")
        XCTAssertTrue(text(app, containing: "前の返事の記録が終わりしだい、答えます").appears(timeout: 10),
                      "並べた質問の待ちの言葉が出ない: \(screenSummary(app))")
        XCTAssertTrue(text(app, containing: Self.recordingText).exists, "送った後も前の返事の記録は続いている")
        attach(app, "2-queued-question-while-recording")

        // 前の返事の記録が終わってから、並べた質問に答える。どちらも止まらない。
        let replies = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "自信がある行"))
        XCTAssertTrue(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 2"), object: replies)], timeout: 60) == .completed,
                      "並べた質問に答えない: \(screenSummary(app))")
        XCTAssertTrue(wait(text(app, containing: Self.recordingText), "exists == false", timeout: 30), "記録が終わらない")
        XCTAssertFalse(text(app, containing: "停止しました").exists, "前の返事が止められた")
        XCTAssertFalse(text(app, containing: "応答を生成できませんでした").exists)
        attach(app, "3-both-replies-done")
    }

    /// 例題の段: 準備OKの返事が記録を書いている間に「先に進む」が出て押せる。押すと類題の段に進み、記録は裏で終わる。
    @MainActor
    func testAdvanceAppearsWhileReadyReplyIsRecording() throws {
        let app = launch(["-skip-onboarding", "-workbook-model-stage"], tailMs: "15000")
        let row = element(app, "workbook-subunit-sub-1")
        XCTAssertTrue(row.appears(timeout: 30), "ホームに小単元の行が無い")
        row.tap()
        // 段階 1 の要点(これも記録を書く)。出終わったら「先に進む」。
        XCTAssertTrue(text(app, containing: "要点を話すね").appears(timeout: 20))
        let advance = element(app, "workbook-advance")
        XCTAssertTrue(wait(advance, "exists == true AND enabled == true", timeout: 30), "要点の後に「先に進む」が押せない: \(screenSummary(app))")
        attach(app, "4-intro-advance-while-recording")
        advance.press(forDuration: 0.15)
        XCTAssertTrue(text(app, containing: "頂点の座標を求めよ").appears(timeout: 60), "例題が出ない: \(screenSummary(app))")
        // 例題の起動の返事の記録が終わるまで待つ(例題は返事の終わりに保存される)。
        XCTAssertTrue(wait(text(app, containing: Self.recordingText), "exists == false", timeout: 40))

        type(app, "できた")
        let send = sendButton(app)
        XCTAssertTrue(wait(send, "exists == true AND enabled == true"))
        send.press(forDuration: 0.15)
        XCTAssertTrue(text(app, containing: "よくできました").appears(timeout: 20), "準備OKの返事が出ない")
        // 入力中は「先に進む」を隠すので、キーボードが出ていれば閉じる。
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            let screen = app.windows.firstMatch
            element(app, "chat-page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.05, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
        }
        XCTAssertTrue(wait(advance, "exists == true AND enabled == true", timeout: 10), "記録の間に「先に進む」が出ない: \(screenSummary(app))")
        XCTAssertTrue(text(app, containing: Self.recordingText).exists, "まだ記録を書いている最中であること")
        attach(app, "5-advance-while-ready-reply-recording")
        advance.press(forDuration: 0.15)
        XCTAssertTrue(element(app, "workbook-request-set").appears(timeout: 20) || text(app, containing: "類題").appears(timeout: 5),
                      "類題の段に進まない: \(screenSummary(app))")
        attach(app, "6-advanced-to-similar-problem")
    }

    /// 実 Codex(hyotan 上の app-server)で同じことを確かめる。`TEST_RUNNER_STRUIS_REAL_CODEX_AUTH=<auth.json>` の時だけ動く。
    /// 本物のモデルが返事の後ろの記録を書いている間に次の質問を送り、前の返事が止まらずに出来上がり、次の質問にも答えること。
    @MainActor
    func testQuestionSheetSendsWhileRecordingWithRealCodex() throws {
        let auth = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_AUTH"] ?? ""
        try XCTSkipIf(auth.isEmpty, "TEST_RUNNER_STRUIS_REAL_CODEX_AUTH が無い (実 Codex 検証は手動)")
        let app = XCUIApplication()
        app.launchArguments += ["-skip-onboarding"]
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "1"
        app.launchEnvironment["STRUIS_LEDGER"] = "memory"
        app.launchEnvironment["STRUIS_DEBUG_CODEX_AUTH_FILE"] = auth
        let assets = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_ASSETS_DIR"] ?? ""
        try XCTSkipIf(assets.isEmpty, "TEST_RUNNER_STRUIS_REAL_CODEX_ASSETS_DIR が無い (既定単元の実AI試験には外部配信資産が必要)")
        app.launchEnvironment["STRUIS_DEVICE_ASSETS_DIR"] = assets
        app.launch()
        XCTAssertTrue(app.openQuestionSheet(timeout: 60))
        type(app, "y = sin(2x + π/3) の周期と、位相のずれを教えてください。")
        let send = sendButton(app)
        XCTAssertTrue(wait(send, "exists == true AND enabled == true", timeout: 120), "送信できない(配信の準備)")
        send.press(forDuration: 0.15)

        let recording = text(app, containing: Self.recordingText)
        XCTAssertTrue(recording.appears(timeout: 300), "返事の後ろの記録の言葉が出ない: \(screenSummary(app))")
        attach(app, "real-1-recording-composer-is-send")
        XCTAssertFalse(stopButton(app).exists, "記録だけを書いている間に入力欄が停止ボタンになっている")

        type(app, "なんですかこれ")
        XCTAssertTrue(wait(send, "exists == true AND enabled == true", timeout: 5), "記録の間に送信ボタンが押せない")
        send.press(forDuration: 0.15)
        XCTAssertTrue(text(app, containing: "なんですかこれ").appears(timeout: 10), "送った質問が吹き出しに出ない")
        attach(app, "real-2-queued-question")

        // 前の返事の記録と、並べた質問の返事が両方とも出来上がる(どちらも止まらない)。
        XCTAssertTrue(wait(recording, "exists == false", timeout: 600), "記録が終わらない")
        XCTAssertTrue(wait(text(app, containing: "前の返事の記録が終わりしだい"), "exists == false", timeout: 600))
        XCTAssertTrue(wait(stopButton(app), "exists == false", timeout: 600), "並べた質問の返事が終わらない: \(screenSummary(app))")
        // 並べた質問の返事の記録(進み具合・記憶)も書き終わって、返事が出来上がる。
        let writing = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", Self.recordingText, "書き留めています")).firstMatch
        XCTAssertTrue(wait(writing, "exists == false", timeout: 600), "並べた質問の返事の記録が終わらない")
        let thoughts = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "秒考えました"))
        XCTAssertTrue(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 2"), object: thoughts)], timeout: 60) == .completed,
                      "2 つの返事が両方とも出来上がっていない: \(screenSummary(app))")
        XCTAssertFalse(text(app, containing: "停止しました").exists, "前の返事が止められた: \(screenSummary(app))")
        XCTAssertFalse(text(app, containing: "応答を生成できませんでした").exists, "失敗した: \(screenSummary(app))")
        XCTAssertFalse(text(app, containing: "送り直す").exists, "失敗した: \(screenSummary(app))")
        attach(app, "real-3-both-replies-done")
    }


    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
