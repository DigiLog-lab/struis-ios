import Observation
import UIKit
import SwiftUI

// 質問・撮る・単元のチップを、引っぱって開く。
// - ボタン(チップ)を、開く画面の方へ引くと、Liquid Glass のままその画面の形まで伸びる。指を止めればその形で止まる。
//   離した位置と速さで、開くか戻るかを決める。開く時は、形が画面の大きさになったところで本物の画面に入れ替える。
// - タップでは開かない。引く方向に少しだけ顔を出して戻る(送るボタンと同じく、動かし方を形で伝える)。
// - VoiceOver では、ボタンとして実行すれば開く。
// - 形は2つのバネで動かす。先を行く形(指についていく)と、少し遅れてついてくる形をガラスで溶け合わせると、
//   伸びる時に液体のように先がふくらむ。

enum TimelinePullKind: Hashable {
    /// 質問の画面(iPhone は下からのシート、iPad は右の欄)。
    case ask
    /// カメラ(画面いっぱい)。
    case camera
    /// 解く範囲(単元)の一覧のシート。
    case scope
}

/// 開く画面の形(画面全体の座標)。
struct TimelinePullTarget: Equatable {
    var rect: CGRect
    var cornerRadius: Double
}

/// 引いた量・速さ → 開くかどうか。
nonisolated enum TimelinePullRule {
    /// ボタンから画面までの距離がこれより短くても、これだけ引けば開ききる。
    static let minimumSpan: Double = 180
    /// 離した時にここまで来ていたら開く。
    static let openProgress: Double = 0.42
    /// これより速く開く方へはじいたら、短くても開く(1秒あたりの割合)。
    static let openVelocity: Double = 1.8

    static func opens(progress: Double, velocity: Double) -> Bool {
        progress > openProgress || (velocity > openVelocity && progress > 0.06)
    }

    /// 指の進み → 形の進み。開ききった先は重くする。
    static func progress(distance: Double, span: Double) -> Double {
        let p = distance / max(span, 1)
        return p <= 1 ? p : 1 + (p - 1) * 0.25
    }
}

@MainActor
@Observable
final class TimelinePullOut {
    /// 今動いているもの(無ければ描かない)。
    private(set) var active: TimelinePullKind?
    /// 開いてよい(数が変わったら、呼んだ側が `openedKind` の画面を出す)。
    private(set) var openRequest = 0
    private(set) var openedKind: TimelinePullKind?
    /// 触覚の合図(開くと決まった時)。
    private(set) var commitFeedback = 0

    var reduceMotion = false

    /// ボタンの場所と、開く画面の場所(どちらも画面全体の座標)。
    @ObservationIgnored var origins: [TimelinePullKind: CGRect] = [:]
    @ObservationIgnored var targets: [TimelinePullKind: TimelinePullTarget] = [:]
    /// 描く層の左上(画面全体の座標)。
    @ObservationIgnored var layerOrigin: CGPoint = .zero

    @ObservationIgnored private var lead = LiquidSpring(0)
    @ObservationIgnored private var trail = LiquidSpring(0)
    /// 画面に入れ替えた後、ガラスを消していく割合(1 = 見えている)。
    @ObservationIgnored private var visibility = LiquidSpring(1)
    @ObservationIgnored private var lastDate: Date?
    @ObservationIgnored private var committing = false
    @ObservationIgnored private var sequence: Task<Void, Never>?

    // MARK: 指

    /// 開く方向(ボタンの中心 → 画面の中心)と、開ききるまでの距離。
    func direction(_ kind: TimelinePullKind) -> (x: Double, y: Double, span: Double)? {
        guard let origin = origins[kind], let target = targets[kind] else { return nil }
        let dx = target.rect.midX - origin.midX, dy = target.rect.midY - origin.midY
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1 else { return nil }
        return (dx / length, dy / length, max(TimelinePullRule.minimumSpan, length))
    }

    /// `kind` を `translation` だけ引いている。
    func pull(_ kind: TimelinePullKind, translation: CGSize) {
        guard let d = direction(kind), active == nil || active == kind, !committing else { return }
        sequence?.cancel()
        active = kind
        visibility.hold(1)
        let along = translation.width * d.x + translation.height * d.y
        lead.hold(max(0, TimelinePullRule.progress(distance: along, span: d.span)))
    }

