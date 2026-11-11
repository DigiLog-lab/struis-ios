import StoreKitTest
import XCTest

/// 実使用テスト用の操作代行ランナー(検証用のブランチ `claude/real-usage-test` だけに置く。main には入れない)。
/// `E2EDriverUITests` と同じく `STRUIS_E2E_DRIVER_DIR` の `cmd.json` を 1 件ずつ実行して `result.txt` に結果を書く。
/// 違い: 起動先を単元ホームに差し替えない(利用者と同じくオンボーディング・タイムラインから始まる)、
/// StoreKit の設定ファイルで購入できる、手書き(`ink`)、画面の要素の一覧(`snap`)、他のアプリ(通知の確認など)の操作。
final class RealUsageDriverUITests: XCTestCase {
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
        var env: [String: String]?
        var args: [String]?
        var strokes: [[[Double]]]?
        var bundle: String?
    }

    private var storeSession: SKTestSession?

    @MainActor
    func testDrive() throws {
        let env: [String: String] = ProcessInfo.processInfo.environment
        guard let dirPath = env["STRUIS_E2E_DRIVER_DIR"] else { throw XCTSkip("検証専用の操作代行ランナー(STRUIS_E2E_DRIVER_DIR が無いときは動かさない)") }
        let dir: URL = URL(fileURLWithPath: dirPath)
        let cmdURL: URL = dir.appendingPathComponent("cmd.json")
        let resultURL: URL = dir.appendingPathComponent("result.txt")
        executionTimeAllowance = 60 * 60 * 6
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait

        let configuration: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/Struis.storekit")
        let session: SKTestSession = try SKTestSession(contentsOf: configuration)
        session.disableDialogs = true
        if env["STRUIS_E2E_STORE_KEEP"] == nil { session.clearTransactions() }
        storeSession = session

        let app: XCUIApplication = XCUIApplication()
        let prefix: String = "STRUIS_E2E_APP_ENV_"
        var baseEnvironment: [String: String] = [:]
        for (key, value) in env where key.hasPrefix(prefix) {
            baseEnvironment[String(key.dropFirst(prefix.count))] = value
        }
        let springboard: XCUIApplication = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try? FileManager.default.removeItem(at: cmdURL)
        write("ready", to: resultURL)

        func host(_ command: Command) -> XCUIApplication {
            guard let bundle = command.bundle else { return app }
            return bundle == "springboard" ? springboard : XCUIApplication(bundleIdentifier: bundle)
        }
        func point(_ target: XCUIApplication, _ x: Double, _ y: Double) -> XCUICoordinate {
            target.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }
        func element(_ target: XCUIApplication, _ key: String, contains: Bool) -> XCUIElement {
            let screen: CGRect = target.frame
            let all: XCUIElementQuery = target.descendants(matching: .any)
            let queries: [XCUIElementQuery] = contains
                ? [all.matching(NSPredicate(format: "label CONTAINS %@", key))]
                : [all.matching(identifier: key), all.matching(NSPredicate(format: "label == %@", key))]
            for query in queries {
                for candidate in query.allElementsBoundByIndex where candidate.exists {
                    let frame: CGRect = candidate.frame
                    if !frame.isEmpty, screen.intersects(frame), frame.minX >= 0, candidate.isHittable { return candidate }
                }
            }
            return queries[0].firstMatch
        }

        while true {
            guard let data = try? Data(contentsOf: cmdURL),
                  let command = try? JSONDecoder().decode(Command.self, from: data) else {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            try? FileManager.default.removeItem(at: cmdURL)
            var result: String = "ok"
            let target: XCUIApplication = host(command)
            let needsApp: Bool = !["launch", "activate", "quit", "sleep", "home", "store", "orientation"].contains(command.op)
            if needsApp, command.bundle == nil, app.state == .notRunning {
                write("\(command.seq) app not running", to: resultURL)
                continue
            }
            switch command.op {
            case "launch":
                app.launchArguments = command.args ?? []
                var environment: [String: String] = baseEnvironment
                for (key, value) in command.env ?? [:] {
                    if value == "__unset__" { environment.removeValue(forKey: key) } else { environment[key] = value }
                }
                app.launchEnvironment = environment
                app.launch()
            case "activate":
                target.activate()
            case "home":
                XCUIDevice.shared.press(.home)
            case "terminate":
                target.terminate()
            case "state":
                result = "state \(target.state.rawValue)"
            case "tap":
                point(target, command.x ?? 0, command.y ?? 0).tap()
            case "doubletap":
                point(target, command.x ?? 0, command.y ?? 0).doubleTap()
            case "press":
                point(target, command.x ?? 0, command.y ?? 0).press(forDuration: command.duration ?? 1)
            case "drag":
                point(target, command.x ?? 0, command.y ?? 0)
                    .press(forDuration: command.duration ?? 0.05, thenDragTo: point(target, command.x2 ?? 0, command.y2 ?? 0))
            case "flick":
                point(target, command.x ?? 0, command.y ?? 0)
                    .press(forDuration: 0.02, thenDragTo: point(target, command.x2 ?? 0, command.y2 ?? 0), withVelocity: .fast, thenHoldForDuration: 0)
            case "tapid", "taplabel":
                let found: XCUIElement = element(target, command.id ?? "", contains: command.op == "taplabel")
                if found.appears(timeout: command.timeout ?? 5) {
                    found.tap()
                } else {
                    result = "missing \(command.id ?? "")"
                }
            case "wait", "waitlabel":
                let found: XCUIElement = element(target, command.id ?? "", contains: command.op == "waitlabel")
                result = found.appears(timeout: command.timeout ?? 30) ? "exists" : "missing"
            case "gone":
                let found: XCUIElement = element(target, command.id ?? "", contains: false)
                result = found.waitForNonExistence(timeout: command.timeout ?? 30) ? "gone" : "still"
            case "type":
                if target.keyboards.count > 0 {
                    target.typeText(command.text ?? "")
                } else {
                    result = "no keyboard"
                }
            case "ink":
                let strokes: [[[Double]]] = command.strokes ?? []
                var mode: String = "segments"
                if command.text == "path" {
                    if let reason = Self.synthesize(strokes: strokes, speed: command.duration ?? 500) {
                        result = "path unavailable: \(reason)"
                        break
                    }
                    mode = "path"
                } else {
                    for stroke in strokes {
                        guard let first = stroke.first, first.count >= 2 else { continue }
                        if stroke.count == 1 {
                            point(target, first[0], first[1]).tap()
                            continue
                        }
                        for index in 0..<(stroke.count - 1) {
                            let from: [Double] = stroke[index]
                            let to: [Double] = stroke[index + 1]
                            point(target, from[0], from[1]).press(
                                forDuration: 0.01, thenDragTo: point(target, to[0], to[1]), withVelocity: .fast, thenHoldForDuration: 0)
                        }
                    }
                }
                result = "ok \(mode) \(strokes.count) strokes"
            case "snap":
                do {
                    let snapshot: any XCUIElementSnapshot = try target.snapshot()
                    let screen: CGRect = snapshot.frame
                    var lines: [String] = []
                    func clean(_ value: String) -> String {
                        value.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: " ")
                    }
                    func walk(_ node: any XCUIElementSnapshot) {
                        let frame: CGRect = node.frame
                        let value: String = (node.value as? String) ?? node.value.map { "\($0)" } ?? ""
                        if !(node.label.isEmpty && node.identifier.isEmpty && value.isEmpty), !frame.isEmpty, frame.intersects(screen) {
                            lines.append([
                                "\(node.elementType.rawValue)", clean(node.identifier), clean(node.label), clean(value),
                                "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))",
                                node.isEnabled ? "" : "disabled",
                            ].joined(separator: "\t"))
                        }
                        for child in node.children { walk(child) }
                    }
                    walk(snapshot)
                    let url: URL = dir.appendingPathComponent("\(command.name ?? "snap").tsv")
                    write(lines.joined(separator: "\n"), to: url)
                    result = url.path
                } catch {
                    result = "snap failed \(error)"
                }
            case "alert":
                let label: String = command.text ?? "許可"
                let button: XCUIElement = springboard.buttons[label].firstMatch
                if button.appears(timeout: command.timeout ?? 3) {
                    button.tap()
                } else {
                    result = "no alert button \(label)"
                }
            case "store":
                switch command.text ?? "" {
                case "clear": session.clearTransactions()
                case "dialogs-on": session.disableDialogs = false
                case "dialogs-off": session.disableDialogs = true
                case "expire":
                    do { try session.expireSubscription(productIdentifier: command.id ?? "") } catch { result = "expire failed \(error)" }
                case "list":
                    result = "transactions " + session.allTransactions().map { "\($0.productIdentifier):\($0.state.rawValue)" }.joined(separator: ",")
                default: result = "unknown store op"
                }
            case "orientation":
                XCUIDevice.shared.orientation = command.text == "landscape" ? .landscapeLeft : .portrait
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

    /// 1 本の線を、途中で指を離さずに書く(XCTest の非公開の入力の合成)。使えなければ理由を返す(呼び出し側は線分ごとのドラッグに切り替える)。
    @MainActor
    private static func synthesize(strokes: [[[Double]]], speed: Double) -> String? {
        guard let pathClass: AnyClass = NSClassFromString("XCPointerEventPath"),
              let recordClass: AnyClass = NSClassFromString("XCSynthesizedEventRecord") else { return "classes missing" }
        let initTouchSelector: Selector = NSSelectorFromString("initForTouchAtPoint:offset:")
        let moveSelector: Selector = NSSelectorFromString("moveToPoint:atOffset:")
        let liftSelector: Selector = NSSelectorFromString("liftUpAtOffset:")
        let initRecordSelector: Selector = NSSelectorFromString("initWithName:interfaceOrientation:")
        let addSelector: Selector = NSSelectorFromString("addPointerEventPath:")
        let synthesizeSelector: Selector = NSSelectorFromString("synthesizeWithError:")
        guard let initTouchMethod = class_getInstanceMethod(pathClass, initTouchSelector),
              let moveMethod = class_getInstanceMethod(pathClass, moveSelector),
              let liftMethod = class_getInstanceMethod(pathClass, liftSelector),
              let initRecordMethod = class_getInstanceMethod(recordClass, initRecordSelector),
              let addMethod = class_getInstanceMethod(recordClass, addSelector),
              let synthesizeMethod = class_getInstanceMethod(recordClass, synthesizeSelector) else { return "selectors missing" }
        typealias InitTouch = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Unmanaged<AnyObject>
        typealias Move = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias Lift = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias InitRecord = @convention(c) (AnyObject, Selector, NSString, Int) -> Unmanaged<AnyObject>
        typealias Add = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Synthesize = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer?) -> Bool
        let initTouch: InitTouch = unsafeBitCast(method_getImplementation(initTouchMethod), to: InitTouch.self)
        let move: Move = unsafeBitCast(method_getImplementation(moveMethod), to: Move.self)
        let lift: Lift = unsafeBitCast(method_getImplementation(liftMethod), to: Lift.self)
        let initRecord: InitRecord = unsafeBitCast(method_getImplementation(initRecordMethod), to: InitRecord.self)
        let add: Add = unsafeBitCast(method_getImplementation(addMethod), to: Add.self)
        let synthesizeRecord: Synthesize = unsafeBitCast(method_getImplementation(synthesizeMethod), to: Synthesize.self)
        let allocSelector: Selector = NSSelectorFromString("alloc")
        for stroke in strokes {
            guard let first = stroke.first, first.count >= 2 else { continue }
            guard let rawPath = (pathClass as AnyObject).perform(allocSelector)?.takeUnretainedValue(),
                  let rawRecord = (recordClass as AnyObject).perform(allocSelector)?.takeUnretainedValue() else { return "alloc failed" }
            let path: AnyObject = initTouch(rawPath, initTouchSelector, CGPoint(x: first[0], y: first[1]), 0).takeUnretainedValue()
            var offset: Double = 0.05
            var last: CGPoint = CGPoint(x: first[0], y: first[1])
            for sample in stroke.dropFirst() where sample.count >= 2 {
                let next: CGPoint = CGPoint(x: sample[0], y: sample[1])
                offset += max(0.012, Double(hypot(next.x - last.x, next.y - last.y)) / max(speed, 50))
                move(path, moveSelector, next, offset)
                last = next
            }
            lift(path, liftSelector, offset + 0.04)
            let record: AnyObject = initRecord(rawRecord, initRecordSelector, "ink" as NSString, 1).takeUnretainedValue()
            add(record, addSelector, path)
            if !synthesizeRecord(record, synthesizeSelector, nil) { return "synthesize failed" }
        }
        return nil
    }

    private func write(_ text: String, to url: URL) {
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
