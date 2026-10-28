import XCTest

final class ChatPhysicalImageSendUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPhysicalCameraImmediateSend() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_PHYSICAL_CAMERA_TEST"] == "1",
                          "実機の撮影・本番送信を明示的に許可した検証でのみ実行")
        let app = XCUIApplication.struisUnits()
        app.launchArguments = ["-skip-onboarding"]
        app.launchEnvironment["OS_ACTIVITY_DT_MODE"] = "YES"
        app.launch()
        let plus = app.buttons["添付"].firstMatch
        guard plus.appears(timeout: 30) else {
            capture("chat-unavailable")
            XCTFail("実機の認証済みチャットへ到達できません")
            return
        }
        app.buttons["履歴"].firstMatch.tap()
        let previousThread = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(previousThread.appears(timeout: 10))
        previousThread.tap()
        let marker = "Upload-check-" + UUID().uuidString.prefix(8)
        let field = app.textViews.matching(identifier: "chat-page").firstMatch
        field.tap()
        field.typeText(marker)
        capture("before-camera")
        plus.press(forDuration: 0.6)
        let shutter = app.buttons["chat-camera-shutter"]
        XCTAssertTrue(shutter.appears(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15), .completed)
        capture("physical-preview")
        shutter.tap()
        let attachment = app.buttons.matching(NSPredicate(format:
            "label BEGINSWITH 'photo-' AND label ENDSWITH 'を解除'")).firstMatch
        XCTAssertTrue(attachment.appears(timeout: 15))
        let send = app.buttons.matching(NSPredicate(format:
            "label == %@ AND identifier == %@", "送信", "chat-page")).firstMatch
        let started = Date()
        send.tap()
        let error = app.staticTexts["ネットワークに接続できません"]
        let sentText = app.staticTexts[marker].firstMatch
        let result = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            error.exists || (sentText.exists && !attachment.exists && !app.activityIndicators.firstMatch.exists)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [result], timeout: 150), .completed)
        print("PHYSICAL_SEND marker=\(marker) elapsed=\(Date().timeIntervalSince(started)) error=\(error.exists) restored=\(attachment.exists)")
        capture("physical-send-result")
        XCTAssertFalse(error.exists, "撮影直後の送信で通信エラー")
        XCTAssertFalse(attachment.exists, "未送信の添付へ戻った")
        XCTAssertTrue(sentText.exists)
        // Optimistic bubbles cannot satisfy this check: relaunch discards them.
        app.terminate()
        app.launch()
        XCTAssertTrue(plus.appears(timeout: 30))
        app.buttons["履歴"].firstMatch.tap()
        let savedThread = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(savedThread.appears(timeout: 10))
        savedThread.tap()
        XCTAssertTrue(app.staticTexts[marker].appears(timeout: 20), "再起動後も送信が保存されていること")
        let savedImage = app.buttons.matching(NSPredicate(format:
            "label CONTAINS 'photo-1.jpg' AND NOT label CONTAINS 'を解除'")).firstMatch
        XCTAssertTrue(savedImage.appears(timeout: 20))
        capture("physical-send-reopened")
    }

    @MainActor private func capture(_ name: String) {
        let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        item.name = name
        item.lifetime = .keepAlways
        add(item)
    }
}