    /// 指を離した。開くなら true(形が画面の大きさになったら `openRequest` が増える)。
    @discardableResult
    func release(_ kind: TimelinePullKind, translation: CGSize, velocity: CGSize) -> Bool {
        guard active == kind, let d = direction(kind), !committing else { return false }
        let along = translation.width * d.x + translation.height * d.y
        let progress = TimelinePullRule.progress(distance: along, span: d.span)
        let speed = (velocity.width * d.x + velocity.height * d.y) / d.span
        if TimelinePullRule.opens(progress: progress, velocity: speed) {
            open(kind, velocity: speed)
            return true
        }
        lead.aim(0, stiffness: 240, dampingRatio: z(0.7))
        lead.velocity = min(0, speed)
        settleThenIdle()
        return false
    }

    /// タップした: 開く方へ少し顔を出して戻る。
    func peek(_ kind: TimelinePullKind) {
        guard direction(kind) != nil, active == nil || active == kind, !committing, !reduceMotion else { return }
        sequence?.cancel()
        active = kind
        visibility.hold(1)
        lead.aim(0, stiffness: 260, dampingRatio: 0.45)
        lead.velocity = 1.6
        settleThenIdle()
    }

    /// 開く(VoiceOver でボタンとして実行した時も、ここから)。
    func open(_ kind: TimelinePullKind, velocity: Double = 0) {
        guard direction(kind) != nil, !committing else {
            // 形を描けない時(場所がまだ分からない)は、すぐ画面を出す。
            openedKind = kind
            openRequest += 1
            return
        }
        sequence?.cancel()
        active = kind
        committing = true
        commitFeedback += 1
        visibility.hold(1)
        lead.aim(1, stiffness: reduceMotion ? 400 : 190, dampingRatio: z(0.85))
        lead.velocity = max(lead.velocity, velocity)
        sequence = Task { [weak self] in
            // 形が画面の大きさに届いたら、本物の画面に入れ替える。
            while let self, !Task.isCancelled {
                if self.trail.value > 0.96 || self.reduceMotion { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard let self, !Task.isCancelled else { return }
            self.openedKind = kind
            self.openRequest += 1
            try? await Task.sleep(for: .milliseconds(60))
            self.visibility.aim(0, stiffness: 300, dampingRatio: 1)
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            self.finish()
        }
    }

    /// 普段の見た目に戻す。
    func finish() {
        sequence?.cancel()
        committing = false
        active = nil
        lead.hold(0); trail.hold(0); visibility.hold(1)
        lastDate = nil
    }

    private func settleThenIdle() {
        sequence = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if self.lead.isSettled, abs(self.trail.value) < 0.01, self.lead.value < 0.01 {
                    self.active = nil
                    return
                }
            }
        }
    }

    private func z(_ ratio: Double) -> Double { reduceMotion ? 1 : ratio }

    // MARK: 描く

    struct Shape: Equatable {
        var rect: CGRect
        var cornerRadius: Double
    }

    struct Frame {
        var kind: TimelinePullKind
        /// 遅れてついてくる形(ボタンの本体)と、先を行く形。
        var body: Shape
        var tip: Shape?
        /// どこまで開いたか(0 = ボタン、1 = 画面)。
        var progress: Double
        /// ガラスの見え方(画面に入れ替えた後に消える)。
        var opacity: Double
    }

    func frame(at date: Date) -> Frame? {
        guard let kind = active, let origin = origins[kind], let target = targets[kind] else { return nil }
        if let last = lastDate {
            let dt = min(1.0 / 30, max(0, date.timeIntervalSince(last)))
            for _ in 0..<3 {
                trail.aim(lead.value, stiffness: reduceMotion ? 600 : 170, dampingRatio: z(0.55))
                lead.step(dt / 3); trail.step(dt / 3); visibility.step(dt / 3)
            }
        }
        lastDate = date
        let local = origin.offsetBy(dx: -layerOrigin.x, dy: -layerOrigin.y)
        var to = target
        to.rect = target.rect.offsetBy(dx: -layerOrigin.x, dy: -layerOrigin.y)
        let body = Self.shape(origin: local, target: to, t: trail.value, scale: 1)
        let tip = abs(lead.value - trail.value) > 0.01 ? Self.shape(origin: local, target: to, t: lead.value, scale: 0.9) : nil
        return Frame(kind: kind, body: body, tip: tip, progress: max(0, min(1, trail.value)), opacity: max(0, min(1, visibility.value)))
    }

