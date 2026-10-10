import XCTest

/// 一枚を何枚の写真に分けて撮っても、一枚として採点する(配信Skillの説明)。
/// シミュレータ既定フィクスチャ(台帳は起動ごとに空、ターンはモック)。モックの判定は 1 枚の写真に一枚の問題が
/// 2 問ずつ順に写っている扱い(`STRUIS_MOCK_GRADING_PER_PHOTO=2`)。演習の一枚は 5 問で、最後の 1 問だけ誤答。
final class WorkbookSplitGradingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-skip-onboarding"]
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_TEST_CAMERA_IMAGE"] = UITestSupport.paperImagePath
        app.launchEnvironment["STRUIS_MOCK_GRADING_PER_PHOTO"] = "2"
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func waitLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 30) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func screenSummary(_ app: XCUIApplication) -> String {
        let lines = app.debugDescription.split(separator: "\n")
            .filter { $0.contains("label:") || $0.contains("identifier: 'workbook-") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return String(lines.joined(separator: " | ").prefix(3000))
    }

    /// 類題をクリアして、演習の一枚(5 問)を開く。
    @MainActor
    private func openPracticeSet(_ app: XCUIApplication) {
        let row = element(app, "workbook-subunit-sub-1")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let request = element(app, "workbook-request-set")
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        request.tap()
        XCTAssertTrue(element(app, "workbook-set-problem-1").waitForExistence(timeout: 20))
        tapCamera(app)
        shoot(app)
        let status = element(app, "workbook-result-status")
        XCTAssertTrue(waitLabel(status, "クリア"), "類題がクリアにならない: \(screenSummary(app))")
        element(app, "workbook-result-practice").tap()
        XCTAssertTrue(element(app, "workbook-set-problem-5").waitForExistence(timeout: 20), "演習の一枚が開かない")
    }

    @MainActor
    private func tapCamera(_ app: XCUIApplication) {
        let camera = element(app, "workbook-capture-button")
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        camera.tap()
    }

    /// カメラが開いている状態から、撮って「使う」。
    @MainActor
    private func shoot(_ app: XCUIApplication) {
        let shutter = app.buttons["chat-camera-shutter"].firstMatch
        XCTAssertTrue(shutter.waitForExistence(timeout: 15), "カメラが開かない: \(screenSummary(app))")
        if !shutter.isEnabled { app.tap() }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15)
        shutter.tap()
        let use = element(app, "workbook-capture-use")
        XCTAssertTrue(use.waitForExistence(timeout: 20), "撮影確認が出ない: \(screenSummary(app))")
        use.tap()
    }

    @MainActor
    func testPhotosAddUpToOneSetResult() throws {
        let app = launch()
        openPracticeSet(app)

        // 1 枚目(1・2): 途中のリザルト。一枚は締めず、撮り足すか結果を出すかを聞く。
        tapCamera(app)
        shoot(app)
        let title = element(app, "workbook-set-progress-title")
        XCTAssertTrue(waitLabel(title, "3〜5 が見つかりませんでした"), "途中のリザルトにならない: \(screenSummary(app))")
        XCTAssertTrue(element(app, "workbook-result-capture-more").exists, "「撮り足す」が無い")
        XCTAssertEqual(element(app, "workbook-result-close-set").label, "見つかった 2 問で結果を出す")
        XCTAssertFalse(element(app, "workbook-verdict-score").exists, "途中の答案に正解数を出している")
        XCTAssertFalse(element(app, "workbook-result-retry").exists, "途中の答案で「やり直す」を出している")
        attach(app, "1-partial-first-photo")

        // 撮り足す(3・4): 同じ一枚を文脈にしてカメラが開く。まだ 5 が残る。
        element(app, "workbook-result-capture-more").tap()
        XCTAssertTrue(app.buttons["chat-camera-shutter"].firstMatch.waitForExistence(timeout: 15), "「撮り足す」でカメラが開かない")
        attach(app, "1b-capture-more-camera")
        shoot(app)
        XCTAssertTrue(waitLabel(element(app, "workbook-set-progress-title"), "5 が見つかりませんでした"), "2 枚目の後の途中のリザルトにならない: \(screenSummary(app))")
        XCTAssertEqual(element(app, "workbook-result-close-set").label, "見つかった 4 問で結果を出す")
        attach(app, "2-partial-second-photo")

        // 撮り足す(5、誤答): 全問そろって一枚の結果。4 / 5 で直近 5 問の 8 割に届く。
        element(app, "workbook-result-capture-more").tap()
        shoot(app)
        let status = element(app, "workbook-result-status")
        XCTAssertTrue(waitLabel(status, "小単元 合格"), "全問そろっても一枚の結果にならない: \(screenSummary(app))")
        XCTAssertEqual(element(app, "workbook-verdict-score").label, "4 / 5", "一枚の集計になっていない")
        XCTAssertTrue(element(app, "workbook-set-progress").exists, "一枚のマスが無い")
        XCTAssertFalse(element(app, "workbook-set-progress-missing").exists)
        attach(app, "3-set-complete")
    }

    @MainActor
    func testCloseSetWithFoundProblems() throws {
        let app = launch()
        openPracticeSet(app)
        tapCamera(app)
        shoot(app)
        XCTAssertTrue(waitLabel(element(app, "workbook-set-progress-title"), "3〜5 が見つかりませんでした"), "途中のリザルトにならない: \(screenSummary(app))")

        element(app, "workbook-result-close-set").tap()
        let missing = element(app, "workbook-set-progress-missing")
        XCTAssertTrue(waitLabel(missing, "3〜5 は未提出", timeout: 10), "締めた後に未提出の番号が出ない: \(screenSummary(app))")
        XCTAssertEqual(element(app, "workbook-verdict-score").label, "2 / 2")
        XCTAssertTrue(element(app, "workbook-result-retry").exists, "締めた後に次の行動が出ない")
        XCTAssertFalse(element(app, "workbook-result-capture-more").exists)
        attach(app, "4-closed-with-missing")

        // 締めた後に一枚の画面から残りを撮る(3・4、次に 5): 一枚の集計に足し直し、窓が届けば合格(R4)。
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "workbook-set-problem-5").waitForExistence(timeout: 10), "一枚の画面に戻れない: \(screenSummary(app))")
        attach(app, "5-set-after-close")
        tapCamera(app)
        shoot(app)
        XCTAssertTrue(waitLabel(element(app, "workbook-set-progress-missing"), "5 は未提出"), "締めた後の答案が一枚に足されない: \(screenSummary(app))")
        XCTAssertEqual(element(app, "workbook-verdict-score").label, "4 / 4")
        XCTAssertFalse(element(app, "workbook-set-progress-title").exists, "締めた後の答案を途中にしている")
        attach(app, "6-late-photo-added")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "workbook-set-problem-5").waitForExistence(timeout: 10))
        tapCamera(app)
        shoot(app)
        XCTAssertTrue(waitLabel(element(app, "workbook-result-status"), "小単元 合格"), "締めた後に残りを撮っても合格にならない: \(screenSummary(app))")
        XCTAssertEqual(element(app, "workbook-verdict-score").label, "4 / 5")
        attach(app, "7-late-photo-passed")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
