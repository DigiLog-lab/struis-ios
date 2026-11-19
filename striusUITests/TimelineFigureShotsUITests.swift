import XCTest

/// 図とグラフのカード(2026-11-19 のプロトタイプ)を、実際のタイムラインの画面で撮る(持ち主に見せる確かめ用。CI では流さない)。
///
/// `STRUIS_FIGURE_SHOTS_BATCH`(`cards` を持つ JSON。`TimelineFigureLiveTests` が実際の Claude で作った figure_live.json)と
/// `STRUIS_FIGURE_SHOTS`(撮った画面を置く場所)が無ければ飛ばす。`STRUIS_FIGURE_SHOTS_CARDS`(「3,7,12」)の番号のカードごとに、
/// モックの出題(`STRUIS_MOCK_TIMELINE_BATCH_FILE`)でそのカードを 1 枚目にしてアプリを起動し、画面全体を撮る。
final class TimelineFigureShotsUITests: XCTestCase {
    @MainActor
    func testFigureCardsOnTheTimeline() throws {
        let env = ProcessInfo.processInfo.environment
        guard let batch = env["STRUIS_FIGURE_SHOTS_BATCH"], !batch.isEmpty, let out = env["STRUIS_FIGURE_SHOTS"], !out.isEmpty else {
            throw XCTSkip("STRUIS_FIGURE_SHOTS_BATCH と STRUIS_FIGURE_SHOTS が無い")
        }
        continueAfterFailure = true
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let indices = (env["STRUIS_FIGURE_SHOTS_CARDS"] ?? "0").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let prefix = env["STRUIS_FIGURE_SHOTS_PREFIX"] ?? "shot"
        XCUIDevice.shared.orientation = .portrait
        for index in indices {
            let app = XCUIApplication()
            app.launchArguments = ["-skip-onboarding"]
            app.launchEnvironment["STRUIS_LEDGER"] = "memory"
            app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
            app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
            app.launchEnvironment["STRUIS_MOCK_TIMELINE_BATCH_FILE"] = batch
            app.launchEnvironment["STRUIS_MOCK_TIMELINE_CARD_START"] = String(index)
            app.launch()
            let figure = app.descendants(matching: .any)["timeline-figure"].firstMatch
            if figure.appears(timeout: 45) {
                // 出てくる動きが落ち着くまで待つ。
                sleep(2)
            } else {
                XCTFail("カード \(index) の図が出ない")
            }
            let shot = XCUIScreen.main.screenshot()
            try shot.pngRepresentation.write(to: URL(fileURLWithPath: out).appendingPathComponent(String(format: "%@-%02d.png", prefix, index + 1)))
            app.terminate()
        }
    }
}