    /// ボタンの形(円・カプセル)から画面の形へ、`t` の割合だけ近づけた形。`scale` は大きさだけを縮める。
    nonisolated static func shape(origin: CGRect, target: TimelinePullTarget, t: Double, scale: Double) -> Shape {
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        let originRadius = min(origin.width, origin.height) / 2
        let grow = max(0, t)
        let width = (origin.width + (target.rect.width - origin.width) * grow) * (grow > 0 ? scale : 1)
        let height = (origin.height + (target.rect.height - origin.height) * grow) * (grow > 0 ? scale : 1)
        let cx = lerp(origin.midX, target.rect.midX), cy = lerp(origin.midY, target.rect.midY)
        let radius = originRadius + (target.cornerRadius - originRadius) * min(1, grow)
        return Shape(rect: CGRect(x: cx - width / 2, y: cy - height / 2, width: max(0, width), height: max(0, height)),
                     cornerRadius: max(0, min(radius, min(width, height) / 2)))
    }
}

/// 引っぱって開く形を描く層(タイムラインの画面全体に重ねる)。指は通す。
struct TimelinePullOutLayer: View {
    let pullOut: TimelinePullOut
    /// 撮るボタンが銅色の大きいボタンの時(iPhone で書く前)。
    let cameraIsProminent: Bool

    var body: some View {
        TimelineView(.animation(paused: pullOut.active == nil)) { context in
            if let frame = pullOut.frame(at: context.date) {
                let style = style(frame)
                ZStack(alignment: .topLeading) {
                    GlassEffectContainer(spacing: 30) {
                        ZStack(alignment: .topLeading) {
                            glass(frame.body, style.glass)
                            if let tip = frame.tip { glass(tip, style.glass) }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    // 開ききる手前から、入れ替わる画面の地の色に寄せる(入れ替わった時に色が跳ねないように)。
                    fill(frame.body, style.ground.opacity(style.groundAmount))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(frame.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { pullOut.layerOrigin = $0 }
    }

    private func style(_ frame: TimelinePullOut.Frame) -> (glass: Glass, ground: Color, groundAmount: Double) {
        let t = frame.progress
        let late = max(0, min(1, (t - 0.55) / 0.45))
        switch frame.kind {
        case .ask:
            return (.regular, Theme.ground, late * late)
        case .scope:
            return (.regular, Theme.card, late * late)
        case .camera:
            // ボタンの色から、カメラの黒へ。
            let dark = min(1, t * 1.6)
            let tint: Color = cameraIsProminent && dark < 0.5 ? Theme.accentColor.opacity(1 - dark * 2) : Color.black.opacity(0.85 * dark)
            return (.regular.tint(tint), .black, late * late)
        }
    }

    private func glass(_ shape: TimelinePullOut.Shape, _ glass: Glass) -> some View {
        Color.clear
            .frame(width: shape.rect.width, height: shape.rect.height)
            .glassEffect(glass, in: RoundedRectangle(cornerRadius: shape.cornerRadius, style: .continuous))
            .position(x: shape.rect.midX, y: shape.rect.midY)
    }

    private func fill(_ shape: TimelinePullOut.Shape, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: shape.cornerRadius, style: .continuous)
            .fill(color)
            .frame(width: shape.rect.width, height: shape.rect.height)
            .position(x: shape.rect.midX, y: shape.rect.midY)
    }
}

/// 引っぱって開くボタン(質問・撮る)。見た目は右下の他のボタンと同じ Liquid Glass の円。
/// タップでは開かず、開く方へ少し顔を出す。引けば開く。VoiceOver ではボタンとして実行すれば開く。
struct TimelinePullButton: View {
    let pullOut: TimelinePullOut
    let kind: TimelinePullKind
    let symbol: String
    let label: String
    var prominent = false
    let identifier: String

    @State private var isDragging = false

    var body: some View {
        let size: CGFloat = prominent ? 72 : 52
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 26 : 20, weight: .semibold))
                .foregroundStyle(prominent ? Theme.onAccent : Theme.primaryText)
                .frame(width: size, height: size)
                .background {
                    Color.clear
                        .glassEffect(prominent ? .regular.tint(Theme.accentColor).interactive() : .regular.interactive(), in: Circle())
                        .opacity(pullOut.active == kind ? 0 : 1)
                }
                .timelinePullOrigin(kind)
                .opacity(pullOut.active == kind ? 0.0 : 1)
            Text(label).font(Typography.sans(size: 12, weight: .bold)).foregroundStyle(Theme.secondaryText)
        }
        .contentShape(Rectangle())
        .gesture(TimelinePullGesture.make(pullOut: pullOut, kind: kind, isDragging: $isDragging))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint("引っぱって開く")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { pullOut.open(kind) }
        .accessibilityIdentifier(identifier)
    }
}

/// 引っぱって開く指の動き(ボタンにもチップにも付ける)。
enum TimelinePullGesture {
    @MainActor
    static func make(pullOut: TimelinePullOut, kind: TimelinePullKind, isDragging: Binding<Bool>) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging.wrappedValue {
                    guard hypot(value.translation.width, value.translation.height) > 6 else { return }
                    isDragging.wrappedValue = true
                }
                pullOut.pull(kind, translation: value.translation)
            }
            .onEnded { value in
                defer { isDragging.wrappedValue = false }
                if isDragging.wrappedValue {
                    pullOut.release(kind, translation: value.translation, velocity: value.velocity)
                } else {
                    pullOut.peek(kind)
                }
            }
    }
}

