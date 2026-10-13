import SwiftUI
import WebKit
import CryptoKit

/// 本文と数式を描く。数式を含む本文は KaTeX(WebView)で描く。
///
/// 数式の吹き出しが空のまま待たされないように(K1、2026-10-03 作り直し):
/// - 描き終えた見た目を画像として端末に残し(`KaTeXSnapshotStore`)、次に同じ本文を出す時は WebView を作らずに画像で出す。
///   再起動の後に長い会話を開いても、WebView の起動や KaTeX の読み込みを待たない。
/// - 画像がまだ無い本文は、WebView が描き終えるまで、数式を読める文字に直した仮の文字(`MathPlainText`)を出す(空にしない)。
/// - WebView は保存領域を共有し、KaTeX の JS・CSS と描画のスクリプトは同梱のファイルから読む(HTML に毎回埋め込まない)。
///   本文が変わった時はページを読み込み直さず、描き直すだけにする。
/// - 横にはみ出す数式(D5)は隠さず横スクロールにし、右端を薄くして続きがあることを示す。はみ出す本文は画像だけにせず、
///   WebView を残して横に動かせるようにする。
struct KaTeXMathText: View {
    let raw: String
    let display: Bool
    let foregroundColor: UIColor
    let fontSize: CGFloat
    let fontWeight: Int
    /// 先頭から何個の数式・強調に淡い面の色をつけるか(§6: 要点から例題へ運ぶ語の元の箇所)。
    /// 数え方は `StruisMarkedSpans.spans` と同じ。描き直さずに色だけを変える。
    let highlightCount: Int

    init(
        _ raw: String,
        display: Bool = false,
        foregroundColor: UIColor,
        fontSize: CGFloat = 15,
        fontWeight: Int = 500,
        highlightCount: Int = 0
    ) {
        self.raw = raw
        self.display = display
        self.foregroundColor = foregroundColor
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.highlightCount = highlightCount
    }

