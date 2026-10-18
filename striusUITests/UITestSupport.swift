import XCTest

private final class UITestResourceBundle: NSObject {}

/// 共通の起動と導線。チャット (質問) はホーム「単元」の右上「質問」から開くシートにある。
/// 端末完結の既定: モデル応答はモック (`STRUIS_DEVICE_TURNS=mock`)、ゲスト Linux は起動しない、
/// カメラはテスト用紙画像 (シミュレータにカメラが無いため)。
enum UITestSupport {
    static var paperImagePath: String {
        if let supplied = ProcessInfo.processInfo.environment["STRUIS_TEST_CAMERA_IMAGE"] { return supplied }
        guard let image = Bundle(for: UITestResourceBundle.self).url(forResource: "handwritten_eigenvalue", withExtension: "jpeg") else {
            preconditionFailure("Missing bundled canonical UI camera image: handwritten_eigenvalue.jpeg")
        }
        return image.path
    }

    @MainActor
    static func deviceApp(arguments: [String] = ["-skip-onboarding"]) -> XCUIApplication {
        // A previous rotation test can leave the simulator in landscape.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launchEnvironment["STRUIS_TEST_CAMERA_IMAGE"] = paperImagePath
        return app
    }

    /// 画面の写真(PNG)と要素の木(txt)を `STRUIS_PROBE_DIR` に残す(CI では `$RUNNER_TEMP/ui-probe` を artifact に入れる)。
    /// 変数が無ければ添付だけにする。
    @MainActor
    static func saveProbe(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let tree = app.debugDescription
        guard let directory = ProcessInfo.processInfo.environment["STRUIS_PROBE_DIR"], !directory.isEmpty else {
            print("PROBE \(name) tree=\(tree.prefix(6000))")
            return
        }
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: base.appendingPathComponent("\(name).png"))
        try? tree.write(to: base.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        print("PROBE \(name) saved to \(directory)")
    }
}

extension XCUIApplication {
    /// ホームの「質問」を押して質問シート (ChatView) を開き、入力欄が出るまで待つ。
    @MainActor
    @discardableResult
    func openQuestionSheet(timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let pill = buttons["workbook-question-pill"].firstMatch
        guard pill.appears(timeout: timeout) else {
            XCTFail("ホームの「質問」ボタンが無い", file: file, line: line)
            return false
        }
        pill.tap()
        let field = textViews.matching(identifier: "chat-page").firstMatch
        guard field.appears(timeout: 10) else {
            XCTFail("質問シートが開かない", file: file, line: line)
            return false
        }
        return true
    }
}

extension XCUIApplication {
    /// 新しい Simulator で初めてキーボードを出すと、システムが「なぞり入力」の案内(Continue)をキーボードの上に重ねる。
    /// アプリの画面ではなく Simulator ごとに 1 回だけ出るもので、出ている間は入力欄の周りが押せない。
    /// キーボードを出した後に呼び、出ていれば閉じる(出ていなければ何もしない)。
    @MainActor
    func dismissKeyboardIntroductionIfShown(timeout: TimeInterval = 2) {
        let labels = ["Continue", "続ける"]
        let predicate = NSPredicate(format: "label IN %@", labels)
        let candidates = [keyboards.buttons.matching(predicate).firstMatch, buttons.matching(predicate).firstMatch]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let shown = candidates.first(where: { $0.exists && $0.isHittable }) {
                shown.tap()
                _ = shown.waitForNonExistence(timeout: 3)
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
    }
}

extension XCUIElement {
    /// 今あればすぐ true を返し、無ければ `timeout` まで待つ。`waitForExistence` は要素がすでにあっても、
    /// 最初の確認まで約 1 秒待つ。
    @MainActor
    func appears(timeout: TimeInterval) -> Bool {
        exists || waitForExistence(timeout: timeout)
    }
}
