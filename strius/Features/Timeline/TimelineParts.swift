import Foundation
import PencilKit
import SwiftUI

/// タイムラインの周りの情報は、文字より記号で出す。記号の意味は1つに固定する(Issue #46 の対応表)。
enum TimelineSymbol {
    /// さっきの続き
    static let chain = "link"
    /// 前に解いた(昨日・5日前など)
    static let past = "arrow.counterclockwise"
    /// 目安の時間
    static let clock = "timer"
    /// 余白に指で書ける
    static let pencil = "pencil"
    /// 新しい手順
    static let new = "sparkle"
    /// 入試の形
    static let exam = "graduationcap"
    /// 次の段まで
    static let stairs = "stairs"
    /// やり方の確認
    static let book = "book.closed"
    /// 速攻
    static let bolt = "bolt"
    /// 自己ベスト
    static let trophy = "trophy"
    /// さわるだけ
    static let hand = "hand.point.up"
    static let units = "book"
    static let ask = "bubble.left"
    static let skip = "arrow.down"
    static let camera = "camera"
    static let send = "arrow.up"
    static let next = "arrow.down"
    static let explain = "text.book.closed"
    /// 一段戻す(やさしくした問題)。↺(前に解いた)とは別の記号にする。
    static let back = "arrow.turn.left.down"
    /// 数値だけ変えた同じ形の問題
    static let variant = "arrow.left.arrow.right"
    /// 書いた線を1つ戻す・全部消す(iPad の右上の書く道具)
    static let undo = "arrow.uturn.backward"
    static let clear = "trash"
}

/// iPad の並び(問題は左の列、右は全部紙。書く道具は右上、質問は右に開く)。iPad で横幅が広い時だけ使う。
/// iPhone と、Split View で狭くした iPad は `.compact`(今の並び)のまま。
enum TimelineLayout: Equatable {
    case compact
    /// iPad 横向き: 問題は左の列、下の帯は問題の列の下だけ。
    case padLandscape
    /// iPad 縦向き: 問題は上に全幅、下の帯も全幅。
    case padPortrait

    /// 画面全体(右に開いた質問の欄も含む)の大きさから決める。欄を開いてタイムラインが細くなっても、横向きのまま。
    @MainActor
    static func resolve(sizeClass: UserInterfaceSizeClass?, size: CGSize) -> TimelineLayout {
        guard isPad(sizeClass) else { return .compact }
        return size.width > size.height ? .padLandscape : .padPortrait
    }

    @MainActor
    static func isPad(_ sizeClass: UserInterfaceSizeClass?) -> Bool {
        sizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
    }

    var isPad: Bool { self != .compact }

    /// 横向きの問題の列(左 40pt・幅 384pt)と、その下の帯(左 16pt・幅 432pt)。
    static let columnLeading: CGFloat = 40
    static let columnWidth: CGFloat = 384
    static let stripLeading: CGFloat = 16
    static let stripWidth: CGFloat = 432
    /// 右に開く質問の欄の幅。
    static let questionPanelWidth: CGFloat = 380
    /// iPad の「送る」の大きさ。
    static let sendDiameter: CGFloat = 64
}

/// ○ ×(正誤。色だけに頼らない)。
struct TimelineMark: View {
    let correct: Bool
    var size: CGFloat = 12

    var body: some View {
        Group {
            if correct {
                Circle().stroke(Theme.growthColor, lineWidth: max(1.5, size / 7)).frame(width: size, height: size)
            } else {
                Image(systemName: "xmark").font(.system(size: size, weight: .bold)).foregroundStyle(Theme.regressColor)
            }
        }
        .accessibilityLabel(correct ? "正解" : "誤答")
    }
}

/// 上の段のチップ(単元・時計・鎖・↺)。
struct TimelineChip: View {
    let text: String?
    var symbol: String? = nil
    var tinted = false

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
            if let text { Text(text).font(Typography.sans(size: 13, weight: .bold)).lineLimit(1) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(Theme.primaryText)
        .background(tinted ? Theme.accentColor.opacity(0.16) : Theme.hairline, in: Capsule())
    }
}

/// 系列のバー(2 / 3)。
struct TimelineChainBar: View {
    let position: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...max(1, total), id: \.self) { index in
                Capsule().fill(index <= position ? Theme.accentColor : Theme.hairline).frame(width: 18, height: 4)
            }
            Text("\(position) / \(total)").font(Typography.sans(size: 13, weight: .bold)).foregroundStyle(Theme.secondaryText).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("続きの \(position) 問目、全 \(total) 問")
        .accessibilityIdentifier("timeline-chain-bar")
    }
}

/// 数式(SwiftMath)。読めなければ文字で出す。
struct TimelineMath: View {
    let latex: String
    var size: CGFloat = 34
    /// 前の問題から変えたところ(式の中にあれば銅色の地にする)。
    var changed: String? = nil

