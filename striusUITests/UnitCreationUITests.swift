import XCTest

/// ホームの「単元を作る」(#132): 会話ではなく、選んで計画を作り、「はじめる」で作った単元を開く。AI はモック。
/// 画面の写真は持ち主に見せるためのもの(`STRUIS_PROBE_DIR` があればそこにも残す)。
final class UnitCreationUITests: XCTestCase {
    @MainActor
    private func app() -> XCUIApplication {
        let app = UITestSupport.deviceApp()
        app.launchEnvironment["STRUIS_LEDGER"] = "memory"
        app.launchEnvironment["STRUIS_IOS_USE_FIXTURES"] = "0"
        // フィクスチャを切るとシミュレータの認証の迂回も切れるので、迂回だけを明示する。学年は飛ばしたオンボーディングの中3。
        app.launchEnvironment["STRUIS_DEV_AUTH_BYPASS"] = "1"
        app.launchEnvironment["STRUIS_PLAN"] = "light"
        app.launchEnvironment["STRUIS_USAGE_PERCENT"] = "0"
        return app
    }

    @MainActor
    func testChoosingAUnitAndDeadlineCreatesTheUnitAndOpensIt() throws {
        let app = app()
        app.launch()
        let create = app.buttons["workbook-create-unit"].firstMatch
        XCTAssertTrue(create.appears(timeout: 30), "単元を作るボタンが無い")
        create.tap()

        let range = app.buttons["onboarding-intent-range"].firstMatch
        XCTAssertTrue(range.appears(timeout: 10), "「ここから何をしますか」が出ない(会話が開いている)")
        UITestSupport.saveProbe(app, name: "unit-creation-1-intent")
        range.tap()

        let unit = app.buttons["unit-creation-unit-二次方程式"].firstMatch
        if !unit.appears(timeout: 10) { UITestSupport.saveProbe(app, name: "unit-creation-2-missing") }
        XCTAssertTrue(unit.exists, "単元の一覧が出ない")
        XCTAssertTrue(app.buttons["unit-creation-grade-中2"].exists && app.buttons["unit-creation-grade-高1"].exists, "前後の学年を選べない")
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
        XCTAssertTrue(app.navigationBars["二次方程式"].appears(timeout: 20), "作った単元が開かない")
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.descendants(matching: .any)["unit-creation"].firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 10), .completed, "単元を作る画面が閉じない")
        UITestSupport.saveProbe(app, name: "unit-creation-5-unit")
    }

    /// 本物の Claude で、単元を作る時の計画づくり(期限の日付・すでにある単元を渡す)が計画を返すか。
    /// Dev Box で `TEST_RUNNER_STRUIS_REAL_CLAUDE_KEY_FILE` を渡した時だけ走る(費用がかかるので手動)。
    @MainActor
    func testRealClaudeMakesAPlanForTheChosenUnitAndDeadline() throws {
        let key = ProcessInfo.processInfo.environment["STRUIS_REAL_CLAUDE_KEY_FILE"] ?? ""
        try XCTSkipIf(key.isEmpty, "TEST_RUNNER_STRUIS_REAL_CLAUDE_KEY_FILE が無い (実 Claude 検証は手動)")
        let app = app()
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = nil
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "1"
        app.launchEnvironment["STRUIS_DEBUG_ANTHROPIC_KEY_FILE"] = key
        app.launch()
        let create = app.buttons["workbook-create-unit"].firstMatch
        XCTAssertTrue(create.appears(timeout: 30))
        create.tap()
        app.buttons["onboarding-intent-range"].firstMatch.tap()
        let unit = app.buttons["unit-creation-unit-平方根"].firstMatch
        XCTAssertTrue(unit.appears(timeout: 10))
        unit.tap()
        app.buttons["unit-creation-until-休みが終わるまで"].firstMatch.tap()
        app.buttons["unit-creation-plan"].firstMatch.tap()
        let start = app.buttons["onboarding-plan-start"].firstMatch
        if !start.appears(timeout: 300) { UITestSupport.saveProbe(app, name: "unit-creation-real-missing") }
        XCTAssertTrue(start.exists, "本物の Claude の計画が出ない")
        XCTAssertTrue(app.buttons["onboarding-plan-deadline"].exists, "期限の日付が無い")
        UITestSupport.saveProbe(app, name: "unit-creation-real-plan")
        start.tap()
        XCTAssertTrue(app.navigationBars.element(boundBy: 0).appears(timeout: 20))
        UITestSupport.saveProbe(app, name: "unit-creation-real-unit")
    }
}
