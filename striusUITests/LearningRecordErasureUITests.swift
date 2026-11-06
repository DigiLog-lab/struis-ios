import XCTest

/// 設定の「学習記録」から、すべての学習記録を消す(#78)。確認を出し、キャンセルでは消さず、「すべて消す」で単元も会話も消える。
/// 台帳はメモリ(`STRUIS_LEDGER=memory`)に単元のフィクスチャを入れて始める。iCloud はこの環境では使わない。
final class LearningRecordErasureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEraseAllFromSettingsAsksFirstThenLeavesNoUnit() throws {
        let app = UITestSupport.deviceApp()
        app.launchEnvironment["STRUIS_LEDGER"] = "memory"
        app.launchEnvironment["STRUIS_UNIT_DELETION_UI_TEST"] = "1"
        app.launchEnvironment["STRUIS_IOS_USE_FIXTURES"] = "0"
        // フィクスチャを切るとシミュレータの認証の迂回も切れる。サインイン済みとして始める。
        app.launchEnvironment["STRUIS_DEV_AUTH_BYPASS"] = "1"
        app.launch()

        let card = app.buttons["workbook-unit-card-unit-1"].firstMatch
        XCTAssertTrue(card.appears(timeout: 20), "単元のフィクスチャが無い")
        app.buttons["workbook-open-settings"].firstMatch.tap()
        let learningRecord = app.buttons["settings-row-learning-record"].firstMatch
        XCTAssertTrue(learningRecord.appears(timeout: 10))
        learningRecord.tap()

        let erase = app.buttons["settings-erase-all"].firstMatch
        XCTAssertTrue(erase.appears(timeout: 10), "すべての学習記録を消すボタンが無い")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "お試しの数、年齢の確認と同意の記録は消えません")).firstMatch.exists,
                      "消えないものの説明が無い")
        record(app, "学習記録の設定")

        // 確認を出す。キャンセルでは消さない。
        erase.tap()
        let alert = app.alerts["すべての学習記録を消しますか？"]
        XCTAssertTrue(alert.appears(timeout: 5), "消す前の確認が出ない")
        XCTAssertTrue(alert.staticTexts.element(matching: NSPredicate(format: "label CONTAINS %@", "同じ Apple ID の別の端末からも消えます")).exists)
        record(app, "消す前の確認")
        alert.buttons["キャンセル"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["settings-erase-message"].exists, "キャンセルで消えた")

        erase.tap()
        XCTAssertTrue(alert.appears(timeout: 5))
        alert.buttons["すべて消す"].tap()
        let message = app.descendants(matching: .any)["settings-erase-message"].firstMatch
        XCTAssertTrue(message.appears(timeout: 30), "消した結果が出ない")
        XCTAssertTrue(message.label.contains("学習記録を消しました"), message.label)
        record(app, "消した後")

        // 設定を閉じると、単元が無い(使い始めの案内)。
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.buttons["単元を作る"].firstMatch.appears(timeout: 15), "消した後に使い始めの画面にならない")
        XCTAssertFalse(card.exists, "単元が残っている")
        record(app, "消した後の単元")
    }

    @MainActor
    private func record(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
