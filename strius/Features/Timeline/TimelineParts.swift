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
}

/// 本文と数式が混ざった文(結果の答え・「前は」・問題文など)。LaTeX を文字のまま出さずに数式として描く。
struct TimelineRichText: View {
    let text: String
    var size: CGFloat = 16
    var weight: Typography.SansFontName = .medium
    var color: Color = Theme.primaryText

    var body: some View {
        let source = TimelineRichText.source(text)
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
}

/// 問いの文。前の問題から変えたところ(例: 範囲の a)は銅色の地にする。
struct TimelineQuestionText: View {
    let text: String
    var changed: String?
    var size: CGFloat = 20

    var body: some View {
        Text(attributed)
            .font(Typography.sans(size: size, weight: .bold))
            .foregroundStyle(Theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("timeline-question")
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
    var identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: prominent ? 26 : 20, weight: .semibold))
                    .foregroundStyle(prominent ? Theme.onAccent : Theme.primaryText)
                    .frame(width: prominent ? 72 : 52, height: prominent ? 72 : 52)
                    .background(prominent ? AnyShapeStyle(Theme.accentColor) : AnyShapeStyle(Theme.card), in: Circle())
                    .overlay { if !prominent { Circle().stroke(Theme.hairline, lineWidth: 1) } }
                    .shadow(color: .black.opacity(prominent ? 0.18 : 0.06), radius: prominent ? 10 : 4, y: 3)
                Text(label).font(Typography.sans(size: 12, weight: .bold)).foregroundStyle(Theme.secondaryText)
            }
        }
        .buttonStyle(.plain)
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
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            (scrollView as? TimelinePassThroughCanvas)?.fitPaper()
        }
    }
}

/// 書く面。紙は画面の縦横2倍の大きさで持ち、等倍では左上の1画面分を見せる。指を通す区画では触れても書かない。
final class TimelinePassThroughCanvas: PKCanvasView {
    var passThrough: [CGRect] = []
    private var paperBase: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        // layoutSubviews はつまんでいる間も毎回呼ばれる。そこで大きさを入れ直すと、指の間を中心に縮まず左上へ跳ぶので、
        // 紙の大きさは画面の大きさが変わった時だけ決め直す。
        guard bounds.width > 0, bounds.height > 0, bounds.size != paperBase, !isZooming, !isZoomBouncing else { return }
        paperBase = bounds.size
        fitPaper()
        updateAccessibilityCenter()
    }

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
