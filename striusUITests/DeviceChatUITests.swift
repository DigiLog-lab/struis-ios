import XCTest

/// 端末完結の質問ターン (design §6.3 / §9 M5): 質問シートで送信 → 台帳に学習者の発言と
/// 保留中の返信 → ターン実行 → 修復ループ・memory・進行更新を通って返信が完了する。
///
/// - `testQuestionTurnWithMockModel`: モデル出力だけ固定 (`STRUIS_DEVICE_TURNS=mock`)。
/// - `testQuestionTurnWithRealCodex`: hyotan 上の実 Codex app-server で回す。
///   `TEST_RUNNER_STRUIS_REAL_CODEX_AUTH=<auth.json のパス>` を xcodebuild に渡したときだけ動く
///   (DEBUG + simulator 限定の `STRUIS_DEBUG_CODEX_AUTH_FILE` でゲストに置く)。
final class DeviceChatUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // 前のテストや手動の操作で横向きが残っていると、入力欄や送信ボタンが画面外に出て落ちる。
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testQuestionTurnWithMockModel() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-skip-onboarding"]
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launch()
        let reply = try ask(app, "平方完成の途中で符号が分からなくなりました。", timeout: 30)
        XCTAssertTrue(reply.contains("いいですね"), "モック返信が出ない: \(reply)")
        XCTAssertFalse(reply.contains("struis_memory_update"), "私的ブロックが画面に漏れている")
        snapshot(app, "chat-mock-reply")
    }

    @MainActor
    func testQuestionTurnWithRealCodex() throws {
        let auth = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_AUTH"] ?? ""
        try XCTSkipIf(auth.isEmpty, "TEST_RUNNER_STRUIS_REAL_CODEX_AUTH が無い (実 Codex 検証は手動)")
        let app = XCUIApplication()
        app.launchArguments += ["-skip-onboarding"]
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "1"
        app.launchEnvironment["STRUIS_LEDGER"] = "memory"
        if let stdio = ProcessInfo.processInfo.environment["STRUIS_STDIO_LOG"] { app.launchEnvironment["STRUIS_STDIO_LOG"] = stdio }
        app.launchEnvironment["STRUIS_DEBUG_CODEX_AUTH_FILE"] = auth
        let assets = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_ASSETS_DIR"] ?? ""
        try XCTSkipIf(assets.isEmpty, "TEST_RUNNER_STRUIS_REAL_CODEX_ASSETS_DIR が無い (既定単元の実AI試験には外部配信資産が必要)")
        app.launchEnvironment["STRUIS_DEVICE_ASSETS_DIR"] = assets
        app.launch()
        let reply = try ask(app, "y = x^2 - 4x + 1 を平方完成すると、どうして -3 が出てくるのですか？", timeout: 240)
        XCTAssertFalse(reply.isEmpty)
        assertTurnSucceeded(reply, "ターン")
        XCTAssertFalse(reply.contains("<struis_"), "私的ブロックが画面に漏れている: \(reply)")
        snapshot(app, "chat-real-codex-reply")

        // 同じ会話に続けて聞く: thread/resume + inject_items の経路。
        let followUp = try ask(app, "では y = x^2 + 6x + 2 の頂点はどこですか？", timeout: 240, openSheet: false)
        assertTurnSucceeded(followUp, "2 通目")
        XCTAssertFalse(followUp.contains("<struis_"), "私的ブロックが画面に漏れている: \(followUp)")
        snapshot(app, "chat-real-codex-follow-up")
    }

    /// 学習計画の依頼 → `<struis_workbook_proposal>` → 端末で単元生成ターン → 提案カードの「はじめる」。
    /// 続けて過去の会話記録を調べる依頼を送り、Luna 委任の経路を通す (委任するかはモデル判断)。
    @MainActor
    func testWorkbookProposalAndLookupWithRealCodex() throws {
        let auth = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_AUTH"] ?? ""
        try XCTSkipIf(auth.isEmpty, "TEST_RUNNER_STRUIS_REAL_CODEX_AUTH が無い (実 Codex 検証は手動)")
        let app = XCUIApplication()
        app.launchArguments += ["-skip-onboarding"]
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "1"
        app.launchEnvironment["STRUIS_LEDGER"] = "memory"
        app.launchEnvironment["STRUIS_DEBUG_CODEX_AUTH_FILE"] = auth
        let assets = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_ASSETS_DIR"] ?? ""
        try XCTSkipIf(assets.isEmpty, "TEST_RUNNER_STRUIS_REAL_CODEX_ASSETS_DIR が無い (既定単元の実AI試験には外部配信資産が必要)")
        app.launchEnvironment["STRUIS_DEVICE_ASSETS_DIR"] = assets
        app.launch()
        let reply = try ask(app, "春休みに三角比を一から予習したいです。計画を立ててください。", timeout: 240)
        assertTurnSucceeded(reply, "計画の依頼")
        XCTAssertFalse(reply.contains("<struis_"), "私的ブロックが画面に漏れている: \(reply)")
        let start = app.descendants(matching: .any)["workbook-proposal-start"].firstMatch
        XCTAssertTrue(start.appears(timeout: 300), "単元の提案カードが出ない")
        snapshot(app, "chat-real-codex-proposal")
        start.tap()
        // 「はじめる」の後は質問画面を閉じて小単元 1 の要点を開く(質問画面に取り残されない)。
        let header = app.descendants(matching: .any)["workbook-subunit-header"].firstMatch
        XCTAssertTrue(header.appears(timeout: 30), "提案から単元を始められない")
        app.navigationBars.buttons.firstMatch.tap()

        let lookup = try ask(app, "さっき私が何を予習したいと言ったか、会話の記録を調べて一言で確認してください。", timeout: 300)
        XCTAssertTrue(lookup.contains("三角比"), "記録の確認ができていない: \(lookup)")
        snapshot(app, "chat-real-codex-lookup")
    }

    /// 中断 (turn/interrupt) と、停止の後の再送・再起動後の継続。
    @MainActor
    func testInterruptWithRealCodex() throws {
        let auth = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_AUTH"] ?? ""
        try XCTSkipIf(auth.isEmpty, "TEST_RUNNER_STRUIS_REAL_CODEX_AUTH が無い (実 Codex 検証は手動)")
        let app = XCUIApplication()
        app.launchArguments += ["-skip-onboarding"]
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "1"
        app.launchEnvironment["STRUIS_LEDGER"] = "persistent"
        app.launchEnvironment["STRUIS_DEBUG_CODEX_AUTH_FILE"] = auth
        let assets = ProcessInfo.processInfo.environment["STRUIS_REAL_CODEX_ASSETS_DIR"] ?? ""
        try XCTSkipIf(assets.isEmpty, "TEST_RUNNER_STRUIS_REAL_CODEX_ASSETS_DIR が無い (既定単元の実AI試験には外部配信資産が必要)")
        app.launchEnvironment["STRUIS_DEVICE_ASSETS_DIR"] = assets
        app.launch()
        assertTurnSucceeded(try ask(app, "y = (x-3)^2 + 5 の頂点を一言で教えてください。", timeout: 240), "本流の返信")

        // 中断: 長い返信を頼み、返信中に停止する。
        let field = app.textViews.matching(identifier: "chat-page").firstMatch
        field.tap()
        field.typeText("二次関数の最大・最小について、場合分けの考え方を例を 5 つ挙げて詳しく説明してください。")
        let chatSend = app.buttons.matching(NSPredicate(format: "label == %@", "送信")).allElementsBoundByIndex.first { $0.isHittable && $0.frame.minX >= 0 }
        chatSend?.press(forDuration: 0.15)
        let stop = app.buttons["停止"].firstMatch
        XCTAssertTrue(stop.appears(timeout: 20), "停止ボタンが出ない")
        sleep(6)
        stop.tap()
        XCTAssertTrue(app.staticTexts["停止しました。"].firstMatch.appears(timeout: 60), "停止が反映されない")
        snapshot(app, "chat-real-codex-interrupted")
        let resent = try ask(app, "13 と 17 の積だけ答えてください。", timeout: 240, openSheet: false)
        assertTurnSucceeded(resent, "停止後の再送")
        XCTAssertTrue(resent.contains("221"), resent)
        snapshot(app, "chat-real-codex-after-interrupt")
        app.terminate()
        app.launch()
        let resumed = try ask(app, "直前に求めた積はいくつでしたか？数字だけで答えてください。", timeout: 240)
        assertTurnSucceeded(resumed, "アプリ再起動後の継続")
        XCTAssertTrue(resumed.contains("221"), resumed)
        snapshot(app, "chat-real-codex-after-relaunch")
    }

    @MainActor
    private func waitForReply(_ app: XCUIApplication, excluding before: Set<String>, timeout: TimeInterval, requireText: String) throws -> String {
        let replies = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-message-"))
        let initial = before.isEmpty ? Set(replies.allElementsBoundByIndex.filter { $0.elementType != .activityIndicator }.map(\.identifier)) : before
        let deadline = Date().addingTimeInterval(timeout)
        var lastSeen = ""
        while Date() < deadline {
            let labels = replies.allElementsBoundByIndex.filter { !initial.contains($0.identifier) }.flatMap { element -> [String] in
                switch element.elementType {
                case .webView: element.staticTexts.allElementsBoundByIndex.map(\.label)
                case .staticText: [element.label]
                default: []
                }
            }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != "…" }
            // 数式の WebView は本文の Text より遅れて文字が出るので、2 回続けて同じになるまで待つ。
            if !labels.isEmpty {
                let text = labels.joined(separator: "\n")
                if text == lastSeen { return text }
                lastSeen = text
            }
            Thread.sleep(forTimeInterval: 2)
        }
        snapshot(app, "reply-timeout")
        XCTFail("返信が \(Int(timeout)) 秒以内に完了しない")
        return ""
    }

    /// 返信がターンの失敗表示 (異常終了・利用上限・タイムアウトなど) でないこと。
    private static let failureMarkers = ["Codex が終了", "失敗", "timeout", "usage limit", "hit your", "上限", "rate limit", "受け取れませんでした"]

    private func assertTurnSucceeded(_ reply: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let marker = Self.failureMarkers.first { reply.localizedCaseInsensitiveContains($0) }
        XCTAssertNil(marker, "\(label)が失敗した (\(marker ?? "")): \(reply)", file: file, line: line)
    }

    /// 質問シートを開いて送信し、完了した返信の本文を返す。
    @MainActor
    private func ask(_ app: XCUIApplication, _ text: String, timeout: TimeInterval, openSheet: Bool = true) throws -> String {
        if openSheet {
            let pill = app.buttons["workbook-question-pill"].firstMatch
            XCTAssertTrue(pill.appears(timeout: 20), "質問ボタンが無い")
            pill.tap()
        }
        let field = app.textViews.matching(identifier: "chat-page").firstMatch
        XCTAssertTrue(field.appears(timeout: 10), "入力欄が無い")
        field.tap()
        field.typeText(text)
        let sendButtons = app.buttons.matching(NSPredicate(format: "label == %@", "送信"))
        XCTAssertTrue(sendButtons.firstMatch.appears(timeout: 5), "送信ボタンが無い")
        let send = sendButtons.allElementsBoundByIndex.first { $0.isHittable && $0.frame.minX >= 0 }
        XCTAssertNotNil(send, "表示中の送信ボタンが無い")
        let replies = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-message-"))
        let before = Set(replies.allElementsBoundByIndex.map(\.identifier))
        Thread.sleep(forTimeInterval: 0.5)
        send?.press(forDuration: 0.15)
        XCTAssertTrue(app.staticTexts[text].firstMatch.appears(timeout: 10), "学習者の発言が出ない")

        // 返信の本文は Text と数式ビュー (KaTeX) が混ざるので、識別子を継いだ全要素から
        // 保留中の進捗表示以外の要素を拾う。
        let deadline = Date().addingTimeInterval(timeout)
        var lastSeen = ""
        while Date() < deadline {
            // 返事が入れ替わる間は要素が消えることがあるので、番号で取り、あるものだけ読む。
            // 自分の発言より下にある返信だけを読む(遅延描画で後から現れる古い返信を拾わない)。
            let mine = app.staticTexts[text].firstMatch
            let floor = mine.exists ? mine.frame.maxY - 1 : -CGFloat.infinity
            let current = (0..<replies.count).map { replies.element(boundBy: $0) }.filter { $0.exists && $0.frame.minY >= floor }
            let labels = current.filter { !before.contains($0.identifier) }.flatMap { element -> [String] in
                switch element.elementType {
                case .webView: element.staticTexts.allElementsBoundByIndex.map(\.label)
                case .staticText: [element.label]
                default: []
                }
            }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != "…" }
            // 数式の WebView は本文の Text より遅れて文字が出るので、2 回続けて同じになるまで待つ。
            if !labels.isEmpty {
                let text = labels.joined(separator: "\n")
                if text == lastSeen { return text }
                lastSeen = text
            }
            Thread.sleep(forTimeInterval: 2)
        }
        snapshot(app, "chat-timeout")
        print("HIERARCHY_BEGIN\n\(app.debugDescription)\nHIERARCHY_END")
        XCTFail("返信が \(Int(timeout)) 秒以内に完了しない")
        return ""
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
