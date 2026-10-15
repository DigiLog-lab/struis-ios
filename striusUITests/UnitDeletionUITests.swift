import XCTest

final class UnitDeletionUITests: XCTestCase {
    @MainActor
    func testLongPressCancelDeleteLastUnitAndEmptyState() throws {
        let app = UITestSupport.deviceApp()
        app.launchEnvironment["STRUIS_LEDGER"] = "memory"
        app.launchEnvironment["STRUIS_UNIT_DELETION_UI_TEST"] = "1"
        app.launchEnvironment["STRUIS_IOS_USE_FIXTURES"] = "0"
        // フィクスチャを切ると認証の省略も切れる(STRUIS_AUTH_REQUIRED=YES のビルドではログイン画面で止まる)。
        app.launchEnvironment["STRUIS_DEV_AUTH_BYPASS"] = "1"
        app.launch()
        let card = app.buttons["workbook-unit-card-unit-1"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
        XCTAssertTrue(app.navigationBars["二次関数"].waitForExistence(timeout: 5), "短いタップで単元が開く")
        app.navigationBars.buttons["単元"].tap()
        card.press(forDuration: 1)
        let delete = app.buttons["削除"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let alert = app.alerts["単元を削除しますか？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.element(matching: NSPredicate(format: "label CONTAINS %@", "二次関数")).exists)
        record(app, "削除確認")
        alert.buttons["キャンセル"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.press(forDuration: 1)
        app.buttons["削除"].firstMatch.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["削除"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: card)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(app.buttons["単元を作る"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workbook-subunit-sub-1"].exists)
        record(app, "最後の単元を削除")
    }

    @MainActor
    func testLargeTextConfirmationAndCancel() throws {
        let app = UITestSupport.deviceApp(arguments: ["-skip-onboarding", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.launchEnvironment["STRUIS_LEDGER"] = "memory"
        app.launchEnvironment["STRUIS_UNIT_DELETION_UI_TEST"] = "1"
        app.launchEnvironment["STRUIS_IOS_USE_FIXTURES"] = "0"
        // フィクスチャを切ると認証の省略も切れる(STRUIS_AUTH_REQUIRED=YES のビルドではログイン画面で止まる)。
        app.launchEnvironment["STRUIS_DEV_AUTH_BYPASS"] = "1"
        app.launch()
        let card = app.buttons["workbook-unit-card-unit-1"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        for _ in 0..<8 where !card.isHittable { app.swipeUp() }
        XCTAssertTrue(card.isHittable)
        card.press(forDuration: 1)
        app.buttons["削除"].firstMatch.tap()
        let alert = app.alerts["単元を削除しますか？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["キャンセル"].isHittable)
        XCTAssertTrue(alert.buttons["削除"].isHittable)
        record(app, "大きい文字の削除確認")
        alert.buttons["キャンセル"].tap()
        XCTAssertTrue(card.exists)
    }

    @MainActor
    private func record(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
