import Observation
import SwiftUI

// 送る → 採点中 → 結果を、1つの液体の形の変化でつなぐ(#issue)。
// - 「送る」は上に引いた時だけ送る。指に合わせてボタンからしずくが引き出され、指を止めればその形で止まる。
//   くびれが切れる所まで引いて離すか、速くはじくと送る。タップでは送らず、しずくが少し顔を出して「上にスワイプで送る」を出す。
// - 送ると、ボタンが横に伸びて「採点中」のカプセルになる。
// - 採点が終わると、カプセルからしずくが出て、結果の ○(×)の位置まで流れ、真ん中が開いて ○ になる。カプセルは「次へ」に戻る。
// 形はどれもバネで動かす(止まる位置を決めるのはバネ、時間で決めない)。液体のくびれは、ぼかしてからしきい値で切る
// (SwiftUI の Canvas の alphaThreshold)。

/// 1つの値を目標へ寄せるバネ(減衰振動)。`dampingRatio` が 1 未満だと行き過ぎて揺れる。
nonisolated struct LiquidSpring: Equatable {
    var value: Double
    var velocity: Double = 0
    var target: Double
    var stiffness: Double = 200
    var dampingRatio: Double = 1

    init(_ value: Double) {
        self.value = value
        self.target = value
    }

    mutating func aim(_ target: Double, stiffness: Double, dampingRatio: Double) {
        self.target = target
        self.stiffness = stiffness
        self.dampingRatio = dampingRatio
    }

    /// 指で持っている間など、その場に置く(揺れも消す)。
    mutating func hold(_ value: Double) {
        self.value = value
        target = value
        velocity = 0
    }

    mutating func step(_ dt: Double) {
        let damping = 2 * stiffness.squareRoot() * dampingRatio
        velocity += (-stiffness * (value - target) - damping * velocity) * dt
        value += velocity * dt
    }

    var isSettled: Bool { abs(value - target) < 0.01 && abs(velocity) < 0.05 }
}

/// 角の丸い四角(円もこれで表す)。中心と半分の幅・高さ。
nonisolated struct LiquidShape: Equatable {
    var center: CGPoint
    var halfWidth: Double
    var halfHeight: Double

    var rect: CGRect {
        CGRect(x: center.x - halfWidth, y: center.y - halfHeight, width: halfWidth * 2, height: halfHeight * 2)
    }

    var isVisible: Bool { halfWidth > 0.5 && halfHeight > 0.5 }

    var path: Path {
        let r = min(halfWidth, halfHeight)
        return Path(roundedRect: rect, cornerRadius: r, style: .continuous)
    }
}

/// 送るを引いた時の決まり(引いた距離・速さ → 形と、送るかどうか)。
nonisolated enum LiquidPull {
    /// 指の移動のうち、しずくが 1:1 でついてくる長さ。これを超えると重くなる。
    static let follow: Double = 150
    /// ここまで引いて離したら送る(くびれが切れるあたり)。
    static let commitDistance: Double = 115
    /// これより速く上にはじいたら、距離が短くても送る(pt/秒、上が負)。
    static let commitVelocity: Double = -650

    /// しずくの中心がボタンの上端からどれだけ上にあるか。
    static func travel(up: Double) -> Double {
        let up = max(0, up)
        return up < follow ? up * 0.9 : follow * 0.9 + (up - follow) * 0.3
    }

    /// 0(引き始め)〜 1(くびれが切れるあたり)。
    static func progress(up: Double) -> Double { min(1, max(0, up) / follow) }

    static func commits(up: Double, velocity: Double) -> Bool {
        up > commitDistance || velocity < commitVelocity
    }
}

@MainActor
@Observable
final class TimelineLiquid {
    enum Stage: Equatable {
        /// 何もしていない(ボタンは普段の見た目)。
        case idle
        /// 送るボタンを引いている、タップの案内を出している、送った直後で戻っている。
        case pulling
        /// 採点中のカプセル。
        case grading
        /// しずくが ○ へ流れている。
        case emerging
    }

    private(set) var stage: Stage = .idle
    /// 「上にスワイプで送る」の案内。
    private(set) var showsGuide = false
    /// 触覚の合図(数が変わるたびに鳴らす)。
    private(set) var pinchFeedback = 0
    private(set) var sendFeedback = 0
    /// しずくが ○(×)の位置に着いた(結果の ○ を見せてよい)。
    private(set) var hasLanded = true