    var body: some View {
        // 長い式は小さくして、画面の幅に収める(横にはみ出させない)。
        KaTeXMathText(TimelineMath.highlighting(latex, changed: changed), display: true, foregroundColor: UIColor(Theme.primaryText), fontSize: fitted, fontWeight: 500)
            .accessibilityIdentifier("timeline-math")
    }

    /// 変えたところを銅色の地にした式(見つからなければそのまま)。
    static func highlighting(_ latex: String, changed: String?) -> String {
        guard let changed = changed?.trimmingCharacters(in: .whitespaces), !changed.isEmpty, let range = latex.range(of: changed) else { return latex }
        return latex.replacingCharacters(in: range, with: "\\colorbox{#E9C8A6}{$\\color{#1F1A17}{" + changed + "}$}")
    }

    private var fitted: CGFloat {
        let length = TimelineMath.plain(latex).count
        return length > 14 ? max(18, size * 14 / CGFloat(length) * 1.25) : size
    }

    /// 下の帯・選択肢に 1 行で出す、読める文字。
    static func plain(_ latex: String) -> String {
        latex.isEmpty ? "" : MathPlainText.preview("\\(" + latex + "\\)")
    }

    /// 「次の1問」の 1 行: 式と問い(問いの中の `$…$` も読める文字に)。どちらも無ければ問題文。
    static func previewLine(_ card: TimelineCardRecord) -> String {
        let line = [plain(card.math), MathPlainText.preview(card.question)].filter { !$0.isEmpty }.joined(separator: "  ")
        return line.isEmpty ? MathPlainText.preview(card.prompt) : line
    }
}

/// 本文と数式が混ざった文(結果の答え・「前は」・問題文など)。LaTeX を文字のまま出さずに数式として描く。
struct TimelineRichText: View {
    let text: String
    var size: CGFloat = 16
    var weight: Typography.SansFontName = .medium
    var color: Color = Theme.primaryText
    /// 答えの欄: 計算機向けに書かれた式(`pi^2/8+1`・`1/3`)も数式に直して組む。
    var plainMath = false

