import SwiftUI

/// 図形の問題の図とグラフ(`TimelineFigure`)を描く。教科書の図と同じく、線は本文の色の細い線、印と角の文字は銅色、
/// 点の名前は本文と同じ書体にする。座標平面は軸・目盛り・曲線・塗り、立体は斜めから見た図(見えない辺は点線)。
struct TimelineFigureView: View {
    let figure: TimelineFigure
    /// 一覧に並べた小さいカード(`TimelineProblemView` の compact)。
    var compact = false
    /// 高さの上限(問題の列の残りの高さ)。nil なら既定の上限。
    var maxHeight: CGFloat? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// 既定の高さの上限。iPad は画面が広いので大きく描く。
    private var cap: CGFloat { compact ? 150 : (sizeClass == .regular ? 420 : 300) }

    private var inset: CGFloat { compact ? 18 : 28 }
    private var fontSize: CGFloat { compact ? 12 : 16 }
    private var smallFontSize: CGFloat { compact ? 10 : 13 }
    private var angleFontSize: CGFloat { compact ? 11 : 14 }
    private var lineWidth: CGFloat { compact ? 1.2 : 1.6 }

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .aspectRatio(figure.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: min(cap, maxHeight ?? cap))
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("timeline-figure")
    }

    /// VoiceOver で読む図の中身(点と線と角の文字、グラフの式)。
    private var accessibilityText: String {
        var parts: [String] = [figure.axes == nil ? "図" : "グラフ"]
        if !figure.curves.isEmpty {
            parts.append(figure.curves.map { TimelineFigure.displayLabel($0.label.isEmpty ? "y = " + $0.expr : $0.label) }.joined(separator: "、"))
        }
        if !figure.segments.isEmpty { parts.append("線分 " + figure.segments.map { $0.from + $0.to }.joined(separator: "、")) }
        let labeled = figure.angles.filter { !$0.label.isEmpty }
        if !labeled.isEmpty {
            parts.append(labeled.map { "角\($0.from)\($0.vertex)\($0.to) は \(TimelineFigure.displayLabel($0.label))" }.joined(separator: "、"))
        }
        return parts.joined(separator: "。")
    }

    private var ink: GraphicsContext.Shading { .color(Theme.primaryText) }
    private var mark: GraphicsContext.Shading { .color(Theme.accentColor) }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let layout = figure.layout(in: size, inset: inset)
        let place: (TimelineFigure.Point) -> CGPoint = { p in let q = figure.plane(p); return layout(q.x, q.y) }
        let window: CGRect? = figure.axes.map { axes in
            let a = layout(axes.xMin, axes.yMax), b = layout(axes.xMax, axes.yMin)
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }

        if let axes = figure.axes, axes.grid { drawGrid(axes, layout: layout, in: &context) }
        drawFills(layout: layout, window: window, place: place, in: &context)
        if let axes = figure.axes, let window { drawAxes(axes, window: window, layout: layout, in: &context) }
        drawCircles(layout: layout, place: place, in: &context)
        drawCurves(layout: layout, window: window, in: &context)
        drawAngles(place: place, in: &context)
        drawSegments(place: place, in: &context)
        drawPoints(place: place, in: &context)
    }

    // MARK: 座標平面

    private func drawGrid(_ axes: TimelineFigure.Axes, layout: TimelineFigure.Layout, in context: inout GraphicsContext) {
        var path = Path()
        for x in ticks(axes.xMin, axes.xMax, pi: axes.piTicks) {
            path.move(to: layout(x, axes.yMin)); path.addLine(to: layout(x, axes.yMax))
        }
        for y in ticks(axes.yMin, axes.yMax, pi: false) {
            path.move(to: layout(axes.xMin, y)); path.addLine(to: layout(axes.xMax, y))
        }
        context.stroke(path, with: .color(Theme.tertiaryText.opacity(0.35)), lineWidth: 0.6)
    }

    private func drawAxes(_ axes: TimelineFigure.Axes, window: CGRect, layout: TimelineFigure.Layout, in context: inout GraphicsContext) {
        let axisWidth = lineWidth * 0.8
        let overshoot: CGFloat = compact ? 6 : 10
        let hasX = axes.yMin <= 0 && axes.yMax >= 0, hasY = axes.xMin <= 0 && axes.xMax >= 0
        let xAxisY = layout(0, 0).y, yAxisX = layout(0, 0).x
        if hasX {
            let start = CGPoint(x: window.minX - overshoot * 0.5, y: xAxisY), end = CGPoint(x: window.maxX + overshoot, y: xAxisY)
            stroke(line: start, end, with: ink, width: axisWidth, in: &context)
            arrowHead(at: end, from: start, in: &context, width: axisWidth)
            text("x", at: CGPoint(x: end.x - 2, y: end.y + (compact ? 9 : 12)), size: fontSize, italic: true, in: &context)
        }
        if hasY {
            let start = CGPoint(x: yAxisX, y: window.maxY + overshoot * 0.5), end = CGPoint(x: yAxisX, y: window.minY - overshoot)
            stroke(line: start, end, with: ink, width: axisWidth, in: &context)
            arrowHead(at: end, from: start, in: &context, width: axisWidth)
            text("y", at: CGPoint(x: end.x + (compact ? 9 : 12), y: end.y + 2), size: fontSize, italic: true, in: &context)
        }
        // 原点に点(O)を置いた図は、点の名前と重なるので軸の O を出さない。
        let originIsPoint = figure.points.contains { abs($0.x) < 1e-9 && abs($0.y) < 1e-9 }
        // 点の名前と重なる目盛りの数字は出さない(点の座標は問題に出てくる大事な数なので、点の方を残す)。
        let pointSpots = figure.points.filter { !$0.isHidden }.map { layout($0.x, $0.y) }
        func nearPoint(_ p: CGPoint) -> Bool { pointSpots.contains { hypot($0.x - p.x, $0.y - p.y) < (compact ? 14 : 20) } }
        if hasX && hasY && !originIsPoint { text("O", at: CGPoint(x: yAxisX - (compact ? 8 : 10), y: xAxisY + (compact ? 9 : 11)), size: smallFontSize, in: &context) }
        guard axes.ticks else { return }
        let tick: CGFloat = compact ? 3 : 4
        if hasX {
            for x in ticks(axes.xMin, axes.xMax, pi: axes.piTicks) where abs(x) > 1e-9 {
                let p = layout(x, 0)
                stroke(line: CGPoint(x: p.x, y: p.y - tick), CGPoint(x: p.x, y: p.y + tick), with: ink, width: axisWidth, in: &context)
                if nearPoint(p) { continue }
                text(tickLabel(x, pi: axes.piTicks), at: CGPoint(x: p.x, y: p.y + (compact ? 10 : 13)), size: smallFontSize, color: Theme.secondaryText, in: &context)
            }
        }
        if hasY {
            for y in ticks(axes.yMin, axes.yMax, pi: false) where abs(y) > 1e-9 {
                let p = layout(0, y)
                stroke(line: CGPoint(x: p.x - tick, y: p.y), CGPoint(x: p.x + tick, y: p.y), with: ink, width: axisWidth, in: &context)
                if nearPoint(p) { continue }
                text(tickLabel(y, pi: false), at: CGPoint(x: p.x - (compact ? 6 : 8), y: p.y), size: smallFontSize, color: Theme.secondaryText,
                     anchor: .trailing, in: &context)
            }
        }
    }

    private func ticks(_ low: Double, _ high: Double, pi: Bool) -> [Double] {
        let step = pi ? Double.pi / 2 : TimelineFigure.tickStep(high - low)
        guard step > 0 else { return [] }
        let first = Int(ceil(low / step - 1e-9)), last = Int(floor(high / step + 1e-9))
        guard last >= first, last - first < 60 else { return [] }
        // 窓の端の目盛りは、軸の矢印や文字とぶつかるので出さない。
        return (first...last).map { Double($0) * step }.filter { $0 > low + step * 0.2 && $0 < high - step * 0.2 }
    }

    private func tickLabel(_ value: Double, pi: Bool) -> String {
        if pi {
            let halves = Int((value / (Double.pi / 2)).rounded())
            let sign = halves < 0 ? "−" : ""
            let n = abs(halves)
            if n % 2 == 0 { return n == 2 ? "\(sign)π" : "\(sign)\(n / 2)π" }
            return n == 1 ? "\(sign)π/2" : "\(sign)\(n)π/2"
        }
        let rounded = (value * 1000).rounded() / 1000
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
        return text.replacingOccurrences(of: "-", with: "−")
    }

    private func drawCurves(layout: TimelineFigure.Layout, window: CGRect?, in context: inout GraphicsContext) {
        var clipped = context
        if let window { clipped.clip(to: Path(window.insetBy(dx: -1, dy: -1))) }
        var placedLabels: [CGPoint] = []
        for curve in figure.curves {
            let samples = figure.samples(of: curve)
            var path = Path()
            var previous: CGPoint?
            var visible: [CGPoint] = []
            let jump = (window?.height ?? 400) * 1.5
            for sample in samples {
                guard let sample else { previous = nil; continue }
                let p = layout(sample.x, sample.y)
                // 漸近線をまたぐ所(1/x・tan x)は、縦に大きく跳ぶ。つながない。
                if let q = previous, abs(p.y - q.y) < jump { path.addLine(to: p) } else { path.move(to: p) }
                previous = p
                if window?.insetBy(dx: -1, dy: -1).contains(p) ?? true { visible.append(p) }
            }
            clipped.stroke(path, with: ink, style: StrokeStyle(lineWidth: lineWidth * 1.1, lineCap: .round, lineJoin: .round, dash: curve.dashed ? [6, 4] : []))
            // 曲線の名前(y = x^2 など)は、見えている部分の終わりの近くに置く。
            let label = TimelineFigure.displayLabel(curve.label)
            if !label.isEmpty, visible.count > 4 {
                // 点の名前やほかの曲線の名前と重ならない所を、見えている部分の終わりの近くから順に探す。
                // 軸の線の上も避ける(軸に名前が掛かると読めない)。
                var axisSpots: [CGPoint] = []
                if let axes = figure.axes, let window {
                    let origin = layout(0, 0)
                    if axes.yMin <= 0, axes.yMax >= 0 { axisSpots += stride(from: window.minX, through: window.maxX, by: 16).map { CGPoint(x: $0, y: origin.y) } }
                    if axes.xMin <= 0, axes.xMax >= 0 { axisSpots += stride(from: window.minY, through: window.maxY, by: 16).map { CGPoint(x: origin.x, y: $0) } }
                }
                let spots = figure.points.filter { !$0.isHidden }.map { layout($0.x, $0.y) } + placedLabels + axisSpots
                let candidates = [0.88, 0.78, 0.95, 1.0, 0.65, 0.5, 0.35, 0.2, 0.08, 0.0].map { visible[Int(Double(visible.count - 1) * $0)] }
                // 名前は点の左上か右上に出る。名前の枠と、点・軸・ほかの名前との離れ具合で選ぶ。
                let width = CGFloat(label.count) * angleFontSize * 0.6 + 4, height = angleFontSize * 1.2
                func box(_ p: CGPoint) -> CGRect {
                    let right = p.x > (window?.midX ?? 0)
                    return CGRect(x: right ? p.x - 6 - width : p.x + 6, y: p.y - 4 - height, width: width, height: height)
                }
                func clearance(_ p: CGPoint) -> CGFloat {
                    let r = box(p)
                    let gaps = spots.map { s in hypot(max(r.minX - s.x, 0, s.x - r.maxX), max(r.minY - s.y, 0, s.y - r.maxY)) }
                    // 枠が窓からはみ出す所は選ばない。
                    let outside = window.map { !$0.insetBy(dx: -4, dy: -4).contains(r) } ?? false
                    return outside ? -1 : min(gaps.min() ?? .infinity, 40)
                }
                let at = candidates.max { a, b in clearance(a) + 0.5 < clearance(b) } ?? candidates[0]
                let frame = box(at)
                placedLabels += [CGPoint(x: frame.minX, y: frame.midY), CGPoint(x: frame.midX, y: frame.midY), CGPoint(x: frame.maxX, y: frame.midY)]
                text(label, at: CGPoint(x: frame.midX, y: frame.midY), size: angleFontSize, color: Theme.primaryText, weight: .bold, in: &context)
            }
        }
    }

    private func drawFills(layout: TimelineFigure.Layout, window: CGRect?, place: (TimelineFigure.Point) -> CGPoint, in context: inout GraphicsContext) {
        let shade = GraphicsContext.Shading.color(Theme.accentColor.opacity(0.18))
        for region in figure.regions {
            let corners = region.points.compactMap(figure.point).map(place)
            guard corners.count >= 3 else { continue }
            var path = Path()
            path.addLines(corners)
            path.closeSubpath()
            context.fill(path, with: shade)
        }
        var clipped = context
        if let window { clipped.clip(to: Path(window)) }
        for fill in figure.fills {
            guard let upper = TimelineFigure.expression(fill.upper), let lower = TimelineFigure.expression(fill.lower), fill.to > fill.from else { continue }
            let steps = 200
            let xs = (0...steps).map { fill.from + (fill.to - fill.from) * Double($0) / Double(steps) }
            let top = xs.compactMap { x in TimelineFigure.value(upper, "x", x).map { layout(x, $0) } }
            let bottom = xs.reversed().compactMap { x in TimelineFigure.value(lower, "x", x).map { layout(x, $0) } }
            guard top.count > 1, bottom.count > 1 else { continue }
            var path = Path()
            path.addLines(top + bottom)
            path.closeSubpath()
            clipped.fill(path, with: shade)
        }
    }

    // MARK: 円・弧

    private func drawCircles(layout: TimelineFigure.Layout, place: (TimelineFigure.Point) -> CGPoint, in context: inout GraphicsContext) {
        for circle in figure.circles {
            guard let c = figure.point(circle.center), circle.radius > 0 else { continue }
            // 立体では、円は水平な面(底面)の上にあるとして描く(斜めから見ると楕円になる)。
            let points: [CGPoint] = (0...144).map { k in
                let t = Double(k) / 144 * 2 * .pi
                let q = figure.plane(c.x + circle.radius * cos(t), c.y + circle.radius * sin(t), c.z)
                return layout(q.x, q.y)
            }
            // 立体の底の円(上に円錐の頂点や円柱の上の円がある円)は、教科書の見取図と同じく奥の半分を点線にする。
            if figure.isSpace, isBottom(circle) {
                let front = points.enumerated().filter { sin(Double($0.offset) / 144 * 2 * .pi) <= 0 }.map(\.element)
                let back = points.enumerated().filter { sin(Double($0.offset) / 144 * 2 * .pi) >= 0 }.map(\.element)
                var frontPath = Path(), backPath = Path()
                frontPath.addLines(front)
                backPath.addLines(back)
                context.stroke(frontPath, with: ink, style: StrokeStyle(lineWidth: lineWidth))
                context.stroke(backPath, with: ink, style: StrokeStyle(lineWidth: lineWidth, dash: [5, 4]))
                continue
            }
            var path = Path()
            path.addLines(points)
            context.stroke(path, with: ink, style: StrokeStyle(lineWidth: lineWidth, dash: circle.dashed ? [5, 4] : []))
        }
        drawSolidOutlines(layout: layout, place: place, in: &context)
        for arc in figure.arcs {
            guard let c = figure.point(arc.center), let a = figure.point(arc.from), let b = figure.point(arc.to) else { continue }
            let r = hypot(a.x - c.x, a.y - c.y)
            let start = atan2(a.y - c.y, a.x - c.x)
            var end = atan2(b.y - c.y, b.x - c.x)
            while end <= start { end += 2 * .pi }
            let points: [CGPoint] = (0...96).map { k in
                let t = start + (end - start) * Double(k) / 96
                let q = figure.plane(c.x + r * cos(t), c.y + r * sin(t), c.z)
                return layout(q.x, q.y)
            }
            var path = Path()
            path.addLines(points)
            context.stroke(path, with: ink, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            let label = TimelineFigure.displayLabel(arc.label)
            if !label.isEmpty {
                let middle = points[points.count / 2], center = place(c)
                let direction = unit(CGVector(dx: middle.x - center.x, dy: middle.y - center.y))
                text(label, at: middle + direction * (compact ? 10 : 14), size: angleFontSize, color: Theme.accentColor, weight: .bold, in: &context)
            }
        }
    }

    /// 立体の円が底面か(真上か真下に円錐の頂点、または同じ中心の円がある)。
    private func isBottom(_ circle: TimelineFigure.Circle) -> Bool {
        guard let c = figure.point(circle.center) else { return false }
        let above = figure.points.contains { $0.name != c.name && abs($0.x - c.x) < 1e-6 && abs($0.y - c.y) < 1e-6 && $0.z > c.z }
        return above
    }

    /// 円錐と円柱の輪郭。円錐は頂点から底面の楕円への 2 本の接線、円柱は上下の楕円の左右の端を結ぶ 2 本の線。
    /// 斜めから見た楕円の接点はモデルには計算しにくいので、アプリが描く。
    private func drawSolidOutlines(layout: TimelineFigure.Layout, place: (TimelineFigure.Point) -> CGPoint, in context: inout GraphicsContext) {
        guard figure.isSpace else { return }
        func ellipse(_ circle: TimelineFigure.Circle, _ c: TimelineFigure.Point) -> [CGPoint] {
            (0..<360).map { k in
                let t = Double(k) / 360 * 2 * .pi
                let q = figure.plane(c.x + circle.radius * cos(t), c.y + circle.radius * sin(t), c.z)
                return layout(q.x, q.y)
            }
        }
        for circle in figure.circles {
            guard let c = figure.point(circle.center), circle.radius > 0 else { continue }
            let rim = ellipse(circle, c)
            // 円柱: 同じ中心の真上にある同じ半径の円。
            if let top = figure.circles.first(where: { other in
                guard let o = figure.point(other.center) else { return false }
                return abs(o.x - c.x) < 1e-6 && abs(o.y - c.y) < 1e-6 && o.z > c.z && abs(other.radius - circle.radius) < 1e-6
            }), let o = figure.point(top.center) {
                let upper = ellipse(top, o)
                guard let left = rim.indices.min(by: { rim[$0].x < rim[$1].x }), let right = rim.indices.max(by: { rim[$0].x < rim[$1].x }) else { continue }
                stroke(line: rim[left], upper[left], with: ink, width: lineWidth, in: &context)
                stroke(line: rim[right], upper[right], with: ink, width: lineWidth, in: &context)
                continue
            }
            // 円錐: 中心の真上の点(頂点)。円が無い高さの点だけ。
            for apex in figure.points where apex.name != c.name && abs(apex.x - c.x) < 1e-6 && abs(apex.y - c.y) < 1e-6 && apex.z > c.z {
                let hasCircle = figure.circles.contains { figure.point($0.center).map { $0.name == apex.name } ?? false }
                if hasCircle { continue }
                let pa = place(apex)
                let angles = rim.map { atan2($0.y - pa.y, $0.x - pa.x) }
                guard let low = angles.indices.min(by: { angles[$0] < angles[$1] }), let high = angles.indices.max(by: { angles[$0] < angles[$1] }) else { continue }
                stroke(line: pa, rim[low], with: ink, width: lineWidth, in: &context)
                stroke(line: pa, rim[high], with: ink, width: lineWidth, in: &context)
            }
        }
    }

    // MARK: 角

    private func drawAngles(place: (TimelineFigure.Point) -> CGPoint, in context: inout GraphicsContext) {
        // 同じ頂点に印が 2 つ以上ある時(∠ACB と ∠ACD など)は、小さい角から順に弧を外へずらす。同じ半径だと弧と文字が重なる。
        var rank: [Int: Int] = [:]
        for (_, group) in Dictionary(grouping: figure.angles.indices, by: { figure.angles[$0].vertex }) where group.count > 1 {
            let ordered = group.sorted { (figure.degrees(of: figure.angles[$0]) ?? 0) < (figure.degrees(of: figure.angles[$1]) ?? 0) }
            for (position, index) in ordered.enumerated() { rank[index] = position }
        }
        // 角の文字どうしが重なる時(同じ頂点の印、近い頂点の印)は、あとの文字を二等分線に沿って外へずらす。
        var placed: [CGRect] = figure.points.filter { !$0.isHidden }.map { p in
            let c = place(p)
            return CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
        }
        for (index, angle) in figure.angles.enumerated() {
            guard let v = figure.point(angle.vertex), let a = figure.point(angle.from), let b = figure.point(angle.to) else { continue }
            let pv = place(v), pa = place(a), pb = place(b)
            let ua = unit(pa - pv), ub = unit(pb - pv)
            let radius: CGFloat = (compact ? 13 : 20) + CGFloat(rank[index] ?? 0) * (compact ? 9 : 14)
            if angle.right {
                let s = radius * 0.6
                var path = Path()
                path.move(to: pv + ua * s)
                path.addLine(to: pv + ua * s + ub * s)
                path.addLine(to: pv + ub * s)
                context.stroke(path, with: mark, lineWidth: lineWidth)
            } else {
                let start = atan2(ua.dy, ua.dx), end = atan2(ub.dy, ub.dx)
                // 小さい方の角(180° 未満)を回る向き。
                var delta = end - start
                while delta > .pi { delta -= 2 * .pi }
                while delta < -.pi { delta += 2 * .pi }
                for k in 0..<max(1, angle.arcs) {
                    let r = radius + CGFloat(k) * 4
                    var path = Path()
                    path.addArc(center: pv, radius: r, startAngle: .radians(start), endAngle: .radians(start + delta), clockwise: delta < 0)
                    context.stroke(path, with: mark, lineWidth: lineWidth)
                }
            }
            let label = TimelineFigure.displayLabel(angle.label)
            if !label.isEmpty {
                var bisector = unit(CGVector(dx: ua.dx + ub.dx, dy: ua.dy + ub.dy))
                if bisector == .zero { bisector = CGVector(dx: -ua.dy, dy: ua.dx) }
                // 弧の外側に置く。角が小さいほど、弧の近くでは文字が線に掛かるので遠ざける。
                let opening = acos(max(-1, min(1, ua.dx * ub.dx + ua.dy * ub.dy)))
                var distance = radius + CGFloat(max(0, angle.arcs - 1)) * 4 + (compact ? 10 : 14) + (opening < 0.9 ? (compact ? 6 : 10) : 0)
                let size = CGSize(width: CGFloat(label.count) * angleFontSize * 0.62 + 2, height: angleFontSize * 1.15)
                func box(_ d: CGFloat) -> CGRect {
                    let c = pv + bisector * d
                    return CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
                }
                var tries = 0
                while tries < 5, placed.contains(where: { $0.intersects(box(distance)) }) {
                    distance += compact ? 8 : 12
                    tries += 1
                }
                placed.append(box(distance))
                text(label, at: pv + bisector * distance, size: angleFontSize, color: Theme.accentColor, weight: .bold, in: &context)
            }
        }
    }

    // MARK: 線分

    private func drawSegments(place: (TimelineFigure.Point) -> CGPoint, in context: inout GraphicsContext) {
        let planes = figure.points.map(place)
        let centroid = CGPoint(x: planes.map(\.x).reduce(0, +) / CGFloat(max(1, planes.count)), y: planes.map(\.y).reduce(0, +) / CGFloat(max(1, planes.count)))
        for segment in figure.segments {
            guard let a = figure.point(segment.from), let b = figure.point(segment.to) else { continue }
            let pa = place(a), pb = place(b)
            stroke(line: pa, pb, with: ink, width: lineWidth, dash: segment.dashed ? [5, 4] : [], in: &context)
            if segment.head { arrowHead(at: pb, from: pa, in: &context, width: lineWidth) }
            let direction = unit(pb - pa)
            let normal = CGVector(dx: -direction.dy, dy: direction.dx)
            // 印は線の上の点(交点など)と重ならない所に置く。
            let t = CGFloat(figure.markPosition(of: segment))
            let middle = CGPoint(x: pa.x + (pb.x - pa.x) * t, y: pa.y + (pb.y - pa.y) * t)
            // 等しい長さの印: 辺に垂直な短い線。
            if segment.ticks > 0 {
                let half: CGFloat = compact ? 4 : 6, gap: CGFloat = compact ? 3 : 4
                for k in 0..<segment.ticks {
                    let shift = (CGFloat(k) - CGFloat(segment.ticks - 1) / 2) * gap
                    let center = middle + direction * shift
                    stroke(line: center + normal * half, center - normal * half, with: ink, width: lineWidth, in: &context)
                }
            }
            // 平行の印: 辺の向きの矢じり。
            if segment.arrows > 0 {
                let size: CGFloat = compact ? 4 : 6, gap: CGFloat = compact ? 4 : 5
                for k in 0..<segment.arrows {
                    let shift = (CGFloat(k) - CGFloat(segment.arrows - 1) / 2) * gap
                    let tip = middle + direction * (shift + size / 2)
                    var head = Path()
                    head.move(to: tip - direction * size + normal * size * 0.8)
                    head.addLine(to: tip)
                    head.addLine(to: tip - direction * size - normal * size * 0.8)
                    context.stroke(head, with: ink, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
            // 辺の文字(長さなど): 図の外側の向きに添える。
            let label = TimelineFigure.displayLabel(segment.label)
            if !label.isEmpty {
                let side = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
                let outward = (side.x - centroid.x) * normal.dx + (side.y - centroid.y) * normal.dy >= 0 ? normal : CGVector(dx: -normal.dx, dy: -normal.dy)
                text(label, at: side + outward * (compact ? 10 : 14), size: smallFontSize, color: Theme.primaryText, in: &context)
            }
        }
    }

    // MARK: 点

    private func drawPoints(place: (TimelineFigure.Point) -> CGPoint, in context: inout GraphicsContext) {
        for point in figure.points where !point.isHidden {
            let p = place(point)
            let dot: CGFloat = (compact ? 2 : 2.6) * (figure.axes == nil ? 1 : 1.2)
            context.fill(Path(ellipseIn: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2)), with: ink)
            guard !point.name.isEmpty else { continue }
            let direction = figure.labelDirection(of: point)
            let distance: CGFloat = compact ? 10 : 14
            text(TimelineFigure.displayLabel(point.name), at: CGPoint(x: p.x + direction.dx * distance, y: p.y + direction.dy * distance),
                 size: fontSize, in: &context)
        }
    }

    // MARK: 部品

    private func stroke(line a: CGPoint, _ b: CGPoint, with shading: GraphicsContext.Shading, width: CGFloat, dash: [CGFloat] = [],
                        in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        context.stroke(path, with: shading, style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
    }

    private func arrowHead(at tip: CGPoint, from tail: CGPoint, in context: inout GraphicsContext, width: CGFloat) {
        let direction = unit(tip - tail)
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let size: CGFloat = compact ? 6 : 8
        var path = Path()
        path.move(to: tip - direction * size + normal * size * 0.5)
        path.addLine(to: tip)
        path.addLine(to: tip - direction * size - normal * size * 0.5)
        context.stroke(path, with: ink, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private func text(_ string: String, at point: CGPoint, size: CGFloat, color: Color = Theme.primaryText, anchor: UnitPoint = .center,
                      weight: Typography.SansFontName = .medium, italic: Bool = false, in context: inout GraphicsContext) {
        var text = Text(string).font(Typography.sans(size: size, weight: weight))
        if italic { text = text.italic() }
        context.draw(text.foregroundColor(color), at: point, anchor: anchor)
    }

    private func unit(_ v: CGVector) -> CGVector {
        let l = hypot(v.dx, v.dy)
        return l > 0 ? CGVector(dx: v.dx / l, dy: v.dy / l) : .zero
    }
}

private func - (a: CGPoint, b: CGPoint) -> CGVector { CGVector(dx: a.x - b.x, dy: a.y - b.y) }
private func + (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x + v.dx, y: p.y + v.dy) }
private func - (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x - v.dx, y: p.y - v.dy) }
private func * (v: CGVector, s: CGFloat) -> CGVector { CGVector(dx: v.dx * s, dy: v.dy * s) }
