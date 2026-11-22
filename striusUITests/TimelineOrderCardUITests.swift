import XCTest

/// 並び替えのカードの高さと、読めなかった時のお知らせ(数式を含む)が問題を変えると消えること(AI はモック)。
final class TimelineOrderCardUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testOrderCardFitsAndErrorClearsOnNextCard() throws {
        let app = UITestSupport.deviceApp(arguments: ["-skip-onboarding", "-timeline-order-demo"])
        app.launchEnvironment["STRUIS_START_SCREEN"] = nil
        app.launch()
        func shot(_ name: String) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = name
            image.lifetime = .keepAlways
            add(image)
        }
        func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier] }

        let list = element("timeline-order-list")
        XCTAssertTrue(list.appears(timeout: 30), "並び替えのカードが出ない")
        let error = element("timeline-error")
        XCTAssertTrue(error.appears(timeout: 10), "お知らせが出ない")
        sleep(1)
        shot("1-order-with-error")

        // 一覧の中で隠れている行が無い: 3つの行がどれも一覧の枠の中に収まっている。
        let cells = list.cells.allElementsBoundByIndex
        XCTAssertEqual(cells.count, 3, "並び替えの行が 3 つ出ていない")
        for (index, cell) in cells.enumerated() {
            XCTAssertTrue(list.frame.contains(cell.frame), "\(index) 行目が一覧の枠からはみ出している(\(cell.frame) / \(list.frame))")
        }

        // 飛ばして次の問題へ進むと、前の問題のお知らせは消える。
        app.buttons["timeline-skip"].tap()
        XCTAssertTrue(list.waitForNonExistence(timeout: 10), "次の問題に進まない")
        XCTAssertTrue(error.waitForNonExistence(timeout: 5), "問題が変わってもお知らせが残っている")
        sleep(1)
        shot("2-next-card")
    }
}
