import XCTest

/// 端末完結の問題集ループ (design §6.4 / §9 M4): 一枚を作る → 撮る → 判定 → マスに綴じる。
/// シミュレータ既定フィクスチャ (台帳に単元を投入) と DEBUG のモック応答 (判定・生成の
/// モデル出力だけ固定) で、Engine・台帳・画面は本番の経路を通す。
final class DeviceWorkbookUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // 前のテストや手動の操作で横向きが残っていると、入力欄や送信ボタンが画面外に出て落ちる。
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testSetGenerationCaptureAndGradingOnDevice() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-skip-onboarding"]
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launchEnvironment["STRUIS_TEST_CAMERA_IMAGE"] = UITestSupport.paperImagePath
        app.launch()
        try runLoop(app, generationTimeout: 30, gradingTimeout: 30, name: "verdict")
    }

    /// 同じループを hyotan 上の実 Codex で回す。`TEST_RUNNER_STRUIS_REAL_CODEX_AUTH` が必要。
    @MainActor
    func testSetGenerationCaptureAndGradingWithRealCodex() throws {
        let auth = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_AUTH"] ?? ""
        try XCTSkipIf(auth.isEmpty, "TEST_RUNNER_STRUIS_REAL_CODEX_AUTH が無い (実 Codex 検証は手動)")
        let app = XCUIApplication()
        app.launchArguments += ["-skip-onboarding"]
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "1"
        app.launchEnvironment["STRUIS_LEDGER"] = "persistent"
        app.launchEnvironment["STRUIS_DEBUG_CODEX_AUTH_FILE"] = auth
        let assets = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_ASSETS_DIR"] ?? ""
        try XCTSkipIf(assets.isEmpty, "TEST_RUNNER_STRUIS_REAL_CODEX_ASSETS_DIR が無い (既定単元の実AI試験には外部配信資産が必要)")
        app.launchEnvironment["STRUIS_DEVICE_ASSETS_DIR"] = assets
        app.launchEnvironment["STRUIS_TEST_CAMERA_IMAGE"] = UITestSupport.paperImagePath
        app.launch()
        try runLoop(app, generationTimeout: 300, gradingTimeout: 300, name: "verdict-real-codex")
    }

    @MainActor
    private func runLoop(_ app: XCUIApplication, generationTimeout: TimeInterval, gradingTimeout: TimeInterval, name: String) throws {

        // 段階 3 (自力例題) の小単元を開く。
        let row = app.descendants(matching: .any)["workbook-subunit-sub-1"].firstMatch
        XCTAssertTrue(row.appears(timeout: 15), "ホームに小単元の行が無い")
        row.tap()

        // 一枚を作る (生成ターン → open)。
        let request = app.descendants(matching: .any)["workbook-request-set"].firstMatch
        XCTAssertTrue(request.appears(timeout: 10), "一枚を作るボタンが無い")
        request.tap()
        let problem = app.descendants(matching: .any)["workbook-set-problem-1"].firstMatch
        XCTAssertTrue(problem.appears(timeout: generationTimeout), "生成された一枚の問題が出ない")

        // 撮る → 使う。
        let camera = app.descendants(matching: .any)["workbook-capture-button"].firstMatch
        XCTAssertTrue(camera.appears(timeout: 5))
        addUIInterruptionMonitor(withDescription: "カメラの許可") { alert in
            let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["許可", "OK", "Allow"])).firstMatch
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        camera.tap()
        let shutter = app.buttons["chat-camera-shutter"].firstMatch
        XCTAssertTrue(shutter.appears(timeout: 15), "カメラが開かない")
        if !shutter.isEnabled { app.tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15), .completed)
        shutter.tap()
        // カメラは閉じずに続けて撮れる(一括採点)。「採点する 1」で確認画面へ。
        let done = app.buttons["chat-camera-done"].firstMatch
        XCTAssertTrue(done.appears(timeout: 20), "「採点する」が出ない")
        done.tap()
        let use = app.descendants(matching: .any)["workbook-capture-use"].firstMatch
        XCTAssertTrue(use.appears(timeout: 20), "撮影確認が出ない")
        use.tap()

        // 一枚から撮ると、そのままリザルト画面が開き、判定中はそこで待つ。
        let verdict = app.descendants(matching: .any)["workbook-verdict"].firstMatch
        XCTAssertTrue(verdict.appears(timeout: 20), "リザルト画面が開かない")
        // 判定が終わると 正解数 (graded) か「整理する」(triage) が出る。失敗表示は不可。
        let score = app.descendants(matching: .any)["workbook-verdict-score"].firstMatch
        let triage = app.buttons["整理する"].firstMatch
        let deadline = Date().addingTimeInterval(gradingTimeout)
        while Date() < deadline, !score.exists, !triage.exists { sleep(1) }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(score.exists || triage.exists, "判定結果が出ない")
        XCTAssertFalse(app.staticTexts["判定できませんでした"].exists, "判定が失敗した")
    }


}
