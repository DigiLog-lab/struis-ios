import XCTest

/// 16 歳未満の保護者の同意(#76): 規約の次に保護者の同意の画面が出て、押すだけでは進まず、右へのスワイプで同意するとお試しへ進む。
/// 文面の版が上がった時は、タイムラインに同意の画面を重ねて出し直す。運営者側への記録は送らない(`STRUIS_GUARDIAN_CONSENT_STORE=fail`)。
final class GuardianConsentUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// 16 歳未満の回答(学年・年齢の区分)を UserDefaults に残さない。続けて流れる別のテストが、前の回答の年齢で同意の画面を出さないようにする。
    @MainActor
    override func tearDownWithError() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reset-onboarding"]
        app.launch()
        app.terminate()
    }

    @MainActor
    private func launch(_ arguments: [String], environment: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launchEnvironment["STRUIS_GUARDIAN_CONSENT_STORE"] = "fail"
        app.launchEnvironment.merge(environment) { $1 }
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func text(_ app: XCUIApplication, containing value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// つまみを左端から右端まで引く。
    @MainActor
    private func swipeToConfirm(_ control: XCUIElement) {
        let start = control.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let end = control.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    @MainActor
    func testUnder16NeedsTheGuardianSwipeBeforeTheTrial() throws {
        let app = launch(["-reset-onboarding", "-workbook-empty"], environment: ["STRUIS_AGE_RANGE": "under16"])

        XCTAssertTrue(text(app, containing: "まず1問、解いてみましょう").appears(timeout: 20), "最初に学年の画面が出ない")
        app.buttons["中1"].firstMatch.tap()
        element(app, "onboarding-grade-next").tap()
        XCTAssertTrue(text(app, containing: "はじめる前に").appears(timeout: 10), "年齢の後に規約の画面が出ない")
        XCTAssertTrue(element(app, "onboarding-terms-under16").exists, "16歳未満なのに保護者の方へ渡す一文が無い")
        XCTAssertFalse(element(app, "onboarding-terms-minor").exists, "16歳未満に18歳未満の一文が出た")
        element(app, "onboarding-terms-accept").tap()

        // 「AI に送る内容」の代わりに保護者の同意。
        XCTAssertTrue(text(app, containing: "保護者の方へ").appears(timeout: 10), "規約の後に保護者の同意が出ない")
        XCTAssertFalse(text(app, containing: "AI に送る内容について").exists, "16歳未満に AI に送る内容の画面が出た")
        XCTAssertTrue(text(app, containing: "保護者の方が操作します").exists)
        XCTAssertTrue(text(app, containing: "質問、学習記録、学年を、採点と説明のために米国の Anthropic に送ります").exists, "送る内容と送り先の国が書かれていない")
        XCTAssertTrue(text(app, containing: "続けるには有料のプランが必要です").exists)
        attach(app, "guardian")

        let swipe = element(app, "onboarding-guardian-swipe")
        XCTAssertTrue(swipe.appears(timeout: 5))
        swipe.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(text(app, containing: "保護者の方へ").exists, "押しただけで進んだ")
        XCTAssertFalse(element(app, "onboarding-trial-capture").exists, "押しただけでお試しが出た")

        swipeToConfirm(swipe)
        XCTAssertTrue(element(app, "onboarding-trial-capture").appears(timeout: 10), "スワイプで同意した後にお試しへ進まない")
        attach(app, "trial")
    }

    /// 文面の版が上がった 16 歳未満(`STRUIS_GUARDIAN_CONSENT_VERSION=v0`): タイムラインに同意の画面を重ねて出し直し、スワイプで消える。
    @MainActor
    func testNewTextVersionShowsTheGuardianScreenAgainOverTheTimeline() throws {
        let app = launch(["-skip-onboarding", "-workbook-empty"], environment: ["STRUIS_GUARDIAN_CONSENT_VERSION": "v0"])
        let renewal = element(app, "guardian-consent-renewal")
        XCTAssertTrue(renewal.appears(timeout: 20), "版が上がったのに同意の画面が出ない")
        XCTAssertTrue(text(app, containing: "保護者の同意の内容を新しくしました").exists)
        XCTAssertFalse(element(app, "onboarding-back").exists, "出し直しに戻るが出た")
        attach(app, "renewal")

        swipeToConfirm(element(app, "onboarding-guardian-swipe"))
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: renewal)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "同意した後も同意の画面が残る")
        XCTAssertTrue(element(app, "timeline-screen").exists)
    }
}
