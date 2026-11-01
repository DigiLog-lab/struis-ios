import XCTest

/// 端末実行ランタイム (design §9 M2 受け入れ): 同梱 rootfs の展開 → hyotan 起動 →
/// codex app-server の initialize → 設定画面に状態が出る → デバイスコードログインの開始。
/// ChatGPT へのログイン完了は本人操作なので、コード取得（またはネットワーク到達不可の明示）までを検証する。
final class DeviceRuntimeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // 前のテストや手動の操作で横向きが残っていると、入力欄や送信ボタンが画面外に出て落ちる。
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testRuntimeBootsAndDeviceCodeLoginStarts() throws {
        let app = XCUIApplication.struisUnits()
        // ChatGPT(Codex)の入口は選択肢から外した(#40)。検証用の起動引数でだけ出す。
        app.launchArguments += ["-skip-onboarding", "-show-codex-settings"]
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "1"
        app.launch()

        let gear = app.buttons["workbook-open-settings"].firstMatch
        XCTAssertTrue(gear.appears(timeout: 20), "設定ボタンが無い")
        gear.tap()

        // 実行環境の状態: rootfs の展開 (初回) と起動、app-server の initialize を待つ。
        let advanced = app.buttons["settings-row-advanced"].firstMatch
        XCTAssertTrue(advanced.appears(timeout: 10))
        advanced.tap()
        let appServer = app.staticTexts["settings-runtime-appserver"].firstMatch
        XCTAssertTrue(appServer.appears(timeout: 10))
        let running = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "実行中", "実行中")
        let deadline = Date().addingTimeInterval(240)
        var runtimeText = ""
        while Date() < deadline {
            runtimeText = descriptionOf(app.descendants(matching: .any)["settings-runtime-appserver"].firstMatch)
                + " | " + descriptionOf(app.descendants(matching: .any)["settings-runtime-boot"].firstMatch)
            if runtimeText.contains("実行中") { break }
            if runtimeText.contains("失敗") { XCTFail("実行環境の起動に失敗: \(runtimeText)"); return }
            sleep(2)
        }
        XCTAssertTrue(runtimeText.contains("実行中"), "app-server が実行中にならない: \(runtimeText)")
        XCTAssertTrue(runtimeText.contains("起動済み"), "Linux が起動済みにならない: \(runtimeText)")
        _ = running
        add(attachment(named: "runtime-rows", text: runtimeText))
        app.navigationBars.buttons.firstMatch.tap()

        // ChatGPT / Codex: デバイスコードログインを開始する。
        let codexRow = app.buttons["settings-row-codex"].firstMatch
        XCTAssertTrue(codexRow.appears(timeout: 10))
        codexRow.tap()
        let connect = app.buttons["settings-codex-connect"].firstMatch
        XCTAssertTrue(connect.appears(timeout: 20), "接続ボタンが無い")
        connect.tap()

        let code = app.staticTexts["settings-codex-user-code"].firstMatch
        let error = app.staticTexts["settings-codex-error"].firstMatch
        let loginDeadline = Date().addingTimeInterval(90)
        while Date() < loginDeadline, !code.exists, !error.exists { sleep(1) }
        if code.exists {
            let value = code.label
            XCTAssertFalse(value.isEmpty)
            add(attachment(named: "device-code", text: "user code obtained (\(value.count) chars)"))
        } else if error.exists {
            // ネットワーク到達不可はこのテストの失敗にしない。app-server 経由でエラーが学習者向け文言で出たことを記録する。
            add(attachment(named: "login-error", text: error.label))
            XCTAssertFalse(error.label.isEmpty)
        } else {
            XCTFail("接続の結果が 90 秒以内に出ない")
        }
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
