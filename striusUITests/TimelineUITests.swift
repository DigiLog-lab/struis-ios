import XCTest

/// 学習タイムライン(Issue #46)の画面: 起動したらタイムラインが出る、単元ホームを重ねて戻る、撮る・指で書く・飛ばす・
/// やめどき・2択カード。モデルの応答はモック(`STRUIS_DEVICE_TURNS=mock`)で、次の5枚・採点・知識グラフも固定の応答。
final class TimelineUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// タイムラインから始める起動(単元ホームを重ねない)。
    @MainActor
    private func launchTimeline() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-skip-onboarding"]
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launchEnvironment["STRUIS_TEST_CAMERA_IMAGE"] = UITestSupport.paperImagePath
        app.launchEnvironment["STRUIS_TEST_CAPTURE_FINISH_SECONDS"] = UITestSupport.captureFinishSecondsWithoutRace
        app.launch()
        return app
    }

    @MainActor
    private func waitForProblem(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.otherElements["timeline-screen"].firstMatch.appears(timeout: 30) || app.descendants(matching: .any)["timeline-screen"].firstMatch.appears(timeout: 5),
                      "起動してタイムラインが出ない", file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any)["timeline-prompt"].firstMatch.appears(timeout: 30)
                      || app.descendants(matching: .any)["timeline-question"].firstMatch.appears(timeout: 5),
                      "1問目が出ない", file: file, line: line)
    }

    /// 起動したらタイムライン。左上の「単元」で単元ホームを全画面で重ね、単元ホームの左上の「タイムライン」で戻る。
    @MainActor
    func testLaunchShowsTimelineAndUnitsHomeCoversIt() throws {
        let app = launchTimeline()
        waitForProblem(app)
        XCTAssertFalse(app.staticTexts["Struis"].exists, "タイムラインにブランド名を出さない")
        XCTAssertTrue(app.buttons["timeline-units-button"].exists)
        XCTAssertTrue(app.buttons["timeline-today-count"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["timeline-next-strip"].firstMatch.exists, "下の帯に次の問題が無い")
        app.buttons["timeline-units-button"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["workbook-home"].firstMatch.appears(timeout: 10), "単元ホームが重ならない")
        XCTAssertTrue(app.buttons["workbook-question-pill"].exists, "単元ホームの質問が無い")
        XCTAssertTrue(app.buttons["workbook-open-settings"].exists, "単元ホームの設定が無い")
        app.buttons["workbook-close-timeline"].tap()
        XCTAssertTrue(app.buttons["timeline-units-button"].appears(timeout: 10), "タイムラインに戻らない")
    }

    /// 撮って採点されたら、すぐ次へ。結果の画面の右下は 質問・解説・次へ。
    @MainActor
    func testCaptureGradesAndMovesToTheNextProblem() throws {
        let app = launchTimeline()
        waitForProblem(app)
        let first = app.descendants(matching: .any)["timeline-question"].firstMatch.label
        app.buttons["timeline-capture"].tap()
        let shutter = app.buttons["chat-camera-shutter"]
        XCTAssertTrue(shutter.appears(timeout: 10))
        shutter.tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-result-correct"].firstMatch.appears(timeout: 30), "採点の結果が出ない")
        XCTAssertTrue(app.buttons["timeline-explain"].exists)
        XCTAssertTrue(app.buttons["timeline-ask"].exists)
        XCTAssertTrue(app.buttons["timeline-today-count"].label.contains("1"), "今日の問題数が増えない")
        app.buttons["timeline-next"].tap()
        XCTAssertTrue(app.buttons["timeline-capture"].appears(timeout: 10))
        XCTAssertNotEqual(app.descendants(matching: .any)["timeline-question"].firstMatch.label, first, "次の問題に進まない")
        XCTAssertTrue(app.descendants(matching: .any)["timeline-chain-bar"].firstMatch.label.contains("2"), "さっきの続きの2問目ではない")
    }

    /// 余白に指で書いたら、大きいボタンが「送る」に変わる。送ると採点される。
    @MainActor
    func testWritingInTheMarginTurnsTheBigButtonIntoSend() throws {
        let app = launchTimeline()
        waitForProblem(app)
        XCTAssertFalse(app.buttons["timeline-send"].exists)
        let ink = app.descendants(matching: .any)["timeline-ink"].firstMatch
        XCTAssertTrue(ink.appears(timeout: 5))
        let start = ink.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: ink.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        XCTAssertTrue(app.buttons["timeline-send"].appears(timeout: 5), "書いたのに「送る」にならない")
        XCTAssertTrue(app.buttons["timeline-ink-undo"].exists)
        app.buttons["timeline-send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-result-correct"].firstMatch.appears(timeout: 30))
    }

    /// 書く面は、上の帯と下の帯の間を画面の端から端まで覆う。問題文の上にも書け、指が触れただけでは「送る」にならない。
    /// 2本指でつまむと縮小でき、「元の大きさ」で戻せる。
    @MainActor
    func testInkCoversTheWholeWidthAndTheProblemTextAndZoomsOut() throws {
        let app = launchTimeline()
        waitForProblem(app)
        let ink = app.descendants(matching: .any)["timeline-ink"].firstMatch
        XCTAssertTrue(ink.appears(timeout: 5))
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(ink.frame.minX, window.minX, accuracy: 1, "書く面が画面の左端まで無い")
        XCTAssertEqual(ink.frame.maxX, window.maxX, accuracy: 1, "書く面が画面の右端まで無い")
        let question = app.descendants(matching: .any)["timeline-question"].firstMatch
        XCTAssertTrue(ink.frame.contains(CGPoint(x: question.frame.midX, y: question.frame.midY)), "問題文の上に書けない")
        // 指が触れただけの点は、書いたものに数えない。
        ink.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertFalse(app.buttons["timeline-send"].waitForExistence(timeout: 1), "触れただけで「送る」になった")
        // 問題文の上を横切って書く。
        let origin = ink.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: 8, dy: question.frame.midY - ink.frame.minY))
        let to = origin.withOffset(CGVector(dx: ink.frame.width - 8, dy: question.frame.midY - ink.frame.minY + 10))
        from.press(forDuration: 0.05, thenDragTo: to)
        XCTAssertTrue(app.buttons["timeline-send"].appears(timeout: 5), "問題文の上に書いたのに「送る」にならない")
        XCTAssertTrue(app.buttons["timeline-skip"].exists == false, "書いた後も「飛ばす」が残っている")
        ink.pinch(withScale: 0.5, velocity: -1)
        let reset = app.buttons["timeline-ink-zoom-reset"]
        XCTAssertTrue(reset.appears(timeout: 5), "つまんでも縮小できない")
        reset.tap()
        XCTAssertTrue(reset.waitForNonExistence(timeout: 5), "「元の大きさ」で戻らない")
        XCTAssertTrue(app.buttons["timeline-send"].exists, "縮小して戻したら書いたものが消えた")
    }

    /// 飛ばしたら、画面の上に「飛ばしました」と理由の2択。2回続けて飛ばしたら2択カード。
    @MainActor
    func testSkippingShowsReasonsAndTwoSkipsOfferTheDipCard() throws {
        let app = launchTimeline()
        waitForProblem(app)
        app.buttons["timeline-skip"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-skip-banner"].firstMatch.appears(timeout: 5))
        app.buttons["timeline-skip-too-hard"].tap()
        XCTAssertTrue(app.buttons["timeline-skip"].appears(timeout: 10))
        app.buttons["timeline-skip"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-dip"].firstMatch.appears(timeout: 10), "飛ばすが2回続いても2択カードが出ない")
        XCTAssertTrue(app.descendants(matching: .any)["timeline-dip-rapid"].firstMatch.exists)
        app.descendants(matching: .any)["timeline-dip-continue"].firstMatch.tap()
        XCTAssertTrue(app.buttons["timeline-skip"].appears(timeout: 10))
    }

    /// やめようとしたときのシート: 今日の問題数と時間、「あと 1 つ」と「今日はここまで」。
    @MainActor
    func testStopSheetOffersOneMoreOrStop() throws {
        let app = launchTimeline()
        waitForProblem(app)
        app.buttons["timeline-today-count"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-stop-sheet"].firstMatch.appears(timeout: 5))
        let more = app.buttons["timeline-one-more"], stop = app.buttons["timeline-stop-today"]
        XCTAssertTrue(more.exists && stop.exists)
        XCTAssertEqual(more.frame.height, stop.frame.height, accuracy: 1, "2つのボタンを同じ大きさで並べる")
        stop.tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-finished"].firstMatch.appears(timeout: 5))
        app.buttons["timeline-resume"].tap()
        XCTAssertTrue(app.buttons["timeline-capture"].appears(timeout: 10))
    }
}
