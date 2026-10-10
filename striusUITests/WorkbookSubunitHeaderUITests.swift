import XCTest

/// 小単元 段階 1・2 の折りたたみヘッダー(シミュレータ既定フィクスチャ)。
/// 開いた状態 → 取っ手を上へスワイプで畳む → 再起動しても畳んだまま → タップで戻る。
final class WorkbookSubunitHeaderUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        // 前のテストや手動の操作で横向きが残っていると、入力欄や送信ボタンが画面外に出て落ちる。
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testHeaderCollapsesBySwipePersistsAndReopensByTap() throws {
        var app = launch()
        var header = openIntroductionSubunit(app)

        // 前回の状態が残っていれば開いてから始める。
        if header.value as? String == "collapsed" {
            header.tap()
            XCTAssertTrue(waitForValue(header, "expanded"), "タップで開かない")
        }
        XCTAssertTrue(app.staticTexts["平方完成で頂点を求める"].waitForExistence(timeout: 3), "開いた状態で到達目標が出ない")

        let grabber = app.descendants(matching: .any)["workbook-subunit-header-grabber"].firstMatch
        XCTAssertTrue(grabber.waitForExistence(timeout: 3))
        let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -120))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(waitForValue(header, "collapsed"), "上スワイプで畳まれない")
        XCTAssertTrue(
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["平方完成で頂点を求める"])
                .fulfill(timeout: 3),
            "畳んだ後も到達目標が見えている"
        )
        XCTAssertTrue(app.staticTexts["二次関数"].firstMatch.exists, "畳んだ行に単元名が無い")

        app.terminate()
        app = launch()
        header = openIntroductionSubunit(app)
        XCTAssertTrue(waitForValue(header, "collapsed"), "再起動後に畳んだ状態が残っていない")

        header.tap()
        XCTAssertTrue(waitForValue(header, "expanded"), "畳んだ行のタップで開かない")
        XCTAssertTrue(app.staticTexts["平方完成で頂点を求める"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-skip-onboarding", "-workbook-model-stage"]
        app.launch()
        return app
    }

    @MainActor
    private func openIntroductionSubunit(_ app: XCUIApplication) -> XCUIElement {
        let row = app.descendants(matching: .any)["workbook-subunit-sub-1"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "ホームに小単元の行が無い")
        row.tap()
        let header = app.descendants(matching: .any)["workbook-subunit-header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "折りたたみヘッダーが無い")
        return header
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 3) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTNSPredicateExpectation(predicate: predicate, object: element)
            .fulfill(timeout: timeout)
    }
}

private extension XCTNSPredicateExpectation {
    func fulfill(timeout: TimeInterval) -> Bool {
        XCTWaiter().wait(for: [self], timeout: timeout) == .completed
    }
}