    var reduceMotion = false

    /// 送るボタン(と、その後の採点中・次へ)の円の中心と半径。液体の層の座標で受け取る(`setSlot`)。
    @ObservationIgnored private(set) var slotCenter: CGPoint = .zero
    @ObservationIgnored private(set) var slotRadius: Double = 36
    /// ボタンの場所をまだ知らない(写真で送った時など、送るボタンを出さずに採点に入った最初の時)。
    /// 知らないまま置くと、画面の左上から流れてくる。場所が分かった時に置く。
    @ObservationIgnored private var slotKnown = false
    @ObservationIgnored private var needsPlacement = false
    /// 結果の ○ の中心と半径。
    @ObservationIgnored var markCenter: CGPoint?
    @ObservationIgnored var markRadius: Double = 11

    // 形はどれもバネ。描くたびに `advance(to:)` で今の時刻まで進める(観測しない: 描くたびに変わるため)。
    @ObservationIgnored private var a = Blob()
    @ObservationIgnored private var b = Blob()
    /// しずくの色(0 = 銅、1 = ○ の色)と、輪の開き具合(0 = 塗りつぶし、1 = 細い輪)。
    @ObservationIgnored private var mix = LiquidSpring(0)
    @ObservationIgnored private var ring = LiquidSpring(0)
    @ObservationIgnored private var lastDate: Date?
    @ObservationIgnored private var wasPinched = false
    @ObservationIgnored private var guideTask: Task<Void, Never>?
    @ObservationIgnored private var sequence: Task<Void, Never>?
    @ObservationIgnored private var correct = true

    private struct Blob {
        var x = LiquidSpring(0)
        var y = LiquidSpring(0)
        var w = LiquidSpring(0)
        var h = LiquidSpring(0)

        mutating func hold(_ center: CGPoint, _ halfWidth: Double, _ halfHeight: Double) {
            x.hold(center.x); y.hold(center.y); w.hold(halfWidth); h.hold(halfHeight)
        }

        mutating func step(_ dt: Double) {
            x.step(dt); y.step(dt); w.step(dt); h.step(dt)
        }

        var shape: LiquidShape {
            LiquidShape(center: CGPoint(x: x.value, y: y.value), halfWidth: max(0, w.value), halfHeight: max(0, h.value))
        }

        var isSettled: Bool { x.isSettled && y.isSettled && w.isSettled && h.isSettled }
    }

    /// 描く必要があるか(普段のボタンの見た目の時は描かない)。
    var isActive: Bool { stage != .idle }

    private func z(_ ratio: Double) -> Double { reduceMotion ? 1 : ratio }

    /// ボタンの場所が分かった・変わった(採点中のカプセルや「次へ」もここに置く)。
    func setSlot(center: CGPoint, radius: Double) {
        slotCenter = center
        slotRadius = radius
        slotKnown = true
        if needsPlacement {
            needsPlacement = false
            a.hold(center, radius, radius)
            if stage == .grading { startGrading() }
            return
        }
        switch stage {
        case .idle:
            a.hold(center, radius, radius)
        case .grading:
            a.x.aim(center.x, stiffness: 260, dampingRatio: 1)
            a.y.aim(center.y, stiffness: 260, dampingRatio: 1)
        case .pulling, .emerging:
            break
        }
    }

    // MARK: 送る

    /// 送るボタンを `up` pt 上に引いている。
    func pull(up: Double) {
        sequence?.cancel()
        stage = .pulling
        hideGuide()
        let travel = LiquidPull.travel(up: up)
        let p = LiquidPull.progress(up: up)
        let size = 10 + 8 * min(1, p / 0.3)
        a.hold(CGPoint(x: slotCenter.x, y: slotCenter.y - 6 * p), slotRadius - 4 * p, slotRadius + 6 * p)
        b.hold(CGPoint(x: slotCenter.x, y: slotCenter.y - (slotRadius - 2) - travel * 0.78), size, size + min(8, travel * 0.05))
        mix.hold(0); ring.hold(0)
        let pinched = up > LiquidPull.commitDistance
        if pinched != wasPinched {
            wasPinched = pinched
            if pinched { pinchFeedback += 1 }
        }
    }

