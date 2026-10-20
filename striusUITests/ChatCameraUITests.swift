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
        XCTAssertTrue(plus.appears(timeout: 30), "実機のチャットに到達できません")
        // ＋のパレットは「撮る」「写真を選ぶ」「ファイル」の順(E2E M8)。
        plus.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "撮る", "chat-page")).firstMatch.appears(timeout: 3))
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
            XCTAssertTrue(cancel.appears(timeout: 5))
            if !shutter.isEnabled { app.tap() }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15), .completed)
            XCTAssertFalse(app.buttons["写真を選ぶ"].exists, "長押し後の指離しで添付メニューを開かないこと")
        }
        func cameraFrames() throws -> (app: CGRect, preview: CGRect, panel: CGRect, shutter: CGRect) {
            // Each element.frame crosses the automation connection and asks
            // the application for another accessibility snapshot. Read all
            // geometry from one tree so the assertions describe one layout.
            let root = try app.snapshot()
            let identifiers: Set<String> = ["chat-camera-preview", "chat-camera-panel", "chat-camera-shutter"]
            var frames: [String: CGRect] = [:]
            var remaining = root.children
            while let node = remaining.popLast() {
                if identifiers.contains(node.identifier) { frames[node.identifier] = node.frame }
                remaining.append(contentsOf: node.children)
            }
            return (root.frame,
                    try XCTUnwrap(frames["chat-camera-preview"], "プレビューが要素の木に無い"),
                    try XCTUnwrap(frames["chat-camera-panel"], "カメラの枠が要素の木に無い"),
                    try XCTUnwrap(frames["chat-camera-shutter"], "シャッターが要素の木に無い"))
        }
        func verifyPreview(_ name: String) throws {
            let preview = app.otherElements["chat-camera-preview"]
            XCTAssertTrue(preview.appears(timeout: 5))
            // 回転は非同期: 向きを変えた直後は、画面もプレビューもまだ前の向きの大きさで測れる(388 vs 611 で落ちた)。
            // 画面の向きが揃い、プレビューの大きさが 2 回続けて同じになるまで待ってから測る。
            let landscape = [.landscapeLeft, .landscapeRight].contains(XCUIDevice.shared.orientation)
            let deadline = Date().addingTimeInterval(8)
            var last = CGRect.null
            var frames = try cameraFrames()
            while Date() < deadline {
                let frame = frames.preview
                let oriented = (frames.app.width > frames.app.height) == landscape
                if oriented, frame == last, frame.width > 0 { break }
                last = frame
                Thread.sleep(forTimeInterval: 0.25)
                frames = try cameraFrames()
            }
            if (frames.app.width > frames.app.height) != landscape || frames.preview.width <= frames.app.width * 0.7 {
                UITestSupport.saveProbe(app, name: "camera-rotation-\(name)")
            }
            XCTAssertEqual(frames.app.width > frames.app.height, landscape, "画面の向きが変わっていない: \(frames.app)")
            XCTAssertGreaterThan(frames.preview.width, frames.app.width * 0.7)
            XCTAssertEqual(frames.preview.minX, frames.panel.minX + 4, accuracy: 1)
            XCTAssertEqual(frames.preview.maxX, frames.panel.maxX - 4, accuracy: 1)
            XCTAssertEqual(frames.preview.minY, frames.panel.minY + 16, accuracy: 1)
            XCTAssertEqual(frames.preview.maxY, frames.shutter.minY - 8, accuracy: 1)
            XCTAssertEqual(frames.shutter.width, frames.shutter.height, accuracy: 1)
            XCTAssertTrue(shutter.isHittable)
            XCTAssertTrue(cancel.isHittable)
            print("\(name): app=\(frames.app) preview=\(frames.preview) shutter=\(frames.shutter)")
            screenScreenshot(name)
        }
        openCamera()
        try verifyPreview("rotation-01-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        try verifyPreview("rotation-02-landscape-left")
        XCUIDevice.shared.orientation = .landscapeRight
        try verifyPreview("rotation-03-landscape-right")
        XCUIDevice.shared.orientation = .portrait
        try verifyPreview("rotation-04-portrait-restored")
        cancel.tap()
        XCTAssertTrue(shutter.waitForNonExistence(timeout: 5))

        XCUIDevice.shared.orientation = .landscapeLeft
        openCamera()
        try verifyPreview("rotation-05-open-in-landscape")
        cancel.tap()
        XCTAssertTrue(shutter.waitForNonExistence(timeout: 5))

        XCUIDevice.shared.orientation = .portrait
        let field = app.textViews.matching(identifier: "chat-page").firstMatch
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: 5))
        app.dismissKeyboardIntroductionIfShown()
        openCamera()
        XCUIDevice.shared.orientation = .landscapeRight
        try verifyPreview("rotation-07-keyboard-landscape")
        cancel.tap()
        XCTAssertTrue(shutter.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: 5))
        // 新しい Simulator では、戻ったキーボードにシステムの初回案内が重なり「添付」を覆う(アプリの表示ではない)。
        app.dismissKeyboardIntroductionIfShown()
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
        if !plus.appears(timeout: 30) {
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
        XCTAssertTrue(plus.appears(timeout: 10))
        let field = app.textViews.matching(identifier: "chat-page").firstMatch
        XCTAssertTrue(field.exists)
        XCTAssertGreaterThan(field.frame.width, 0)
        let initialField = field.frame
        let initialPlus = plus.frame
        let chat = app.scrollViews["chat-page"]
        // 会話の本文は台帳から非同期に入る。「添付」は入力欄の一部なので先に出る。最後の発言が出るまで待つ。
        // 4 往復の短い会話は 1 画面に収まり、位置は下寄せで止まっている。`swipeDown` はしない:
        // `.large` のシートの中で、上端にあるスクロールを引き下げるとシートごと動いて本文が隠れる。
        let lastLine = chat.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "写真で送ります")).firstMatch
        if !lastLine.waitForExistence(timeout: 10) { UITestSupport.saveProbe(app, name: "camera-preservation-no-thread") }
        XCTAssertTrue(lastLine.exists, "保存済みの会話の本文が出ない")
        let visibleText = chat.staticTexts.allElementsBoundByIndex.filter { $0.isHittable }
        let positions = visibleText.map { ($0, $0.frame) }
        if positions.isEmpty { UITestSupport.saveProbe(app, name: "camera-preservation-no-text") }
        XCTAssertFalse(positions.isEmpty)
        screenshot(app, "01-chat-before")

        plus.tap()
        let camera = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "撮る", "chat-page")).firstMatch
        XCTAssertTrue(camera.appears(timeout: 3))
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
        XCTAssertTrue(cancel.appears(timeout: 5))
        // Trigger the interruption monitor if first-time camera permission is up.
        if !app.buttons["chat-camera-shutter"].isEnabled { app.tap() }
        let shutter = app.buttons["chat-camera-shutter"]
        XCTAssertTrue(shutter.appears(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15), .completed)
        XCTAssertFalse(app.buttons["写真を選ぶ"].exists, "長押し後の指離しで添付メニューを開いてはいけません")
        XCTAssertGreaterThan(cancel.frame.minY, app.frame.height * 0.25)
        XCTAssertEqual(shutter.frame.width, shutter.frame.height)
        XCTAssertEqual(field.frame, initialField)
        for (element, frame) in positions { XCTAssertEqual(element.frame, frame) }
        screenshot(app, "03-live-camera-after-release")
        cancel.tap()
        XCTAssertTrue(plus.appears(timeout: 5))
        XCTAssertEqual(field.frame, initialField)
        XCTAssertEqual(plus.frame, initialPlus)
        for (element, frame) in positions { XCTAssertEqual(element.frame, frame) }
        screenshot(app, "04-chat-after-cancel")

        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: 5))
        let keyboardField = field.frame
        let keyboardPlus = plus.frame
        plus.press(forDuration: 0.8)
        XCTAssertTrue(cancel.appears(timeout: 5))
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
        XCTAssertTrue(attachment.appears(timeout: 5), "撮影写真が送信前の添付一覧にあること")
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
