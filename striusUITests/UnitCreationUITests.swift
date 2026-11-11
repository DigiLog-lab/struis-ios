import XCTest

/// ホームの「単元を作る」(#132): 会話ではなく、選んで計画を作り、「はじめる」で作った単元を開く。AI はモック。
/// 画面の写真は持ち主に見せるためのもの(`STRUIS_PROBE_DIR` があればそこにも残す)。
final class UnitCreationUITests: XCTestCase {
    @MainActor
    private func app(grade: String) -> XCUIApplication {
        let app = UITestSupport.deviceApp()
        app.launchEnvironment["STRUIS_LEDGER"] = "memory"
        app.launchEnvironment["STRUIS_IOS_USE_FIXTURES"] = "0"
        // フィクスチャを切るとシミュレータの認証の迂回も切れるので、迂回だけを明示する。
        app.launchEnvironment["STRUIS_DEV_AUTH_BYPASS"] = "1"
        app.launchEnvironment["STRUIS_PLAN"] = "light"
        app.launchEnvironment["STRUIS_USAGE_PERCENT"] = "0"
        app.launchEnvironment["STRUIS_ONBOARDING_GRADE"] = grade
        return app
    }

    @MainActor
    func testChoosingAUnitAndDeadlineCreatesTheUnitAndOpensIt() throws {
        let app = app(grade: "高1")
        app.launch()
        let create = app.buttons["workbook-create-unit"].firstMatch
        XCTAssertTrue(create.appears(timeout: 30), "単元を作るボタンが無い")
        create.tap()

        let range = app.buttons["onboarding-intent-range"].firstMatch
        XCTAssertTrue(range.appears(timeout: 10), "「ここから何をしますか」が出ない(会話が開いている)")
        UITestSupport.saveProbe(app, name: "unit-creation-1-intent")
        range.tap()

        let unit = app.buttons["unit-creation-unit-二次関数"].firstMatch
        XCTAssertTrue(unit.appears(timeout: 10))
        XCTAssertTrue(app.buttons["unit-creation-grade-中3"].exists && app.buttons["unit-creation-grade-高2"].exists, "前後の学年を選べない")
        unit.tap()
        app.buttons["unit-creation-until-休みが終わるまで"].firstMatch.tap()
        UITestSupport.saveProbe(app, name: "unit-creation-2-unit")
        app.buttons["unit-creation-plan"].firstMatch.tap()

        let start = app.buttons["onboarding-plan-start"].firstMatch
        XCTAssertTrue(start.appears(timeout: 60), "計画が出ない")
        let deadline = app.buttons["onboarding-plan-deadline"].firstMatch
        XCTAssertTrue(deadline.exists, "期限のボタンが無い")
        XCTAssertTrue(deadline.label.hasSuffix("日まで"), deadline.label)
        UITestSupport.saveProbe(app, name: "unit-creation-3-plan")
        deadline.tap()
        let done = app.buttons["完了"].firstMatch
        XCTAssertTrue(done.appears(timeout: 5), "日付を直す画面が出ない")
        UITestSupport.saveProbe(app, name: "unit-creation-4-deadline")
        done.tap()

        XCTAssertTrue(start.appears(timeout: 5))
        start.tap()
        XCTAssertTrue(app.navigationBars["二次関数"].appears(timeout: 20), "作った単元が開かない")
        XCTAssertFalse(app.descendants(matching: .any)["unit-creation"].exists, "単元を作る画面が閉じない")
        UITestSupport.saveProbe(app, name: "unit-creation-5-unit")
    }
}
