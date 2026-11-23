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
}
