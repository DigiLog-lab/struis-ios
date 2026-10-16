import XCTest

final class ChatImmediateImageSendUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// 質問シートで撮影 → 添付 → 送信。送信は端末の台帳に入り、モック応答が返る。
    @MainActor
    private func launchCameraTestApp() throws -> XCUIApplication {
        let app = UITestSupport.deviceApp()
        app.launch()
        app.openQuestionSheet()
        return app
    }

    @MainActor
    func testCancelWhileCaptureIsFinishing() throws {
        let app = UITestSupport.deviceApp()
        // キャンセルを撮影が終わる前に押すため、シミュレータの撮影が終わるまでを長くする(既定の 3 秒では、遅い CI で
        // シャッターからキャンセルが届くまでに 3.5 秒かかり、撮影が先に終わって写真が添付されていた)。
        let finishSeconds: TimeInterval = 8
        app.launchEnvironment["STRUIS_TEST_CAPTURE_FINISH_SECONDS"] = String(finishSeconds)
        app.launch()
        app.openQuestionSheet()
        let plus = app.buttons["添付"].firstMatch
        XCTAssertTrue(plus.appears(timeout: 30))
        plus.press(forDuration: 0.6)
        let shutter = app.buttons["chat-camera-shutter"]
        XCTAssertTrue(shutter.appears(timeout: 5))
        let shutterTapped = Date()
        shutter.tap()
        app.buttons["キャンセル"].tap()
        XCTAssertLessThan(Date().timeIntervalSince(shutterTapped), finishSeconds, "キャンセルが撮影の終わりより後に届いた")
        XCTAssertTrue(shutter.waitForNonExistence(timeout: 5))
        let attachment = app.buttons.matching(NSPredicate(format:
            "label BEGINSWITH 'photo-' AND label ENDSWITH 'を解除'")).firstMatch
        let unexpectedAttachment = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"), object: attachment)
        unexpectedAttachment.isInverted = true
        // 撮影が終わった後(写真が遅れて届く時)まで見る。少なくとも以前と同じ 4 秒は見る。
        let window = max(4, finishSeconds + 2 - Date().timeIntervalSince(shutterTapped))
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedAttachment], timeout: window), .completed)
        XCTAssertTrue(plus.isEnabled)
    }

    /// 写真 2 枚を送って、アプリを再起動しても端末の台帳から同じ 2 枚が戻ること。
    @MainActor
    func testTwoImagesPersistAfterRelaunch() throws {
        let app = UITestSupport.deviceApp()
        app.launchEnvironment["STRUIS_LEDGER"] = "persistent"
        app.launch()
        app.openQuestionSheet()
        let plus = app.buttons["添付"].firstMatch
        XCTAssertTrue(plus.appears(timeout: 30))
        app.buttons["履歴"].firstMatch.tap()
        app.buttons["新しい会話"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: plus
        )], timeout: 30), .completed)
        for count in 1...2 {
            plus.press(forDuration: 0.6)
            let shutter = app.buttons["chat-camera-shutter"]
            XCTAssertTrue(shutter.appears(timeout: 10))
            shutter.tap()
            let attachments = app.buttons.matching(NSPredicate(format:
                "label BEGINSWITH 'photo-' AND label ENDSWITH 'を解除'"))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in attachments.count == count }, object: nil
            )], timeout: 15), .completed)
        }
        app.buttons.matching(NSPredicate(format:
            "label == %@ AND identifier == %@", "送信", "chat-page")).firstMatch.tap()
        for name in ["photo-1.jpg", "photo-2.jpg"] {
            let image = app.buttons.matching(NSPredicate(format:
                "label CONTAINS %@ AND NOT label CONTAINS 'を解除'", name)).firstMatch
            XCTAssertTrue(image.appears(timeout: 30), "\(name) が送信後の会話に出ない")
        }
        capture("two-images-sent")

        // 再起動: 最新の会話 (いま送ったもの) を質問シートで開く。
        app.terminate()
        app.launch()
        app.openQuestionSheet()
        for name in ["photo-1.jpg", "photo-2.jpg"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format:
                "label CONTAINS %@ AND NOT label CONTAINS 'を解除'", name)).firstMatch.appears(timeout: 30),
                "\(name) が再起動後に残っていない")
        }
        capture("two-images-reopened")
    }

    @MainActor private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSendImmediatelyAfterCameraAttachment() throws {
        let app = try launchCameraTestApp()

        let plus = app.buttons["添付"].firstMatch
        XCTAssertTrue(plus.appears(timeout: 30))
        app.buttons["履歴"].firstMatch.tap()
        app.buttons["新しい会話"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: plus
        )], timeout: 30), .completed)
        plus.press(forDuration: 0.6)
        let shutter = app.buttons["chat-camera-shutter"]
        XCTAssertTrue(shutter.appears(timeout: 5))
        XCTAssertTrue(shutter.isEnabled)
        shutter.tap()

        // The sensor has delivered pixels, but the simulated final capture
        // callback has not run. The old code exposed an attachment here.
        XCTAssertTrue(shutter.exists, "撮影完了前にカメラを閉じて添付を公開してはいけません")
        let removeAttachment = app.buttons.matching(NSPredicate(format:
            "label BEGINSWITH 'photo-' AND label ENDSWITH 'を解除'")).firstMatch
        XCTAssertFalse(removeAttachment.exists, "撮影完了前には送信対象を公開しないこと")
        XCTAssertTrue(removeAttachment.appears(timeout: 10))
        let send = app.buttons.matching(NSPredicate(format:
            "label == %@ AND identifier == %@", "送信", "chat-page")).firstMatch
        XCTAssertTrue(send.isEnabled)
        // No screenshot, sleep, or other interaction between attachment and send.
        send.tap()

        let sentImage = app.buttons.matching(NSPredicate(format:
            "label CONTAINS 'photo-1.jpg' AND NOT label CONTAINS 'を解除'")).firstMatch
        XCTAssertTrue(sentImage.appears(timeout: 150), "送信済み画像が履歴に表示されること")
        XCTAssertFalse(app.staticTexts["ネットワークに接続できません"].exists)
        XCTAssertFalse(removeAttachment.exists, "成功後に未送信の添付へ戻らないこと")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "immediate-camera-image-sent"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