    var body: some View {
        if raw.needsKaTeX || display {
            KaTeXRenderedText(
                raw: raw, display: display, foregroundColor: foregroundColor, fontSize: fontSize,
                fontWeight: fontWeight, highlightCount: highlightCount
            )
        } else if highlightCount > 0 {
            Text(StruisMarkedSpans.highlighted(raw.replacingOccurrences(of: "\\n", with: "\n"), count: highlightCount))
                .font(Typography.sans(size: fontSize, weight: fontWeight >= 500 ? .medium : .regular))
                .foregroundStyle(Color(foregroundColor))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            Text(StruisInlineMarkdown.attributed(raw.replacingOccurrences(of: "\\n", with: "\n")))
                .font(Typography.sans(size: fontSize, weight: fontWeight >= 500 ? .medium : .regular))
                .foregroundStyle(Color(foregroundColor))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// 数式の無い本文の強調(`**…**`)を太字にする。WebView の描き方(`renderTextMarkdown`)と同じく強調だけを読み、
/// ほかの記号はそのまま残す(穴埋めの `____` を強調と取り違えないよう、`__` は読まない)。
enum StruisInlineMarkdown {
    static func attributed(_ text: String) -> AttributedString {
        guard text.contains("**") else { return AttributedString(text) }
        var result = AttributedString()
        var strong = false
        var rest = Substring(text)
        func append(_ part: Substring) {
            guard !part.isEmpty else { return }
            var piece = AttributedString(String(part))
            if strong { piece.inlinePresentationIntent = .stronglyEmphasized }
            result += piece
        }
        while let range = rest.range(of: "**") {
            append(rest[..<range.lowerBound])
            strong.toggle()
            rest = rest[range.upperBound...]
        }
        append(rest)
        return result
    }
}

/// 数式を含む本文。描き終えた画像があれば画像、無ければ WebView(描き終わるまでは仮の文字)。
private struct KaTeXRenderedText: View {
    let raw: String
    let display: Bool
    let foregroundColor: UIColor
    let fontSize: CGFloat
    let fontWeight: Int
    let highlightCount: Int

    @Environment(\.displayScale) private var displayScale
    @State private var width: CGFloat = 0
    /// WebView が描き終えて高さを測った本文と、その高さ。
    @State private var rendered: (key: String, height: CGFloat)?

    private var key: String {
        KaTeXLayoutCache.renderKey(raw: raw, display: display, color: foregroundColor, fontSize: fontSize, fontWeight: fontWeight)
    }

    var body: some View {
        let key = key
        let webReady = rendered?.key == key
        // WebView が描き終えた後は、そのまま WebView を使う(画像との入れ替えで見た目を揺らさない)。
        let snapshot = webReady || width <= 0 ? nil : KaTeXSnapshotStore.shared.snapshot(for: key, width: width, scale: displayScale)
        let needsWeb = width > 0 && (webReady || snapshot == nil || snapshot?.interactive == true || highlightCount > 0)
        // 描き終えた高さが分かっている(画像・前に測った高さ)間は、仮の文字もその高さに揃える。WebView が描き終えて
        // 仮の文字と入れ替わる時に行の高さが変わると、会話のスクロール位置がずれて画面が跳ぶ。
        let settledHeight: CGFloat? = webReady ? nil : snapshot?.size.height ?? KaTeXLayoutCache.height(for: key, width: width)
        ZStack(alignment: .topLeading) {
            if needsWeb {
                KaTeXWebView(
                    raw: raw, display: display, foregroundColor: foregroundColor, fontSize: fontSize, fontWeight: fontWeight,
                    highlightCount: highlightCount, renderKey: key, availableWidth: width
                ) { renderedKey, height in
                    guard renderedKey == self.key else { return }
                    if rendered?.key != renderedKey || abs((rendered?.height ?? 0) - height) >= 1 {
                        rendered = (renderedKey, height)
                    }
                }
                .frame(height: webHeight(key: key, snapshot: snapshot))
                .opacity(webReady ? 1 : 0)
                .allowsHitTesting(webReady)
                .accessibilityHidden(!webReady)
            }
            if !webReady {
                if let snapshot {
                    snapshotImage(snapshot)
                } else {
                    placeholder
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: settledHeight, alignment: .top)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .transaction { $0.animation = nil }
    }

    private func webHeight(key: String, snapshot: KaTeXSnapshot?) -> CGFloat {
        if let rendered, rendered.key == key { return rendered.height }
        if let snapshot { return snapshot.size.height }
        return KaTeXLayoutCache.height(for: key, width: width) ?? fontSize * 1.58
    }

    private var readable: String {
        MathPlainText.readable(raw.replacingOccurrences(of: "\\n", with: "\n"))
    }

    /// 描き終えた画像。VoiceOver には読める文字で、長押しで文字を写せる。
    private func snapshotImage(_ snapshot: KaTeXSnapshot) -> some View {
        Image(uiImage: snapshot.image)
            .resizable()
            .frame(width: snapshot.size.width, height: snapshot.size.height)
            .accessibilityRepresentation { Text(readable) }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = readable
                } label: {
                    Label("コピー", systemImage: "doc.on.doc")
                }
            }
    }

    /// WebView が描き終えるまでの仮の文字。空の吹き出しにしない(K1)。
    private var placeholder: some View {
        Text(readable)
            .font(Typography.sans(size: fontSize, weight: fontWeight >= 500 ? .medium : .regular))
            .foregroundStyle(Color(foregroundColor))
            .lineSpacing(fontSize * 0.25)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("katex-placeholder")
    }
}

private struct KaTeXWebView: UIViewRepresentable {
    let raw: String
    let display: Bool
    let foregroundColor: UIColor
    let fontSize: CGFloat
    let fontWeight: Int
    let highlightCount: Int
    let renderKey: String
    let availableWidth: CGFloat
    let onRendered: (String, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "height")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        // 保存領域は全 WebView で 1 つを共有する(1 通ごとに作らない)。
        configuration.websiteDataStore = KaTeXWebEnvironment.dataStore
        configuration.allowsInlineMediaPlayback = false
        configuration.suppressesIncrementalRendering = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // WebView 自体はスクロールさせない(高さは本文に合わせてある)。測った高さとの 1pt 未満のずれでも縦にスクロールできると、
        // 吹き出しの上から始めた縦のドラッグを WebView が取り、会話のスクロールが止まる。横にはみ出す数式は、ページの中の
        // 横スクロールの要素(`struis-math.css` の `overflow-x: auto`)が動かす。
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onRendered = onRendered
        let widthChanged = coordinator.availableWidth != availableWidth
        coordinator.availableWidth = availableWidth
        coordinator.applyHighlight(highlightCount)
        guard coordinator.renderKey != renderKey else {
            if widthChanged {
                webView.evaluateJavaScript("if (typeof struisNotifyHeight !== 'undefined') struisNotifyHeight()")
            }
            return
        }
        coordinator.renderKey = renderKey
        coordinator.appliedHighlight = highlightCount
        let options = renderOptions
        coordinator.lastOptions = options
        if coordinator.pageReady {
            // ページは読み込み済み: 本文だけを描き直す。
            webView.evaluateJavaScript("struisRender(\(options))")
        } else {
            webView.loadHTMLString(KaTeXWebEnvironment.shell(initialRender: options), baseURL: KaTeXWebEnvironment.baseURL)
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelSnapshot()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "height")
    }

    private var renderOptions: String {
        let options: [String: Any] = [
            "source": raw, "display": display, "key": renderKey, "color": foregroundColor.hexString,
            "fontSize": Double(fontSize), "fontWeight": fontWeight, "highlight": highlightCount,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: options, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var renderKey: String?
        var availableWidth: CGFloat = 0
        var onRendered: ((String, CGFloat) -> Void)?
        weak var webView: WKWebView?
        /// 描画のスクリプトを読み込み終えたページか(以後は読み込み直さずに描き直す)。
        var pageReady = false
        /// 最後に描いた本文の引数(中身のプロセスが落ちた時に読み込み直す)。
        var lastOptions: String?
        /// 描き終えた本文に反映した色の数と、求められている数。
        var appliedHighlight = 0
        var wantedHighlight = 0
        private var loadedKey: String?
        private var lastMeasured: (key: String, width: CGFloat, height: CGFloat, overflow: Bool)?
        private var snapshotGeneration = 0

        func applyHighlight(_ count: Int) {
            wantedHighlight = count
            guard loadedKey == renderKey, appliedHighlight != count else { return }
            appliedHighlight = count
            webView?.evaluateJavaScript("if (typeof setStruisHighlight !== 'undefined') setStruisHighlight(\(count))")
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            pageReady = false
            loadedKey = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            pageReady = false
        }

        /// WebView の中身のプロセスが落ちた時は、読み込み直す(空のまま残さない)。
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            pageReady = false
            loadedKey = nil
            guard let lastOptions else { return }
            webView.loadHTMLString(KaTeXWebEnvironment.shell(initialRender: lastOptions), baseURL: KaTeXWebEnvironment.baseURL)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "height", let payload = message.body as? [String: Any] else { return }
            if payload["loaded"] as? Bool == true {
                pageReady = true
                loadedKey = payload["key"] as? String
                appliedHighlight = -1
                applyHighlight(wantedHighlight)
                return
            }
            guard let key = payload["key"] as? String, key == renderKey,
                  let width = payload["width"] as? Double,
                  let value = payload["height"] as? Double,
                  width > 0, value.isFinite, value > 0,
                  abs(width - availableWidth) < 2 else { return }
            let measured = CGFloat(value)
            let overflow = payload["overflow"] as? Bool ?? false
            KaTeXLayoutCache.store(measured, for: key, width: CGFloat(width))
            lastMeasured = (key, CGFloat(width), measured, overflow)
            onRendered?(key, measured)
            scheduleSnapshot()
        }

        func cancelSnapshot() {
            snapshotGeneration += 1
        }

        /// 描き終えた見た目を画像として残す。本文と幅と高さが落ち着いてから(フォントの読み込みで高さが変わる間は待つ)。
        /// 色をつけている間(§6)は残さない。
        private func scheduleSnapshot(attempt: Int = 0) {
            if attempt == 0 { snapshotGeneration += 1 }
            let generation = snapshotGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.6 : 1.0)) { [weak self] in
                guard let self, generation == self.snapshotGeneration else { return }
                // 画面の外にある間は撮らない(WebKit は見えていない所を描かないので、空の画像になる)。見えるまで待つ。
                if !self.takeSnapshotIfSettled(), attempt < 60 { self.scheduleSnapshot(attempt: attempt + 1) }
            }
        }

        /// 撮った(または撮る必要が無い)なら true。画面に全部が見えていない間は false。
        @discardableResult
        private func takeSnapshotIfSettled() -> Bool {
            guard let webView, let measured = lastMeasured, measured.key == renderKey,
                  wantedHighlight == 0, appliedHighlight == 0,
                  abs(webView.bounds.height - measured.height) < 1, abs(webView.bounds.width - measured.width) < 2
            else { return true }
            guard let window = webView.window, webView.alpha > 0.99, !webView.isHidden else { return false }
            let frame = webView.convert(webView.bounds, to: window).insetBy(dx: 1, dy: 1)
            guard window.bounds.contains(frame) else { return false }
            // 会話のスクロールの見えている範囲(進捗バーの下に切られる所を除く)に全部が入っている時だけ。
            var ancestor = webView.superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            if let scroller = ancestor as? UIScrollView,
               !scroller.convert(scroller.bounds, to: window).contains(frame) { return false }
            let scale = webView.window?.screen.scale ?? webView.traitCollection.displayScale
            guard !KaTeXSnapshotStore.shared.contains(key: measured.key, width: measured.width, scale: scale) else { return true }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            configuration.afterScreenUpdates = true
            let generation = snapshotGeneration
            webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                guard let self, let image, generation == self.snapshotGeneration, self.renderKey == measured.key else { return }
                KaTeXSnapshotStore.shared.store(image, interactive: measured.overflow, key: measured.key, width: measured.width, scale: scale)
            }
            return true
        }
    }
}

