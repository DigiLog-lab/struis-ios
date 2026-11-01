import StoreKitTest
import XCTest

/// オンボーディング(#40): 学年 → 年齢 → 規約 → 写真の扱い → お試しの1問 → 採点 → 購入(StoreKit の設定ファイル)→
/// A ルート → 計画 → 通知 → タイムライン。再起動で繰り返さない。Simulator では Apple の年齢の確認を出せないので
/// `STRUIS_AGE_RANGE` で結果を差し替え、AI の返事は模擬(`STRUIS_DEVICE_TURNS=mock`)、カメラはテスト用紙の画像。
final class OnboardingFlowUITests: XCTestCase {
    private var storeSession: SKTestSession?

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        // 購入は StoreKit の設定ファイル(`Config/Struis.storekit`)で。確認のシートは出さずに通す。
        let configuration = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/Struis.storekit")
        let session = try SKTestSession(contentsOf: configuration)
        session.disableDialogs = true
        session.clearTransactions()
        storeSession = session
    }

    @MainActor
    private func launch(_ arguments: [String], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launchEnvironment["STRUIS_TEST_CAMERA_IMAGE"] = UITestSupport.paperImagePath
        app.launchEnvironment["STRUIS_TEST_CAPTURE_FINISH_SECONDS"] = UITestSupport.captureFinishSecondsWithoutRace
        app.launchEnvironment.merge(environment) { $1 }
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(app, identifier)
        guard target.appears(timeout: timeout) else {
            UITestSupport.saveProbe(app, name: "onboarding-missing-\(identifier)")
            XCTFail("\(identifier) が出ない", file: file, line: line)
            return
        }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: target)
        _ = XCTWaiter().wait(for: [enabled], timeout: 5)
        target.tap()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func text(_ app: XCUIApplication, containing value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    /// App Store の購入の確認(StoreKit Testing のシート)と、通知の確認(SpringBoard)を押す。
    @MainActor
    private func confirmSystemSheet(buttons titles: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let storeUI = XCUIApplication(bundleIdentifier: "com.apple.storekit.StoreKitUIService")
        while Date() < deadline {
            for host in [springboard, storeUI] {
                for title in titles {
                    let button = host.buttons[title].firstMatch
                    if button.exists, button.isHittable {
                        button.tap()
                        return true
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    @MainActor
    func testOnboardingTrialPurchaseAndPlanLeadToTimelineAndAreNotShownAgain() throws {
        var app = launch(["-reset-onboarding", "-workbook-empty"], environment: ["STRUIS_AGE_RANGE": "under18"])

        // 1 学年。年齢の結果(18歳未満)の後、規約には保護者の方への一文が出る。
        XCTAssertTrue(text(app, containing: "まず1問、解いてみましょう").appears(timeout: 20), "最初に学年の画面が出ない")
        XCTAssertFalse(element(app, "onboarding-grade-next").isEnabled, "学年を選ぶ前に次へが押せる")
        app.buttons["中3"].firstMatch.tap()
        tap(app, "onboarding-grade-next")
        XCTAssertTrue(text(app, containing: "はじめる前に").appears(timeout: 10), "年齢の後に規約の画面が出ない")
        XCTAssertTrue(element(app, "onboarding-terms-minor").exists, "18歳未満なのに保護者の方への一文が無い")
        tap(app, "onboarding-terms-accept")
        XCTAssertTrue(text(app, containing: "写真の扱いについて").appears(timeout: 10))
        tap(app, "onboarding-consent-accept")

        // お試しの1問: 撮って採点(模擬は正解)。
        XCTAssertTrue(element(app, "onboarding-trial-badge").appears(timeout: 10))
        XCTAssertTrue(element(app, "onboarding-trial-badge").label.contains("お試し 1 / 3"), "お試しの数: \(element(app, "onboarding-trial-badge").label)")
        attach(app, "trial")
        tap(app, "onboarding-trial-capture")
        let shutter = app.buttons["chat-camera-shutter"].firstMatch
        XCTAssertTrue(shutter.appears(timeout: 15), "カメラが開かない")
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15)
        shutter.tap()
        XCTAssertTrue(element(app, "onboarding-verdict").appears(timeout: 30), "採点の結果が出ない")
        XCTAssertEqual(element(app, "onboarding-verdict").label, "正解")
        XCTAssertTrue(text(app, containing: "お試しはあと2問").exists, "もう1問やるの残りの数が出ない")
        attach(app, "result")

        // 購入画面(StoreKit の設定ファイルの商品)。
        tap(app, "onboarding-continue")
        let price = element(app, "paywall-price-light")
        XCTAssertTrue(price.appears(timeout: 15), "購入画面が出ない")
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ AND value == %@", "1,480", "App Store"), object: price)
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 15), .completed, "App Store の商品が読めない: \(price.label) \(price.value ?? "")")
        attach(app, "paywall")
        tap(app, "paywall-purchase")
        if !element(app, "onboarding-intent-range").appears(timeout: 5) {
            XCTAssertTrue(confirmSystemSheet(buttons: ["Subscribe", "購読", "登録", "Confirm", "OK"], timeout: 20), "購入の確認が出ない")
            _ = confirmSystemSheet(buttons: ["OK"], timeout: 5)
        }

        // A: やる範囲が決まっている → 単元 → 次のテストまで → 問題のページ(なし)→ 計画。
        tap(app, "onboarding-intent-range", timeout: 30)
        app.buttons["二次方程式"].firstMatch.tap()
        tap(app, "onboarding-unit-next")
        app.buttons["2週間くらい"].firstMatch.tap()
        tap(app, "onboarding-material-skip")
        let start = element(app, "onboarding-plan-start")
        XCTAssertTrue(start.appears(timeout: 30), "計画が出ない")
        XCTAssertTrue(text(app, containing: "お試しの1問でできていたので短めです").exists, "計画にお試しの結果の反映が無い")
        XCTAssertTrue(text(app, containing: "テストまで 2週間くらい").exists)
        attach(app, "plan")
        start.tap()

        // 通知の前置き(ボタンは「次へ」の 1 つだけ)→ iOS の確認。
        XCTAssertTrue(text(app, containing: "勉強する時間に知らせますか").appears(timeout: 10))
        tap(app, "onboarding-notify-next")
        _ = confirmSystemSheet(buttons: ["許可", "Allow"], timeout: 10)

        // 最後の行き先はタイムライン: 1 枚目は計画の小単元 1 から、30 秒で解ける問題。
        XCTAssertTrue(element(app, "timeline-screen").appears(timeout: 20), "オンボーディングの後にタイムラインが出ない")
        let unitChip = element(app, "timeline-unit-chip")
        XCTAssertTrue(unitChip.appears(timeout: 15), "1 枚目に単元のチップが無い")
        XCTAssertTrue(unitChip.label.contains("二次方程式 1 / 6"), "単元のチップ: \(unitChip.label)")
        XCTAssertTrue(text(app, containing: "30秒").exists, "30秒のチップが無い")
        attach(app, "timeline")

        app.terminate()
        app = launch(["-workbook-empty"])
        XCTAssertTrue(element(app, "timeline-screen").appears(timeout: 20), "再起動後にタイムラインが出ない")
        XCTAssertFalse(text(app, containing: "まず1問、解いてみましょう").exists, "再起動でオンボーディングがまた出た")
    }
}
