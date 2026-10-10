//
//  striusUITests.swift
//  striusUITests
//
//  Created by 宮氏朋愛 on 2026/04/17.
//

import XCTest

final class striusUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    /// 質問の会話は 1 ページだけ。左右にスワイプしても、別のページ(旧・分岐や答案のページ)へ動かない。
    @MainActor
    func testHorizontalSwipesKeepTheSingleChatPage() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-skip-onboarding")
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launch()
        app.openQuestionSheet()

        let chatPage = app.scrollViews["chat-page"]
        XCTAssertTrue(chatPage.waitForExistence(timeout: 10))
        let composer = app.textViews.matching(identifier: "chat-page").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let before = composer.frame

        chatPage.swipeRight()
        chatPage.swipeLeft()
        let start = chatPage.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.75))
        let end = chatPage.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)

        XCTAssertTrue(composer.isHittable)
        XCTAssertEqual(composer.frame.minX, before.minX, accuracy: 1, "入力欄が横に動いた")
        XCTAssertFalse(app.scrollViews["branch-page"].exists)
        XCTAssertFalse(app.scrollViews["answer-attempt-page"].exists)
        attachScreenshot(app, name: "chat-page-after-horizontal-swipes")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
