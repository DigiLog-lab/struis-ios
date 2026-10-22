import XCTest

/// 一枚を何枚の写真に分けて撮っても、一枚として採点する(配信Skillの説明)。
/// シミュレータ既定フィクスチャ(台帳は起動ごとに空、ターンはモック)。モックの判定は 1 枚の写真に一枚の問題が
/// 2 問ずつ順に写っている扱い(`STRUIS_MOCK_GRADING_PER_PHOTO=2`)。演習の一枚は 5 問で、最後の 1 問だけ誤答。
///
/// 共通の起動と導線だけを持つ入れ物。Xcode の並列テストはクラスを単位に配るので、テストは 1 つずつ
/// 別のクラスに置く。テストの中身と判定は分ける前と同じ。
class WorkbookSplitGradingUITestCase: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    fileprivate func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-skip-onboarding"]
        // 演習の一枚を開いた状態から始める(類題に合格して演習を作るまでは台帳に本物の規則で入れる。
        // その準備が正しいことは単体テスト WorkbookPracticeFixtureTests が確かめる)。
        app.launchArguments += ["-workbook-practice-ready"]
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_TEST_CAMERA_IMAGE"] = UITestSupport.paperImagePath
        // 撮影の途中には何もしない(完了を待ってから次へ進む)ので、偽カメラの完了までの間は短くする。
        app.launchEnvironment["STRUIS_TEST_CAPTURE_FINISH_SECONDS"] = UITestSupport.captureFinishSecondsWithoutRace
        app.launchEnvironment["STRUIS_MOCK_GRADING_PER_PHOTO"] = "2"
        app.launch()
        return app
    }

    @MainActor
    fileprivate func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    fileprivate func waitLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 30) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)], timeout: timeout) == .completed
    }

    @MainActor
    fileprivate func screenSummary(_ app: XCUIApplication) -> String {
        let lines = app.debugDescription.split(separator: "\n")
            .filter { $0.contains("label:") || $0.contains("identifier: 'workbook-") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return String(lines.joined(separator: " | ").prefix(3000))
    }

    /// 準備済みの演習の一枚(5 問)を開く。
    @MainActor
    fileprivate func openPracticeSet(_ app: XCUIApplication) {
        let row = element(app, "workbook-subunit-sub-1")
        XCTAssertTrue(row.appears(timeout: 15))
        row.tap()
        let open = element(app, "workbook-open-set")
        XCTAssertTrue(open.appears(timeout: 15), "準備した演習の一枚が無い")
        open.tap()
        XCTAssertTrue(element(app, "workbook-set-problem-5").appears(timeout: 20), "演習の一枚が開かない")
    }

    @MainActor
    fileprivate func tapCamera(_ app: XCUIApplication) {
        let camera = element(app, "workbook-capture-button")
        XCTAssertTrue(camera.appears(timeout: 5))
        camera.tap()
    }

    /// カメラが開いている状態から、撮って「使う」。
    @MainActor
    fileprivate func shoot(_ app: XCUIApplication) {
        let shutter = app.buttons["chat-camera-shutter"].firstMatch
        XCTAssertTrue(shutter.appears(timeout: 15), "カメラが開かない: \(screenSummary(app))")
        if !shutter.isEnabled { app.tap() }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15)
        shutter.tap()
        // カメラは閉じずに続けて撮れる(一括採点)。「採点する 1」で確認画面へ。
        let done = app.buttons["chat-camera-done"].firstMatch
        XCTAssertTrue(done.appears(timeout: 20), "「採点する」が出ない: \(screenSummary(app))")
        done.tap()
        let use = element(app, "workbook-capture-use")
        XCTAssertTrue(use.appears(timeout: 20), "撮影確認が出ない: \(screenSummary(app))")
        use.tap()
    }

    @MainActor
    fileprivate func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

final class WorkbookSplitGradingUITests: WorkbookSplitGradingUITestCase {
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
        XCTAssertTrue(app.buttons["chat-camera-shutter"].firstMatch.appears(timeout: 15), "「撮り足す」でカメラが開かない")
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
}

final class WorkbookSplitGradingCloseSetUITests: WorkbookSplitGradingUITestCase {
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
        XCTAssertTrue(element(app, "workbook-set-problem-5").appears(timeout: 10), "一枚の画面に戻れない: \(screenSummary(app))")
        attach(app, "5-set-after-close")
        tapCamera(app)
        shoot(app)
        XCTAssertTrue(waitLabel(element(app, "workbook-set-progress-missing"), "5 は未提出"), "締めた後の答案が一枚に足されない: \(screenSummary(app))")
        XCTAssertEqual(element(app, "workbook-verdict-score").label, "4 / 4")
        XCTAssertFalse(element(app, "workbook-set-progress-title").exists, "締めた後の答案を途中にしている")
        attach(app, "6-late-photo-added")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "workbook-set-problem-5").appears(timeout: 10))
        tapCamera(app)
        shoot(app)
        XCTAssertTrue(waitLabel(element(app, "workbook-result-status"), "小単元 合格"), "締めた後に残りを撮っても合格にならない: \(screenSummary(app))")
        XCTAssertEqual(element(app, "workbook-verdict-score").label, "4 / 5")
        attach(app, "7-late-photo-passed")
    }
}

final class WorkbookSplitGradingBatchUITests: WorkbookSplitGradingUITestCase {
    /// 一括採点: カメラを閉じずに 3 枚続けて撮り、確認画面で 1 枚外し、2 枚を 1 つの答案にして 1 回で判定する。
    /// モックの判定は 1 枚に 2 問ずつなので、2 枚で 1〜4 が判定され、5 だけが残る。
    @MainActor
    func testBatchOfPhotosGradedAsOneAnswer() throws {
        let app = launch()
        openPracticeSet(app)
        tapCamera(app)
        let shutter = app.buttons["chat-camera-shutter"].firstMatch
        XCTAssertTrue(shutter.appears(timeout: 15), "カメラが開かない: \(screenSummary(app))")
        let done = app.buttons["chat-camera-done"].firstMatch
        for count in 1...3 {
            if !shutter.isEnabled { app.tap() }
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15)
            shutter.tap()
            XCTAssertTrue(waitLabel(done, "\(count) 枚を採点する", timeout: 20), "\(count) 枚目が束に入らない: \(screenSummary(app))")
        }
        XCTAssertTrue(app.buttons["chat-camera-shutter"].exists, "撮った後にカメラが閉じた")
        attach(app, "batch-1-camera")
        done.tap()

        let title = element(app, "workbook-capture-title")
        XCTAssertTrue(waitLabel(title, "3 枚をまとめて採点します"), "確認画面に 3 枚が並ばない: \(screenSummary(app))")
        attach(app, "batch-2-review")
        element(app, "workbook-capture-remove-3").tap()
        XCTAssertTrue(waitLabel(title, "2 枚をまとめて採点します", timeout: 5), "外した写真が残る: \(screenSummary(app))")
        let use = element(app, "workbook-capture-use")
        XCTAssertEqual(use.label, "2 枚をまとめて採点する")
        use.tap()

        XCTAssertTrue(waitLabel(element(app, "workbook-set-progress-title"), "5 が見つかりませんでした", timeout: 40), "2 枚が 1 つの答案として判定されない: \(screenSummary(app))")
        XCTAssertEqual(element(app, "workbook-result-close-set").label, "見つかった 4 問で結果を出す")
        XCTAssertEqual(element(app, "workbook-result-photo").value as? String, "2 枚", "答案の写真が 2 枚並ばない")
        attach(app, "batch-3-result")
    }
}
