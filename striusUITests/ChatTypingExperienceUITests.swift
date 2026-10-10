import XCTest

final class ChatTypingExperienceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testJapaneseMultilineAndSend() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_TYPING_UI_TEST"] == "1",
                          "ローカル検証サーバーを使う入力UIテスト")
        let app = XCUIApplication()
        app.launchArguments = ["-skip-onboarding"]
        app.launchEnvironment = [
            "STRUIS_API_BASE_URL": "http://127.0.0.1:18765",
            "STRUIS_IOS_USE_FIXTURES": "0",
            "STRUIS_DEV_ACCESS_TOKEN": "local-typing-verification-token"
        ]
        app.launch()
        let field = app.textViews.matching(identifier: "chat-page").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["どこまで分かっているか、途中の考え方も書いてみてください。"].waitForExistence(timeout: 20))
        event("入力欄をタップ", field)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        print("TYPING_PHASE \(Date().timeIntervalSince1970) | 日本語を入力")
        let first = "平方完成の途中で迷いました。"
        field.typeText(first)
        XCTAssertEqual(field.value as? String, first)
        capture("japanese-input")
        Thread.sleep(forTimeInterval: 0.7)
        print("TYPING_PHASE \(Date().timeIntervalSince1970) | 改行して続ける")
        field.typeText("\n")
        let second = "どこで符号が変わるのか教えてください。"
        field.typeText(second)
        XCTAssertEqual(field.value as? String, first + "\n" + second)
        capture("japanese-newline")
        Thread.sleep(forTimeInterval: 0.7)
        print("TYPING_PHASE \(Date().timeIntervalSince1970) | 長文を入力")
        let long = "\n途中式も一つずつ確かめたいです。自分では同じ計算をしているつもりですが、答えが合いません。"
        field.typeText(long)
        let expected = first + "\n" + second + long
        XCTAssertEqual(field.value as? String, expected)
        XCTAssertTrue(field.frame.height < 200)
        capture("japanese-long")
        Thread.sleep(forTimeInterval: 0.7)
        event("入力中のガラスに触れる", field)
        field.tap()
        Thread.sleep(forTimeInterval: 0.8)
        let send = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "送信", "chat-page")).firstMatch
        XCTAssertTrue(send.isHittable)
        event("送信ボタンをタップ", send)
        send.press(forDuration: 0.15)
        XCTAssertTrue(app.staticTexts[expected].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["送信を受け付けました。（録画用の検証応答）"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(field.value as? String, "")
        capture("japanese-sent")
        print("TYPING_PHASE \(Date().timeIntervalSince1970) | 送信完了")
    }

    @MainActor
    func testJapaneseCandidateSelection() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_TYPING_UI_TEST"] == "1")
        let app = XCUIApplication()
        app.launchArguments = ["-skip-onboarding"]
        app.launchEnvironment = ["STRUIS_API_BASE_URL": "http://127.0.0.1:18765", "STRUIS_IOS_USE_FIXTURES": "0", "STRUIS_DEV_ACCESS_TOKEN": "local-typing-verification-token"]
        app.launch()
        let field = app.textViews.matching(identifier: "chat-page").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["どこまで分かっているか、途中の考え方も書いてみてください。"].waitForExistence(timeout: 20))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText(" ")
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        app.buttons["Next keyboard"].press(forDuration: 1)
        app.cells["日本語ローマ字"].tap()
        field.typeText(" ")
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        for letter in ["k", "a", "n", "j", "i"] { app.keys[letter].tap() }
        XCTAssertEqual(field.value as? String, "かんじ")
        capture("ime-composing")
        app.cells["感じ"].tap()
        XCTAssertEqual(field.value as? String, "感じ")
        capture("ime-committed")
        app.buttons["Return"].tap()
        XCTAssertEqual(field.value as? String, "感じ\n")
        capture("ime-keyboard")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        settings.buttons["com.apple.settings.accessibility"].tap()
        settings.buttons["MOTION_TITLE"].tap()
        let reduced = settings.switches["REDUCE_MOTION"]
        if reduced.value as? String != "1" { reduced.switches.firstMatch.tap() }
        XCTAssertTrue(reduced.waitForExistence(timeout: 3))
        XCTAssertEqual(reduced.value as? String, "1")
        capture("reduce-motion-on")
        app.activate()
        field.tap()
        field.typeText("確認")
        XCTAssertEqual(field.value as? String, "感じ\n確認")
        capture("reduce-motion-composer")
        let send = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "送信", "chat-page")).firstMatch
        send.press(forDuration: 0.15)
        XCTAssertTrue(app.staticTexts["感じ\n確認"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "")
        capture("reduce-motion-sent")
        settings.activate()
        Thread.sleep(forTimeInterval: 0.7)
        reduced.switches.firstMatch.tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: reduced)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed)
        capture("reduce-motion-restored")
        capture("settings-start")
    }

    @MainActor private func event(_ label: String, _ element: XCUIElement) {
        let rect = element.frame
        print("TYPING_EVENT \(Date().timeIntervalSince1970) | \(label) | \(rect.midX) | \(rect.midY)")
    }
    @MainActor private func capture(_ name: String) {
        let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        item.name = name
        item.lifetime = .keepAlways
        add(item)
    }
}
