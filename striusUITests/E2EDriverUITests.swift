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

        let app = XCUIApplication.struisUnits()
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
            if !["launch", "activate", "quit", "sleep", "home", "screenshot", "alert", "stap", "orient"].contains(command.op), app.state == .notRunning {
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
            case "stap":
                // SpringBoard の座標でたたく。アプリが idle になるのを待たないので、返事が流れている途中の停止ボタンにも届く。
                springboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: command.x ?? 0, dy: command.y ?? 0)).tap()
            case "press":
                point(command.x ?? 0, command.y ?? 0).press(forDuration: command.duration ?? 1)
            case "drag":
                point(command.x ?? 0, command.y ?? 0)
                    .press(forDuration: 0.05, thenDragTo: point(command.x2 ?? 0, command.y2 ?? 0))
            case "tapid":
                let target = element(command.id ?? "")
                if target.appears(timeout: command.timeout ?? 5) {
                    target.tap()
                } else {
                    result = "missing \(command.id ?? "")"
                }
            case "wait":
                let target = element(command.id ?? "")
                result = target.appears(timeout: command.timeout ?? 30) ? "exists" : "missing"
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
                if button.appears(timeout: command.timeout ?? 3) {
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
            case "orient":
                // スクショ撮影用: text が landscape なら横向き(ホームボタン側が右)、それ以外は縦向きにする。
                XCUIDevice.shared.orientation = command.text == "landscape" ? .landscapeLeft : .portrait
                Thread.sleep(forTimeInterval: 1.5)
            case "segs":
                // スクショ撮影用: 「x1 y1 x2 y2;...」(アプリの座標、pt)の線分を順に引く(書く面に字を書く)。
                for part in (command.text ?? "").split(separator: ";") {
                    let v = part.split(separator: " ").compactMap { Double($0) }
                    guard v.count == 4 else { continue }
                    point(v[0], v[1]).press(forDuration: 0.02, thenDragTo: point(v[2], v[3]), withVelocity: 1500, thenHoldForDuration: 0)
                }
            case "ink":
                // スクショ撮影用: 「x,y x,y ...;x,y ...」(アプリの座標、pt)の線を、1回の合成イベントでまとめて引く。
                // 1本ずつ XCUICoordinate で引くと1本に1秒以上かかり、結果に出る解答の秒数が人の書く速さと合わなくなるため。
                result = Self.synthesizeInk(command.text ?? "", step: command.duration ?? 0.012, each: command.name == "each",
                                            orientationOverride: command.x.map { Int($0) }, app: app)
            case "dragid":
                // スクショ撮影用: 要素を (x, y) だけ引く(撮る・質問のように引いて開くもの、上に引いて送る「送る」)。
                let target = element(command.id ?? "")
                if target.appears(timeout: command.timeout ?? 5) {
                    let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: command.x ?? 0, dy: command.y ?? 0)),
                                withVelocity: XCUIGestureVelocity(command.duration ?? 600), thenHoldForDuration: 0.4)
                } else {
                    result = "missing \(command.id ?? "")"
                }
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

    /// XCTest の非公開の合成イベント(XCPointerEventPath・XCSynthesizedEventRecord)で、線を続けて引く(撮影用)。
    @MainActor
    private static func synthesizeInk(_ text: String, step: Double, each: Bool, orientationOverride: Int?, app: XCUIApplication) -> String {
        guard let pathClass = NSClassFromString("XCPointerEventPath"),
              let recordClass = NSClassFromString("XCSynthesizedEventRecord") else { return "no event classes" }
        let strokes: [[CGPoint]] = text.split(separator: ";").map { stroke in
            stroke.split(separator: " ").compactMap { pair -> CGPoint? in
                let v = pair.split(separator: ",").compactMap { Double($0) }
                return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil
            }
        }.filter { $0.count >= 2 }
        guard !strokes.isEmpty else { return "no strokes" }
        func method<T>(_ cls: AnyClass, _ name: String, _ type: T.Type) -> (Selector, T)? {
            let sel = NSSelectorFromString(name)
            guard let found = class_getInstanceMethod(cls, sel) else { return nil }
            return (sel, unsafeBitCast(method_getImplementation(found), to: type))
        }
        func alloc(_ cls: AnyClass) -> AnyObject? {
            (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        }
        typealias InitTouch = @convention(c) (AnyObject, Selector, CGPoint, Double) -> AnyObject
        typealias Move = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias Lift = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias InitRecord = @convention(c) (AnyObject, Selector, NSString, Int64) -> AnyObject
        typealias Add = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Synth = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool
        guard let initTouch = method(pathClass, "initForTouchAtPoint:offset:", InitTouch.self),
              let move = method(pathClass, "moveToPoint:atOffset:", Move.self),
              let lift = method(pathClass, "liftUpAtOffset:", Lift.self),
              let initRecord = method(recordClass, "initWithName:interfaceOrientation:", InitRecord.self),
              let add = method(recordClass, "addPointerEventPath:", Add.self),
              let synth = method(recordClass, "synthesizeWithError:", Synth.self) else { return "no event methods" }
        var orientation = 1
        if app.responds(to: NSSelectorFromString("interfaceOrientation")), let value = app.value(forKey: "interfaceOrientation") as? Int {
            orientation = value
        }
        if let orientationOverride { orientation = orientationOverride }
        // each: 1本ごとに別の合成イベントにして順に送る(1つのイベントに何本も入れると、同時に触れた指として扱われうる)。
        let groups: [[[CGPoint]]] = each ? strokes.map { [$0] } : [strokes]
        var offset = 0.0
        var ok = true
        var error: NSError?
        for group in groups {
            guard let recordObject = alloc(recordClass) else { return "no record" }
            let record = initRecord.1(recordObject, initRecord.0, "ink" as NSString, Int64(orientation))
            var local = 0.0
            for stroke in group {
                guard let pathObject = alloc(pathClass) else { return "no path" }
                let path = initTouch.1(pathObject, initTouch.0, stroke[0], local)
                for point in stroke.dropFirst() {
                    local += step
                    move.1(path, move.0, point, local)
                }
                local += step
                lift.1(path, lift.0, local)
                add.1(record, add.0, path)
                local += step * 3
            }
            offset += local
            ok = synth.1(record, synth.0, &error) && ok
        }
        return ok ? "ok \(strokes.count) strokes \(String(format: "%.1f", offset))s orientation \(orientation)" : "synth failed \(error?.localizedDescription ?? "")"
    }

    private func write(_ text: String, to url: URL) {
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
