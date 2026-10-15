import XCTest

/// Issue #10(使ってみて気になった点)の画面を撮る。モック応答・シミュレータ既定フィクスチャ。
/// 撮った画像は添付に残し、`SHOT_DIR`(`TEST_RUNNER_SHOT_DIR`)があればそこへも書き出す(修正前後の比較用)。
final class Issue10ScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func text(_ app: XCUIApplication, containing fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    @MainActor
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    @MainActor
    private func shoot(_ app: XCUIApplication, camera: XCUIElement) {
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        camera.press(forDuration: 0.15)
        let shutter = app.buttons["chat-camera-shutter"].firstMatch
        XCTAssertTrue(shutter.waitForExistence(timeout: 15), "カメラが開かない")
        if !shutter.isEnabled { app.tap() }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15)
        shutter.tap()
        // カメラは閉じずに続けて撮れる(一括採点、PR #7)。「採点する 1」で確認画面へ。
        let done = app.buttons["chat-camera-done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 20), "「採点する」が出ない")
        done.tap()
        let use = element(app, "workbook-capture-use")
        XCTAssertTrue(use.waitForExistence(timeout: 20), "撮影確認が出ない")
        use.tap()
    }

    /// 演習の一覧 → 問題 →「採点」→ 全問正解のリザルト(丸)→ 演習の一覧へ戻る。
    @MainActor
    func testProblemCaptureAndAllCorrectResult() throws {
        let app = UITestSupport.deviceApp()
        app.launchEnvironment["STRUIS_MOCK_GRADING_LAST_ONLY"] = "1"
        app.launch()
        let row = element(app, "workbook-subunit-sub-1")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let request = element(app, "workbook-request-set")
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        request.tap()
        XCTAssertTrue(element(app, "workbook-set-problem-1").waitForExistence(timeout: 20))
        shoot(app, camera: element(app, "workbook-capture-button"))
        let practice = element(app, "workbook-result-practice")
        XCTAssertTrue(practice.waitForExistence(timeout: 60), "類題のリザルトに「演習へ」が無い: \(app.debugDescription.prefix(4000))")
        practice.tap()

        // 演習の一枚(作られた演習の一覧)から 1 問を開く。
        let problem = element(app, "workbook-set-problem-5")
        XCTAssertTrue(problem.waitForExistence(timeout: 20), "演習の一枚が開かない")
        sleep(1)
        shot("1-set-list")
        problem.tap()
        let retry = element(app, "workbook-problem-retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "問題の画面に撮るボタンが無い")
        sleep(1)
        shot("2-problem")

        shoot(app, camera: retry)
        let status = element(app, "workbook-verdict-score")
        XCTAssertTrue(status.waitForExistence(timeout: 40), "リザルトが出ない")
        sleep(2)
        shot("3-result")

        let back = element(app, "workbook-result-return-to-set")
        if back.waitForExistence(timeout: 3) {
            back.tap()
            XCTAssertTrue(element(app, "workbook-set-problem-5").waitForExistence(timeout: 10), "演習の一覧へ戻らない")
            sleep(1)
            shot("4-after-return")
        }
    }

    /// 数式と強調の混じった返事: 本文を書き終えて記録を書いている間(生成直後)と、出来上がった後。
    @MainActor
    func testReplyRendersMathRightAfterGeneration() throws {
        let app = UITestSupport.deviceApp()
        app.launchEnvironment["STRUIS_MOCK_TAIL_DELAY_MS"] = "15000"
        app.launch()
        XCTAssertTrue(app.openQuestionSheet())
        let input = app.textViews.matching(identifier: "chat-page").firstMatch
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        input.typeText("積分の途中を見て")
        let send = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "送信", "chat-page")).firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        send.press(forDuration: 0.15)

        XCTAssertTrue(text(app, containing: "学習の進み具合を記録しています").waitForExistence(timeout: 20), "記録の言葉が出ない")
        sleep(3)
        shot("5-reply-while-recording")
        XCTAssertTrue(element(app, "chat-thought-seconds").waitForExistence(timeout: 40), "返事が出来上がらない")
        sleep(3)
        shot("6-reply-completed")
    }
}
