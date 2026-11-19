import SwiftUI

/// 図形の問題の図(`TimelineFigure`)を描く。点・線分・角の弧と文字・等しい長さと平行の印・円。
/// 教科書の図と同じく、線は本文の色の細い線、点の名前と角の文字は本文と同じ書体にする。
struct TimelineFigureView: View {
    let figure: TimelineFigure
    /// 一覧に並べた小さいカード(`TimelineProblemView` の compact)。
    var compact = false

    private var inset: CGFloat { compact ? 18 : 26 }
    private var fontSize: CGFloat { compact ? 12 : 16 }
    private var angleFontSize: CGFloat { compact ? 11 : 14 }
    private var lineWidth: CGFloat { compact ? 1.2 : 1.6 }

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .aspectRatio(figure.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: compact ? 140 : 260)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("timeline-figure")
    }

    /// VoiceOver で読む図の中身(点と線と角の文字)。
    private var accessibilityText: String {
        var parts: [String] = ["図"]
        if !figure.segments.isEmpty { parts.append("線分 " + figure.segments.map { $0.from + $0.to }.joined(separator: "、")) }
        let labeled = figure.angles.filter { !$0.label.isEmpty }
        if !labeled.isEmpty {
            parts.append(labeled.map { "角\($0.from)\($0.vertex)\($0.to) は \(TimelineFigure.displayLabel($0.label))" }.joined(separator: "、"))
        }
        return parts.joined(separator: "。")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let place = figure.transform(in: size, inset: inset)
        let ink = GraphicsContext.Shading.color(Theme.primaryText)
        let mark = GraphicsContext.Shading.color(Theme.accentColor)

        // 円
        if let bounds = figure.bounds {
            let scale = min((size.width - inset * 2) / max(bounds.width, 1e-9), (size.height - inset * 2) / max(bounds.height, 1e-9))
            for circle in figure.circles {
                guard let center = figure.point(circle.center) else { continue }
                let c = place(center), r = circle.radius * scale
                context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: ink, lineWidth: lineWidth)
            }
        }

        // 角の弧と直角の印(線の下に置く)
        for angle in figure.angles {
            guard let v = figure.point(angle.vertex), let a = figure.point(angle.from), let b = figure.point(angle.to) else { continue }
            let pv = place(v), pa = place(a), pb = place(b)
            let ua = unit(pa - pv), ub = unit(pb - pv)
            let radius: CGFloat = compact ? 13 : 20
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
                let distance = radius + CGFloat(max(0, angle.arcs - 1)) * 4 + (compact ? 10 : 14) + (opening < 0.9 ? (compact ? 6 : 10) : 0)
                let text = Text(label).font(Typography.sans(size: angleFontSize, weight: .bold)).foregroundColor(Theme.accentColor)
                context.draw(text, at: pv + bisector * distance, anchor: .center)
            }
        }

        // 線分と印
        for segment in figure.segments {
            guard let a = figure.point(segment.from), let b = figure.point(segment.to) else { continue }
            let pa = place(a), pb = place(b)
            var path = Path()
            path.move(to: pa)
            path.addLine(to: pb)
            context.stroke(path, with: ink, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: segment.dashed ? [5, 4] : []))
            let direction = unit(pb - pa)
            let normal = CGVector(dx: -direction.dy, dy: direction.dx)
            let middle = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
            // 等しい長さの印: 辺に垂直な短い線。
            if segment.ticks > 0 {
                let half: CGFloat = compact ? 4 : 6, gap: CGFloat = compact ? 3 : 4
                for k in 0..<segment.ticks {
                    let shift = (CGFloat(k) - CGFloat(segment.ticks - 1) / 2) * gap
                    let center = middle + direction * shift
                    var tick = Path()
                    tick.move(to: center + normal * half)
                    tick.addLine(to: center - normal * half)
                    context.stroke(tick, with: ink, lineWidth: lineWidth)
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
        }

        // 点と名前
        for point in figure.points {
            let p = place(point)
            let dot: CGFloat = compact ? 2 : 2.6
            context.fill(Path(ellipseIn: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2)), with: ink)
            guard !point.name.isEmpty else { continue }
            let direction = figure.labelDirection(of: point)
            let distance: CGFloat = compact ? 10 : 14
            let text = Text(point.name).font(Typography.sans(size: fontSize, weight: .medium)).foregroundColor(Theme.primaryText)
            context.draw(text, at: CGPoint(x: p.x + direction.dx * distance, y: p.y + direction.dy * distance), anchor: .center)
        }
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
