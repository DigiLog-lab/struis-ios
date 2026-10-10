import XCTest

final class ConversationExportUITests: XCTestCase {
    @MainActor
    func testCopyConversation() throws {
        let app = UITestSupport.deviceApp()
        app.launch()
        continueAfterFailure = false
        // 前のテストや手動の操作で横向きが残っていると、入力欄や送信ボタンが画面外に出て落ちる。
        XCUIDevice.shared.orientation = .portrait
        app.openQuestionSheet()
        XCTAssertTrue(app.staticTexts["写真で送ります。"].waitForExistence(timeout: 30))
        let export = app.buttons["会話を書き出す"]
        XCTAssertTrue(export.waitForExistence(timeout: 30))
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "export-chat-header"
        before.lifetime = .keepAlways
        add(before)
        export.tap()
        XCTAssertTrue(app.navigationBars["会話の書き出し"].waitForExistence(timeout: 5))
        app.buttons["コピー"].tap()
        XCTAssertTrue(app.buttons["コピーしました"].waitForExistence(timeout: 5))
        let sheet = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        sheet.name = "export-copied"
        sheet.lifetime = .keepAlways
        add(sheet)
        app.navigationBars["会話の書き出し"].buttons["閉じる"].tap()
        let field = app.textViews.matching(identifier: "chat-page").firstMatch
        XCTAssertTrue(field.exists)
        field.tap()
        field.press(forDuration: 1.2)
        let paste = app.menuItems["ペースト"].exists ? app.menuItems["ペースト"] : app.menuItems["Paste"]
        if paste.waitForExistence(timeout: 3) {
            paste.tap()
        } else {
            app.typeKey("v", modifierFlags: .command)
        }
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@", "[Struis]")).firstMatch.waitForExistence(timeout: 5), "コピーした会話を入力欄へ貼り付けられる")
        print("EXPORT_UI: header visible; sheet opened; copied; pasted text contains [Struis]")
    }
}