    var body: some View {
        let source = plainMath ? TimelineRichText.answerSource(text) : TimelineRichText.source(text)
        if source.containsCatalogLaTeX {
            KaTeXMathText(source, foregroundColor: UIColor(color), fontSize: size, fontWeight: weight == .bold ? 700 : 500)
                .fixedSize(horizontal: false, vertical: true)
                .allowsHitTesting(false)
        } else {
            Text(text).font(Typography.sans(size: size, weight: weight)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 数式区切りが無い LaTeX(`\frac{\pi}{2}+1` など、日本語を含まない式だけの文)は `$…$` で囲む。日本語の文の中の式は、
    /// 単元ホームと同じ見分け方で区切る。
    static func source(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.containsCatalogLaTeX else { return trimmed }
        let japanese = trimmed.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
        let latexLike = trimmed.contains("\\") || trimmed.contains("^") || trimmed.contains("_{")
        if !japanese, latexLike { return "$" + trimmed + "$" }
        if japanese, trimmed.contains("\\") {
            // 日本語の中にある `\` から始まる式の塊を区切る。
            return trimmed.replacingOccurrences(of: #"([A-Za-z0-9 ()+\-=^_{}.,\\]*\\[A-Za-z]+[A-Za-z0-9 ()+\-=^_{}.,\\]*)"#, with: "\\$$1\\$", options: .regularExpression)
        }
        return WorkbookMathSource.withInlineMath(trimmed)
    }

    /// 答えの欄の本文。式だけの答え(日本語を含まない)は、文字で書かれていても数式に直す(`pi` を斜体の p・i にしない)。
    static func answerSource(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let latex = TimelinePlainMath.latex(trimmed) { return "$" + latex + "$" }
        return source(trimmed)
    }
}

/// 問いの文。前の問題から変えたところ(例: 範囲の a)は銅色の地にする。
struct TimelineQuestionText: View {
    let text: String
    var changed: String?
    var size: CGFloat = 20

    var body: some View {
        if text.containsCatalogLaTeX {
            // 文の中の式(`$\sin\frac{5\pi}{2}$`)は数式として組む。変えたところの色は付けない(式の中の位置を文字では指せない)。
            TimelineRichText(text: text, size: size, weight: .bold)
                .accessibilityIdentifier("timeline-question")
        } else {
            Text(attributed)
                .font(Typography.sans(size: size, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("timeline-question")
        }
    }

    private var attributed: AttributedString {
        var value = AttributedString(text)
        if let changed, !changed.isEmpty, let range = value.range(of: changed) {
            value[range].backgroundColor = Theme.accentColor.opacity(0.22)
        }
        return value
    }
}

/// 右下の縦並びのボタン(ラベルは残す)。
struct TimelineActionButton: View {
    let symbol: String
    let label: String
    var prominent = false
    /// 押せない間は、大きいボタンを薄い銅色の地に銅色の印にする(iPad の「送る」は書くまで押せない)。
    var isEnabled = true
    /// 大きいボタンの直径(iPad の「送る」は 64pt)。
    var diameter: CGFloat? = nil
    var identifier: String
    let action: () -> Void

    var body: some View {
        let size = diameter ?? (prominent ? 72 : 52)
        let raised = prominent && isEnabled
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: prominent ? 26 : 20, weight: .semibold))
                    .foregroundStyle(prominent ? (isEnabled ? Theme.onAccent : Theme.accentColor) : Theme.primaryText)
                    .frame(width: size, height: size)
                    .background(prominent ? AnyShapeStyle(isEnabled ? Theme.accentColor : Theme.accentColor.opacity(0.16)) : AnyShapeStyle(Theme.card), in: Circle())
                    .overlay { if !prominent { Circle().stroke(Theme.hairline, lineWidth: 1) } }
                    .shadow(color: .black.opacity(raised ? 0.18 : 0.06), radius: raised ? 10 : 4, y: 3)
                Text(label).font(Typography.sans(size: 12, weight: .bold)).foregroundStyle(Theme.secondaryText)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// 余白に指で書く(枠を置かない: 答えの形が分かってしまうため)。上の帯と下の帯の間を、画面の端から端まで覆う。
/// 問題文の上にも書ける。下に置いたボタン(使う手順の「見る」など)の上だけは、指をボタンへ通す。
/// 2本指でつまむと、指の間を中心に縮小・拡大できる。縮小すると、紙を足したように右と下へ書き足せる(最大で縦横2倍)。
struct TimelineInkCanvas: UIViewRepresentable {
    @Binding var hasInk: Bool
    @Binding var isDrawing: Bool
    @Binding var isZoomed: Bool
    let controller: TimelineInkController
    /// 指を通す区画(このビューの座標)。
    var passThrough: [CGRect] = []

    /// 書いた線の色と太さ。細さは前のペン(幅3)のまま、濃い一定幅の線にする。
    static let inkColor = UIColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 1)
    static let inkWidth: CGFloat = 3
    /// 指が触れただけの点は、書いたものに数えない(pt)。
    static let minimumStrokeExtent: CGFloat = 6
    /// 縮小の下限(縦横2倍の紙を画面に収める)と、拡大の上限。
    static let minimumZoom: CGFloat = 0.5
    static let maximumZoom: CGFloat = 3

    func makeUIView(context: Context) -> TimelinePassThroughCanvas {
        let canvas = TimelinePassThroughCanvas()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.tool = PKInkingTool(.monoline, color: Self.inkColor, width: Self.inkWidth)
        canvas.minimumZoomScale = Self.minimumZoom
        canvas.maximumZoomScale = Self.maximumZoom
        canvas.bouncesZoom = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.delegate = context.coordinator
        canvas.accessibilityIdentifier = "timeline-ink"
        controller.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: TimelinePassThroughCanvas, context: Context) {
        canvas.passThrough = passThrough
    }

    func makeCoordinator() -> Coordinator { Coordinator(hasInk: $hasInk, isDrawing: $isDrawing, isZoomed: $isZoomed) }

    /// 指が触れただけの点(ごく短い線)を除いて、書いた線があるか。
    static func hasMeaningfulInk(_ drawing: PKDrawing) -> Bool {
        drawing.strokes.contains { stroke in
            let points = stroke.path.map(\.location)
            guard let first = points.first else { return false }
            return points.contains { abs($0.x - first.x) >= minimumStrokeExtent || abs($0.y - first.y) >= minimumStrokeExtent }
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let hasInk: Binding<Bool>
        let isDrawing: Binding<Bool>
        let isZoomed: Binding<Bool>
        init(hasInk: Binding<Bool>, isDrawing: Binding<Bool>, isZoomed: Binding<Bool>) {
            self.hasInk = hasInk
            self.isDrawing = isDrawing
            self.isZoomed = isZoomed
        }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let value = TimelineInkCanvas.hasMeaningfulInk(canvasView.drawing)
            if hasInk.wrappedValue != value { hasInk.wrappedValue = value }
        }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            if !isDrawing.wrappedValue { isDrawing.wrappedValue = true }
        }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            if isDrawing.wrappedValue { isDrawing.wrappedValue = false }
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? TimelinePassThroughCanvas)?.updateAccessibilityCenter()
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? TimelinePassThroughCanvas)?.updateAccessibilityCenter()
            let value = abs(scrollView.zoomScale - 1) > 0.01
            if isZoomed.wrappedValue != value { isZoomed.wrappedValue = value }
        }
        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            // 自分でつまんだら、欄を閉じた時にも倍率を戻さない。
            (scrollView as? TimelinePassThroughCanvas)?.forgetAutoFit()
        }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            (scrollView as? TimelinePassThroughCanvas)?.fitPaper()
        }
    }
}

