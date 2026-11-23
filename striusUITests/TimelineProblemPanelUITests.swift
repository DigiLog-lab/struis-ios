import UIKit
import XCTest

/// iPad の問題のパネル(#176): 紙を全面に敷き、問題は紙の上に浮かぶパネル。高さだけが変わり、畳むと問いの 1 行が残る。
/// 画面の確かめ用のスクショを残す(iPad でだけ動く。iPhone では飛ばす)。
final class TimelineProblemPanelUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func shot(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor
    private func launch(_ arguments: [String], environment: [String: String] = [:]) -> XCUIApplication {
        let app = UITestSupport.deviceApp(arguments: ["-skip-onboarding"] + arguments)
        app.launchEnvironment["STRUIS_START_SCREEN"] = nil
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
        return app
    }

    /// 前後比較用: main にもある並び替えのカード(`-timeline-order-demo`)を、横向きと縦向きで撮るだけ。
    /// main のビルドにも同じ操作で撮れるように、パネルの有無は確かめない。
    @MainActor
    func testOrderCardShots() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad の並びだけ")
        let app = launch(["-timeline-order-demo"])
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.descendants(matching: .any)["timeline-order-list"].waitForExistence(timeout: 30), "並び替えのカードが出ない")
        sleep(2)
        shot("order-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        shot("order-portrait")
    }

    /// 選ぶカード: 条件を改行して並べた問題文が、縦向きでも横向きでも同じ幅のパネルに入る。
    @MainActor
    func testReasonCardInPanel() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad の並びだけ")
        let app = launch(["-timeline-panel-demo"])
        XCUIDevice.shared.orientation = .landscapeLeft
        let panel = app.descendants(matching: .any)["timeline-problem-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 30), "問題のパネルが出ない")
        sleep(2)
        shot("reason-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        shot("reason-portrait")
        XCTAssertEqual(panel.frame.width, 432, accuracy: 1, "縦向きでもパネルの幅は横向きと同じ")
        // 縦向きで右に質問の欄を開くと、タイムラインが狭くなる。パネルは欄の中まではみ出さない(Codex のレビューの指摘)。
        app.buttons["timeline-ask"].drag(by: CGVector(dx: -240, dy: 0))
        let close = app.buttons["question-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 6), "引いても質問が開かない")
        sleep(2)
        shot("reason-portrait-question-open")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(panel.frame.maxX, window.maxX - 380 + 1, "質問の欄を開くと、パネルが欄の中まではみ出す")
        close.tap()
        sleep(2)
        XCTAssertEqual(panel.frame.width, 432, accuracy: 1, "質問の欄を閉じても、パネルの幅が戻らない")
        // 選ぶと、結果もパネルの中に出る。
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "異符号の電荷は引き合うから")).firstMatch.tap()
        XCTAssertTrue(app.buttons["timeline-next"].waitForExistence(timeout: 15), "選んだ後の結果が出ない")
        sleep(2)
        shot("reason-portrait-result")
    }

    /// 書くカード: つまみを引くと指を止めた所でパネルが止まり、下まで引くと畳んで問いの 1 行が残る。畳んだ所に書いてから
    /// 広げると、書いた線はパネルの下に隠れる。帯を押すと広がる。
    @MainActor
    func testPanelFollowsFingerAndCollapses() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad の並びだけ")
        // 誤答で返す(結果の画面で、書いた線に赤ペンが重なる所まで見る)。
        let app = launch(["-timeline-panel-demo", "-timeline-panel-solve"], environment: ["STRUIS_MOCK_TIMELINE_WRONG": "1"])
        XCUIDevice.shared.orientation = .landscapeLeft
        let panel = app.descendants(matching: .any)["timeline-problem-panel"]
        let handle = app.descendants(matching: .any)["timeline-problem-panel-handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 30), "パネルのつまみが出ない")
        sleep(2)
        shot("solve-1-expanded")
        let expanded: CGFloat = panel.frame.height

        // 半分ほど下げて止める: 離した位置で止まる。
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: 0, dy: expanded * 0.45)),
                    withVelocity: 300, thenHoldForDuration: 0.6)
        sleep(1)
        shot("solve-2-half")
        XCTAssertLessThan(panel.frame.height, expanded - 100, "引いた分だけ低くならない")
        XCTAssertGreaterThan(panel.frame.height, 150, "途中で止めたのに畳まれた")

        // 下まで引く: 畳んで問いの 1 行だけが残る。
        let middle = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.press(forDuration: 0.3, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: expanded)), withVelocity: 500,
                     thenHoldForDuration: 0.2)
        let collapsed = app.descendants(matching: .any)["timeline-problem-panel-collapsed"]
        XCTAssertTrue(collapsed.waitForExistence(timeout: 5), "畳んだ帯が出ない")
        sleep(1)
        shot("solve-3-collapsed")
        XCTAssertLessThan(panel.frame.height, 80, "畳んでも高いまま")

        // パネルがあった所(左)と右に書く。
        let window = app.windows.firstMatch
        func stroke(_ from: CGVector, _ to: CGVector) {
            window.coordinate(withNormalizedOffset: from).press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: to),
                                                                withVelocity: 600, thenHoldForDuration: 0)
        }
        stroke(CGVector(dx: 0.06, dy: 0.30), CGVector(dx: 0.30, dy: 0.34))
        stroke(CGVector(dx: 0.06, dy: 0.42), CGVector(dx: 0.30, dy: 0.40))
        stroke(CGVector(dx: 0.55, dy: 0.30), CGVector(dx: 0.80, dy: 0.36))
        sleep(1)
        shot("solve-4-collapsed-ink")

        // 帯を押すと広がり、左に書いた線はパネルの下に隠れる(右の線は残る)。
        collapsed.tap()
        sleep(2)
        shot("solve-5-expanded-over-ink")
        XCTAssertGreaterThan(panel.frame.height, expanded - 4, "帯を押しても広がらない")

        // 縦向きでも同じ幅のパネル。つまみを押すと畳む。
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        shot("solve-6-portrait")
        handle.tap()
        sleep(2)
        shot("solve-7-portrait-collapsed")
        XCTAssertLessThan(panel.frame.height, 80, "つまみを押しても畳まない")

        // 送ると、畳んでいてもパネルを広げて結果を出す。書いた線はパネルの右に残る。
        let send = app.buttons["timeline-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "送るが出ない")
        send.pullUp()
        XCTAssertTrue(app.buttons["timeline-next"].waitForExistence(timeout: 30), "結果が出ない")
        sleep(3)
        shot("solve-8-portrait-result")
        XCTAssertGreaterThan(panel.frame.height, 300, "結果の時にパネルが広がらない")
    }

    /// 実際の Claude が、条件ごとに改行した問題文を出すか(#176)。力学の単元に固定して 3 問撮り、問題文を文字でも残す。
    /// `STRUIS_DEMO_ANTHROPIC_KEY_FILE`(API キーのファイル)が無ければ飛ばす(CI では流さない)。
    @MainActor
    func testRealClaudeWritesConditionsOnSeparateLines() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad の並びだけ")
        guard let key = ProcessInfo.processInfo.environment["STRUIS_DEMO_ANTHROPIC_KEY_FILE"], !key.isEmpty else {
            throw XCTSkip("STRUIS_DEMO_ANTHROPIC_KEY_FILE が無い")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-skip-onboarding", "-timeline-scope-demo"]
        app.launchEnvironment["STRUIS_LEDGER"] = "memory"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "1"
        app.launchEnvironment["STRUIS_DEBUG_ANTHROPIC_KEY_FILE"] = key
        app.launchEnvironment["STRUIS_PLAN"] = "generous"
        app.launchEnvironment["STRUIS_USAGE_PERCENT"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["timeline-units-button"].waitForExistence(timeout: 60), "タイムラインが出ない")
        app.buttons["timeline-units-button"].tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workbook-unit-card-' AND label CONTAINS '力学'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "力学の単元が無い")
        if !card.isHittable { app.swipeUp() }
        card.tap()
        let solve = app.buttons["workbook-unit-solve-in-timeline"]
        XCTAssertTrue(solve.waitForExistence(timeout: 15), "「タイムラインで解く」が無い")
        solve.tap()
        var previous: String = ""
        var texts: [String] = []
        for index in 1...3 {
            XCTAssertTrue(waitForProblem(app, timeout: 420, changingFrom: previous), "\(index) 問目が出ない")
            sleep(3)
            previous = problemText(app)
            texts.append("--- \(index)\n" + previous)
            shot("real-\(index)")
            guard index < 3, app.buttons["timeline-skip"].exists else { break }
            app.buttons["timeline-skip"].tap()
        }
        let text = XCTAttachment(string: texts.joined(separator: "\n"))
        text.name = "real-problem-texts"
        text.lifetime = .keepAlways
        add(text)
    }

    @MainActor
    private func problemText(_ app: XCUIApplication) -> String {
        let problem = app.descendants(matching: .any)["timeline-problem"].firstMatch
        let prompt = app.descendants(matching: .any)["timeline-prompt"].firstMatch
        return [problem, prompt].filter(\.exists).map(\.label).joined(separator: "\n[prompt]\n")
    }

    @MainActor
    private func waitForProblem(_ app: XCUIApplication, timeout: TimeInterval, changingFrom previous: String) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = problemText(app)
            if !text.isEmpty, text != previous { return true }
            sleep(2)
        }
        return false
    }
}
