import XCTest

/// Exercises the production camera and attachment route inside the 質問 sheet.
/// The simulator has no camera, so the capture uses the test paper image.
final class ChatCameraUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCameraRotationAndReopening() throws {
        let app = UITestSupport.deviceApp()
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        app.openQuestionSheet()
        let plus = app.buttons["添付"]
        XCTAssertTrue(plus.waitForExistence(timeout: 30), "実機のチャットに到達できません")
        // ＋のパレットは「撮る」「写真を選ぶ」「ファイル」の順(E2E M8)。
        plus.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "撮る", "chat-page")).firstMatch.waitForExistence(timeout: 3))
        plus.tap()

        addUIInterruptionMonitor(withDescription: "カメラの許可") { alert in
            let allow = alert.buttons.matching(NSPredicate(format:
                "label IN %@", ["許可", "OK", "Allow"])).firstMatch
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        let shutter = app.buttons["chat-camera-shutter"]
        let cancel = app.buttons["キャンセル"]
        func screenScreenshot(_ name: String) {
            // Capture the screen rather than crop the application's rotated
            // multi-window frame, which truncates landscape screenshots.
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = name
            image.lifetime = .keepAlways
            add(image)
        }
        func openCamera() {
            plus.press(forDuration: 0.8)
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            if !shutter.isEnabled { app.tap() }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15), .completed)
            XCTAssertFalse(app.buttons["写真を選ぶ"].exists, "長押し後の指離しで添付メニューを開かないこと")
        }
        func verifyPreview(_ name: String) {
            let panel = app.otherElements["chat-camera-panel"]
            let preview = app.otherElements["chat-camera-preview"]
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(preview.frame.width, app.frame.width * 0.7)
            XCTAssertEqual(preview.frame.minX, panel.frame.minX + 4, accuracy: 1)
            XCTAssertEqual(preview.frame.maxX, panel.frame.maxX - 4, accuracy: 1)
            XCTAssertEqual(preview.frame.minY, panel.frame.minY + 16, accuracy: 1)
            XCTAssertEqual(preview.frame.maxY, shutter.frame.minY - 8, accuracy: 1)
            XCTAssertEqual(shutter.frame.width, shutter.frame.height, accuracy: 1)
            XCTAssertTrue(shutter.isHittable)
            XCTAssertTrue(cancel.isHittable)
            print("\(name): app=\(app.frame) preview=\(preview.frame) shutter=\(shutter.frame)")
            screenScreenshot(name)
        }
        openCamera()
        verifyPreview("rotation-01-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        verifyPreview("rotation-02-landscape-left")
        XCUIDevice.shared.orientation = .landscapeRight
        verifyPreview("rotation-03-landscape-right")
        XCUIDevice.shared.orientation = .portrait
        verifyPreview("rotation-04-portrait-restored")
        cancel.tap()
        XCTAssertTrue(shutter.waitForNonExistence(timeout: 5))

        XCUIDevice.shared.orientation = .landscapeLeft
        openCamera()
        verifyPreview("rotation-05-open-in-landscape")
        cancel.tap()
        XCTAssertTrue(shutter.waitForNonExistence(timeout: 5))

        XCUIDevice.shared.orientation = .portrait
        let field = app.textViews.matching(identifier: "chat-page").firstMatch
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        openCamera()
        XCUIDevice.shared.orientation = .landscapeRight
        verifyPreview("rotation-07-keyboard-landscape")
        cancel.tap()
        XCTAssertTrue(shutter.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(plus.isHittable)
        screenScreenshot("rotation-08-chat-restored")
    }

    @MainActor
    func testCameraAndChatPreservation() throws {
        let app = UITestSupport.deviceApp()
        app.launch()
        app.openQuestionSheet()
        let plus = app.buttons["添付"]
        if !plus.waitForExistence(timeout: 30) {
            screenshot(app, "00-chat-unavailable")
            XCTFail("実機のチャットに到達できません。サインイン状態を確認してください。")
            return
        }
        app.buttons["履歴"].tap()
        // 端末フィクスチャの「前回の続き」の会話 (LedgerFixtures.seedChatIfEmpty)。
        let savedThread = app.buttons.allElementsBoundByIndex.first {
            $0.isHittable && $0.label.contains("二次関数の途中式")
        }
        XCTAssertNotNil(savedThread, "チャット表示の維持を確認するため、既存の会話が必要です")
        savedThread?.tap()
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        let field = app.textViews.matching(identifier: "chat-page").firstMatch
        XCTAssertTrue(field.exists)
        XCTAssertGreaterThan(field.frame.width, 0)
        let initialField = field.frame
        let initialPlus = plus.frame
        let chat = app.scrollViews["chat-page"]
        chat.swipeDown()
        let visibleText = chat.staticTexts.allElementsBoundByIndex.filter { $0.isHittable }
        let positions = visibleText.map { ($0, $0.frame) }
        XCTAssertFalse(positions.isEmpty)
        screenshot(app, "01-chat-before")

        plus.tap()
        let camera = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "撮る", "chat-page")).firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["写真を選ぶ"].exists)
        XCTAssertTrue(app.buttons["ファイル"].exists)
        XCTAssertLessThan(camera.frame.minX, app.buttons["写真を選ぶ"].frame.minX, "「撮る」が先頭にない")
        screenshot(app, "02-attachment-palette")
        plus.tap()
        XCTAssertFalse(app.buttons["写真を選ぶ"].exists)

        addUIInterruptionMonitor(withDescription: "Camera permission") { alert in
            let allow = alert.buttons.matching(NSPredicate(format:
                "label IN %@", ["許可", "OK", "Allow"])).firstMatch
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        plus.press(forDuration: 0.8)
        let cancel = app.buttons["キャンセル"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        // Trigger the interruption monitor if first-time camera permission is up.
        if !app.buttons["chat-camera-shutter"].isEnabled { app.tap() }
        let shutter = app.buttons["chat-camera-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15), .completed)
        XCTAssertFalse(app.buttons["写真を選ぶ"].exists, "長押し後の指離しで添付メニューを開いてはいけません")
        XCTAssertGreaterThan(cancel.frame.minY, app.frame.height * 0.25)
        XCTAssertEqual(shutter.frame.width, shutter.frame.height)
        XCTAssertEqual(field.frame, initialField)
        for (element, frame) in positions { XCTAssertEqual(element.frame, frame) }
        screenshot(app, "03-live-camera-after-release")
        cancel.tap()
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        XCTAssertEqual(field.frame, initialField)
        XCTAssertEqual(plus.frame, initialPlus)
        for (element, frame) in positions { XCTAssertEqual(element.frame, frame) }
        screenshot(app, "04-chat-after-cancel")

        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let keyboardField = field.frame
        let keyboardPlus = plus.frame
        plus.press(forDuration: 0.8)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertEqual(field.frame, keyboardField)
        XCTAssertEqual(plus.frame, keyboardPlus)
        screenshot(app, "05-camera-with-keyboard")
        cancel.tap()
        XCTAssertEqual(field.frame, keyboardField)
        XCTAssertEqual(plus.frame, keyboardPlus)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        screenshot(app, "06-keyboard-after-cancel")

        plus.press(forDuration: 0.8)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15), .completed)
        screenshot(app, "07-preview-before-photo")
        XCTAssertTrue(shutter.isHittable)
        shutter.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: shutter)], timeout: 15), .completed)
        let attachment = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'photo-' AND label ENDSWITH 'を解除'")).firstMatch
        XCTAssertTrue(attachment.waitForExistence(timeout: 5), "撮影写真が送信前の添付一覧にあること")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "送信", "chat-page")).firstMatch.isEnabled)
        XCTAssertEqual(field.frame.width, initialField.width)
        screenshot(app, "08-photo-attached-unsent")
        attachment.tap()
        XCTAssertFalse(attachment.exists)
    }

    @MainActor private func screenshot(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
