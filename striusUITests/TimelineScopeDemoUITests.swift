import XCTest

/// 解く範囲(単元の固定)を、実際の Claude で一通り動かして画面を撮る(持ち主に見せる確かめ用。CI では流さない)。
/// `STRUIS_DEMO_ANTHROPIC_KEY_FILE`(API キーのファイル)と `STRUIS_DEMO_SHOTS`(撮った画面を置く場所)が無ければ飛ばす。
final class TimelineScopeDemoUITests: XCTestCase {
    private var shotsDir: String?

    @MainActor
    func testScopeTour() throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["STRUIS_DEMO_ANTHROPIC_KEY_FILE"], !key.isEmpty else { throw XCTSkip("STRUIS_DEMO_ANTHROPIC_KEY_FILE が無い") }
        shotsDir = env["STRUIS_DEMO_SHOTS"]
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-skip-onboarding", "-timeline-scope-demo"]
        app.launchEnvironment["STRUIS_LEDGER"] = "memory"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launchEnvironment["STRUIS_DEBUG_ANTHROPIC_KEY_FILE"] = key
        app.launch()

        // おまかせ: 単元をまたいで出る。
        XCTAssertTrue(waitForProblem(app, timeout: 420), "おまかせの1問目が出ない")
        shot(app, "01-auto")
        mark("auto-problem")

        // チップ → 解く範囲のシート。
        app.buttons["timeline-scope-chip"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-scope-sheet"].firstMatch.appears(timeout: 10), "範囲のシートが出ない")
        sleep(1)
        shot(app, "02-scope-sheet")
        mark("sheet")

        // 微分法に固定 → 微分法の問題に替わる。
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timeline-scope-unit-' AND label CONTAINS '微分法'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["timeline-scope-clear"].appears(timeout: 10), "固定のチップにならない")
        let pinnedProblem = waitForProblem(app, timeout: 420, changingFrom: problemText(app))
        XCTAssertTrue(pinnedProblem, "微分法の問題が出ない")
        sleep(1)
        shot(app, "03-pinned-calculus")
        mark("pinned-calculus")

        // 飛ばして、次も微分法から出るか。
        if app.buttons["timeline-skip"].exists {
            let before = problemText(app)
            app.buttons["timeline-skip"].tap()
            _ = waitForProblem(app, timeout: 300, changingFrom: before)
            sleep(1)
            shot(app, "04-pinned-calculus-next")
            mark("pinned-calculus-next")
        }

        // 単元の画面から「タイムラインで解く」(力学)。飛ばした直後の帯が消えるのを待つ。
        sleep(6)
        let beforeMechanics = problemText(app)
        app.buttons["timeline-units-button"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["workbook-home"].firstMatch.appears(timeout: 10), "単元ホームが出ない")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workbook-unit-card-' AND label CONTAINS '力学'")).firstMatch
        if !card.isHittable { app.swipeUp() }
        card.tap()
        let solve = app.buttons["workbook-unit-solve-in-timeline"]
        XCTAssertTrue(solve.appears(timeout: 15), "「タイムラインで解く」が無い")
        sleep(1)
        shot(app, "05-unit-entry")
        mark("unit-entry")
        solve.tap()
        XCTAssertTrue(app.buttons["timeline-scope-clear"].appears(timeout: 15), "タイムラインに固定で戻らない")
        XCTAssertTrue(waitForChip(app, title: "力学", timeout: 10), "チップが力学にならない")
        XCTAssertTrue(waitForProblem(app, timeout: 420, changingFrom: beforeMechanics), "力学の問題が出ない")
        sleep(2)
        shot(app, "06-pinned-mechanics")
        mark("pinned-mechanics")

        // ✕ でおまかせに戻す。
        app.buttons["timeline-scope-clear"].tap()
        XCTAssertTrue(app.buttons["timeline-scope-chip"].appears(timeout: 10))
        sleep(1)
        shot(app, "07-auto-again")
        mark("done")
    }

    @MainActor
    private func problemText(_ app: XCUIApplication) -> String {
        let prompt = app.descendants(matching: .any)["timeline-prompt"].firstMatch
        if prompt.exists { return prompt.label }
        let question = app.descendants(matching: .any)["timeline-question"].firstMatch
        return question.exists ? question.label : ""
    }

    @MainActor
    private func waitForProblem(_ app: XCUIApplication, timeout: TimeInterval, changingFrom previous: String? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = problemText(app)
            if !text.isEmpty, previous == nil || text != previous { return true }
            sleep(2)
        }
        return false
    }

    @MainActor
    private func waitForChip(_ app: XCUIApplication, title: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.buttons["timeline-scope-chip"].label.contains(title) { return true }
            sleep(1)
        }
        return false
    }

    /// 録画の中の区切り(シェル側で時刻を拾う)。
    private func mark(_ name: String) {
        guard let shotsDir else { return }
        let line = "\(Date().timeIntervalSince1970) \(name)\n"
        let url = URL(fileURLWithPath: shotsDir).appendingPathComponent("marks.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shotsDir else { return }
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: shotsDir).appendingPathComponent(name + ".png"))
    }
}