/// 書く面。紙は画面の縦横2倍の大きさで持ち、等倍では左上の1画面分を見せる。指を通す区画では触れても書かない。
/// 書く面が狭くなった時(iPad で右に質問の欄を開いた時など)は、書いた線の全体が見える倍率まで縮め、広がったら戻す。
final class TimelinePassThroughCanvas: PKCanvasView {
    var passThrough: [CGRect] = []
    private var paperBase: CGSize = .zero
    /// 狭くなって自動で縮めている(広がったら等倍に戻す)。
    private var isAutoFitted = false

    override func layoutSubviews() {
        super.layoutSubviews()
        // layoutSubviews はつまんでいる間も毎回呼ばれる。そこで大きさを入れ直すと、指の間を中心に縮まず左上へ跳ぶので、
        // 紙の大きさは画面の大きさが変わった時だけ決め直す。
        guard bounds.width > 0, bounds.height > 0, bounds.size != paperBase, !isZooming, !isZoomBouncing else { return }
        let previous = paperBase
        paperBase = bounds.size
        fitPaper()
        updateAccessibilityCenter()
        guard previous.width > 0 else { return }
        // 倍率を変えると delegate から SwiftUI の状態(isZoomed)が変わるので、レイアウトが終わってから変える。
        DispatchQueue.main.async { [weak self] in self?.keepInkVisible() }
    }

    /// 書いた線が見える範囲からはみ出したら縮め、自動で縮めた後に広がったら等倍に戻す。自分でつまんだ倍率は変えない。
    private func keepInkVisible() {
        guard !isZooming, !isZoomBouncing, bounds.width > 0, bounds.height > 0 else { return }
        let ink = drawing.strokes.isEmpty ? CGRect.null : drawing.bounds
        let margin: CGFloat = 32
        let needed = ink.isNull ? 1 : min(1, bounds.width / (ink.maxX + margin), bounds.height / (ink.maxY + margin))
        if isAutoFitted || abs(zoomScale - 1) <= 0.01 {
            let target = max(minimumZoomScale, needed)
            guard abs(target - zoomScale) > 0.01 else { return }
            isAutoFitted = target < 1
            setZoomScale(target, animated: false)
            contentOffset = .zero
            fitPaper()
            updateAccessibilityCenter()
        }
    }

    func forgetAutoFit() { isAutoFitted = false }

    /// 紙(等倍の画面の2倍)を、今の倍率の大きさにする。
    func fitPaper() {
        guard paperBase.width > 0 else { return }
        let scaled = CGSize(width: paperBase.width * 2 * zoomScale, height: paperBase.height * 2 * zoomScale)
        if abs(contentSize.width - scaled.width) > 0.5 || abs(contentSize.height - scaled.height) > 0.5 {
            contentSize = scaled
        }
    }

    /// 画面の真ん中に見えている紙の位置(等倍の座標)。つまんだ所を中心に縮むかを UI テストで確かめる。
    func updateAccessibilityCenter() {
        guard zoomScale > 0 else { return }
        let x = (contentOffset.x + bounds.width / 2) / zoomScale
        let y = (contentOffset.y + bounds.height / 2) / zoomScale
        accessibilityValue = "\(Int(x.rounded())),\(Int(y.rounded()))"
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // passThrough はこのビューの枠の座標。スクロールした分を引いて比べる。
        let local = CGPoint(x: point.x - contentOffset.x, y: point.y - contentOffset.y)
        if passThrough.contains(where: { $0.contains(local) }) { return nil }
        return super.hitTest(point, with: event)
    }
}

/// 指を通す区画(書く面の座標空間 `TimelineInkSpace.name` での枠)を集める。
struct TimelineInkPassThroughKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}

enum TimelineInkSpace {
    static let name = "timeline-ink-space"
}

extension View {
    /// 書く面の上にあっても、このビューには指を通す(押せるボタン)。
    func timelineInkPassThrough() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: TimelineInkPassThroughKey.self, value: [proxy.frame(in: .named(TimelineInkSpace.name))])
            }
        }
    }
}

/// 書いた線の「1つ戻す」「全部消す」「元の大きさ」と、送る画像づくり。
@MainActor
final class TimelineInkController {
    weak var canvas: PKCanvasView?

    func undo() {
        guard let canvas else { return }
        var drawing = canvas.drawing
        guard !drawing.strokes.isEmpty else { return }
        drawing.strokes.removeLast()
        canvas.drawing = drawing
    }

    func clear() { canvas?.drawing = PKDrawing() }

    func resetZoom() {
        guard let canvas else { return }
        (canvas as? TimelinePassThroughCanvas)?.forgetAutoFit()
        canvas.setZoomScale(1, animated: true)
        canvas.setContentOffset(.zero, animated: true)
    }

