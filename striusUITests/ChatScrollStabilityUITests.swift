import XCTest

/// 会話のスクロールの安定(2026-10-07): 指を離した後に会話が勝手に動かない(ワープしない)、数式の吹き出しの上から
/// 始めた縦のドラッグでも会話が動く(止まらない)、左右のスワイプで別のページへ動かない(旧・分岐や答案のページは無い)。
/// 小単元 1 の 40 往復の数式入りの会話(`-workbook-long-chat`)を、初めて開く状態(数式の画像がまだ無い)で使う。
final class ChatScrollStabilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func launchLongChat(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-skip-onboarding", "-workbook-long-chat", "-workbook-model-stage", "-katex-fresh"]
        app.launchEnvironment.merge(environment) { $1 }
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launch()
        let row = app.descendants(matching: .any)["workbook-subunit-sub-1"].firstMatch
        XCTAssertTrue(row.appears(timeout: 30), "ホームに小単元の行が無い")
        row.tap()
        XCTAssertTrue(app.scrollViews["chat-page"].firstMatch.appears(timeout: 20), "会話が出ない")
        return app
    }

    /// 見えている吹き出しの位置(識別子 → 画面上の y)。1 回の snapshot で読む(要素ごとに問い合わせない)。
    /// 画面の枠は snapshot の根(アプリ)の枠を使い、窓を別に探さない(要素の検索はアプリのメインスレッドで木を作るので、
    /// 数式の WebView が多い会話では 1 回ごとに数秒かかることがある)。
    @MainActor
    private func bubbleOrigins(_ app: XCUIApplication) -> [String: CGFloat] {
        guard let root = try? app.snapshot() else { return [:] }
        let screen = root.frame
        var result: [String: CGFloat] = [:]
        var stack: [XCUIElementSnapshot] = [root]
        var layout: [String] = []
        while let node = stack.popLast() {
            if node.identifier.hasPrefix("assistant-message-"), node.frame.intersects(screen), node.frame.height > 0 {
                result[node.identifier] = node.frame.minY
            } else if node.identifier == "chat-page", node.elementType == .scrollView {
                layout.append("page:\(Int(node.frame.minY))+\(Int(node.frame.height))")
            } else if node.identifier == "workbook-subunit-header" {
                layout.append("header:\(Int(node.frame.maxY))")
            }
            stack.append(contentsOf: node.children)
        }
        lastLayout = layout.sorted().joined(separator: ",")
        return result
    }

    /// 最後の `bubbleOrigins` で見えた会話の枠と小単元のヘッダーの下端(吹き出しが動いた時に、会話の枠ごと動いたのかを見分ける)。
    private var lastLayout = ""

    /// 2 つの読み取りで共通する吹き出しの、いちばん大きい縦の移動。
    private func maxShift(_ a: [String: CGFloat], _ b: [String: CGFloat]) -> CGFloat {
        a.keys.compactMap { key in b[key].map { abs($0 - a[key]!) } }.max() ?? 0
    }

    /// 会話の枠の中の点(0〜1 の割合)を、アプリを起点にした座標にする。会話の枠は最初に 1 回だけ読む。
    /// 会話の ScrollView を起点にした座標は、指を動かすたびに ScrollView を探し直す(1 回のドラッグで 5 回以上)ので、
    /// 何度もドラッグする観測ではこちらを使う。
    @MainActor
    private func pagePoints(_ app: XCUIApplication) -> (CGFloat, CGFloat) -> XCUICoordinate {
        let frame = app.scrollViews["chat-page"].firstMatch.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        return { x, y in origin.withOffset(CGVector(dx: frame.minX + frame.width * x, dy: frame.minY + frame.height * y)) }
    }

    /// 指を離した後(慣性も止まった後)に、会話の中身が動かない。上へ読み返す 8 回のドラッグで確かめる。
    @MainActor
    func testConversationDoesNotJumpAfterTheFingerLifts() throws {
        let app = launchLongChat()
        Thread.sleep(forTimeInterval: 4)
        let point = pagePoints(app)
        var jumps: [CGFloat] = []
        for step in 0..<8 {
            point(0.5, 0.3).press(forDuration: 0.05, thenDragTo: point(0.5, 0.75), withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 0.6)
            let settled = bubbleOrigins(app)
            var later = settled
            var trace: [String] = []
            for _ in 0..<6 {
                Thread.sleep(forTimeInterval: 0.5)
                let sample = bubbleOrigins(app)
                trace.append(sample.sorted { $0.value < $1.value }.map { "\($0.key.suffix(4)):\(Int($0.value))" }.joined(separator: ",") + " " + lastLayout)
                later = sample
            }
            let shift = maxShift(settled, later)
            jumps.append(shift)
            let first = settled.sorted { $0.value < $1.value }.map { "\($0.key.suffix(4)):\(Int($0.value))" }.joined(separator: ",")
            print("PROBE jump step=\(step) shift=\(shift) t0=[\(first)] trace=\(trace.map { "[\($0)]" }.joined(separator: " "))")
            if shift > 2 { attach(app, "jump-step-\(step)") }
        }
        print("PROBE jumps=\(jumps.map { Int($0.rounded()) })")
        XCTAssertLessThanOrEqual(jumps.max() ?? 0, 2, "指を離した後に会話が動いた(跳んだ): \(jumps.map { Int($0.rounded()) })")
    }

    /// 画面の中ほどにある数式の WebView の枠(1 回の snapshot で探す)。枠の一部が小単元のヘッダーの裏にあるものは選ばない
    /// (枠の中ほどがヘッダーに覆われていると、指がヘッダーに当たり数式の吹き出しに届かない)。
    @MainActor
    private func mathFrame(_ app: XCUIApplication) -> CGRect? {
        let header = app.descendants(matching: .any)["workbook-subunit-header"].firstMatch
        let visibleTop = header.exists ? header.frame.maxY : 0
        guard let root = try? app.snapshot() else { return nil }
        let screen = app.windows.firstMatch.frame
        var stack: [XCUIElementSnapshot] = [root]
        var found: [CGRect] = []
        while let node = stack.popLast() {
            if node.elementType == .webView, node.frame.height > 12,
               node.frame.minY > max(screen.height * 0.25, visibleTop), node.frame.maxY < screen.height * 0.7 {
                found.append(node.frame)
            }
            stack.append(contentsOf: node.children)
        }
        return found.min { $0.minY < $1.minY }
    }

    /// 開いた直後の最初のドラッグが、指の動きどおりに会話を動かす(位置の基準の切り替えで止めない)。
    @MainActor
    func testFirstDragAfterOpeningFollowsTheFinger() throws {
        let app = launchLongChat()
        Thread.sleep(forTimeInterval: 3)
        let page = app.scrollViews["chat-page"].firstMatch
        var moves: [Int] = []
        for _ in 0..<3 {
            let before = bubbleOrigins(app)
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)), withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 0.8)
            moves.append(Int(maxShift(before, bubbleOrigins(app)).rounded()))
        }
        let expected = Int((page.frame.height * 0.25).rounded())
        print("PROBE firstdrag expected=\(expected) moves=\(moves)")
        XCTAssertGreaterThan(moves.first ?? 0, expected / 2, "開いた直後の最初のドラッグで会話が動かない: \(moves)")
    }

    /// 数式の吹き出し(WebView)の上から始めた縦のドラッグでも、会話がスクロールする。
    @MainActor
    func testDragStartingOnMathBubbleScrollsTheConversation() throws {
        let app = launchLongChat()
        Thread.sleep(forTimeInterval: 2)
        let page = app.scrollViews["chat-page"].firstMatch
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        var stalls = 0
        var tried = 0
        for step in 0..<8 {
            guard let frame = mathFrame(app) else {
                page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                    .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)), withVelocity: .slow, thenHoldForDuration: 0.3)
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            tried += 1
            let before = bubbleOrigins(app)
            let start = origin.withOffset(CGVector(dx: frame.minX + min(60, frame.width / 2), dy: frame.midY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 220)), withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 0.8)
            let after = bubbleOrigins(app)
            let moved = maxShift(before, after)
            print("PROBE mathdrag step=\(step) moved=\(moved)")
            if moved < 60 {
                stalls += 1
                attach(app, "math-drag-stalled-\(step)")
            }
        }
        print("PROBE mathdrag tried=\(tried) stalls=\(stalls)")
        XCTAssertGreaterThan(tried, 0, "数式の吹き出しが見つからない")
        XCTAssertEqual(stalls, 0, "数式の吹き出しの上からのドラッグで会話が動かなかった")
    }

    /// 小単元の会話で左右にスワイプしても、別のページ(旧・分岐のページ)へ動かない。右へのスワイプは
    /// システムの「戻る」(ホームへ戻る)としてだけ働く。
    @MainActor
    func testHorizontalSwipeInSubunitConversationStaysOnTheConversation() throws {
        let app = launchLongChat()
        let page = app.scrollViews["chat-page"].firstMatch
        let input = app.textViews.matching(identifier: "chat-page").firstMatch
        XCTAssertTrue(input.appears(timeout: 10))
        let before = input.frame
        page.swipeLeft()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(input.exists && input.isHittable, "左へのスワイプで会話の入力欄が消えた")
        if input.exists { XCTAssertEqual(input.frame.minX, before.minX, accuracy: 1, "左へのスワイプで会話が横に動いた") }
        page.swipeRight()
        Thread.sleep(forTimeInterval: 1.5)
        let branchShown = app.scrollViews["branch-page"].exists
        let stayed = input.exists && input.isHittable
        let wentHome = app.descendants(matching: .any)["workbook-subunit-sub-1"].firstMatch.isHittable
        print("PROBE swipe branchPage=\(branchShown) stayed=\(stayed) wentHome=\(wentHome)")
        attach(app, "after-swipe-right")
        XCTAssertFalse(branchShown, "右へのスワイプで分岐のページが出た")
        XCTAssertTrue(stayed || wentHome, "右へのスワイプで会話でもホームでもない所へ動いた")
    }

    /// 送った後に上へ読み返している間に返事が出来上がっても、読んでいる所から引き戻さない。送った直後は自分の
    /// メッセージまで送られ、返事が出来上がった時に下の方を見ていれば返事の頭が見える。
    @MainActor
    func testReadingBackIsNotPulledWhenTheReplyArrives() throws {
        let app = launchLongChat(environment: ["STRUIS_MOCK_TURN_DELAY_MS": "6000"])
        Thread.sleep(forTimeInterval: 3)
        let input = app.textViews.matching(identifier: "chat-page").firstMatch
        XCTAssertTrue(input.appears(timeout: 10))
        input.tap()
        input.typeText("読み返しの確認")
        let send = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "送信", "chat-page")).firstMatch
        XCTAssertTrue(send.appears(timeout: 5))
        send.press(forDuration: 0.15)
        let sent = app.staticTexts["読み返しの確認"].firstMatch
        XCTAssertTrue(sent.appears(timeout: 10), "送った文が出ない")
        XCTAssertTrue(sent.isHittable, "送った直後に自分のメッセージまで送られない")
        // 返事を待っている間に、キーボードを閉じて上へ読み返す。
        let page = app.scrollViews["chat-page"].firstMatch
        for _ in 0..<3 {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        Thread.sleep(forTimeInterval: 0.6)
        let reading = bubbleOrigins(app)
        // 返事が出来上がるまで待つ(モックは 6 秒)。
        Thread.sleep(forTimeInterval: 9)
        let after = bubbleOrigins(app)
        let common = Set(reading.keys).intersection(after.keys).count
        let shift = maxShift(reading, after)
        print("PROBE readback common=\(common) shift=\(shift)")
        attach(app, "reading-back-after-reply")
        XCTAssertGreaterThan(common, 0, "読み返していた吹き出しが画面から消えた(引き戻された)")
        XCTAssertLessThanOrEqual(shift, 2, "返事が出来上がった時に、読み返している会話が動いた")
    }

    /// 横にはみ出す表示用の数式(D5)は、WebView 自体のスクロールを止めた後も、横にドラッグして続きを読める。
    /// 表示用の数式(背の高い WebView)を横にドラッグし、その WebView の見た目が変わる(中身が横に動く)ものがあることを確かめる。
    @MainActor
    func testOverflowingDisplayMathStillScrollsSideways() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-skip-onboarding", "-screens-fixture", "-workbook-model-stage", "-katex-fresh"]
        app.launchEnvironment["STRUIS_DEVICE_TURNS"] = "mock"
        app.launchEnvironment["STRUIS_DEVICE_RUNTIME"] = "0"
        app.launch()
        let row = app.descendants(matching: .any)["workbook-subunit-sub-1"].firstMatch
        XCTAssertTrue(row.appears(timeout: 30))
        row.tap()
        let page = app.scrollViews["chat-page"].firstMatch
        XCTAssertTrue(page.appears(timeout: 20))
        let screen = app.windows.firstMatch.frame
        var tried = Set<String>()
        var scrolled = false
        for _ in 0..<10 where !scrolled {
            Thread.sleep(forTimeInterval: 3)
            // 背の高い WebView(表示用の数式を含む吹き出し)から試す。
            let webs = app.webViews.allElementsBoundByIndex.filter {
                $0.exists && $0.frame.height > 30 && $0.frame.maxY > screen.height * 0.2 && $0.frame.minY < screen.height * 0.75
            }.sorted { $0.frame.height > $1.frame.height }
            for web in webs where !scrolled {
                // 吹き出しの上が見出しに隠れていると、隠れた行には指が届かず試せない。吹き出しが見える範囲に収まるなら、
                // 先に上端が見えるまで会話を下へ送る(送らないと、ほかの吹き出しを全部試してから会話を送ることになる)。
                let hidden = visibleBand(app, screen: screen)
                if web.frame.minY < hidden.lowerBound, web.frame.height < hidden.upperBound - hidden.lowerBound - 24 {
                    let from = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                    from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: hidden.lowerBound + 24 - web.frame.minY)),
                               withVelocity: .slow, thenHoldForDuration: 0.5)
                    Thread.sleep(forTimeInterval: 1)
                    guard web.exists else { continue }
                }
                let key = "\(Int(web.frame.minY))-\(Int(web.frame.height))-\(web.label)"
                guard tried.insert(key).inserted else { continue }
                // 吹き出し全体が 1 つの WebView なので、表示用の数式の行に当たるよう縦の位置を 22pt おきに変えて試す。
                // 描画の途中の変化を数えないよう、見た目が落ち着いてから比べ、左へ動いた後に右へ戻すとまた変わる(往復する)ことを見る。
                // 比べるのは WebView のうち会話に見えている部分だけ(枠が見出しや状態バーの裏まで伸びていると、時計や見出しの
                // 変化まで数えてしまう)。指を置くのもその中だけにする(見出しの上から始めた指は数式に届かない)。
                let band = visibleBand(app, screen: screen)
                let settledA = visibleImage(app, web, band: band)?.pngData()
                Thread.sleep(forTimeInterval: 1)
                guard settledA != nil, visibleImage(app, web, band: band)?.pngData() == settledA else { tried.remove(key); continue }
                let rows = max(1, Int(web.frame.height / 22))
                for row in 0..<rows where !scrolled && web.exists {
                    let dy = (CGFloat(row) + 0.5) / CGFloat(rows)
                    let y = web.frame.minY + web.frame.height * dy
                    guard y > max(screen.height * 0.2, band.lowerBound + 4), y < screen.height * 0.75 else { continue }
                    guard let before = visibleImage(app, web, band: band) else { break }
                    let start = web.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: dy))
                    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -200, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)
                    Thread.sleep(forTimeInterval: 0.6)
                    guard let moved = visibleImage(app, web, band: band) else { break }
                    guard moved.pngData() != before.pngData() else { continue }
                    let back = web.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: dy))
                    back.press(forDuration: 0.05, thenDragTo: back.withOffset(CGVector(dx: 200, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)
                    Thread.sleep(forTimeInterval: 0.6)
                    guard let returned = visibleImage(app, web, band: band) else { break }
                    let reversible = returned.pngData() != moved.pngData()
                    print("PROBE overflow candidate h=\(Int(web.frame.height)) row=\(row) movedLeft=true movedBack=\(reversible)")
                    if reversible {
                        scrolled = true
                        for (name, shot) in [("overflow-math-before", before), ("overflow-math-scrolled-left", moved), ("overflow-math-scrolled-back", returned)] {
                            let attachment = XCTAttachment(image: shot)
                            attachment.name = name
                            attachment.lifetime = .keepAlways
                            add(attachment)
                        }
                    }
                }
            }
            if !scrolled {
                page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)), withVelocity: .slow, thenHoldForDuration: 0.3)
            }
        }
        print("PROBE overflow scrolled=\(scrolled) tried=\(tried.count)")
        XCTAssertTrue(scrolled, "はみ出す表示用の数式を横に動かせない(または見つからない)")
    }

    /// 会話のうち、ほかの部品に覆われずに見えている縦の範囲(小単元のヘッダーの下端から、入力欄と「先に進む」の上まで)。
    @MainActor
    private func visibleBand(_ app: XCUIApplication, screen: CGRect) -> ClosedRange<CGFloat> {
        let header = app.descendants(matching: .any)["workbook-subunit-header"].firstMatch
        let top = header.exists ? header.frame.maxY : app.scrollViews["chat-page"].firstMatch.frame.minY
        return top...max(top, screen.height * 0.75)
    }

    /// WebView のうち `band` に入っている部分の画像(画面の写真から切り出す)。WebView が無ければ nil。
    @MainActor
    private func visibleImage(_ app: XCUIApplication, _ web: XCUIElement, band: ClosedRange<CGFloat>) -> UIImage? {
        guard web.exists else { return nil }
        let frame = web.frame
        let minY = max(frame.minY, band.lowerBound)
        let maxY = min(frame.maxY, band.upperBound)
        guard maxY - minY > 1 else { return nil }
        let image = app.screenshot().image
        guard let cgImage = image.cgImage else { return nil }
        let scale = CGFloat(cgImage.width) / app.windows.firstMatch.frame.width
        let rect = CGRect(x: frame.minX * scale, y: minY * scale, width: frame.width * scale, height: (maxY - minY) * scale).integral
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: .up)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