/// 引っぱって開くボタン・チップの場所。
struct TimelinePullOriginKey: PreferenceKey {
    static let defaultValue: [TimelinePullKind: CGRect] = [:]
    static func reduce(value: inout [TimelinePullKind: CGRect], nextValue: () -> [TimelinePullKind: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// この形を、引っぱって開く `kind` の始まりの形として知らせる。
    func timelinePullOrigin(_ kind: TimelinePullKind) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: TimelinePullOriginKey.self, value: [kind: proxy.frame(in: .global)])
            }
        }
    }
}

/// 開く画面が実際に出る場所(画面全体の座標)。システムのシートの大きさに合わせる(Dev Box のシミュレータで測った値)。
enum TimelinePullTargets {
    @MainActor
    static func current(isPad: Bool) -> [TimelinePullKind: TimelinePullTarget] {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        guard let window else { return [:] }
        return targets(bounds: window.bounds, safeTop: window.safeAreaInsets.top, isPad: isPad,
                       displayCorner: isPad ? 21 : 55)
    }

    static func targets(bounds: CGRect, safeTop: Double, isPad: Bool, displayCorner: Double) -> [TimelinePullKind: TimelinePullTarget] {
        let w = bounds.width, h = bounds.height
        // カメラ: 画面いっぱい(枠の底辺は画面の底辺)。
        let camera = TimelinePullTarget(rect: bounds, cornerRadius: displayCorner)
        if isPad {
            // 質問: 右の欄。単元の一覧: 真ん中に浮かぶシート。
            let ask = TimelinePullTarget(rect: CGRect(x: w - TimelineLayout.questionPanelWidth, y: 0, width: TimelineLayout.questionPanelWidth, height: h),
                                         cornerRadius: 0)
            let sheetW = min(w - 80, 580.0), sheetH = min(h - 160, 620.0)
            let scope = TimelinePullTarget(rect: CGRect(x: (w - sheetW) / 2, y: (h - sheetH) / 2, width: sheetW, height: sheetH), cornerRadius: 34)
            return [.ask: ask, .camera: camera, .scope: scope]
        }
        // 質問: 下からの大きいシート。単元の一覧: 画面の半分の高さの、縁から浮いたシート。
        let top = safeTop + 10
        let ask = TimelinePullTarget(rect: CGRect(x: 0, y: top, width: w, height: h - top), cornerRadius: 38)
        let inset = 8.0
        let scope = TimelinePullTarget(rect: CGRect(x: inset, y: h / 2, width: w - inset * 2, height: h / 2 - inset), cornerRadius: displayCorner - inset)
        return [.ask: ask, .camera: camera, .scope: scope]
    }
}
