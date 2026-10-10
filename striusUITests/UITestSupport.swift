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
}

extension XCUIApplication {
    /// ホームの「質問」を押して質問シート (ChatView) を開き、入力欄が出るまで待つ。
    @MainActor
    @discardableResult
    func openQuestionSheet(timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let pill = buttons["workbook-question-pill"].firstMatch
        guard pill.waitForExistence(timeout: timeout) else {
            XCTFail("ホームの「質問」ボタンが無い", file: file, line: line)
            return false
        }
        pill.tap()
        let field = textViews.matching(identifier: "chat-page").firstMatch
        guard field.waitForExistence(timeout: 10) else {
            XCTFail("質問シートが開かない", file: file, line: line)
            return false
        }
        return true
    }
}