    /// 指を離した。送るなら true を返す(呼んだ側が答案を送る)。
    @discardableResult
    func release(up: Double, velocity: Double) -> Bool {
        let commit = LiquidPull.commits(up: up, velocity: velocity)
        wasPinched = false
        // しずくはいつもボタンに戻る。送ったかどうかは、ボタンがその後どうなるかで分かる。
        b.y.aim(slotCenter.y - 10, stiffness: 260, dampingRatio: z(0.7))
        b.y.velocity = max(0, -velocity * 0.3)
        b.w.aim(0, stiffness: 220, dampingRatio: 1)
        b.h.aim(0, stiffness: 220, dampingRatio: 1)
        a.y.aim(slotCenter.y, stiffness: 260, dampingRatio: z(0.35))
        if commit {
            sendFeedback += 1
            startGrading()
        } else {
            a.w.aim(slotRadius, stiffness: 300, dampingRatio: z(0.3))
            a.h.aim(slotRadius, stiffness: 300, dampingRatio: z(0.3))
            settleThenIdle()
        }
        return commit
    }

    /// タップした: 送らずに、しずくが少しだけ顔を出して戻り、「上にスワイプで送る」を出す。
    func hint() {
        sequence?.cancel()
        showGuide()
        guard !reduceMotion else { return }
        stage = .pulling
        a.hold(slotCenter, slotRadius, slotRadius)
        b.hold(CGPoint(x: slotCenter.x, y: slotCenter.y - (slotRadius - 6)), 10, 10)
        mix.hold(0); ring.hold(0)
        b.y.aim(slotCenter.y - slotRadius - 26, stiffness: 120, dampingRatio: 0.7)
        b.w.aim(13, stiffness: 200, dampingRatio: 0.6)
        b.h.aim(14, stiffness: 200, dampingRatio: 0.6)
        sequence = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            guard let self, !Task.isCancelled else { return }
            self.b.y.aim(self.slotCenter.y - 12, stiffness: 160, dampingRatio: 0.75)
            self.b.w.aim(0, stiffness: 140, dampingRatio: 1)
            self.b.h.aim(0, stiffness: 140, dampingRatio: 1)
            self.a.h.velocity -= 60
            self.a.w.velocity += 50
            self.settleThenIdle()
        }
    }

    // MARK: 採点中

    /// ボタンが横に伸びて「採点中」のカプセルになる(幅と高さの落ち着く速さが違うので、液体のように揺れる)。
    func startGrading() {
        if stage == .idle {
            if slotKnown {
                a.hold(slotCenter, slotRadius, slotRadius)
            } else {
                a.hold(slotCenter, 0, 0)
                needsPlacement = true
            }
            b.hold(slotCenter, 0, 0)
            mix.hold(0); ring.hold(0)
        }
        sequence?.cancel()
        stage = .grading
        guard !needsPlacement else { return }
        hasLanded = true
        hideGuide()
        a.x.aim(slotCenter.x, stiffness: 260, dampingRatio: 1)
        a.w.aim(slotRadius + 16, stiffness: 150, dampingRatio: z(0.42))
        a.h.aim(22, stiffness: 320, dampingRatio: z(0.32))
        a.y.aim(slotCenter.y, stiffness: 300, dampingRatio: z(0.5))
    }

    /// 採点中のカプセルを押した: ぷるんと揺れる。
    func poke() {
        guard stage == .grading, !reduceMotion else { return }
        a.w.velocity += 140
        a.h.velocity -= 110
    }

    // MARK: 結果

    /// 採点が終わった: カプセルからしずくが出て、結果の ○(×)の位置へ流れる。
    func emerge(correct: Bool) {
        guard stage == .grading else { return }
        sequence?.cancel()
        self.correct = correct
        stage = .emerging
        hasLanded = false
        let start = CGPoint(x: a.x.value - a.w.value + 10, y: a.y.value)
        b.hold(start, 8, 8)
        mix.hold(0); ring.hold(0)
        b.w.aim(18, stiffness: 220, dampingRatio: z(0.6))
        b.h.aim(18, stiffness: 220, dampingRatio: z(0.6))
        sequence = Task { [weak self] in
            guard let self else { return }
            func wait(_ ms: Int) async -> Bool {
                try? await Task.sleep(for: .milliseconds(ms))
                return !Task.isCancelled
            }
            guard await wait(60) else { return }
            self.b.x.aim(self.a.x.value - self.a.w.value - 40, stiffness: 180, dampingRatio: self.z(0.8))
            guard await wait(60) else { return }
            // カプセルは丸い「次へ」に戻る。
            self.a.w.aim(self.slotRadius, stiffness: 180, dampingRatio: self.z(0.4))
            self.a.h.aim(self.slotRadius, stiffness: 260, dampingRatio: self.z(0.4))
            guard await wait(140) else { return }
            self.a.x.aim(self.slotCenter.x, stiffness: 260, dampingRatio: 1)
            self.a.y.aim(self.slotCenter.y, stiffness: 260, dampingRatio: 1)
            guard let mark = self.markCenter else {
                // ○ × の無い結果: しずくはカプセルに戻すだけ。
                self.b.w.aim(0, stiffness: 220, dampingRatio: 1)
                self.b.h.aim(0, stiffness: 220, dampingRatio: 1)
                self.hasLanded = true
                guard await wait(400) else { return }
                self.stage = .idle
                return
            }
            let radius = self.markRadius
            self.b.x.aim(mark.x, stiffness: 95, dampingRatio: self.z(0.78))
            self.b.y.aim(mark.y, stiffness: 95, dampingRatio: self.z(0.78))
            self.b.w.aim(radius, stiffness: 200, dampingRatio: self.z(0.6))
            self.b.h.aim(radius, stiffness: 200, dampingRatio: self.z(0.6))
            guard await wait(440) else { return }
            if correct {
                // 真ん中が開いて ○ になる。
                self.ring.aim(1, stiffness: 160, dampingRatio: self.z(0.55))
                self.mix.aim(1, stiffness: 120, dampingRatio: 1)
                guard await wait(220) else { return }
            } else {
                // × はしずくが沈んでから描く。
                self.b.w.aim(0, stiffness: 220, dampingRatio: 1)
                self.b.h.aim(0, stiffness: 220, dampingRatio: 1)
                self.mix.aim(1, stiffness: 160, dampingRatio: 1)
                guard await wait(80) else { return }
            }
            self.hasLanded = true
            guard await wait(260) else { return }
            self.stage = .idle
        }
    }

    /// 次の問題に移った・画面を離れた: 普段の見た目に戻す。
    func reset() {
        sequence?.cancel()
        hideGuide()
        stage = .idle
        needsPlacement = false
        hasLanded = true
        wasPinched = false
        a.hold(slotCenter, slotRadius, slotRadius)
        b.hold(slotCenter, 0, 0)
        mix.hold(0); ring.hold(0)
    }

    /// 普段の見た目のボタンに戻ったら、描くのをやめる。
    private func settleThenIdle() {
        sequence?.cancel()
        sequence = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if self.a.isSettled, !self.b.shape.isVisible, self.stage == .pulling {
                    self.stage = .idle
                    return
                }
            }
        }
    }

    private func showGuide() {
        guideTask?.cancel()
        showsGuide = true
        guideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            guard let self, !Task.isCancelled else { return }
            self.showsGuide = false
        }
    }

    private func hideGuide() {
        guideTask?.cancel()
        showsGuide = false
    }

    // MARK: 描く

    struct Frame {
        /// 銅色の液体(ボタン・カプセルと、そこから出たしずく)。
        var button: LiquidShape
        var drop: LiquidShape
        /// ボタンとしずくの間のくびれ(離れると細くなり、切れる)。
        var neck: Path?
        /// しずくのうち、○ の色で描く割合。
        var markMix: Double
        /// 輪の線の太さと、線の中心の半径(線の太さが 0 なら塗りつぶし)。
        var ringWidth: Double
        var ringRadius: Double
    }

    /// くびれが切れる、しずくとボタンの縁の間の距離。
    nonisolated static let neckReach: Double = 75

    /// `date` の時刻まで進めた形。
    func frame(at date: Date) -> Frame {
        if let last = lastDate {
            let dt = min(1.0 / 30, max(0, date.timeIntervalSince(last)))
            // 小さく刻んで進める(硬いバネでも発散しないように)。
            let steps = 3
            for _ in 0..<steps {
                a.step(dt / Double(steps)); b.step(dt / Double(steps))
                mix.step(dt / Double(steps)); ring.step(dt / Double(steps))
            }
        }
        lastDate = date
        let drop = b.shape
        let button = a.shape
        let r = min(drop.halfWidth, drop.halfHeight)
        // 塗りつぶしの丸(内側の半径 0)から、○ と同じ太さの輪へ。○ は直径 2r の円を太さ max(1.5, 2r/7) の線で描く。
        let t = max(0, min(1, ring.value))
        let finalWidth = max(1.5, 2 * markRadius / 7)
        let outer = r + finalWidth / 2 * t
        let inner = max(0, r - finalWidth / 2) * t
        let mixValue = max(0, min(1, mix.value))
        return Frame(button: button, drop: drop,
                     neck: mixValue < 0.01 ? Self.neck(from: button, to: drop) : nil,
                     markMix: mixValue,
                     ringWidth: t > 0.01 ? outer - inner : 0, ringRadius: (outer + inner) / 2)
    }

    /// ボタンの縁からしずくへ伸びる、真ん中のすぼまった帯。離れるほど細くなり、`neckReach` で消える。
    nonisolated static func neck(from button: LiquidShape, to drop: LiquidShape) -> Path? {
        guard button.isVisible, drop.isVisible else { return nil }
        let dx = drop.center.x - button.center.x, dy = drop.center.y - button.center.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.5 else { return nil }
        let ux = dx / length, uy = dy / length
        // ボタンの縁までの距離(楕円で近似)。
        let edge = 1 / ((ux / button.halfWidth) * (ux / button.halfWidth) + (uy / button.halfHeight) * (uy / button.halfHeight)).squareRoot()
        let gap = length - edge
        let s = max(0, gap) / neckReach
        guard s < 1 else { return nil }
        let dropRadius = min(drop.halfWidth, drop.halfHeight)
        let base = dropRadius * 1.1 * (1 - s)
        let waist = dropRadius * 0.7 * pow(1 - s, 1.5)
        let top = dropRadius * 0.8
        let nx = -uy, ny = ux
        let p0 = CGPoint(x: button.center.x + ux * (edge - 4), y: button.center.y + uy * (edge - 4))
        let p1 = drop.center
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        func offset(_ p: CGPoint, _ d: Double) -> CGPoint { CGPoint(x: p.x + nx * d, y: p.y + ny * d) }
        var path = Path()
        path.move(to: offset(p0, base))
        path.addQuadCurve(to: offset(p1, top), control: offset(mid, waist * 2 - (base + top) / 2))
        path.addLine(to: offset(p1, -top))
        path.addQuadCurve(to: offset(p0, -base), control: offset(mid, -(waist * 2 - (base + top) / 2)))
        path.closeSubpath()
        return path
    }

    /// 描き始める前に、ボタンを今の場所に置く。
    func prepare() {
        if stage == .idle {
            a.hold(slotCenter, slotRadius, slotRadius)
            b.hold(slotCenter, 0, 0)
        }
        lastDate = nil
    }
}

