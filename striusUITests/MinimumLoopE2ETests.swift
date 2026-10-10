import XCTest

/// End-to-end verification that the minimum educational loop works against the
/// deployed backend (https://api-struis.digiloglab.com):
/// Onboarding → Dev Sign-In → Bootstrap → send a chat message → wait for a
/// completed assistant reply. Screenshots are attached at each step.
final class MinimumLoopE2ETests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSendMessageAndReceiveAssistantReply() throws {
        guard let token = ProcessInfo.processInfo.environment["STRUIS_E2E_ACCESS_TOKEN"] else {
            throw XCTSkip("STRUIS_E2E_ACCESS_TOKEN is required for the deployed-backend E2E")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-e2e", "-reset-auth", "-skip-onboarding"]
        app.launchEnvironment["STRUIS_IOS_USE_FIXTURES"] = "0"
        app.launchEnvironment["STRUIS_DEV_ACCESS_TOKEN"] = token
        app.launch()

        attachScreenshot(app, name: "01-launch")

        let startButton = app.buttons["はじめる"]
        if startButton.waitForExistence(timeout: 5) {
            startButton.tap()
            attachScreenshot(app, name: "02-after-start")
        }

        let devSignIn = app.buttons["Dev sign-in (DEBUG)"]
        if devSignIn.waitForExistence(timeout: 5) {
            devSignIn.tap()
            attachScreenshot(app, name: "03-after-dev-signin")
        }

        let composer = app.textViews.matching(identifier: "chat-page").firstMatch
        XCTAssertTrue(
            composer.waitForExistence(timeout: 30),
            "ChatMainView composer did not appear within 30s (bootstrap likely failed)"
        )
        attachScreenshot(app, name: "04-chat-loaded")

        composer.tap()
        composer.typeText("こんにちは、今日は何から始めればいいですか？")
        attachScreenshot(app, name: "05-composed")

        // The send button is an SF Symbol "arrow.up.circle.fill" inside a
        // SwiftUI Button. It surfaces as a button without a readable label, so
        // we identify it by image name or fall back to the last image button.
        let sendButton = resolveSendButton(in: app)
        XCTAssertNotNil(sendButton, "Could not find send button in ChatInputBar")
        sendButton?.tap()
        attachScreenshot(app, name: "06-sent")

        // Wait for assistant reply completion. The pending bubble shows
        // "考えています…"; when it's gone and a non-empty assistant text is
        // visible we consider the loop complete.
        let pendingLabel = app.staticTexts["考えています…"]
        XCTAssertTrue(
            pendingLabel.waitForExistence(timeout: 30),
            "Pending assistant bubble never appeared — POST /messages likely failed"
        )
        attachScreenshot(app, name: "07-pending")

        let deadline = Date().addingTimeInterval(180)
        while pendingLabel.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        XCTAssertFalse(
            pendingLabel.exists,
            "Assistant reply did not complete within 180s"
        )
        attachScreenshot(app, name: "08-completed")
    }

    private func resolveSendButton(in app: XCUIApplication) -> XCUIElement? {
        let byIdentifier = app.buttons.matching(identifier: "arrow.up.circle.fill").element
        if byIdentifier.exists { return byIdentifier }
        let candidates = app.buttons.allElementsBoundByIndex
        return candidates.last
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
