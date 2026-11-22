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
        func assertRowsFit(_ label: String) {
            let cells = list.cells.allElementsBoundByIndex
            XCTAssertEqual(cells.count, 3, "\(label): 並び替えの行が 3 つ出ていない")
            for (index, cell) in cells.enumerated() {
                XCTAssertTrue(list.frame.contains(cell.frame), "\(label): \(index) 行目が一覧の枠からはみ出している(\(cell.frame) / \(list.frame))")
            }
        }
        assertRowsFit("縦向き")
        // iPad は横向き(問題が左の列に入り、手順が折り返す)でも確かめる。
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(2)
            assertRowsFit("横向き")
            XCTAssertTrue(error.exists, "回すとお知らせが消える")
            shot("1b-order-with-error-landscape")
        }

        // 飛ばして次の問題へ進むと、前の問題のお知らせは消える。
        app.buttons["timeline-skip"].tap()
        XCTAssertTrue(list.waitForNonExistence(timeout: 10), "次の問題に進まない")
        XCTAssertTrue(error.waitForNonExistence(timeout: 5), "問題が変わってもお知らせが残っている")
        sleep(1)
        shot("2-next-card")

        // 飛ばした理由に「問題がおかしい」がある。押すと帯が閉じる。
        let broken = app.buttons["timeline-skip-broken"]
        XCTAssertTrue(broken.appears(timeout: 5), "飛ばした理由に「問題がおかしい」が無い")
        XCTAssertTrue(app.buttons["timeline-skip-too-hard"].isHittable && app.buttons["timeline-skip-too-easy"].isHittable && broken.isHittable,
                      "理由の 3 つのどれかが押せない")
        broken.tap()
        XCTAssertTrue(element("timeline-skip-banner").waitForNonExistence(timeout: 5), "理由を押しても帯が閉じない")
    }
}
