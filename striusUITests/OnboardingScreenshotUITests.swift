import StoreKitTest
import XCTest

/// オンボーディングの画面の写真(#40)。デザインの画像と目で見比べるためのもので、自動の判定は `OnboardingFlowUITests` が持つ。
/// 各画面へは DEBUG の起動の差し替え(`STRUIS_ONBOARDING_START` など)で直接行く。iPad は横向き(`XCUIDevice.shared.orientation`)。
final class OnboardingScreenshotUITests: XCTestCase {
    private var storeSession: SKTestSession?

    override func setUpWithError() throws {
        continueAfterFailure = true
        let configuration = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/Struis.storekit")
        let session = try SKTestSession(contentsOf: configuration)
        session.disableDialogs = true
        session.clearTransactions()
        storeSession = session
    }

    private struct Shot {
        let name: String
        var environment: [String: String] = [:]
        var arguments: [String] = []
        var tap: String? = nil
        var wait: String? = nil
    }

    @MainActor
    private func capture(_ shot: Shot) {
        let app = XCUIApplication()
        app.launchArguments = shot.arguments
        app.launchEnvironment = ["STRUIS_DEVICE_TURNS": "mock", "STRUIS_DEVICE_RUNTIME": "0", "STRUIS_AGE_RANGE": "adult"]
        app.launchEnvironment.merge(shot.environment) { $1 }
        app.launch()
        if let wait = shot.wait {
            _ = app.descendants(matching: .any)[wait].firstMatch.waitForExistence(timeout: 20)
        } else {
            _ = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "onboarding-")).firstMatch.waitForExistence(timeout: 20)
        }
        if let tap = shot.tap { app.buttons[tap].firstMatch.tap() }
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, shot.name)
        app.terminate()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        // 横向きの iPad では `app.screenshot()` が回って欠けるので、画面全体を撮る。
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func start(_ step: String, _ extra: [String: String] = [:]) -> [String: String] {
        ["STRUIS_ONBOARDING_START": step].merging(extra) { $1 }
    }

    private static let university = ["STRUIS_ONBOARDING_GRADE": "大学生・それ以外", "STRUIS_ONBOARDING_ROUTE": "university"]

    @MainActor
    func testIPhoneScreens() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "iPhone の画面")
        XCUIDevice.shared.orientation = .portrait
        let shots: [Shot] = [
            Shot(name: "Main", environment: start("grade"), tap: "中3"),
            Shot(name: "Birthdate", environment: start("birthdate")),
            Shot(name: "Terms", environment: start("terms", ["STRUIS_AGE_RANGE": "under18"])),
            Shot(name: "Consent", environment: start("consent")),
            Shot(name: "Try", environment: start("trial")),
            Shot(name: "Grading", environment: start("grading")),
            Shot(name: "Correct", environment: start("result")),
            Shot(name: "Wrong", environment: start("result", ["STRUIS_MOCK_TIMELINE_WRONG": "1"])),
            Shot(name: "Paywall", environment: start("paywall"), wait: "paywall"),
            Shot(name: "TrialDone", environment: start("trialDone", ["STRUIS_TRIAL_USED": "3"])),
            Shot(name: "Gauge", environment: ["STRUIS_START_SCREEN": "usage", "STRUIS_USAGE_PERCENT": "42", "STRUIS_PLAN": "light"], arguments: ["-skip-onboarding"], wait: "usage-settings"),
            Shot(name: "LimitReached", environment: ["STRUIS_START_SCREEN": "limit", "STRUIS_USAGE_PERCENT": "100", "STRUIS_PLAN": "light"], arguments: ["-skip-onboarding"], wait: "usage-limit-sheet"),
            Shot(name: "Unsupported", environment: ["STRUIS_CLAUDE_AVAILABLE": "0", "STRUIS_ONBOARDING_START": "grade"]),
            Shot(name: "Intent", environment: start("intent")),
            Shot(name: "A1Unit", environment: start("unit"), tap: "二次方程式"),
            Shot(name: "A2Test", environment: start("untilTest")),
            Shot(name: "A3Pages", environment: start("pages")),
            Shot(name: "PlanWait", environment: start("planWait", ["STRUIS_MOCK_TURN_DELAY_MS": "60000", "STRUIS_ONBOARDING_PAGES": "1"])),
            Shot(name: "A4Plan", environment: start("plan", ["STRUIS_ONBOARDING_PAGES": "1"])),
            Shot(name: "Notify", environment: start("notify")),
            Shot(name: "B1Weak", environment: start("weak"), tap: "関数 y = ax²"),
            Shot(name: "B2Plan", environment: start("plan", ["STRUIS_ONBOARDING_ROUTE": "weak"])),
            Shot(name: "CPlan", environment: start("plan", ["STRUIS_ONBOARDING_ROUTE": "unsure"])),
            Shot(name: "U1Topic", environment: start("topic", Self.university)),
            Shot(name: "U2Material", environment: start("material", Self.university)),
            Shot(name: "U3Goal", environment: start("goal", Self.university)),
            Shot(name: "U4Plan", environment: start("plan", Self.university)),
        ]
        for shot in shots { capture(shot) }
    }

    @MainActor
    func testIPadLandscapeScreens() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPad の画面")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let shots: [Shot] = [
            Shot(name: "iMain", environment: start("grade"), tap: "中3"),
            Shot(name: "iBirthdate", environment: start("birthdate")),
            Shot(name: "iTerms", environment: start("terms", ["STRUIS_AGE_RANGE": "under18"])),
            Shot(name: "iConsent", environment: start("consent")),
            Shot(name: "iPaywall", environment: start("paywall"), wait: "paywall"),
            Shot(name: "iIntent", environment: start("intent")),
            Shot(name: "iA1Unit", environment: start("unit"), tap: "二次方程式"),
            Shot(name: "iA2Test", environment: start("untilTest")),
            Shot(name: "iA3Pages", environment: start("pages")),
            Shot(name: "iA4Plan", environment: start("plan", ["STRUIS_ONBOARDING_PAGES": "1"])),
            Shot(name: "iNotify", environment: start("notify")),
            Shot(name: "iTrialDone", environment: start("trialDone", ["STRUIS_TRIAL_USED": "3"])),
            Shot(name: "iU1Topic", environment: start("topic", Self.university)),
        ]
        for shot in shots { capture(shot) }

        // お試しの1問: 何も書いていない時 → 書いた後(指で線を引く)→ 採点を待つ → 結果。
        let app = XCUIApplication()
        app.launchEnvironment = ["STRUIS_DEVICE_TURNS": "mock", "STRUIS_DEVICE_RUNTIME": "0", "STRUIS_AGE_RANGE": "adult",
                                 "STRUIS_ONBOARDING_START": "trial", "STRUIS_ONBOARDING_INK": "1", "STRUIS_MOCK_TURN_DELAY_MS": "4000"]
        app.launch()
        let send = app.buttons["onboarding-trial-send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 20))
        XCTAssertFalse(send.isEnabled, "何も書いていないのに送るが押せる")
        Thread.sleep(forTimeInterval: 1)
        attach(app, "iTry")
        let paper = app.descendants(matching: .any)["onboarding-ink"].firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 5))
        // x = 2, 3 の代わりに、何本かの線を引く。
        for (from, to) in [((0.25, 0.30), (0.55, 0.30)), ((0.25, 0.45), (0.65, 0.45)), ((0.35, 0.60), (0.55, 0.62)), ((0.30, 0.55), (0.60, 0.70))] {
            paper.coordinate(withNormalizedOffset: CGVector(dx: from.0, dy: from.1))
                .press(forDuration: 0.05, thenDragTo: paper.coordinate(withNormalizedOffset: CGVector(dx: to.0, dy: to.1)))
        }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)], timeout: 5)
        XCTAssertTrue(send.isEnabled, "書いた後も送るが押せない")
        attach(app, "iTryInk")
        send.tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding-grading"].firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, "iGrading")
        XCTAssertTrue(app.descendants(matching: .any)["onboarding-verdict"].firstMatch.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 1)
        attach(app, "iCorrect")
        app.terminate()

        // 最後の行き先: 計画の「はじめる」→ 通知 → タイムライン。
        let finish = XCUIApplication()
        finish.launchArguments = ["-workbook-empty"]
        finish.launchEnvironment = ["STRUIS_DEVICE_TURNS": "mock", "STRUIS_DEVICE_RUNTIME": "0", "STRUIS_AGE_RANGE": "adult", "STRUIS_ONBOARDING_START": "plan"]
        finish.launch()
        let begin = finish.buttons["onboarding-plan-start"].firstMatch
        XCTAssertTrue(begin.waitForExistence(timeout: 20))
        begin.tap()
        let next = finish.buttons["onboarding-notify-next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["許可", "Allow"] where springboard.buttons[title].waitForExistence(timeout: 3) { springboard.buttons[title].tap(); break }
        XCTAssertTrue(finish.descendants(matching: .any)["timeline-screen"].firstMatch.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        attach(finish, "iTimeline")
    }
}