    /// 白地に書いた線(JPEG)。何も書いていなければ nil。
    /// ダークモードでは PencilKit が線を明るい色に反転して描くため、白地に重ねる画像はライトモードの色で描く。
    func image() -> Data? {
        guard let canvas, TimelineInkCanvas.hasMeaningfulInk(canvas.drawing) else { return nil }
        let drawing = canvas.drawing
        let bounds = drawing.bounds.insetBy(dx: -24, dy: -24)
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: bounds, scale: 2)
        }
        let renderer = UIGraphicsImageRenderer(size: ink.size)
        let composed = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: ink.size))
            ink.draw(at: .zero)
        }
        return composed.jpegData(compressionQuality: 0.85)
    }
}

/// やり方の確認の図: 範囲が軸の左・またぐ・右で、最小になる点(●)が右端・頂点・左端に動く。
struct TimelineRangeDiagram: View {
    let position: String
    let minAt: String

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            // 下に凸の放物線(頂点が下)。画面の y は下向きに増える。
            func y(_ x: CGFloat) -> CGFloat { h * 0.85 - (h * 0.7) * pow((x - 0.5) * 2, 2) }
            var parabola = Path()
            for step in 0...40 {
                let t = CGFloat(step) / 40
                let point = CGPoint(x: t * w, y: y(t))
                step == 0 ? parabola.move(to: point) : parabola.addLine(to: point)
            }
            context.stroke(parabola, with: .color(Theme.secondaryText), lineWidth: 1.5)
            var axis = Path()
            axis.move(to: CGPoint(x: w / 2, y: 0))
            axis.addLine(to: CGPoint(x: w / 2, y: h))
            context.stroke(axis, with: .color(Theme.hairline), lineWidth: 1)
            let range: ClosedRange<CGFloat> = switch position {
            case "left": 0.05...0.32
            case "right": 0.68...0.95
            default: 0.38...0.62
            }
            var band = Path()
            for step in 0...20 {
                let t = range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(step) / 20
                let point = CGPoint(x: t * w, y: y(t))
                step == 0 ? band.move(to: point) : band.addLine(to: point)
            }
            context.stroke(band, with: .color(Theme.accentColor), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            let x: CGFloat = switch minAt {
            case "right_end": range.upperBound
            case "left_end": range.lowerBound
            default: 0.5
            }
            let dot = CGRect(x: x * w - 6, y: y(x) - 6, width: 12, height: 12)
            context.fill(Path(ellipseIn: dot), with: .color(Theme.primaryText))
        }
        .frame(height: 96)
        .accessibilityHidden(true)
    }
}

/// 06 グラフと式を結ぶ: 式のグラフを小さく描く。
struct TimelineFunctionPlot: View {
    let expression: String
    var highlighted = false

    var body: some View {
        Canvas { context, size in
            guard let f = try? TimelineExpression.parse(expression) else { return }
            let name = f.variables.first ?? "x"
            let xs = stride(from: -5.0, through: 5.0, by: 0.1).map { $0 }
            let points = xs.compactMap { x -> (Double, Double)? in f.evaluate([name: x]).map { (x, $0) } }
            guard !points.isEmpty else { return }
            let yRange = (-10.0)...(10.0)
            func map(_ p: (Double, Double)) -> CGPoint {
                CGPoint(x: (p.0 + 5) / 10 * size.width, y: size.height - (min(max(p.1, yRange.lowerBound), yRange.upperBound) - yRange.lowerBound) / 20 * size.height)
            }
            var axes = Path()
            axes.move(to: CGPoint(x: 0, y: size.height / 2)); axes.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            axes.move(to: CGPoint(x: size.width / 2, y: 0)); axes.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            context.stroke(axes, with: .color(Theme.hairline), lineWidth: 1)
            var path = Path()
            for (index, point) in points.enumerated() { index == 0 ? path.move(to: map(point)) : path.addLine(to: map(point)) }
            context.stroke(path, with: .color(highlighted ? Theme.accentColor : Theme.secondaryText), lineWidth: 2)
        }
        .frame(height: 80)
        .accessibilityHidden(true)
    }
}

