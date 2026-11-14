import StoreKit
import StoreKitTest
import XCTest

/// 利用枠(#62): 課金(購入・プランを上げた時)すると、設定の「利用枠」のゲージが 0% に戻り、続けて使えるようになる。
/// 購入は StoreKit の設定ファイル(`Config/Struis.storekit`)で行い、確認のシートは出さずに通す。使い切った状態は DEBUG の
/// 起動の差し替え(`STRUIS_USAGE_SEED_PREFIX`・`STRUIS_USAGE_SEED_USD`)で作る。差し替えるのは、指定した期間の使用額だけで、
/// 課金で新しい期間に替わった後の使用額は実際の記録(端末の Keychain と iCloud の代わりのメモリ)を読む。
final class UsageResetUITests: XCTestCase {
    private var storeSession: SKTestSession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let configuration = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/Struis.storekit")
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.clearTransactions()
        storeSession = session
    }

    override func tearDownWithError() throws {
        storeSession?.clearTransactions()
        storeSession = nil
    }

    @MainActor
    private func launchUsageScreen(seedPrefix: String, seedUSD: Double) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-skip-onboarding"]
        app.launchEnvironment = [
            "STRUIS_DEVICE_TURNS": "mock",
            "STRUIS_DEVICE_RUNTIME": "0",
            "STRUIS_AGE_RANGE": "adult",
            "STRUIS_START_SCREEN": "usage",
            "STRUIS_USAGE_SEED_PREFIX": seedPrefix,
            "STRUIS_USAGE_SEED_USD": String(seedUSD),
        ]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["usage-settings"].firstMatch.appears(timeout: 30), "利用枠の画面が出ない")
        return app
    }

    /// 利用枠のゲージ(読み上げの文が「今週の使用量 ○%。…」)。
    @MainActor
    private func gauge(_ app: XCUIApplication, percent: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "今週の使用量 \(percent)%。")).firstMatch
    }

    /// 「プラン」の欄のプラン名(買う前は「プランなし」、無料体験中は「ライト（無料体験中・M月d日まで）」)。
    @MainActor
    private func planName(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "usage-plan-name", label)).firstMatch
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 15) {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.appears(timeout: timeout), "\(identifier) が出ない")
        element.tapWhenSettled()
    }

    /// App Store の購入の確認(StoreKit Testing のシート)が出た時だけ押す。`disableDialogs` で通常は出ない。
    @MainActor
    private func confirmPurchaseSheetIfShown() {
        let storeUI = XCUIApplication(bundleIdentifier: "com.apple.StoreKitUIService")
        for label in ["Subscribe", "購読", "登録", "Confirm", "OK"] {
            let button = storeUI.buttons[label].firstMatch
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// お試しの枠を使い切った状態からライトを買うと、0% から使える。
    @MainActor
    func testBuyingAPlanAfterTheTrialRunsOutResetsTheGaugeToZero() throws {
        // お試しの枠($0.25)とカード 1 枚分を超えた $0.40 を、課金前の週(月曜 0:00 区切り)に使った状態。
        let app = launchUsageScreen(seedPrefix: "usage.week.", seedUSD: 0.40)
        XCTAssertTrue(gauge(app, percent: 100).appears(timeout: 15), "お試しの枠を使い切った状態から始まらない")
        XCTAssertTrue(planName(app, "プランなし").exists, "買う前のプラン名が「プランなし」でない")
        attach(app, "trial-exhausted")

        tap(app, "usage-change-plan")
        tap(app, "paywall-purchase", timeout: 20)
        confirmPurchaseSheetIfShown()

        XCTAssertTrue(app.descendants(matching: .any)["paywall"].firstMatch.waitForNonExistence(timeout: 30), "購入画面が閉じない")
        XCTAssertTrue(gauge(app, percent: 0).appears(timeout: 30), "購入しても 0% に戻らない")
        // 初めての購入なので、ライトの無料体験(1週間)から始まる。
        XCTAssertTrue(planName(app, "ライト（無料体験中・").appears(timeout: 10), "プランがライトの無料体験にならない")
        attach(app, "after-purchase")
    }

    /// ライトを使い切った状態からスタンダードに上げると、0% から使える。
    @MainActor
    func testUpgradingAfterThePlanRunsOutResetsTheGaugeToZero() async throws {
        let light: Transaction = try await storeSession.buyProduct(identifier: "com.digiloglab.strius.plan.light")
        // ライトの期間(取引 ID の期間)に、ライトの上限 $0.80 とカード 1 枚分を超えた $0.90 を使った状態。
        let app = launchUsageScreen(seedPrefix: "usage.period.\(light.id).", seedUSD: 0.90)
        XCTAssertTrue(gauge(app, percent: 100).appears(timeout: 30), "ライトを使い切った状態から始まらない")
        XCTAssertTrue(planName(app, "ライト（無料体験中・").appears(timeout: 10), "プランがライトの無料体験にならない")
        attach(app, "light-exhausted")

        tap(app, "usage-change-plan")
        tap(app, "paywall-plan-standard", timeout: 20)
        tap(app, "paywall-purchase")
        confirmPurchaseSheetIfShown()

        XCTAssertTrue(app.descendants(matching: .any)["paywall"].firstMatch.waitForNonExistence(timeout: 30), "購入画面が閉じない")
        XCTAssertTrue(gauge(app, percent: 0).appears(timeout: 30), "上げても 0% に戻らない")
        XCTAssertTrue(planName(app, "スタンダード").appears(timeout: 10), "プランがスタンダードにならない")
        XCTAssertEqual(planName(app, "スタンダード").label, "スタンダード", "上げた後は無料体験ではない")
        attach(app, "after-upgrade")
    }
}