/// 液体を描く層。画面の座標で、ボタンの円・カプセル・しずく・○ を描く。指は通す。
struct TimelineLiquidLayer: View {
    let liquid: TimelineLiquid
    let correct: Bool

    var body: some View {
        TimelineView(.animation(paused: !liquid.isActive)) { context in
            Canvas { canvas, _ in
                guard liquid.isActive else { return }
                let frame = liquid.frame(at: context.date)
                let accent = Theme.accentColor
                let markColor = correct ? Theme.growthColor : Theme.regressColor
                // ボタンと、そこから出たしずく: ぼかしてからしきい値で切ると、近い形同士がくびれでつながる。
                // (フィルタは後に足したものから先にかかる: ぼかす → しきい値で切る → 縁を少しなめらかに → 影)
                canvas.drawLayer { layer in
                    layer.addFilter(.shadow(color: .black.opacity(0.16), radius: 8, y: 3))
                    layer.addFilter(.blur(radius: 0.5))
                    layer.addFilter(.alphaThreshold(min: 0.5, color: accent))
                    layer.addFilter(.blur(radius: 5))
                    layer.drawLayer { shapes in
                        if frame.button.isVisible { shapes.fill(frame.button.path, with: .color(.black)) }
                        if let neck = frame.neck { shapes.fill(neck, with: .color(.black)) }
                        if frame.drop.isVisible, frame.markMix < 0.01 { shapes.fill(frame.drop.path, with: .color(.black)) }
                    }
                }
                // ○ の色に変わっていくしずくと、真ん中が開いて輪になったしずく(ここからは切れているので、しきい値を通さずに描く)。
                if frame.drop.isVisible, frame.markMix >= 0.01 {
                    let shading: GraphicsContext.Shading = .color(markColor)
                    let base: GraphicsContext.Shading = .color(accent)
                    if frame.ringWidth > 0 {
                        let c = frame.drop.center, rr = frame.ringRadius
                        let circle = Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
                        var under = canvas
                        under.opacity = 1 - frame.markMix
                        under.stroke(circle, with: base, lineWidth: frame.ringWidth)
                        var over = canvas
                        over.opacity = frame.markMix
                        over.stroke(circle, with: shading, lineWidth: frame.ringWidth)
                    } else {
                        var under = canvas
                        under.opacity = 1 - frame.markMix
                        under.fill(frame.drop.path, with: base)
                        var over = canvas
                        over.opacity = frame.markMix
                        over.fill(frame.drop.path, with: shading)
                    }
                }
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 送るボタン。上に引いた時だけ送る(誤って送らないように)。タップでは、しずくが少し顔を出して「上にスワイプで送る」を出す。
/// VoiceOver では、ボタンとして実行すれば送る。
struct TimelineSendButton: View {
    let liquid: TimelineLiquid
    var diameter: CGFloat = 72
    var isEnabled = true
    /// 送れたら true(書いたものが無ければ false)。
    let send: () -> Bool

    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: TimelineSymbol.send)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(isEnabled ? Theme.onAccent : Theme.accentColor)
                .frame(width: diameter, height: diameter)
                .background {
                    // 引いている間は、液体の層が円を描く(円はしずくとくびれでつながる)。
                    Circle()
                        .fill(isEnabled ? Theme.accentColor : Theme.accentColor.opacity(0.16))
                        .shadow(color: .black.opacity(isEnabled ? 0.18 : 0.06), radius: isEnabled ? 10 : 4, y: 3)
                        .opacity(liquid.isActive ? 0 : 1)
                }
                .timelineLiquidSlot()
                .overlay(alignment: .trailing) {
                    if liquid.showsGuide {
                        Text("上にスワイプで送る")
                            .font(Typography.sans(size: 13, weight: .bold))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.card, in: Capsule())
                            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                            .offset(x: -(diameter + 10))
                            .transition(.opacity.combined(with: .offset(x: 6)))
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: Theme.Duration.quick), value: liquid.showsGuide)
            Text("送る").font(Typography.sans(size: 12, weight: .bold)).foregroundStyle(Theme.secondaryText)
        }
        .contentShape(Rectangle())
        .gesture(pull)
        .disabled(!isEnabled)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: liquid.pinchFeedback)
        .sensoryFeedback(.impact(weight: .medium), trigger: liquid.sendFeedback)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("送る")
        .accessibilityHint("上にスワイプで送る")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !send() { liquid.reset() } }
        .accessibilityIdentifier("timeline-send")
    }

    private var pull: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    // 少し動くまではタップとして扱う。
                    guard abs(value.translation.height) > 6 || abs(value.translation.width) > 6 else { return }
                    isDragging = true
                }
                liquid.pull(up: -value.translation.height)
            }
            .onEnded { value in
                defer { isDragging = false }
                guard isDragging else {
                    liquid.hint()
                    return
                }
                if liquid.release(up: -value.translation.height, velocity: value.velocity.height), !send() {
                    liquid.reset()
                }
            }
    }
}

/// 液体の層の座標(タイムラインの、ボタンと問題の欄を重ねた ZStack)。
enum TimelineLiquidSpace {
    static let name = "timeline-liquid"
}

/// 送る・採点中・次へ の円の場所。
struct TimelineLiquidSlotKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

/// 結果の ○ × の場所。
struct TimelineLiquidMarkKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

extension View {
    /// この円を、液体のボタンの場所として知らせる。
    func timelineLiquidSlot() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: TimelineLiquidSlotKey.self, value: proxy.frame(in: .named(TimelineLiquidSpace.name)))
            }
        }
    }

    /// この印を、しずくが流れ着く結果の ○ × の場所として知らせる。
    func timelineLiquidMark() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: TimelineLiquidMarkKey.self, value: proxy.frame(in: .named(TimelineLiquidSpace.name)))
            }
        }
    }
}

extension EnvironmentValues {
    /// しずくがまだ ○ × の場所に着いていない(着くまで結果の印を隠す)。
    @Entry var timelineHidesResultMark = false
}
