import XCTest

/// ホーム「単元」の見せ方(2026-09-21 改定)。`-texture-demo` のフィクスチャ(判定済み 2 枚と判定中 1 枚)で回す。
/// 守るもの: 最近の行(小単元名と点数)、段階の表示名(要点 / 例題 / 類題 / 演習)、
/// 小単元の画面の道のりとボタンの文言、下部ツールバーの撮るボタン。
final class WorkbookHomeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testRecentRowsStageAndCaptureButton() throws {
        let app = XCUIApplication.struisUnits()
        app.launchArguments += ["-skip-onboarding", "-texture-demo"]
        // 空の台帳から始める(フィクスチャは空のときだけ入る)。
        app.launchEnvironment["STRUIS_LEDGER"] = "memory"
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launch()

        // 最近: 行は小単元名と点数を読み上げに含む。判定中の行は点数を出さない。
        let graded = app.descendants(matching: .any)["workbook-recent-demo-cap-1"].firstMatch
        XCTAssertTrue(graded.appears(timeout: 20), "判定済みの行が無い")
        XCTAssertTrue(graded.label.contains("頂点の座標が求められる"), "行に小単元名が無い: \(graded.label)")
        XCTAssertTrue(graded.label.contains("4 / 5"), "行に点数が無い: \(graded.label)")
        // 「合格」は小単元が合格した一枚だけに出す(一枚が 8 割でも、小単元が合格していなければ出さない)。
        XCTAssertFalse(graded.label.contains("合格"), "小単元が合格していない行に合格が出ている: \(graded.label)")
        let pending = app.descendants(matching: .any)["workbook-recent-demo-cap-3"].firstMatch
        XCTAssertTrue(pending.exists, "判定中の行が無い")
        XCTAssertTrue(pending.label.contains("判定中"), "判定中の表示が無い: \(pending.label)")

        // いま: 段階は一語と輪。旧称(自力例題)は出さない。
        let now = app.descendants(matching: .any)["workbook-subunit-sub-1"].firstMatch
        XCTAssertTrue(now.exists, "いまの小単元が無い")
        XCTAssertTrue(now.label.contains("類題"), "段階の表示名が無い: \(now.label)")
        XCTAssertFalse(now.label.contains("自力例題"), "旧い段階名が残っている: \(now.label)")

        // 撮る: 下部ツールバーにあり、押せる。
        let camera = app.descendants(matching: .any)["workbook-capture-button"].firstMatch
        XCTAssertTrue(camera.exists && camera.isHittable, "撮るボタンが押せない")

        // 小単元の画面: 道のりに 4 語が並び、ボタンは「類題 1問」。
        now.tap()
        for label in ["要点", "例題", "類題", "演習"] {
            XCTAssertTrue(app.staticTexts[label].firstMatch.appears(timeout: 5), "道のりに「\(label)」が無い")
        }
        let request = app.buttons["workbook-request-set"].firstMatch
        XCTAssertTrue(request.appears(timeout: 5), "一枚を出すボタンが無い")
        XCTAssertTrue(request.label.contains("類題 1問"), "ボタンの文言が違う: \(request.label)")
        XCTAssertTrue(app.descendants(matching: .any)["workbook-capture-button"].firstMatch.isHittable, "小単元の画面で撮るボタンが押せない")
    }
}
