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

nonisolated enum TimelinePullKind: Hashable {
    /// 質問の画面(iPhone は下からのシート、iPad は右の欄)。
    case ask
    /// カメラ(画面いっぱい)。
    case camera
    /// 解く範囲(単元)の一覧のシート。
    case scope
}

/// 開く画面の形(画面全体の座標)。
nonisolated struct TimelinePullTarget: Equatable {
    var rect: CGRect
    /// 上の角の丸み。
    var cornerRadius: Double
    /// 下の角の丸み(ディスプレイの角に沿う時は大きくする)。
    var bottomRadius: Double

    init(rect: CGRect, cornerRadius: Double, bottomRadius: Double? = nil) {
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.bottomRadius = bottomRadius ?? cornerRadius
    }
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
    /// 今動いているもの、開いているもの(無ければ何も描かない)。
    private(set) var active: TimelinePullKind?
    /// `active` が開ききって止まっている(中身を触れる)。
    private(set) var isOpen = false
    /// 開くと決まった・開ききった(数が変わったら、呼んだ側が `openedKind` に合わせて状態を変える)。
    private(set) var openRequest = 0
    private(set) var openedKind: TimelinePullKind?
    /// 触覚の合図(開くと決まった時)。
    private(set) var commitFeedback = 0
    /// 指で引いた割合(ボタンの印を消していくのに使う。描く形の動きとは別に、指が動いた時だけ変わる)。
    private(set) var fingerProgress = 0.0
    /// 質問の画面の中身。引き始めた時に作って読み込みを始め(開ききった時に読み込み済みにするため)、閉じきったら外す。
    var question: WorkbookQuestionContext?

    var reduceMotion = false

    /// ボタンの場所と、開いた時の場所(どちらも画面全体の座標)。
    @ObservationIgnored var origins: [TimelinePullKind: CGRect] = [:]
    @ObservationIgnored var targets: [TimelinePullKind: TimelinePullTarget] = [:]

    @ObservationIgnored private var lead = LiquidSpring(0)
    @ObservationIgnored private var trail = LiquidSpring(0)
    /// カメラに入れ替えた後、ガラスを消していく割合(1 = 見えている)。
    @ObservationIgnored private var visibility = LiquidSpring(1)
    @ObservationIgnored private var lastDate: Date?
    @ObservationIgnored private var committing = false
    @ObservationIgnored private var sequence: Task<Void, Never>?

    // MARK: 指

    /// 指の動き → 開く向きの進み。質問は左へ、単元の一覧は下へ、カメラは枠の方へ。
    func progress(_ kind: TimelinePullKind, translation: CGSize) -> Double? {
        guard let origin = origins[kind], let target = targets[kind] else { return nil }
        switch kind {
        case .ask:
            let span = max(TimelinePullRule.minimumSpan, origin.midX - target.rect.minX)
            return TimelinePullRule.progress(distance: -translation.width, span: span)
        case .scope:
            let span = max(120, target.rect.height - origin.height)
            return TimelinePullRule.progress(distance: translation.height, span: span)
        case .camera:
            let dx = target.rect.midX - origin.midX, dy = target.rect.midY - origin.midY
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 1 else { return nil }
            let along = (translation.width * dx + translation.height * dy) / length
            return TimelinePullRule.progress(distance: along, span: max(TimelinePullRule.minimumSpan, length))
        }
    }

    private func canMove(_ kind: TimelinePullKind) -> Bool {
        (active == nil || active == kind) && !isOpen && !committing
    }

    /// `kind` を `translation` だけ引いている。
    func pull(_ kind: TimelinePullKind, translation: CGSize) {
        guard canMove(kind), let p = progress(kind, translation: translation) else { return }
        sequence?.cancel()
        active = kind
        visibility.hold(1)
        let value = max(0, p)
        lead.hold(value)
        fingerProgress = value
    }

    /// 指を離した。開くなら true。
    @discardableResult
    func release(_ kind: TimelinePullKind, translation: CGSize, velocity: CGSize) -> Bool {
        guard active == kind, canMove(kind), let p = progress(kind, translation: translation),
              let ahead = progress(kind, translation: CGSize(width: translation.width + velocity.width, height: translation.height + velocity.height))
        else { return false }
        // 1秒あたりの進み(速さを、開く向きの進みに直す)。
        let speed = ahead - p
        if TimelinePullRule.opens(progress: p, velocity: speed) {
            open(kind, velocity: speed)
            return true
        }
        lead.aim(0, stiffness: 240, dampingRatio: z(0.7))
        lead.velocity = min(0, speed)
        fingerProgress = 0
        settleThenIdle()
        return false
    }

    /// タップした: 開く方へ少し顔を出して戻る。
    func peek(_ kind: TimelinePullKind) {
        guard canMove(kind), origins[kind] != nil, targets[kind] != nil, !reduceMotion else { return }
        sequence?.cancel()
        active = kind
        visibility.hold(1)
        lead.aim(0, stiffness: 260, dampingRatio: 0.45)
        lead.velocity = 1.6
        settleThenIdle()
    }

    /// 開く(VoiceOver でボタンとして実行した時も、ここから)。
    func open(_ kind: TimelinePullKind, velocity: Double = 0) {
        guard active == nil || active == kind, !isOpen, !committing else { return }
        guard origins[kind] != nil, targets[kind] != nil else {
            // 形を描けない時(場所がまだ分からない)は、すぐ開いた扱いにする。
            active = kind
            lead.hold(1); trail.hold(1)
            arrive(kind)
            return
        }
        sequence?.cancel()
        active = kind
        committing = true
        commitFeedback += 1
        fingerProgress = 1
        visibility.hold(1)
        lead.aim(1, stiffness: reduceMotion ? 400 : 190, dampingRatio: z(0.82))
        lead.velocity = max(lead.velocity, velocity)
        sequence = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.advanceIfNotDrawn()
                if self.trail.value > 0.96 || self.reduceMotion { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard let self, !Task.isCancelled else { return }
            self.arrive(kind)
        }
    }

    /// 開ききった。カメラは本物のカメラの枠に入れ替えてガラスを消す。単元の一覧と質問は、そのまま開いて止まる。
    private func arrive(_ kind: TimelinePullKind) {
        committing = false
        openedKind = kind
        openRequest += 1
        guard kind == .camera else {
            isOpen = true
            return
        }
        sequence = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, !Task.isCancelled else { return }
            self.visibility.aim(0, stiffness: 300, dampingRatio: 1)
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            self.finish()
        }
    }

    /// 開いている単元の一覧・質問を閉じる: 元のボタン(チップ)へ縮んで戻る。
    func close(_ kind: TimelinePullKind) {
        guard active == kind, isOpen else { return }
        sequence?.cancel()
        isOpen = false
        committing = true
        fingerProgress = 0
        lead.aim(0, stiffness: reduceMotion ? 400 : 220, dampingRatio: z(0.9))
        sequence = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.advanceIfNotDrawn()
                if (self.trail.value < 0.02 && self.lead.value < 0.02) || self.reduceMotion { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard let self, !Task.isCancelled else { return }
            self.finish()
        }
    }

    /// 普段の見た目に戻す。
    func finish() {
        sequence?.cancel()
        committing = false
        isOpen = false
        active = nil
        question = nil
        fingerProgress = 0
        lead.hold(0); trail.hold(0); visibility.hold(1)
        lastDate = nil
    }

    private func settleThenIdle() {
        sequence = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                self.advanceIfNotDrawn()
                if self.lead.isSettled, abs(self.trail.value) < 0.01, self.lead.value < 0.01 {
                    self.finish()
                    return
                }
            }
        }
    }

    private func z(_ ratio: Double) -> Double { reduceMotion ? 1 : ratio }

    // MARK: 描く

    /// 角の丸い四角(上と下で丸みを変えられる)。画面全体の座標。
    nonisolated struct Shape: Equatable {
        var rect: CGRect
        var topRadius: Double
        var bottomRadius: Double

        var swiftUIShape: UnevenRoundedRectangle {
            UnevenRoundedRectangle(topLeadingRadius: topRadius, bottomLeadingRadius: bottomRadius,
                                   bottomTrailingRadius: bottomRadius, topTrailingRadius: topRadius, style: .continuous)
        }
    }

    struct Frame {
        var kind: TimelinePullKind
        /// 遅れてついてくる形(中身はこの形に切り抜く)と、先を行く形(液体のふくらみ)。
        var body: Shape
        var tip: Shape?
        /// どこまで開いたか(0 = ボタン、1 = 開いた形)。
        var progress: Double
        /// ガラスの見え方(カメラに入れ替えた後に消える)。
        var opacity: Double
    }

    /// 開ききって止まっていて、毎フレーム描き直さなくてよい。
    var isResting: Bool { isOpen && !committing }

    /// バネを `date` の時刻まで進める。描く層が無い時(ボタンの場所が分からなくなった時など)も止まらないように、
    /// 開く・閉じる・戻るのを待つ間は、待つ側からも進める。
    private func advance(to date: Date) {
        if let last = lastDate {
            let dt = min(1.0 / 30, max(0, date.timeIntervalSince(last)))
            for _ in 0..<3 {
                trail.aim(lead.value, stiffness: reduceMotion ? 600 : 170, dampingRatio: z(0.6))
                lead.step(dt / 3); trail.step(dt / 3); visibility.step(dt / 3)
            }
        }
        lastDate = date
    }

    /// 描く層がしばらく進めていなければ、ここで進める(待つ側から呼ぶ)。
    private func advanceIfNotDrawn() {
        let now = Date()
        guard let last = lastDate else {
            lastDate = now
            return
        }
        if now.timeIntervalSince(last) > 0.05 { advance(to: now) }
    }

    func frame(at date: Date) -> Frame? {
        guard let kind = active else { return nil }
        advance(to: date)
        guard let origin = origins[kind], let target = targets[kind] else { return nil }
        let body = Self.shape(kind, origin: origin, target: target, t: trail.value)
        let tip = kind != .camera && abs(lead.value - trail.value) > 0.01 ? Self.shape(kind, origin: origin, target: target, t: lead.value) : nil
        return Frame(kind: kind, body: body, tip: tip, progress: max(0, min(1, trail.value)), opacity: max(0, min(1, visibility.value)))
    }

    /// ボタンの形(円・カプセル)から開いた形へ、`t` の割合だけ近づけた形。
    /// - 単元の一覧: チップの左上を留めたまま、下と右へ伸びる(プルダウン)。
    /// - 質問: ボタンから、開いた形へ伸びながら移る。
    /// - カメラ: 引き始めてすぐに下端がディスプレイの下端に付き、下端を付けたまま横に広がって上へ伸びる。
    nonisolated static func shape(_ kind: TimelinePullKind, origin: CGRect, target: TimelinePullTarget, t: Double) -> Shape {
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let r0 = min(origin.width, origin.height) / 2
        let grow = max(0, t)
        let g = min(1, grow)
        switch kind {
        case .camera:
            let down = min(1, grow * 4)
            let minX = lerp(origin.minX, target.rect.minX, grow), maxX = lerp(origin.maxX, target.rect.maxX, grow)
            let maxY = lerp(origin.maxY, target.rect.maxY, down)
            let height = lerp(origin.height, target.rect.height, grow)
            let rect = CGRect(x: minX, y: maxY - height, width: max(0, maxX - minX), height: max(0, height))
            let limit = min(rect.width, rect.height) / 2
            return Shape(rect: rect, topRadius: min(limit, lerp(r0, target.cornerRadius, g)),
                         bottomRadius: min(limit, lerp(r0, target.bottomRadius, down)))
        case .ask, .scope:
            let w = lerp(origin.width, target.rect.width, grow), h = lerp(origin.height, target.rect.height, grow)
            let minX = lerp(origin.minX, target.rect.minX, grow), minY = lerp(origin.minY, target.rect.minY, grow)
            let rect = CGRect(x: minX, y: minY, width: max(0, w), height: max(0, h))
            let limit = min(rect.width, rect.height) / 2
            return Shape(rect: rect, topRadius: min(limit, lerp(r0, target.cornerRadius, g)),
                         bottomRadius: min(limit, lerp(r0, target.bottomRadius, g)))
        }
    }
}

