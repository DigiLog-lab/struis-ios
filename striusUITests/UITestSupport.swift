import StoreKitTest
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

    /// テスト用の偽カメラが、撮ってから撮影の完了までに置く秒数(`STRUIS_TEST_CAPTURE_FINISH_SECONDS`)。
    /// アプリの既定の 3 秒は、撮影の途中に送る・取り消す競合を確かめるテスト(`ChatImmediateImageSendUITests`)のためのもの。
    /// 撮影の途中に何もせず、完了を待つだけのテスト(問題集の撮影)はこれを使う。完了が後から非同期に届く流れは変えない。
    static let captureFinishSecondsWithoutRace = "0.5"

    @MainActor
    static func deviceApp(arguments: [String] = ["-skip-onboarding"]) -> XCUIApplication {
        // A previous rotation test can leave the simulator in landscape.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication.struisUnits()
        app.launchArguments = arguments
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launchEnvironment["STRUIS_TEST_CAMERA_IMAGE"] = paperImagePath
        return app
    }

    /// StoreKit の設定ファイル(`Config/Struis.storekit`)で購入を動かす `SKTestSession`。
    ///
    /// Xcode 27 は、テストするアプリ(`com.digiloglab.strius`)をシミュレータに入れるのを、最初の `launch()` の時まで遅らせる。
    /// アプリがまだ入っていないシミュレータ(作り直した・アプリを消した)で、入る前に `SKTestSession` を作ると、storekitd が
    /// アプリを見つけられず(`LSBundleRecord` の -10814)、設定ファイルを保存できない(`[SKTestSession] Error saving
    /// configuration file`、`SKServiceErrorDomain Code=2`)。`SKTestSession` はこの失敗を投げずにログに出すだけなので、
    /// アプリは設定ファイルではない商品(ライトが $9.99)を読み、購入も失敗していた(2026-11-15、Dev Box で再現)。
    /// だから、アプリを一度起動して閉じ(入っていなければここで入る)、それから作る。作った後は、設定ファイルの
    /// ストアフロント(JPN)が読めることを確かめ、読めなければ setUp を失敗させる。
    @MainActor
    static func storeKitSession() throws -> SKTestSession {
        installAppUnderTest()
        let configuration: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/Struis.storekit")
        let session: SKTestSession = try SKTestSession(contentsOf: configuration)
        let storefront: String = session.storefront
        guard storefront == "JPN" else { throw StoreKitSessionError.configurationNotLoaded(storefront: storefront) }
        return session
    }

    enum StoreKitSessionError: Error, CustomStringConvertible {
        case configurationNotLoaded(storefront: String)

        var description: String {
            switch self {
            case .configurationNotLoaded(let storefront):
                return "StoreKit の設定ファイルが読み込まれていない(ストアフロントが JPN ではなく「\(storefront)」)"
            }
        }
    }

    /// テストするアプリを入れる(このテストの実行で 1 回だけ、起動してすぐ閉じる)。
    @MainActor
    private static func installAppUnderTest() {
        guard !appUnderTestInstalled else { return }
        let app: XCUIApplication = XCUIApplication()
        app.launchEnvironment = ["STRUIS_DEVICE_TURNS": "mock", "STRUIS_DEVICE_RUNTIME": "0"]
        app.launch()
        app.terminate()
        appUnderTestInstalled = true
    }

    @MainActor private static var appUnderTestInstalled: Bool = false

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
    /// 単元ホームから操作するテストの起動。アプリは起動するとタイムライン(Issue #46)を出すので、単元ホームを重ねた
    /// 状態から始める(`STRUIS_START_SCREEN=units`、DEBUG のみ)。重ねた単元ホームの中身は、根元にあった時と同じ。
    @MainActor
    static func struisUnits() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["STRUIS_START_SCREEN"] = "units"
        return app
    }

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

    /// 質問は開くたびに空の新しい会話で始まる。前の会話は左上の「履歴」から選んで開く。
    /// `title` を渡せば、その文字を含む会話を、無ければ一覧のいちばん上(いちばん新しい会話)を開く。
    @MainActor
    @discardableResult
    func openHistoryThread(containing title: String? = nil, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        buttons["履歴"].firstMatch.tap()
        let header = staticTexts["会話履歴"].firstMatch
        guard header.appears(timeout: timeout) else {
            XCTFail("履歴が開かない", file: file, line: line)
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let floor = header.frame.maxY
            let rows = buttons.allElementsBoundByIndex
                .filter { $0.isHittable && $0.frame.minY >= floor && $0.frame.minX >= 0 && $0.frame.minX < header.frame.maxX }
                .filter { row in title.map { row.label.contains($0) } ?? true }
                .sorted { $0.frame.minY < $1.frame.minY }
            if let row = rows.first {
                row.tap()
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("履歴に会話が無い: \(title ?? "いちばん新しい会話")", file: file, line: line)
        return false
    }
}

extension XCUIApplication {
    /// いくつかの要素のどれかが出るまで、全部を同時に見て待つ。`a.appears(timeout:) || b.appears(timeout:)` のように
    /// 順に待つと、その場面で出ない方の待ちを毎回使い切ってから次を見る(Xcode Cloud の PR Gate 161 で 1 回 15〜20 秒)。
    @MainActor
    func anyAppears(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        if elements.contains(where: { $0.exists }) { return true }
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in elements.contains { $0.exists } }, object: nil)
        return XCTWaiter().wait(for: [shown], timeout: timeout) == .completed
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

    /// 質問・撮る・単元のチップのように、引っぱって開くものを引く(タップでは開かない)。
    @MainActor
    func drag(by vector: CGVector) {
        let start = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(vector), withVelocity: 600, thenHoldForDuration: 0.1)
    }

    /// 「送る」のように、上に引いた時だけ動くボタンを引く(タップでは送らない)。
    @MainActor
    func pullUp(by distance: CGFloat = 220) {
        let start = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        // ゆっくり引いて少し止めてから離す(はじく速さではなく、引いた長さで送る。録画に途中の形も残る)。
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                    withVelocity: 320, thenHoldForDuration: 0.4)
    }

    /// 画面の切り替えで動いている要素を、止まってから押す。押す位置は要素の木を取った時の枠の中央なので、
    /// 切り替えの途中の枠で押すと、押す前に要素が動いて外れることがある(Xcode Cloud の PR Gate 160 で、
    /// 出た直後の「今日はここまで」を押しても画面が変わらなかった)。枠が 0.25 秒あけて 2 回同じになり、
    /// 押せる状態になるまで(最長 `timeout` 秒)待ってから押す。押す操作と、その後の判定は変えない。
    @MainActor
    func tapWhenSettled(timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = frame
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            let current = frame
            if current == last, isHittable { break }
            last = current
        }
        tap()
    }
}
