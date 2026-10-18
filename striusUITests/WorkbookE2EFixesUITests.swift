import XCTest

/// E2E 2026-09-23 の修正(配信Skillの説明 §2.2 / §2.4 / §2.6)をモック応答で確かめる。
/// シミュレータ既定フィクスチャ(台帳は起動ごとに空、ターンはモック)。
final class WorkbookE2EFixesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)], timeout: timeout) == .completed
    }

    /// 失敗した時の画面の中身(見えている文字)。Xcode Cloud では結果の束を見られないので、失敗メッセージに載せる。
    @MainActor
    private func screenSummary(_ app: XCUIApplication) -> String {
        let lines = app.debugDescription.split(separator: "\n")
            .filter { $0.contains("label:") || $0.contains("identifier: 'workbook-") || $0.contains("value: ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return String(lines.joined(separator: " | ").prefix(3000))
    }

    // MARK: §2.2 要点・例題をモデルが始める

    @MainActor
    func testIntroductionStartsWithoutTypingAndExampleIsPinned() throws {
        let app = launch(["-skip-onboarding", "-workbook-model-stage"])
        let row = element(app, "workbook-subunit-sub-1")
        XCTAssertTrue(row.appears(timeout: 15))
        row.tap()

        // 何も打たずにモデルの説明が出る。起動メッセージは見えない。
        let intro = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "要点を話すね")).firstMatch
        XCTAssertTrue(intro.appears(timeout: 15), "開いただけでモデルの説明が出ない")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "起動メッセージ")).firstMatch.exists, "起動メッセージが見えている")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "- 全体像")).firstMatch.exists, "箇条書きが「- 」のまま")

        let advance = element(app, "workbook-advance")
        XCTAssertTrue(waitEnabled(advance), "説明が出終わっても「先に進む」が押せない")
        // ガラスのボタンは tap() では押せないことがある。
        advance.press(forDuration: 0.15)

        // 例題バーが進捗バーの下に固定される(入った直後は全文)。
        let card = element(app, "workbook-example-card")
        XCTAssertTrue(card.appears(timeout: 10), "例題カードが無い")
        let pinned = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "頂点の座標を求めよ")).firstMatch
        XCTAssertTrue(pinned.appears(timeout: 15), "例題の問題文が固定されない: \(screenSummary(app))")
        // 「先に進む」はモデルの準備OKまで出さない(§13.13 の 5)。
        XCTAssertFalse(advance.exists, "準備OKの前に「先に進む」が出ている")
        // モデルが始めた例題の返事は、学習者が動かしていなければ見える位置まで送られる。
        let reidaiReply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "例題を一緒に解こう")).firstMatch
        XCTAssertTrue(reidaiReply.appears(timeout: 15))
        XCTAssertTrue(reidaiReply.isHittable, "例題の返事が見える位置に送られていない")
        let introCount = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "要点を話すね")).count

        // 開き直してもメッセージが増えない。
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.appears(timeout: 10))
        row.tap()
        XCTAssertTrue(card.appears(timeout: 10))
        sleep(2)
        XCTAssertEqual(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "要点を話すね")).count, introCount, "開き直しで説明が増えた")
        XCTAssertEqual(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "例題を一緒に解こう")).count, 1, "開き直しで例題が増えた")
        attach(app, "example-pinned")
    }

    // MARK: §1.2 リザルト画面

    @MainActor
    func testSetCaptureOpensResultAndPassShowsImmediately() throws {
        let app = launch(["-skip-onboarding"])
        app.launchEnvironment["STRUIS_TEST_CAMERA_IMAGE"] = UITestSupport.paperImagePath
        app.terminate()
        app.launch()
        let row = element(app, "workbook-subunit-sub-1")
        XCTAssertTrue(row.appears(timeout: 15))
        row.tap()
        let request = element(app, "workbook-request-set")
        XCTAssertTrue(request.appears(timeout: 10))
        request.tap()
        XCTAssertTrue(element(app, "workbook-set-problem-1").appears(timeout: 20))
        shoot(app)
        // 類題(1 問、モックは全問正解): 撮った後そのままリザルト画面。「クリア」と「演習へ」。
        let status = element(app, "workbook-result-status")
        XCTAssertTrue(status.appears(timeout: 20), "撮った後にリザルト画面が開かない")
        XCTAssertEqual(status.label, "クリア")
        XCTAssertFalse(app.buttons["補習"].exists)
        attach(app, "result-example-clear")
        element(app, "workbook-result-practice").tap()
        // 演習 5 問(モックは最後の 1 問だけ誤答 → 4/5 で直近 5 問の 8 割に届く)。
        XCTAssertTrue(element(app, "workbook-set-problem-5").appears(timeout: 20), "演習の一枚が開かない")
        shoot(app)
        XCTAssertTrue(status.appears(timeout: 20))
        XCTAssertTrue(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "小単元 合格"), object: status)], timeout: 20) == .completed, "合格した瞬間のリザルトに「小単元 合格」が出ない: \(status.label)")
        XCTAssertTrue(element(app, "workbook-result-window").exists, "直近 n 問のマスが無い")
        XCTAssertTrue(element(app, "workbook-verdict-next").exists, "「次の小単元へ」が無い")
        attach(app, "result-subunit-passed")
    }

    @MainActor
    private func shoot(_ app: XCUIApplication) {
        let camera = element(app, "workbook-capture-button")
        XCTAssertTrue(camera.appears(timeout: 5))
        camera.tap()
        let shutter = app.buttons["chat-camera-shutter"].firstMatch
        XCTAssertTrue(shutter.appears(timeout: 15), "カメラが開かない")
        if !shutter.isEnabled { app.tap() }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15)
        shutter.tap()
        // カメラは閉じずに続けて撮れる(一括採点)。「採点する 1」で確認画面へ。
        let done = app.buttons["chat-camera-done"].firstMatch
        XCTAssertTrue(done.appears(timeout: 20), "「採点する」が出ない: \(screenSummary(app))")
        done.tap()
        let use = element(app, "workbook-capture-use")
        XCTAssertTrue(use.appears(timeout: 20), "撮影確認が出ない: \(screenSummary(app))")
        use.tap()
    }

    // MARK: §2.4 固まらない

    @MainActor
    func testLongSubunitConversationDoesNotFreeze() throws {
        // 数式入りの返事と全体像カードを含む 40 往復を、ヘッダーのある小単元の画面(表示域が狭い)に読み込み、
        // 送信とスクロールを 20 回繰り返す。毎回、送ったメッセージが会話に入って見える位置にあること、
        // 次の操作が受け付けられることを確かめる。
        // メインスレッドの止まりの上限(2 秒)は、アプリ内の見張り(`-hang-watchdog`)を HID 入力だけで回して測る
        // (関連する画面・動作)。XCUITest の要素検索はアプリのメインスレッドで
        // ツリーを作り、WebView が多いとそれ自体が数秒かかるので、ここでの値は参考として記録だけする。
        //
        // 実行時間の上限は 6 分にする(既定は 3 分)。20 往復のそれぞれで、入力欄を押す・打つ・送る・確かめる・上下に
        // ドラッグする、の 6 回の操作があり、XCUITest は操作ごとにアプリが落ち着くのを待つ(1 回 0.6 秒前後)。無駄を
        // 除いた後も 1 往復に約 10〜12 秒かかり、3 コアの GitHub の runner で起動を含めて約 4 分になる(2026-10-15)。
        // 3 分に収めるには往復の回数を減らすしかなく、確かめる内容が変わるので、往復は減らさず上限を延ばす。
        executionTimeAllowance = 6 * 60
        let app = launch(["-skip-onboarding", "-workbook-model-stage", "-workbook-long-chat", "-hang-watchdog"])
        let row = element(app, "workbook-subunit-sub-1")
        XCTAssertTrue(row.appears(timeout: 30))
        row.tap()
        let input = app.textViews.matching(identifier: "chat-page").firstMatch
        XCTAssertTrue(input.appears(timeout: 30))
        let page = element(app, "chat-page")
        for round in 1...20 {
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
            input.typeText("確認 \(round)")
            let send = sendButton(app)
            XCTAssertTrue(waitEnabled(send, timeout: 30), "送信ボタンが押せない (\(round))")
            Thread.sleep(forTimeInterval: 0.5)
            send.press(forDuration: 0.15)
            let mine = app.staticTexts["確認 \(round)"].firstMatch
            XCTAssertTrue(mine.appears(timeout: 30), "送ったメッセージが出ない (\(round))")
            XCTAssertTrue(mine.isHittable, "送ったメッセージが見える位置にない (\(round))")
            // 上へ読み返して、下へ戻す。速く動かすが、指を止めてから離す(慣性で流さない)。`swipeDown`/`swipeUp` は
            // 慣性のスクロールが止まるまで次の操作を待たされ、1 往復に約 4.5 秒かかっていた。会話の枠は往復ごとに 1 回だけ
            // 読み(キーボードの有無で変わる)、アプリを起点にした座標で動かす(会話を起点にすると、指を動かす間に会話を
            // 5 回以上探し直す)。
            let frame = page.frame
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let top = origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + frame.height * 0.3))
            let bottom = origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + frame.height * 0.6))
            top.press(forDuration: 0.05, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0.1)
            bottom.press(forDuration: 0.05, thenDragTo: top, withVelocity: .fast, thenHoldForDuration: 0.1)
        }
        let watchdog = element(app, "debug-hang-watchdog")
        if watchdog.appears(timeout: 30) {
            print("MAX_MAIN_THREAD_STALL_MS_UNDER_XCUITEST \(watchdog.value as? String ?? watchdog.label)")
        }
        attach(app, "long-chat-after-20-rounds")
    }

    // MARK: §2.6 オンボーディング → 最初の単元

    @MainActor
    func testOnboardingLeadsToFirstUnitAndIsNotShownAgain() throws {
        var app = launch(["-reset-onboarding", "-workbook-empty"])
        XCTAssertTrue(app.buttons["はじめる"].appears(timeout: 20), "サインイン後にオンボーディングが出ない")
        app.buttons["はじめる"].tap()
        let next = app.buttons["次へ"].firstMatch
        XCTAssertTrue(waitEnabled(next, timeout: 15), "ChatGPT 接続の次へが無い")
        next.tap()
        for option in ["中学2年生", "定期テストの勉強", "数学", "問題文から式を作れない", "紙のノートを使う"] {
            let button = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", option)).firstMatch
            XCTAssertTrue(button.appears(timeout: 5), "\(option) が無い")
            button.tap()
            XCTAssertTrue(waitEnabled(next, timeout: 5))
            next.tap()
        }
        XCTAssertTrue(app.buttons["今は追加しない"].appears(timeout: 5))
        app.buttons["今は追加しない"].tap()
        XCTAssertTrue(app.staticTexts["準備ができました"].appears(timeout: 5))
        XCTAssertFalse(app.buttons["最初から見る"].exists, "試作の「最初から見る」が残っている")
        element(app, "onboarding-create-first-unit").tap()

        // 最初の問いはアプリが待ちなしで出す(待ち時間の体験 §3.3)。答えると次の問いがすぐ出て、
        // 3 つ目に答えた時にモデルが動き、全体像の提案まで進む。
        let question = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "いま学校では何をやっている")).firstMatch
        XCTAssertTrue(question.appears(timeout: 10), "単元づくりの最初の問いが出ない")
        let input = app.textViews.matching(identifier: "chat-page").firstMatch
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertEqual((input.value as? String ?? "").trimmingCharacters(in: .whitespaces), "", "入力欄に下書きが入っている")
        let answers: [(String, String?)] = [("中2で連立方程式を予習したい", "次のテストはいつ"), ("10月15日", "どこでつまずいている"), ("文章題の式が作れない", nil)]
        for (answer, nextQuestion) in answers {
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
            input.typeText(answer)
            XCTAssertTrue(waitEnabled(sendButton(app), timeout: 10))
            Thread.sleep(forTimeInterval: 0.5)
            sendButton(app).press(forDuration: 0.15)
            if let nextQuestion {
                let next = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", nextQuestion)).firstMatch
                XCTAssertTrue(next.appears(timeout: 5), "次の問いがすぐ出ない: \(nextQuestion)")
            }
        }
        let start = element(app, "workbook-proposal-start")
        // 3 つ目の答えから全体像カードまでは、モックの応答でも CI で 11〜19 秒かかる(12 run の実測。
        // 全体像を組むターンと、その後の台帳の書き込みの分)。遅い runner では 25 秒を超えて落ちたので、余裕を持つ。
        if !start.appears(timeout: 60) { UITestSupport.saveProbe(app, name: "onboarding-no-proposal") }
        XCTAssertTrue(start.exists, "全体像カードが出ない: \(screenSummary(app))")
        attach(app, "unit-proposal")
        start.tap()

        // 質問画面に取り残されず、小単元 1 の要点が開く。
        XCTAssertTrue(element(app, "workbook-subunit-header").appears(timeout: 15), "はじめるの後に小単元 1 が開かない")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "要点を話すね")).firstMatch.appears(timeout: 15))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "workbook-home").appears(timeout: 10))
        XCTAssertTrue(app.staticTexts["頂点の座標が求められる"].firstMatch.appears(timeout: 5), "ホームに単元が無い")

        app.terminate()
        app = launch(["-workbook-empty"])
        XCTAssertTrue(element(app, "workbook-create-unit").appears(timeout: 20), "再起動後にホーム(単元を作る)が出ない")
        XCTAssertFalse(app.buttons["はじめる"].exists, "再起動でオンボーディングがまた出た")
        attach(app, "relaunch-empty-home")
    }

    @MainActor
    private func sendButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "送信", "chat-page")).firstMatch
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
