import XCTest

/// iPhone の自分で丸付け: 答えを見て ○× を付け、× を付けた問題だけを見直しで撮る(AI はモック)。
final class TimelineSelfGradeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSelfGradeThenPhotographOnlyTheWrongOnes() throws {
        let app = UITestSupport.deviceApp(arguments: ["-skip-onboarding", "-self-grade-demo"])
        app.launch()
        func shot(_ name: String) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = name
            image.lifetime = .keepAlways
            add(image)
        }
        func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier] }

        // 1 問目: 答えを見て × を付ける。
        let answer = app.buttons["timeline-answer"]
        XCTAssertTrue(answer.appears(timeout: 30), "自分で丸付けする問題が出ない")
        shot("1-problem")
        answer.tap()
        XCTAssertTrue(element("timeline-answer-card").appears(timeout: 5), "答えが出ない")
        shot("2-revealed")
        app.buttons["timeline-self-wrong"].tap()

        // × は見直し待ちになり、やさしい版を挟まずに次の問題へ。
        let chip = app.buttons["timeline-review-chip"]
        XCTAssertTrue(chip.appears(timeout: 10), "見直し待ちのチップが出ない")
        XCTAssertEqual(chip.label, "見直し待ち 1問")
        XCTAssertTrue(answer.appears(timeout: 10), "次の問題が出ない")
        shot("3-after-wrong")

        // 2 問目: ○ を付けると、見直し待ちは増えない。
        answer.tap()
        app.buttons["timeline-self-correct"].tap()
        XCTAssertTrue(chip.appears(timeout: 5))
        XCTAssertEqual(chip.label, "見直し待ち 1問")
        shot("4-after-correct")

        // チップから見直し → 撮る → 採点。
        chip.tap()
        XCTAssertTrue(element("timeline-review-card").appears(timeout: 5), "見直しのカードが出ない")
        shot("5-review-card")
        addUIInterruptionMonitor(withDescription: "カメラの許可") { alert in
            let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["許可", "OK", "Allow"])).firstMatch
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        app.buttons["timeline-review-shoot"].tap()
        let shutter = app.buttons["chat-camera-shutter"]
        XCTAssertTrue(shutter.appears(timeout: 10), "見直しのカメラが開かない")
        if !shutter.isEnabled { app.tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15), .completed)
        XCTAssertTrue(app.staticTexts["chat-camera-counter"].label.contains("1 / 1 問目"), "撮る問題の案内が出ない")
        shot("6-camera")
        shutter.tap()
        let done = app.buttons["chat-camera-done"]
        XCTAssertTrue(done.appears(timeout: 10), "撮り終えても「見直す」が出ない")
        shot("7-camera-shot")
        done.tap()

        // 写真が最後の記録になるので、見直し待ちから外れる。
        XCTAssertTrue(chip.waitForNonExistence(timeout: 20), "撮った後も見直し待ちに残っている")
        sleep(4)
        shot("8-graded")
    }
}
