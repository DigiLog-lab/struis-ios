import XCTest

/// 没頭シーンの「没頭 → 質問 → 復帰」ループの実画面検証。
/// シミュレータ fixtures (既定) で動く: chat 送信はシーン専用ストアの
/// 固定応答、シーンはバンドル同梱 iced-tea-dilution。
final class ImmersionSceneChatUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// 検証レビュー用のプレイスルー画像を xcresult に残す。
    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAskFromSceneThenReturnToSameCanvas() throws {
        let app = XCUIApplication()
        // オンボーディングプロトタイプをスキップして chat 画面へ直行する
        // (シミュレータは auth バイパス + fixtures)。
        // TEST_RUNNER_STRUIS_API_BASE_URL を渡すと fixtures を切り、
        // 実 backend + 実 Codex 応答で同じループを検証する。
        // 没頭シーンの入口は保留中の機能で、`-immersion-entry` のときだけ質問シートに出る。
        app.launchArguments = ["-learning-feed-e2e", "-immersion-entry"]
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        let realBackendBaseURL = ProcessInfo.processInfo.environment["STRUIS_API_BASE_URL"]
        if let realBackendBaseURL {
            app.launchEnvironment["STRUIS_API_BASE_URL"] = realBackendBaseURL
            app.launchEnvironment["STRUIS_IOS_USE_FIXTURES"] = "0"
        }
        app.launch()
        app.openQuestionSheet()

        // 質問シートの常設導線からシーンへ入る
        // (実 backend モードは認証+候補取得を挟むため長めに待つ)
        let entry = app.buttons["immersion-scene-entry"]
        XCTAssertTrue(entry.appears(timeout: 30))
        attachScreenshot(app, name: "01-chat-home")
        entry.tap()

        // hook: 候補カードと常設 composer が同時に見えている
        let hookCard = app.staticTexts["タップして予想を置きにいく"]
        XCTAssertTrue(hookCard.appears(timeout: 10))
        let composer = app.textFields["scene-composer-input"]
        XCTAssertTrue(composer.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["この画面について"].exists)
        attachScreenshot(app, name: "02-scene-hook")

        // 質問を送ると chat が canvas と並存して開く
        composer.tap()
        composer.typeText("why does it get weaker?")
        app.buttons["scene-composer-send"].tap()

        if realBackendBaseURL != nil {
            // 実 Codex 応答: 内容は不定なので「scene-chat-pane の内側に日本語の文が
            // 届いた」ことで判定する (fullScreenCover 下層の ChatView やキーボード、
            // canvas の固定文言への誤マッチを構造的に防ぐ)。
            let pane = app.descendants(matching: .any).matching(identifier: "scene-chat-pane").firstMatch
            XCTAssertTrue(pane.appears(timeout: 10))
            let reply = pane.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "。")
            ).firstMatch
            let replyArrived = reply.appears(timeout: 240)
            if replyArrived {
                let note = XCTAttachment(string: "reply: \(reply.label)")
                note.name = "reply-match"
                note.lifetime = .keepAlways
                add(note)
            }
            XCTAssertTrue(replyArrived, "実 Codex 応答が chat パネルに表示されなかった")
        } else {
            let reply = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "どこで予想とずれ始めましたか")
            ).firstMatch
            XCTAssertTrue(reply.appears(timeout: 10))
        }
        attachScreenshot(app, name: "03-chat-over-canvas")

        // 「学習に戻る」で同じ canvas (hook) へ復帰する
        let back = app.buttons["学習に戻る"]
        XCTAssertTrue(back.appears(timeout: 5))
        back.tap()
        XCTAssertTrue(hookCard.appears(timeout: 5))
        // composer は消えていない (常設)
        XCTAssertTrue(composer.exists)
        attachScreenshot(app, name: "04-restored-canvas")
    }

    /// 固定文言「別のものにする」が閉じるだけで終わらず、候補選択を開く。
    @MainActor
    func testChangeCandidateOpensCandidatePicker() throws {
        let app = XCUIApplication()
        // 没頭シーンの入口は保留中の機能で、`-immersion-entry` のときだけ質問シートに出る。
        app.launchArguments = ["-learning-feed-e2e", "-immersion-entry"]
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launch()
        app.openQuestionSheet()

        let entry = app.buttons["immersion-scene-entry"]
        XCTAssertTrue(entry.appears(timeout: 30))
        entry.tap()

        let change = app.buttons["別のものにする"]
        XCTAssertTrue(change.appears(timeout: 10))
        change.tap()

        let candidate = app.buttons["氷を入れた アイスティー、10 分後の甘さは?"]
        XCTAssertTrue(candidate.appears(timeout: 10))
        attachScreenshot(app, name: "candidate-picker")
    }

    /// 通し体験の録画用ウォークスルー (fixtures)。
    /// 前半: 実アプリ導線 → hook → 文脈 chat → 復帰。後半: explore 介入 →
    /// 差 → 圧縮 (再試行) → 転移 → 境界 → 終了。
    @MainActor
    func testJourneyWalkthroughForRecording() throws {
        let app = XCUIApplication()
        // 没頭シーンの入口は保留中の機能で、`-immersion-entry` のときだけ質問シートに出る。
        app.launchArguments = ["-learning-feed-e2e", "-immersion-entry"]
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launch()
        app.openQuestionSheet()

        let entry = app.buttons["immersion-scene-entry"]
        XCTAssertTrue(entry.appears(timeout: 30))
        Thread.sleep(forTimeInterval: 1.0)
        entry.tap()

        let hookCard = app.staticTexts["タップして予想を置きにいく"]
        XCTAssertTrue(hookCard.appears(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)

        let composer = app.textFields["scene-composer-input"]
        composer.tap()
        composer.typeText("why does it get weaker?")
        app.buttons["scene-composer-send"].tap()
        let reply = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "どこで予想とずれ始めましたか")
        ).firstMatch
        XCTAssertTrue(reply.appears(timeout: 10))
        Thread.sleep(forTimeInterval: 2.0)
        app.buttons["学習に戻る"].tap()
        XCTAssertTrue(hookCard.appears(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)

        // 後半: explore からの完走 (ディープリンクで再起動)
        app.launchArguments = ["-immersion-lab", "-immersion-scene", "web.iced-tea-dilution.explore"]
        app.launch()
        let advance = app.buttons["この動きを確かめる"]
        XCTAssertTrue(advance.appears(timeout: 10))
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.appears(timeout: 10))
        Thread.sleep(forTimeInterval: 1.0)
        var manipulated = false
        for attempt in 0..<3 where !manipulated {
            let dy = 0.5 + Double(attempt) * 0.1
            web.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: dy))
                .press(forDuration: 0.2, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: dy)))
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline, !advance.isEnabled {
                Thread.sleep(forTimeInterval: 0.5)
            }
            manipulated = advance.isEnabled
        }
        XCTAssertTrue(manipulated)
        Thread.sleep(forTimeInterval: 1.0)
        advance.tap()
        XCTAssertTrue(app.staticTexts["予想と、結果。"].appears(timeout: 5))
        Thread.sleep(forTimeInterval: 2.5)
        app.buttons["もう一度予想する"].tap()
        XCTAssertTrue(app.staticTexts["氷が全部溶けて 2 倍の量になったら、甘さは?"].appears(timeout: 5))
        Thread.sleep(forTimeInterval: 2.0)
        app.buttons["半分"].tap()
        let toTransfer = app.buttons["支援なしで試してみる"]
        XCTAssertTrue(toTransfer.appears(timeout: 5))
        Thread.sleep(forTimeInterval: 2.0)
        toTransfer.tap()
        let transferField = app.textFields["答えだけここに"]
        XCTAssertTrue(transferField.appears(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        transferField.tap()
        transferField.typeText("half")
        app.buttons["答えを置く"].tap()
        let toBoundary = app.buttons["区切りを確認する"]
        XCTAssertTrue(toBoundary.appears(timeout: 5))
        Thread.sleep(forTimeInterval: 2.0)
        toBoundary.tap()
        XCTAssertTrue(app.buttons["もう少し続ける"].appears(timeout: 5))
        Thread.sleep(forTimeInterval: 2.0)
        app.buttons["今日はここまで"].tap()
        XCTAssertTrue(app.staticTexts["今日はここまで。"].appears(timeout: 5))
        Thread.sleep(forTimeInterval: 2.0)
    }

    /// 哲学 §2 Step4: explore で「介入」(値の変更・なぞる動き) を完了するまで
    /// 結果に進めない。単なるタップでは解除されないこと、および explore →
    /// consequence → insight (再試行) → transfer → boundary → 終了までの
    /// 認知循環の完走を実画面で検証する。
    @MainActor
    func testExploreRequiresManipulationThenFullCycleCompletes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-immersion-lab", "-immersion-scene", "web.iced-tea-dilution.explore"]
        app.launch()

        let advance = app.buttons["この動きを確かめる"]
        XCTAssertTrue(advance.appears(timeout: 10))
        XCTAssertFalse(advance.isEnabled)

        let web = app.webViews.firstMatch
        XCTAssertTrue(web.appears(timeout: 10))

        // 単なるタップは介入に数えない
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(advance.isEnabled)

        // なぞる動き (ドラッグ) で介入が成立する。explore の時間スライダー(シーンが explore に入って描く
        // `<input type="range">`)が出てから、その上をなぞる。画面の中ほどを漠然となぞると、場所によっては
        // 何も受けない要素の上で、3 回とも介入にならなかった(ジェスチャ調停のフレークに備え、成立するまで数回なぞる)。
        let slider = web.sliders.firstMatch
        XCTAssertTrue(slider.appears(timeout: 10), "explore のスライダーが出ない")
        var manipulated = false
        for attempt in 0..<3 where !manipulated {
            let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.2 + Double(attempt) * 0.1, dy: 0.5))
            let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            start.press(forDuration: 0.2, thenDragTo: end)
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline, !advance.isEnabled {
                Thread.sleep(forTimeInterval: 0.5)
            }
            manipulated = advance.isEnabled
        }
        if !manipulated { UITestSupport.saveProbe(app, name: "immersion-no-manipulation") }
        XCTAssertTrue(manipulated, "なぞる操作で介入が成立しなかった")
        // ここからは段が切り替わるたびにボタンが動くので、止まってから押す(tapWhenSettled)。
        advance.tapWhenSettled()
        XCTAssertTrue(app.staticTexts["予想と、結果。"].appears(timeout: 5))

        // consequence → insight: 即答の再試行 (選択肢は誤予想由来)
        app.buttons["もう一度予想する"].tapWhenSettled()
        XCTAssertTrue(app.staticTexts["氷が全部溶けて 2 倍の量になったら、甘さは?"].appears(timeout: 5))
        app.buttons["半分"].tapWhenSettled()

        // 圧縮が使えたら支援なしの転移へ
        let toTransfer = app.buttons["支援なしで試してみる"]
        XCTAssertTrue(toTransfer.appears(timeout: 5))
        toTransfer.tapWhenSettled()
        let transferField = app.textFields["答えだけここに"]
        XCTAssertTrue(transferField.appears(timeout: 5))
        transferField.tap()
        transferField.typeText("half")
        app.buttons["答えを置く"].tapWhenSettled()

        // 転移の答えを置いたら境界の二択、そして終了
        let toBoundary = app.buttons["区切りを確認する"]
        XCTAssertTrue(toBoundary.appears(timeout: 5))
        toBoundary.tapWhenSettled()
        XCTAssertTrue(app.buttons["もう少し続ける"].appears(timeout: 5))
        app.buttons["今日はここまで"].tapWhenSettled()
        XCTAssertTrue(app.staticTexts["今日はここまで。"].appears(timeout: 5))
    }
}