/// 撮るを引いている間のガラスの形(タイムラインの画面全体に重ねる)。指は通す。
struct TimelinePullGlassLayer: View {
    let pullOut: TimelinePullOut
    /// 撮るボタンが銅色の大きいボタンの時(iPhone で書く前)。
    let cameraIsProminent: Bool
    @State private var layerOrigin: CGPoint = .zero

    var body: some View {
        TimelineView(.animation(paused: pullOut.active != .camera)) { context in
            if pullOut.active == .camera, let frame = pullOut.frame(at: context.date) {
                let t = frame.progress
                // ボタンの色から、カメラの枠の黒へ(銅色の大きいボタンは、銅から黒へ混ぜていく)。
                let dark = min(1, max(0, t) * 1.6)
                let tint: Color = cameraIsProminent ? Theme.accentColor.mix(with: .black, by: dark * 0.9) : Color.black.opacity(0.85 * dark)
                let late = max(0, min(1, (t - 0.55) / 0.45))
                let rect = frame.body.rect.offsetBy(dx: -layerOrigin.x, dy: -layerOrigin.y)
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(width: rect.width, height: rect.height)
                        .glassEffect(.regular.tint(tint), in: frame.body.swiftUIShape)
                        .overlay { frame.body.swiftUIShape.fill(Color.black.opacity(late * late)) }
                        .offset(x: rect.minX, y: rect.minY)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(frame.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { layerOrigin = $0 }
    }
}

/// 引っぱって開く中身(単元の一覧・質問の画面)を、指に合わせてボタンから出す。
/// 中身は開いた時の大きさで組んでおき、伸びていく形で切り抜く(文字が縮んだり組み替わったりしない)。
/// 中身は形の左上について動くので、ボタンから出てくるように見える。開ききるまでは触れない。
struct TimelinePullPanel<Content: View>: View {
    let pullOut: TimelinePullOut
    let kind: TimelinePullKind
    /// 開いている間、後ろを暗くする(iPhone の質問)。
    var dims = false
    /// 開いている間、外側を押したら閉じる(単元の一覧)。
    var closesOnOutsideTap = false
    @ViewBuilder let content: () -> Content
    @State private var layerOrigin: CGPoint = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            if pullOut.active == kind, let target = pullOut.targets[kind] {
                if closesOnOutsideTap && pullOut.isOpen {
                    Color.clear.contentShape(Rectangle()).onTapGesture { pullOut.close(kind) }
                }
                TimelineView(.animation(paused: pullOut.isResting)) { context in
                    if let frame = pullOut.frame(at: context.date) {
                        let body = frame.body.rect.offsetBy(dx: -layerOrigin.x, dy: -layerOrigin.y)
                        ZStack(alignment: .topLeading) {
                            if dims {
                                Color.black.opacity(0.22 * frame.progress)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .ignoresSafeArea()
                                    .allowsHitTesting(pullOut.isOpen)
                            }
                            GlassEffectContainer(spacing: 24) {
                                ZStack(alignment: .topLeading) {
                                    glass(frame.body)
                                    if let tip = frame.tip { glass(tip) }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                            .allowsHitTesting(false)
                            content()
                                .frame(width: target.rect.width, height: target.rect.height, alignment: .topLeading)
                                .mask(alignment: .topLeading) {
                                    frame.body.swiftUIShape.frame(width: body.width, height: body.height)
                                }
                                // 開く途中は、形が小さいうちは中身を薄くする(ボタンの大きさで中身の端だけが見えないように)。
                                .opacity(min(1, max(0, (frame.progress - 0.08) / 0.3)))
                                .offset(x: body.minX, y: body.minY)
                                .allowsHitTesting(pullOut.isOpen)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { layerOrigin = $0 }
    }

    private func glass(_ shape: TimelinePullOut.Shape) -> some View {
        let rect = shape.rect.offsetBy(dx: -layerOrigin.x, dy: -layerOrigin.y)
        return Color.clear
            .frame(width: rect.width, height: rect.height)
            .glassEffect(.regular.tint(Theme.card.opacity(0.6)), in: shape.swiftUIShape)
            .offset(x: rect.minX, y: rect.minY)
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
                // 引くにつれて印を消す(形は描く層が引き継ぐ)。タップで顔を出すだけの時は消さない。
                .opacity(pullOut.active == kind ? max(0, 1 - pullOut.fingerProgress * 3) : 1)
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
                } else if pullOut.active == kind, pullOut.isOpen {
                    // 開いている時に押したら閉じる(単元のチップ)。
                    pullOut.close(kind)
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

/// 開く画面が実際に出る場所(画面全体の座標)。システムのシートとカメラの枠の大きさに合わせる
/// (2026-11-13 に Dev Box のシミュレータで、開いた画面の要素の位置と画面写真から測った値)。
enum TimelinePullTargets {
    @MainActor
    static func current(isPad: Bool, chip: CGRect?) -> [TimelinePullKind: TimelinePullTarget] {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        guard let window else { return [:] }
        return targets(bounds: window.bounds, safeTop: window.safeAreaInsets.top, isPad: isPad,
                       displayCorner: isPad ? 21 : 55, chip: chip)
    }

    static func targets(bounds: CGRect, safeTop: Double, isPad: Bool, displayCorner: Double, chip: CGRect?) -> [TimelinePullKind: TimelinePullTarget] {
        let w = bounds.width, h = bounds.height
        var result: [TimelinePullKind: TimelinePullTarget] = [:]
        // カメラ: 下の 65% に、縁から 8pt 浮いて出る枠。下端はディスプレイの下端で、下の角はディスプレイの角に沿う。
        // 測った値: iPhone 17 は (8, 306, 386, 568)、iPad mini は (8, 396.5, 728, 736.5)。
        result[.camera] = TimelinePullTarget(rect: CGRect(x: 8, y: h * 0.35, width: w - 16, height: h * 0.65),
                                             cornerRadius: 34, bottomRadius: displayCorner - 8)
        if isPad {
            // 質問: 右の欄(測った値: iPad mini で (364, 0, 380, 1133))。
            result[.ask] = TimelinePullTarget(rect: CGRect(x: w - TimelineLayout.questionPanelWidth, y: 0,
                                                           width: TimelineLayout.questionPanelWidth, height: h), cornerRadius: 0)
        } else {
            // 質問: 安全領域の上端から下まで(下の角はディスプレイの角に沿う)。
            result[.ask] = TimelinePullTarget(rect: CGRect(x: 0, y: safeTop, width: w, height: h - safeTop),
                                              cornerRadius: 38, bottomRadius: displayCorner)
        }
        // 単元の一覧: チップの左上から下へ伸びるプルダウン。
        if let chip {
            // 幅はチップの左端から画面の右の余白まで(iPhone)。iPad は広げすぎない。
            let width = isPad ? min(440, w - chip.minX - 24) : w - chip.minX - 20
            let height = min(h * (isPad ? 0.5 : 0.6), 560)
            result[.scope] = TimelinePullTarget(rect: CGRect(x: chip.minX, y: chip.minY, width: width, height: height), cornerRadius: 24)
        }
        return result
    }
}

/// 引っぱって開く質問の画面の中身。形が伸びる間は毎フレーム組み直すので、同じ質問なら中身は組み直さない。
struct TimelineQuestionDrawerContent: View, Equatable {
    let context: WorkbookQuestionContext
    let onClose: () -> Void
    private let key: String

    init(context: WorkbookQuestionContext, onClose: @escaping () -> Void) {
        self.context = context
        self.onClose = onClose
        key = context.id
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    var body: some View {
        WorkbookQuestionScreen(context: context, onClose: onClose)
            .background(Theme.ground)
    }
}
