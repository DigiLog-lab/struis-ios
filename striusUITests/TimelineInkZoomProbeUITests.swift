import XCTest

/// 調査用(main には入れない): iPad の横向きで、書いた後にカメラを開いて「キャンセル」で閉じると並びがどう変わるか。
final class TimelineInkZoomProbeUITests: XCTestCase {
    @MainActor
    func testProbeCamera() throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-skip-onboarding"]
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launchEnvironment["STRUIS_TEST_CAMERA_IMAGE"] = UITestSupport.paperImagePath
        let env = ProcessInfo.processInfo.environment
        app.launchEnvironment["STRUIS_MOCK_TIMELINE_LONG"] = env["PROBE_SHORT"] == "1" ? "0" : "1"
        let directory = env["STRUIS_PROBE_DIR"] ?? ""
        let tag = env["PROBE_TAG"] ?? "run"
        app.launch()
        let prompt = app.descendants(matching: .any)["timeline-prompt"].firstMatch
        let question = app.descendants(matching: .any)["timeline-question"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 40) || question.waitForExistence(timeout: 5))
        sleep(2)
        let ink = app.descendants(matching: .any)["timeline-ink"].firstMatch
        func report(_ name: String) {
            let screen = app.descendants(matching: .any)["timeline-screen"].firstMatch
            let units = app.descendants(matching: .any)["timeline-units-button"].firstMatch
            let strip = app.descendants(matching: .any)["timeline-next-strip"].firstMatch
            print("PROBEFRAME \(tag) \(name) screen=\(String(describing: screen.value)) units.y=\(units.frame.minY) prompt=\(prompt.frame.minY),h\(prompt.frame.height) question=\(question.frame.minY),h\(question.frame.height) strip.y=\(strip.frame.minY) ink.h=\(ink.frame.height)")
            guard !directory.isEmpty else { return }
            let done = directory + "/\(tag)-\(name).png"
            FileManager.default.createFile(atPath: directory + "/\(tag)-\(name).req", contents: Data())
            for _ in 0..<40 where !FileManager.default.fileExists(atPath: done) { usleep(500_000) }
            sleep(1)
        }
        report("1-start")
        // 問題文の上を指で上へ動かす: 入りきらない時はスクロール(線は増えない)、入る時は線になる。
        let qf = question.frame
        let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: qf.midX, dy: qf.midY))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 20, dy: -200)))
        sleep(1)
        print("PROBEFRAME \(tag) after-finger undoEnabled=\(app.buttons["timeline-ink-undo"].isEnabled)")
        report("1b-finger-on-column")
        let origin = ink.coordinate(withNormalizedOffset: .zero)
        let w = ink.frame.width, h = ink.frame.height
        origin.withOffset(CGVector(dx: w * 0.6, dy: h * 0.3)).press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: w * 0.8, dy: h * 0.35)))
        sleep(1)
        report("2-inked")
        let capture = app.buttons["timeline-capture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        capture.tap()
        let cancel = app.buttons["キャンセル"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "カメラが開かない")
        sleep(1)
        report("3-camera")
        cancel.tap()
        sleep(2)
        report("4-camera-closed")
        capture.tap()
        if cancel.waitForExistence(timeout: 10) { cancel.tap() }
        sleep(2)
        report("5-camera-closed-again")
    }
}
