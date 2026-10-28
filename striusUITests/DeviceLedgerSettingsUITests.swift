import XCTest

/// 台帳の書き出し / 取り込み (design §4.3) と使用量報告のトグル (§8-4) を設定画面から確かめる。
/// シミュレータ既定フィクスチャで台帳に単元が入った状態から書き出す。
final class DeviceLedgerSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // 前のテストや手動の操作で横向きが残っていると、入力欄や送信ボタンが画面外に出て落ちる。
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testExportLedgerAndUsageToggleDefaultOff() throws {
        let app = XCUIApplication.struisUnits()
        app.launchArguments += ["-skip-onboarding"]
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        if let auth = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_AUTH"], !auth.isEmpty {
            app.launchEnvironment.removeValue(forKey: "STRUIS_DEVICE_TURNS")
            app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "1"
            app.launchEnvironment["STRUIS_LEDGER"] = "persistent"
            app.launchEnvironment["STRUIS_DEBUG_CODEX_AUTH_FILE"] = auth
            let assets = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_ASSETS_DIR"] ?? ""
            try XCTSkipIf(assets.isEmpty, "TEST_RUNNER_STRUIS_REAL_CODEX_ASSETS_DIR が無い (既定単元の実AI試験には外部配信資産が必要)")
            app.launchEnvironment["STRUIS_DEVICE_ASSETS_DIR"] = assets
        }
        app.launch()

        let gear = app.buttons["workbook-open-settings"].firstMatch
        XCTAssertTrue(gear.appears(timeout: 20), "設定ボタンが無い")
        gear.tap()
        let advanced = app.buttons["settings-row-advanced"].firstMatch
        XCTAssertTrue(advanced.appears(timeout: 10))
        advanced.tap()

        // 使用量報告は既定オフ。
        let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "使用量を送る")).firstMatch
        XCTAssertTrue(toggle.appears(timeout: 10), "使用量のトグルが無い")
        XCTAssertEqual(toggle.value as? String, "0", "使用量報告が既定でオンになっている")

        // 台帳に記録がある端末では取り込みはできない (空の台帳だけ)。
        let importButton = app.buttons["選ぶ"].firstMatch
        XCTAssertTrue(importButton.appears(timeout: 5))
        XCTAssertFalse(importButton.isEnabled, "記録がある台帳に取り込めてしまう")

        // 書き出す → zip ができ、共有の導線が出る。
        let export = app.buttons["書き出す"].firstMatch
        XCTAssertTrue(export.appears(timeout: 5))
        export.tap()
        let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "書き出しました")).firstMatch
        XCTAssertTrue(message.appears(timeout: 20), "書き出しの完了が出ない")
        let fileName = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "struis-ledger-")).firstMatch
        XCTAssertTrue(fileName.exists, "書き出したファイル名が出ない")
        XCTAssertTrue(fileName.label.hasSuffix(".zip"))
        XCTAssertTrue(app.buttons["保存・共有"].firstMatch.exists, "共有ボタンが無い")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "settings-ledger-export"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
