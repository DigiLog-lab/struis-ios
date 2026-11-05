import XCTest

/// 端末実行ランタイム (design §9 M2 受け入れ): コマンドの helper(hyotan)の準備と起動 → 設定画面の開発者向けに状態が出る。
/// AI は Claude だけ(App Attest で端末から直接使う)なので、接続の操作は無い。
final class DeviceRuntimeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // 前のテストや手動の操作で横向きが残っていると、入力欄や送信ボタンが画面外に出て落ちる。
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testRuntimeHelperBoots() throws {
        let app = XCUIApplication.struisUnits()
        app.launchArguments += ["-skip-onboarding"]
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "1"
        app.launch()

        let gear = app.buttons["workbook-open-settings"].firstMatch
        XCTAssertTrue(gear.appears(timeout: 20), "設定ボタンが無い")
        gear.tap()

        // 実行環境の状態: helper の準備(初回)と起動を待つ。
        let developer = app.buttons["settings-row-developer"].firstMatch
        XCTAssertTrue(developer.appears(timeout: 10))
        developer.tap()
        let boot = app.descendants(matching: .any)["settings-runtime-boot"].firstMatch
        XCTAssertTrue(boot.appears(timeout: 10))
        let deadline: Date = Date().addingTimeInterval(240)
        var runtimeText: String = ""
        while Date() < deadline {
            runtimeText = descriptionOf(app.descendants(matching: .any)["settings-runtime-boot"].firstMatch)
            if runtimeText.contains("起動済み") { break }
            if runtimeText.contains("失敗") { XCTFail("実行環境の起動に失敗: \(runtimeText)"); return }
            sleep(2)
        }
        XCTAssertTrue(runtimeText.contains("起動済み"), "helper が起動済みにならない: \(runtimeText)")
        add(attachment(named: "runtime-rows", text: runtimeText))
    }

    @MainActor
    private func descriptionOf(_ element: XCUIElement) -> String {
        guard element.exists else { return "" }
        return [element.label, element.value as? String ?? ""].joined(separator: " ")
    }

    private func attachment(named name: String, text: String) -> XCTAttachment {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