/// 文字で書かれた式(`pi^2/8+1`・`-cos(5x)/5`・`(1/2){sin 8x + sin(-2x)}`)を LaTeX に直す。
///
/// 答え(`answer_key`)と生徒の答え(`learner_answer`)は、モデルが計算機向けの書き方で返すことがある。そのまま数式として
/// 組むと `pi` が斜体の p・i になり(実機 2026-10-26)、文字のまま出すと `1/3` が分数に見えない。日本語を含む文や、
/// 読めない記号を含む文は直さない(`nil`)。
nonisolated enum TimelinePlainMath {
    /// 直した LaTeX(区切りなし)。直すところが無い(`0`・`x` だけ)か、読めなければ nil。
    static func latex(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\\"), !trimmed.contains("$") else { return nil }
        guard let tokens = tokenize(trimmed) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let piece = parser.parseList(), parser.atEnd else { return nil }
        let latex = piece.latex
        // 数字・文字・符号だけ(`0`・`-1`・`x`)は文字のままでよい。
        guard latex.contains("\\") || latex.contains("^") || latex.contains("{") else { return nil }
        return latex
    }

    // MARK: - 字句

    enum Token: Equatable {
        case number(String)
        case word(String)
        /// すでに LaTeX の命令になったもの(π → `\pi`)。
        case symbol(String)
        /// `+ - * / ^ = , < >` と `\le` などの関係。
        case op(String)
        case open(Character)
        case close(Character)
        /// 上付きの数字(`²`)。
        case superscript(String)
        case space
    }

    static let functions: [String] = [
        "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "sqrt", "sin", "cos", "tan", "cot", "sec", "csc", "log", "exp", "abs", "ln",
    ]

    private static let unicodeSymbols: [Character: Token] = [
        "π": .symbol("\\pi"), "∞": .symbol("\\infty"), "θ": .symbol("\\theta"), "α": .symbol("\\alpha"), "β": .symbol("\\beta"),
        "−": .op("-"), "–": .op("-"), "×": .op("*"), "·": .op("*"), "⋅": .op("*"), "÷": .op("/"),
        "≤": .op("\\le"), "≦": .op("\\le"), "≥": .op("\\ge"), "≧": .op("\\ge"), "≠": .op("\\ne"), "±": .op("\\pm"),
        "（": .open("("), "）": .close(")"), "，": .op(","), "、": .op(","), "　": .space,
    ]

    private static let superscripts: [Character: Character] = [
        "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "⁻": "-",
    ]

    static func tokenize(_ text: String) -> [Token]? {
        let chars = Array(text)
        var tokens: [Token] = []
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == " " || char == "\t" {
                if tokens.last != .space { tokens.append(.space) }
                index += 1
            } else if char.isASCII, char.isNumber || char == "." {
                var end = index
                while end < chars.count, chars[end].isASCII, chars[end].isNumber || chars[end] == "." { end += 1 }
                tokens.append(.number(String(chars[index..<end])))
                index = end
            } else if char.isASCII, char.isLetter {
                var end = index
                while end < chars.count, chars[end].isASCII, chars[end].isLetter { end += 1 }
                tokens.append(contentsOf: words(String(chars[index..<end])))
                index = end
            } else if superscripts[char] != nil {
                var end = index
                var value = ""
                while end < chars.count, let next = superscripts[chars[end]] { value.append(next); end += 1 }
                tokens.append(.superscript(value))
                index = end
            } else if let token = unicodeSymbols[char] {
                if token == .space { if tokens.last != .space { tokens.append(.space) } } else { tokens.append(token) }
                index += 1
            } else if "+-*/^=,<>".contains(char) {
                // `<=`・`>=`・`!=` は関係の記号。
                if index + 1 < chars.count, chars[index + 1] == "=", char == "<" || char == ">" {
                    tokens.append(.op(char == "<" ? "\\le" : "\\ge"))
                    index += 2
                } else {
                    tokens.append(.op(String(char)))
                    index += 1
                }
            } else if char == "!", index + 1 < chars.count, chars[index + 1] == "=" {
                tokens.append(.op("\\ne"))
                index += 2
            } else if "([{".contains(char) {
                tokens.append(.open(char))
                index += 1
            } else if ")]}".contains(char) {
                tokens.append(.close(char))
                index += 1
            } else {
                // 日本語・読めない記号: 直さない。
                return nil
            }
        }
        return tokens
    }

    /// 英字の並びを、関数名・`pi`・ただの文字に分ける(`sinx` → sin と x、`2pi` の pi → π)。
    private static func words(_ run: String) -> [Token] {
        var tokens: [Token] = []
        var rest = Substring(run)
        while !rest.isEmpty {
            if let name = functions.first(where: { rest.hasPrefix($0) }) {
                tokens.append(.word(name))
                rest = rest.dropFirst(name.count)
            } else if rest.hasPrefix("pi") {
                tokens.append(.symbol("\\pi"))
                rest = rest.dropFirst(2)
            } else if rest.hasPrefix("theta") {
                tokens.append(.symbol("\\theta"))
                rest = rest.dropFirst(5)
            } else if rest.hasPrefix("inf") && rest.count == 3 {
                tokens.append(.symbol("\\infty"))
                rest = rest.dropFirst(3)
            } else {
                tokens.append(.word(String(rest.first!)))
                rest = rest.dropFirst()
            }
        }
        return tokens
    }

    // MARK: - 組み立て

    struct Piece {
        var latex: String
        /// `( … )` で囲んだ式なら中身(分数の分子・分母、べきの指数では括弧を外す)。
        var inner: String? = nil
        var containsFraction: Bool { latex.contains("\\frac") }
    }

    struct Parser {
        let tokens: [Token]
        var index = 0

        init(tokens: [Token]) { self.tokens = tokens }

        var atEnd: Bool {
            var probe = index
            while probe < tokens.count, tokens[probe] == .space { probe += 1 }
            return probe >= tokens.count
        }

        private mutating func skipSpaces() {
            while index < tokens.count, tokens[index] == .space { index += 1 }
        }

        private func peek() -> Token? {
            var probe = index
            while probe < tokens.count, tokens[probe] == .space { probe += 1 }
            return probe < tokens.count ? tokens[probe] : nil
        }

        /// `a, b` の並び。
        mutating func parseList() -> Piece? {
            guard var result = parseRelation() else { return nil }
            while peek() == .op(",") {
                skipSpaces()
                index += 1
                guard let next = parseRelation() else { return nil }
                result = Piece(latex: result.latex + ",\\ " + next.latex)
            }
            return result
        }

        private mutating func parseRelation() -> Piece? {
            guard var result = parseSum() else { return nil }
            while case .op(let op)? = peek(), ["=", "<", ">", "\\le", "\\ge", "\\ne"].contains(op) {
                skipSpaces()
                index += 1
                guard let next = parseSum() else { return nil }
                result = Piece(latex: result.latex + " " + op + " " + next.latex)
            }
            return result
        }

        private mutating func parseSum() -> Piece? {
            var latex = ""
            if case .op(let sign)? = peek(), sign == "-" || sign == "+" || sign == "\\pm" {
                skipSpaces()
                index += 1
                latex = sign == "\\pm" ? "\\pm " : sign
            }
            guard let first = parseTerm() else { return nil }
            // 単項の符号が付かない 1 つだけの項は、括弧の中身を保つ(分数の分子などで外せるように)。
            if latex.isEmpty, !isSumOperator(peek()) { return first }
            latex += first.latex
            while case .op(let op)? = peek(), op == "+" || op == "-" || op == "\\pm" {
                skipSpaces()
                index += 1
                guard let next = parseTerm() else { return nil }
                latex += (op == "\\pm" ? " \\pm " : op) + next.latex
            }
            return Piece(latex: latex)
        }

        private func isSumOperator(_ token: Token?) -> Bool {
            guard case .op(let op)? = token else { return false }
            return op == "+" || op == "-" || op == "\\pm"
        }

        /// 掛け算・割り算(書かれていない掛け算を含む)。`a/b` は分数にする。
        private mutating func parseTerm() -> Piece? {
            guard var result = parsePower() else { return nil }
            while true {
                let token = peek()
                if token == .op("/") {
                    skipSpaces()
                    index += 1
                    guard let denominator = parsePower() else { return nil }
                    result = Piece(latex: "\\frac{" + (result.inner ?? result.latex) + "}{" + (denominator.inner ?? denominator.latex) + "}")
                } else if token == .op("*") {
                    skipSpaces()
                    index += 1
                    guard let next = parsePower() else { return nil }
                    result = Piece(latex: Self.multiply(result.latex, next.latex))
                } else if startsFactor(token) {
                    guard let next = parsePower() else { return nil }
                    // `(1/2)π` の括弧は分数だけなら外す。
                    let left = result.inner.flatMap { Self.isSingleFraction($0) ? $0 : nil } ?? result.latex
                    result = Piece(latex: Self.multiply(left, next.latex))
                } else {
                    return result
                }
            }
        }

        private func startsFactor(_ token: Token?) -> Bool {
            switch token {
            case .number?, .word?, .symbol?, .open?: true
            default: false
            }
        }

        static func multiply(_ left: String, _ right: String) -> String {
            let leftDigit = left.last?.isNumber ?? false
            let rightDigit = right.first?.isNumber ?? false
            if leftDigit && rightDigit { return left + " \\cdot " + right }
            return left + " " + right
        }

        static func isSingleFraction(_ latex: String) -> Bool {
            guard latex.hasPrefix("\\frac{") else { return false }
            // `\frac{…}{…}` だけで終わっているか(後ろに続きが無い)。
            var depth = 0
            var groups = 0
            var index = latex.index(latex.startIndex, offsetBy: 5)
            while index < latex.endIndex {
                let char = latex[index]
                if char == "{" { depth += 1 }
                if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        groups += 1
                        if groups == 2 { return latex.index(after: index) == latex.endIndex }
                    }
                }
                index = latex.index(after: index)
            }
            return false
        }

        /// べき(`x^2`・`π²`・`e^(2x)`)と単項の符号。
        private mutating func parsePower() -> Piece? {
            if case .op(let sign)? = peek(), sign == "-" {
                skipSpaces()
                index += 1
                guard let next = parsePower() else { return nil }
                return Piece(latex: "-" + next.latex)
            }
            guard var base = parsePrimary() else { return nil }
            while true {
                // 指数は空白を挟まずに続く時だけ(`x ^2` も読むが、空白の後の数字は掛け算)。
                if index < tokens.count, case .superscript(let value) = tokens[index] {
                    index += 1
                    base = Piece(latex: base.latex + "^{" + value + "}")
                } else if peek() == .op("^") {
                    skipSpaces()
                    index += 1
                    skipSpaces()
                    var sign = ""
                    if peek() == .op("-") { index += 1; sign = "-" }
                    guard let exponent = parsePrimary() else { return nil }
                    base = Piece(latex: base.latex + "^{" + sign + (exponent.inner ?? exponent.latex) + "}")
                } else {
                    return base
                }
            }
        }

        private mutating func parsePrimary() -> Piece? {
            skipSpaces()
            guard index < tokens.count else { return nil }
            let token = tokens[index]
            index += 1
            switch token {
            case .number(let value): return Piece(latex: value)
            case .symbol(let value): return Piece(latex: value)
            case .word(let name) where TimelinePlainMath.functions.contains(name): return parseFunction(name)
            case .word(let name): return Piece(latex: name)
            case .open(let char): return parseGroup(opening: char)
            default: return nil
            }
        }

        private mutating func parseGroup(opening: Character) -> Piece? {
            let closing: Character = opening == "(" ? ")" : opening == "[" ? "]" : "}"
            guard let inner = parseList() else { return nil }
            skipSpaces()
            guard index < tokens.count, tokens[index] == .close(closing) else { return nil }
            index += 1
            switch opening {
            case "(":
                let sized = inner.containsFraction
                return Piece(latex: (sized ? "\\left(" : "(") + inner.latex + (sized ? "\\right)" : ")"), inner: inner.latex)
            case "[":
                return Piece(latex: (inner.containsFraction ? "\\left[" : "[") + inner.latex + (inner.containsFraction ? "\\right]" : "]"))
            default:
                return Piece(latex: (inner.containsFraction ? "\\left\\{" : "\\{") + inner.latex + (inner.containsFraction ? "\\right\\}" : "\\}"))
            }
        }

        /// 関数(`sin 4x`・`cos(5x)`・`sin^2 x`・`sqrt(2)`・`abs(x)`)。括弧の無い引数は、次の演算子までの数字・文字・べき。
        private mutating func parseFunction(_ name: String) -> Piece? {
            var head = "\\" + name
            if peek() == .op("^"), name != "sqrt", name != "abs" {
                skipSpaces()
                index += 1
                guard let exponent = parsePrimary() else { return nil }
                head += "^{" + (exponent.inner ?? exponent.latex) + "}"
            }
            if case .open("(")? = peek() {
                skipSpaces()
                index += 1
                guard let group = parseGroup(opening: "("), let inner = group.inner else { return nil }
                switch name {
                case "sqrt": return Piece(latex: "\\sqrt{" + inner + "}")
                case "abs": return Piece(latex: "\\left|" + inner + "\\right|")
                default: return Piece(latex: head + group.latex)
                }
            }
            // 括弧の無い引数: `4x`・`x`・`2π`(掛け算でつながる数字・文字・べき)。
            guard var argument = parseArgumentFactor() else { return nil }
            while index < tokens.count, startsArgument(tokens[index]) {
                guard let next = parseArgumentFactor() else { return nil }
                argument = Piece(latex: Self.multiply(argument.latex, next.latex))
            }
            switch name {
            case "sqrt": return Piece(latex: "\\sqrt{" + argument.latex + "}")
            case "abs": return Piece(latex: "\\left|" + argument.latex + "\\right|")
            default: return Piece(latex: head + " " + argument.latex)
            }
        }

        /// 引数の続き: 空白を挟まない数字・文字・π(`4x`)。
        private func startsArgument(_ token: Token) -> Bool {
            switch token {
            case .number, .symbol: true
            case .word(let name): !TimelinePlainMath.functions.contains(name)
            default: false
            }
        }

        private mutating func parseArgumentFactor() -> Piece? {
            skipSpaces()
            guard index < tokens.count else { return nil }
            switch tokens[index] {
            case .number(let value):
                index += 1
                return withScripts(Piece(latex: value))
            case .symbol(let value):
                index += 1
                return withScripts(Piece(latex: value))
            case .word(let name) where !TimelinePlainMath.functions.contains(name):
                index += 1
                return withScripts(Piece(latex: name))
            case .op("-"):
                index += 1
                return parseArgumentFactor().map { Piece(latex: "-" + $0.latex) }
            default:
                return nil
            }
        }

        private mutating func withScripts(_ base: Piece) -> Piece? {
            var base = base
            while index < tokens.count {
                if case .superscript(let value) = tokens[index] {
                    index += 1
                    base = Piece(latex: base.latex + "^{" + value + "}")
                } else if tokens[index] == .op("^") {
                    index += 1
                    guard let exponent = parsePrimary() else { return nil }
                    base = Piece(latex: base.latex + "^{" + (exponent.inner ?? exponent.latex) + "}")
                } else {
                    break
                }
            }
            return base
        }
    }
}
