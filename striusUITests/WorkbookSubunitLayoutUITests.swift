import XCTest

/// 例題の段のレイアウト(2026-09-25、関連する画面・動作 §7.2・§13.13)をモック応答で確かめる。
/// 進捗バーと例題バーの 2 本、入力欄は最下段、「先に進む」は会話の右下(入力中は隠す)、
/// 段が変わった直後は新しい段の返事まで送る、ホームの単元カードは「正解数 / n」と短い横棒。
final class WorkbookSubunitLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        wait(element, "exists == true AND enabled == true", timeout: timeout)
    }

    @MainActor
    private func waitValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func wait(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    /// `timeout` 秒以内に始めた確かめのどれかで、要素が無くなっていれば true。述語の待ち(`wait`)は 1 秒おきにしか
    /// 確かめず、段の切り替え直後のようにツリーの取得に 2 秒以上かかると、3 秒の間に 1 回しか確かめられない。
    @MainActor
    private func disappears(_ element: XCUIElement, within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    @MainActor
    private func text(_ app: XCUIApplication, containing fragment: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// 失敗した時の画面の中身(見えている文字)。Xcode Cloud では結果の束を見られないので、失敗メッセージに載せる。
    @MainActor
    private func screenSummary(_ app: XCUIApplication) -> String {
        let lines = app.debugDescription.split(separator: "\n")
            .filter { $0.contains("label:") || $0.contains("identifier: 'workbook-") || $0.contains("value: ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return String(lines.joined(separator: " | ").prefix(3000))
    }

    @MainActor
    private func openFirstSubunit(_ app: XCUIApplication) {
        let row = element(app, "workbook-subunit-sub-1")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "ホームに小単元の行が無い")
        row.tap()
    }

    // MARK: 例題の段: 2 本のバー・入力欄・「先に進む」

    @MainActor
    func testExampleStageBarsComposerAndFloatingAdvance() throws {
        let app = launch(["-skip-onboarding", "-workbook-model-stage"])
        openFirstSubunit(app)

        // 要点: 進捗バーは開いた状態から(今までと同じ)。「先に進む」は入力欄の上、会話の右下。
        let header = element(app, "workbook-subunit-header")
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, containing: "要点を話すね").waitForExistence(timeout: 20), "要点が始まらない")
        let advance = element(app, "workbook-advance")
        XCTAssertTrue(waitEnabled(advance), "説明が出終わっても「先に進む」が押せない")
        let input = app.textViews.matching(identifier: "chat-page").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(advance.frame.maxY, input.frame.minY + 1, "「先に進む」が入力欄の上に無い")
        XCTAssertGreaterThan(advance.frame.midX, window.midX, "「先に進む」が右側に無い")
        XCTAssertGreaterThan(input.frame.minY, window.height * 0.75, "入力欄が最下段に無い")
        attach(app, "introduction-floating-advance")
        advance.press(forDuration: 0.15)

        // 例題: 進捗バーは畳んだ 1 行から始まり、例題バーは全文。
        let card = element(app, "workbook-example-card")
        XCTAssertTrue(card.waitForExistence(timeout: 15), "例題バーが無い")
        XCTAssertTrue(waitValue(header, "collapsed"), "例題の段で進捗バーが畳んだ 1 行から始まらない: \(header.value ?? "-")")
        XCTAssertLessThan(header.frame.height, 50, "畳んだ進捗バーが 40pt の 1 行でない: \(header.frame.height)")
        let prompt = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "頂点の座標を求めよ")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 20), "例題の問題文が出ない: \(screenSummary(app))")
        XCTAssertTrue(waitValue(card, "expanded"), "入った直後に例題が全文でない")
        let reply = text(app, containing: "例題を一緒に解こう")
        XCTAssertTrue(reply.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(reply, "hittable == true", timeout: 5), "例題の返事の位置まで送られていない")
        // 例題の段では、モデルが準備OKを出すまで「先に進む」自体を出さない(§13.13 の 5)。
        XCTAssertFalse(advance.exists, "準備OKの前に「先に進む」が出ている")
        let expandedHeight = card.frame.height
        attach(app, "example-entered")

        // 進捗バーはタップでだけ開閉する。
        header.tap()
        XCTAssertTrue(waitValue(header, "expanded"), "進捗バーのタップで開かない")
        XCTAssertTrue(app.staticTexts["平方完成で頂点を求める"].waitForExistence(timeout: 3), "開いた進捗バーに到達目標が無い")

        // 会話のスクロールで例題バーが 1 行にしまう。進捗バーは勝手に動かない。
        let page = element(app, "chat-page")
        page.swipeDown()
        XCTAssertTrue(waitValue(card, "collapsed"), "会話のスクロールで例題バーがしまわない")
        XCTAssertTrue(element(app, "workbook-example-collapsed").waitForExistence(timeout: 3), "1 行の例題が無い")
        XCTAssertLessThan(card.frame.height, expandedHeight, "しまった例題バーが低くならない")
        XCTAssertEqual(header.value as? String, "expanded", "会話の操作で進捗バーが動いた")
        attach(app, "example-collapsed")
        header.tap()
        XCTAssertTrue(waitValue(header, "collapsed"), "進捗バーのタップで畳まない")

        // 手で開閉できる: 1 行をタップすると全文に戻り、全文の見出しの行をタップすると 1 行にしまう。
        element(app, "workbook-example-collapsed").tap()
        XCTAssertTrue(waitValue(card, "expanded"), "1 行のタップで全文に戻らない")
        // 手で開いた全文は、会話を動かしてもしまわない(読み比べている途中で勝手に閉じない)。
        page.swipeDown()
        XCTAssertFalse(waitValue(card, "collapsed", timeout: 2), "手で開いた例題が会話のスクロールでしまった")
        element(app, "workbook-example-collapse").tap()
        XCTAssertTrue(waitValue(card, "collapsed"), "見出しの行のタップで 1 行にしまわない")
        attach(app, "example-collapsed-by-hand")

        // 入力欄を押すと、キーボードが出ている間は「先に進む」を隠す。入力欄はキーボードのすぐ上。
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertTrue(waitValue(card, "collapsed"), "例題バーが 1 行のままでない")
        XCTAssertTrue(wait(advance, "exists == false"), "入力中も「先に進む」が見えている")
        // シミュレータがハードウェアキーボードにつながっているとソフトウェアキーボードは出ない。出た時だけ位置を確かめる。
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5) else {
            attach(app, "example-typing-no-software-keyboard")
            return
        }
        XCTAssertLessThanOrEqual(input.frame.maxY, keyboard.frame.minY + 1, "入力欄がキーボードに隠れている")
        attach(app, "example-typing")

        // 例題を解けたと送ると、モデルが準備OKを出す(モック応答)。入力中なので「先に進む」はまだ隠れている。
        input.typeText("できた")
        let send = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "送信", "chat-page")).firstMatch
        XCTAssertTrue(waitEnabled(send, timeout: 10))
        send.press(forDuration: 0.15)
        XCTAssertTrue(text(app, containing: "よくできました").waitForExistence(timeout: 20), "準備OKの返事が出ない")

        // キーボードを閉じると「先に進む」が現れる。会話はキーボードまで指を引き下ろすと閉じる(`.interactively`)ので、
        // 会話の上の方から画面の下端まで引き下ろす(短いスワイプでは閉じないことがある)。
        let screen = app.windows.firstMatch
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
        XCTAssertTrue(wait(keyboard, "exists == false", timeout: 5), "キーボードが閉じない")
        XCTAssertTrue(waitEnabled(advance), "キーボードを閉じても「先に進む」が戻らない")
    }

    // MARK: 入力・送信で例題バーは 1 行

    @MainActor
    func testSendingCollapsesExampleBar() throws {
        let app = launch(["-skip-onboarding", "-workbook-model-stage"])
        openFirstSubunit(app)
        let advance = element(app, "workbook-advance")
        XCTAssertTrue(waitEnabled(advance, timeout: 20))
        advance.press(forDuration: 0.15)
        let card = element(app, "workbook-example-card")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "頂点の座標を求めよ")).firstMatch.waitForExistence(timeout: 20), "例題の問題文が出ない: \(screenSummary(app))")
        XCTAssertTrue(text(app, containing: "例題を一緒に解こう").waitForExistence(timeout: 20), "例題の返事が終わらない")

        // 入力欄を押すとしまい、送った後も 1 行のまま(会話の操作で勝手に開かない)。
        let input = app.textViews.matching(identifier: "chat-page").firstMatch
        XCTAssertTrue(waitValue(card, "expanded"), "入った直後に例題が全文でない")
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertTrue(waitValue(card, "collapsed"), "入力欄のフォーカスで例題バーがしまわない")
        input.typeText("x^2 - 4x + 3 = (x - 2)^2 - 1")
        let send = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "送信", "chat-page")).firstMatch
        XCTAssertTrue(waitEnabled(send, timeout: 10))
        Thread.sleep(forTimeInterval: 0.5)
        send.press(forDuration: 0.15)
        XCTAssertTrue(waitValue(card, "collapsed"), "送信の後に例題バーが 1 行でない")
        XCTAssertTrue(app.staticTexts["x^2 - 4x + 3 = (x - 2)^2 - 1"].firstMatch.waitForExistence(timeout: 15), "送った文が出ない")
    }

    // MARK: 例題の「先に進む」はモデルの準備OKの後だけ

    @MainActor
    func testExampleAdvanceAppearsOnlyAfterModelMarksReady() throws {
        let app = launch(["-skip-onboarding", "-workbook-model-stage"])
        openFirstSubunit(app)
        let advance = element(app, "workbook-advance")
        XCTAssertTrue(waitEnabled(advance, timeout: 20), "要点の「先に進む」が押せない")
        advance.press(forDuration: 0.15)
        XCTAssertTrue(text(app, containing: "例題を一緒に解こう").waitForExistence(timeout: 20), "例題の返事が出ない: \(screenSummary(app))")
        XCTAssertTrue(element(app, "workbook-subunit-header").waitForExistence(timeout: 5))

        // 例題の返事が出終わっても、準備OKが無ければ「先に進む」は出ない(薄く出すのでもない)。
        XCTAssertTrue(disappears(advance, within: 3), "準備OKの前に「先に進む」が出ている: \(screenSummary(app))")
        let input = app.textViews.matching(identifier: "chat-page").firstMatch
        let send = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "送信", "chat-page")).firstMatch

        // 途中の答え(モデルは準備OKを出さない)では出ない。
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        input.typeText("(x - 2)^2 - 1")
        XCTAssertTrue(waitEnabled(send, timeout: 10))
        send.press(forDuration: 0.15)
        XCTAssertTrue(text(app, containing: "自信がある行").waitForExistence(timeout: 20), "途中の答えへの返事が出ない")
        XCTAssertFalse(advance.exists, "途中の答えの後に「先に進む」が出ている: \(screenSummary(app))")
        attach(app, "example-not-ready")

        // 解けた答え → モデルが準備OKを出す。block は本文に出ない。
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        input.typeText("できた")
        XCTAssertTrue(waitEnabled(send, timeout: 10))
        send.press(forDuration: 0.15)
        XCTAssertTrue(text(app, containing: "よくできました").waitForExistence(timeout: 20), "準備OKの返事が出ない")
        XCTAssertFalse(text(app, containing: "struis_workbook_example_ready").exists, "準備OKの block が本文に出ている")

        // 開き直すと(入力欄のフォーカスが外れる)、記録された準備OKで「先に進む」が出て押せる。
        app.navigationBars.buttons.firstMatch.tap()
        let row = element(app, "workbook-subunit-sub-1")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(waitEnabled(advance, timeout: 15), "準備OKの後に「先に進む」が出ない: \(screenSummary(app))")
        attach(app, "example-ready")
        advance.press(forDuration: 0.15)
        XCTAssertTrue(element(app, "workbook-request-set").waitForExistence(timeout: 15) || element(app, "workbook-open-set").exists,
                      "「先に進む」で類題へ進まない: \(screenSummary(app))")
        attach(app, "advanced-to-similar")
    }

    // MARK: 段が変わった直後は新しい段の返事まで送る

    @MainActor
    func testAdvanceScrollsToTheNewStageReply() throws {
        // 40 往復の要点の会話を読み返している途中(上の方)で「先に進む」を押す。
        let app = launch(["-skip-onboarding", "-workbook-model-stage", "-workbook-long-chat"])
        openFirstSubunit(app)
        let advance = element(app, "workbook-advance")
        XCTAssertTrue(waitEnabled(advance, timeout: 30), "要点の「先に進む」が押せない")
        let page = element(app, "chat-page")
        for _ in 0..<6 { page.swipeDown(velocity: .fast) }
        let latest = text(app, containing: "質問 39")
        XCTAssertFalse(latest.exists && latest.isHittable, "読み返しの位置まで上がっていない")
        advance.press(forDuration: 0.15)

        let reply = text(app, containing: "例題を一緒に解こう")
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "例題の返事が出ない: \(screenSummary(app))")
        XCTAssertTrue(wait(reply, "hittable == true", timeout: 10), "段が変わった後、新しい段の返事の位置まで送られない")
        attach(app, "advance-followed-new-reply")
    }

    // MARK: 「先に進む」の段は会話を隠さない

    /// 「先に進む」の段に面を敷かない: 止まっている時は最後の吹き出しがボタンの上で止まり、スクロール中の吹き出しは
    /// 途中で切れずにボタンの後ろに透けて見える。
    @MainActor
    func testAdvanceBandDoesNotCoverConversation() throws {
        let app = launch(["-skip-onboarding", "-workbook-model-stage", "-workbook-long-chat"])
        openFirstSubunit(app)
        let advance = element(app, "workbook-advance")
        XCTAssertTrue(waitEnabled(advance, timeout: 30), "要点の「先に進む」が押せない")
        let input = app.textViews.matching(identifier: "chat-page").firstMatch
        // 開いた直後の約 3 秒は会話の末尾へ送り直す(`ChatTimeline.scrollToEnd`)。それが終わってから動かす。
        Thread.sleep(forTimeInterval: 3.5)
        // 少しだけ戻して、吹き出しが段にかかる位置にする。
        let page = element(app, "chat-page")
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.53)))
        sleep(1)
        // 段(ボタンの上端から入力欄の上端まで)にかかる吹き出しの文字がある(面で隠していないことの目視は添付で)。
        let band = CGRect(x: 0, y: advance.frame.minY, width: app.windows.firstMatch.frame.width, height: input.frame.minY - advance.frame.minY)
        // 吹き出しの描き直しで要素の数が変わっても崩れないよう、画面の状態を一度に読む。
        func texts(_ node: XCUIElementSnapshot) -> [CGRect] {
            (node.elementType == .staticText ? [node.frame] : []) + node.children.flatMap(texts)
        }
        let frames = (try? app.snapshot()).map(texts) ?? []
        let crossing = frames.contains { $0.intersects(band) && $0.minY < band.minY }
        XCTAssertTrue(crossing, "段にかかる吹き出しの位置にできていない")
        attach(app, "advance-band")
    }

    // MARK: ホームの単元カード

    @MainActor
    func testUnitCardShowsCorrectOverNAndNothingForUntouched() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-skip-onboarding", "-texture-demo"]
        app.launchEnvironment["STRUIS_LEDGER"] = "memory"
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launch()

        let card = element(app, "workbook-unit-card-unit-1")
        if !card.waitForExistence(timeout: 20) {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5), "単元カードが無い")
        let label = card.label
        // フィクスチャ: 小単元 1 は 5 問中 4 問正解、小単元 2 は 2 問正解、小単元 3(n = 6)は手つかず。
        XCTAssertTrue(label.contains("4 / 5"), "小単元 1 の「正解数 / n」が無い: \(label)")
        XCTAssertTrue(label.contains("2 / 5"), "小単元 2 の「正解数 / n」が無い: \(label)")
        XCTAssertFalse(label.contains("/ 6"), "手をつけていない小単元に進みが出ている: \(label)")
        XCTAssertFalse(label.contains("マス"), "単元カードにマスが残っている: \(label)")
        attach(app, "home-unit-card-progress")

        // マスは小単元の中に残す。
        element(app, "workbook-subunit-sub-1").tap()
        XCTAssertTrue(element(app, "workbook-subunit-tiles").waitForExistence(timeout: 10), "小単元の中のマスが無い")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