/// WebView の共有の持ち物。
@MainActor
private enum KaTeXWebEnvironment {
    /// 全 WebView で 1 つを共有する保存領域(以前は 1 通ごとに `.nonPersistent()` を作っていた)。
    static let dataStore = WKWebsiteDataStore.nonPersistent()
    static let baseURL = Bundle.main.resourceURL?.appendingPathComponent("KaTeX", isDirectory: true)

    /// 同梱のファイルを読むだけの小さなページ。本文は最初の描画の引数として渡す。
    static func shell(initialRender options: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <link rel="stylesheet" href="katex.min.css">
        <link rel="stylesheet" href="struis-math.css">
        <script src="katex.min.js"></script>
        <script src="struis-math.js"></script>
        </head>
        <body>
        <div id="root"></div>
        <script>struisRender(\(options.replacingOccurrences(of: "</", with: "<\\/")));</script>
        </body>
        </html>
        """
    }
}

private extension String {
    var needsKaTeX: Bool {
        contains("$") || contains("\\(") || contains("\\[") || contains("\\begin{")
    }
}

private extension UIColor {
    var hexString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "rgba(%d, %d, %d, %.3f)",
            Int(red * 255),
            Int(green * 255),
            Int(blue * 255),
            Double(alpha)
        )
    }
}

@MainActor
enum KaTeXLayoutCache {
    private static let cache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 256
        return cache
    }()

    static func renderKey(raw: String, display: Bool, color: UIColor, fontSize: CGFloat, fontWeight: Int) -> String {
        let source = [raw, String(display), color.hexString, String(describing: fontSize), String(fontWeight)].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func height(for key: String, width: CGFloat) -> CGFloat? {
        guard width > 0 else { return nil }
        return cache.object(forKey: "\(key):\(Int(width.rounded()))" as NSString).map { CGFloat($0.doubleValue) }
    }

    static func store(_ height: CGFloat, for key: String, width: CGFloat) {
        cache.setObject(NSNumber(value: Double(height)), forKey: "\(key):\(Int(width.rounded()))" as NSString)
    }

    /// サインアウトの時: 高さの記録と、描き終えた画像(学習者の会話の中身)を消す。
    static func clear() {
        cache.removeAllObjects()
        KaTeXSnapshotStore.shared.removeAll()
    }
}

/// 描き終えた数式の画像。
struct KaTeXSnapshot {
    let image: UIImage
    /// 横にはみ出す数式を含む(画像だけでは続きが読めないので、WebView も使う)。
    let interactive: Bool
    var size: CGSize { image.size }
}

/// 描き終えた数式の画像を、メモリと端末(Caches)に残す(K1)。鍵は本文・色・大きさ・幅・画面の倍率と描画の版。
/// 起動し直した後も、同じ本文は WebView を待たずに出せる。サインアウトで消す。
@MainActor
final class KaTeXSnapshotStore {
    static let shared = KaTeXSnapshotStore()
    /// 描画のスクリプト・CSS を変えたら上げる(古い画像を使わない)。
    static let rendererVersion = "2026-10-03.3"
    private static let fileLimit = 3_000

    private final class Box {
        let snapshot: KaTeXSnapshot
        init(_ snapshot: KaTeXSnapshot) { self.snapshot = snapshot }
    }

    private let memory: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private let directory: URL
    /// 端末にある画像の名前(拡張子なし)→ はみ出す数式か。最初に使う時に一度だけ一覧する。
    private var index: [String: Bool]?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        directory = caches.appendingPathComponent("KaTeXSnapshots", isDirectory: true)
        #if DEBUG
        // UI テストで、数式の画像が無い(WebView で描く)初回の状態から始める。
        if ProcessInfo.processInfo.arguments.contains("-katex-fresh") {
            try? FileManager.default.removeItem(at: directory)
        }
        #endif
    }

    func contains(key: String, width: CGFloat, scale: CGFloat) -> Bool {
        let name = Self.name(key: key, width: width, scale: scale)
        return memory.object(forKey: name as NSString) != nil || loadIndex()[name] != nil
    }

    func snapshot(for key: String, width: CGFloat, scale: CGFloat) -> KaTeXSnapshot? {
        let name = Self.name(key: key, width: width, scale: scale)
        if let box = memory.object(forKey: name as NSString) { return box.snapshot }
        guard let interactive = loadIndex()[name] else { return nil }
        guard let data = try? Data(contentsOf: fileURL(name, interactive: interactive)),
              let image = UIImage(data: data, scale: scale) else {
            index?[name] = nil
            return nil
        }
        let snapshot = KaTeXSnapshot(image: image, interactive: interactive)
        memory.setObject(Box(snapshot), forKey: name as NSString, cost: Self.cost(of: image))
        return snapshot
    }

    /// 空の画像(何も描かれていない)は残さない。確かめてから、メモリと端末に置く。
    func store(_ image: UIImage, interactive: Bool, key: String, width: CGFloat, scale: CGFloat) {
        let name = Self.name(key: key, width: width, scale: scale)
        let url = fileURL(name, interactive: interactive)
        let directory = directory
        Task {
            let data: Data? = await Task.detached(priority: .utility) {
                guard Self.hasInk(image) else { return nil }
                return image.pngData()
            }.value
            guard let data else { return }
            let snapshot = KaTeXSnapshot(image: image, interactive: interactive)
            memory.setObject(Box(snapshot), forKey: name as NSString, cost: Self.cost(of: image))
            _ = loadIndex()
            index?[name] = interactive
            Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 縮めた画像に、透明でない画素があるか(文字や数式が描かれているか)。
    nonisolated static func hasInk(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let width = min(cgImage.width, 128)
        let height = max(1, cgImage.height * width / max(cgImage.width, 1))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 24 }
    }

    func clearMemory() {
        memory.removeAllObjects()
    }

    func removeAll() {
        memory.removeAllObjects()
        index = [:]
        let directory = directory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func loadIndex() -> [String: Bool] {
        if let index { return index }
        var result: [String: Bool] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".png") {
            let stem = String(name.dropLast(4))
            if stem.hasSuffix(".i") {
                result[String(stem.dropLast(2))] = true
            } else {
                result[stem] = false
            }
        }
        index = result
        if names.count > Self.fileLimit { prune() }
        return result
    }

    /// 古い画像から消して、数を上限の 3 分の 2 まで減らす。
    private func prune() {
        let directory = directory
        let keep = Self.fileLimit * 2 / 3
        Task.detached(priority: .background) {
            let manager = FileManager.default
            let urls = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let dated = urls.map { url in
                (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }.sorted { $0.1 > $1.1 }
            for (url, _) in dated.dropFirst(keep) { try? manager.removeItem(at: url) }
        }
        index = nil
    }

    private func fileURL(_ name: String, interactive: Bool) -> URL {
        directory.appendingPathComponent(name + (interactive ? ".i.png" : ".png"))
    }

    private static func name(key: String, width: CGFloat, scale: CGFloat) -> String {
        let source = "\(rendererVersion)|\(key)|\(Int(width.rounded()))|\(Int(scale.rounded()))"
        return SHA256.hash(data: Data(source.utf8)).prefix(20).map { String(format: "%02x", $0) }.joined()
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
}
