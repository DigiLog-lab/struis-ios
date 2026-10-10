import XCTest

/// 手動 E2E 用の操作代行ランナー (検証用、main には入れない)。
/// `STRUIS_E2E_DRIVER_DIR` に置かれた `cmd.json` を 1 件ずつ実行し、`result.txt` に結果を書く。
/// 起動は `TEST_RUNNER_STRUIS_E2E_DRIVER_DIR=<dir> xcodebuild test -only-testing:striusUITests/E2EDriverUITests`。
/// アプリへの環境変数は `TEST_RUNNER_STRUIS_E2E_APP_ENV_<NAME>` で渡す。
final class E2EDriverUITests: XCTestCase {
    private struct Command: Decodable {
        let seq: Int
        let op: String
        var x: Double?
        var y: Double?
        var x2: Double?
        var y2: Double?
        var text: String?
        var id: String?
        var name: String?
        var duration: Double?
        var timeout: Double?
    }

    @MainActor
    func testDrive() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["STRUIS_E2E_DRIVER_DIR"] else { throw XCTSkip("検証専用の操作代行ランナー(STRUIS_E2E_DRIVER_DIR が無いときは動かさない)") }
        let dir = URL(fileURLWithPath: dirPath)
        let cmdURL = dir.appendingPathComponent("cmd.json")
        let resultURL = dir.appendingPathComponent("result.txt")
        executionTimeAllowance = 60 * 60 * 6
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait

        let app = XCUIApplication()
        let prefix = "STRUIS_E2E_APP_ENV_"
        for (key, value) in env where key.hasPrefix(prefix) {
            app.launchEnvironment[String(key.dropFirst(prefix.count))] = value
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try? FileManager.default.removeItem(at: cmdURL)
        write("ready", to: resultURL)

        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }
        func element(_ key: String) -> XCUIElement {
            // Prefer an on-screen match: hidden pages (e.g. the branch composer) reuse the same labels.
            let screen = app.frame
            for query in [app.descendants(matching: .any).matching(identifier: key),
                          app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", key))] {
                for candidate in query.allElementsBoundByIndex where candidate.exists {
                    let frame = candidate.frame
                    if !frame.isEmpty, screen.intersects(frame), frame.minX >= 0, candidate.isHittable { return candidate }
                }
            }
            let byID = app.descendants(matching: .any)[key].firstMatch
            if byID.exists { return byID }
            return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", key)).firstMatch
        }

        while true {
            guard let data = try? Data(contentsOf: cmdURL),
                  let command = try? JSONDecoder().decode(Command.self, from: data) else {
                Thread.sleep(forTimeInterval: 0.3)
                continue
            }
            try? FileManager.default.removeItem(at: cmdURL)
            var result = "ok"
            // Querying a terminated app fails the whole run; report instead.
            if !["launch", "activate", "quit", "sleep", "home", "screenshot", "alert"].contains(command.op), app.state == .notRunning {
                write("\(command.seq) app not running", to: resultURL)
                continue
            }
            switch command.op {
            case "launch":
                app.launchArguments = (command.text ?? "").split(separator: " ").map(String.init)
                app.launch()
            case "activate":
                app.activate()
            case "home":
                XCUIDevice.shared.press(.home)
            case "terminate":
                app.terminate()
            case "tap":
                point(command.x ?? 0, command.y ?? 0).tap()
            case "press":
                point(command.x ?? 0, command.y ?? 0).press(forDuration: command.duration ?? 1)
            case "drag":
                point(command.x ?? 0, command.y ?? 0)
                    .press(forDuration: 0.05, thenDragTo: point(command.x2 ?? 0, command.y2 ?? 0))
            case "tapid":
                let target = element(command.id ?? "")
                if target.waitForExistence(timeout: command.timeout ?? 5) {
                    target.tap()
                } else {
                    result = "missing \(command.id ?? "")"
                }
            case "wait":
                let target = element(command.id ?? "")
                result = target.waitForExistence(timeout: command.timeout ?? 30) ? "exists" : "missing"
            case "type":
                // A failed synthesize ends the whole run, so only type into a focused field.
                if app.keyboards.count > 0 {
                    app.typeText(command.text ?? "")
                } else {
                    result = "no keyboard"
                }
            case "alert":
                let label = command.text ?? "許可"
                let button = springboard.buttons[label].firstMatch
                if button.waitForExistence(timeout: command.timeout ?? 3) {
                    button.tap()
                } else {
                    result = "no alert button \(label)"
                }
            case "screenshot":
                let png = XCUIScreen.main.screenshot().pngRepresentation
                let url = dir.appendingPathComponent("\(command.name ?? "shot").png")
                try? png.write(to: url)
                result = url.path
            case "tree":
                let url = dir.appendingPathComponent("tree.txt")
                write(app.debugDescription, to: url)
                result = url.path
            case "sleep":
                Thread.sleep(forTimeInterval: command.duration ?? 1)
            case "quit":
                write("\(command.seq) bye", to: resultURL)
                return
            default:
                result = "unknown op \(command.op)"
            }
            write("\(command.seq) \(result)", to: resultURL)
        }
    }

    private func write(_ text: String, to url: URL) {
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
