import XCTest

final class LearningProgressUITests: XCTestCase {
    @MainActor
    func testInspectActualReplyProgress() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURL = environment["STRUIS_E2E_API_BASE_URL"],
              let token = environment["STRUIS_E2E_ACCESS_TOKEN"],
              let messageID = environment["STRUIS_E2E_PROGRESS_MESSAGE_ID"] else {
            throw XCTSkip("実バックエンドURL・検証用認証・対象返信IDが必要です")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-skip-onboarding", "-reset-auth"]
        app.launchEnvironment["STRUIS_IOS_USE_FIXTURES"] = "0"
        app.launchEnvironment["STRUIS_API_BASE_URL"] = baseURL
        app.launchEnvironment["STRUIS_DEV_ACCESS_TOKEN"] = token
        app.launch()
        let message = app.descendants(matching: .any).matching(identifier: "assistant-message-\(messageID.uppercased())").firstMatch
        if !message.waitForExistence(timeout: 12) {
            app.buttons["履歴"].tap()
            let title = environment["STRUIS_E2E_PROGRESS_THREAD_TITLE"] ?? "学習進行の実経路検証"
            let thread = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(thread.waitForExistence(timeout: 20))
            thread.tap()
        }
        XCTAssertTrue(message.waitForExistence(timeout: 30))
        attach("01-通常チャット")
        message.press(forDuration: 1.2)
        let inspect = app.buttons["進行を確認"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 5))
        attach("02-長押しメニュー")
        inspect.tap()
        XCTAssertTrue(app.navigationBars["学習の進行"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["今の取り組み"].waitForExistence(timeout: 15))
        attach("03-進行の概要")
        let parents = app.buttons["親ゴール"]
        if !parents.isHittable { app.swipeUp() }
        XCTAssertTrue(parents.waitForExistence(timeout: 5))
        parents.tap()
        attach("04-親ゴール")
        let trials = app.buttons["試行履歴"]
        if !trials.isHittable { app.swipeUp() }
        trials.tap()
        attach("05-試行履歴")
        let copy = app.buttons["learning-progress-copy"]
        for _ in 0..<5 where !copy.isHittable { app.swipeUp() }
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(app.buttons["コピーしました"].waitForExistence(timeout: 5))
        attach("06-検証情報コピー")
        app.buttons["閉じる"].tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        print("LEARNING_PROGRESS_UI: 実返信の長押し、概要、親ゴール、試行履歴、コピー、チャット復帰を確認")
    }

    @MainActor private func attach(_ name: String) {
        let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        item.name = name
        item.lifetime = .keepAlways
        add(item)
    }
}
