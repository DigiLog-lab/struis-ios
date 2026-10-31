import SwiftUI
import UIKit

struct StruisProgressViewStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        if configuration.fractionCompleted != nil {
            ProgressView(configuration).progressViewStyle(.linear)
        } else {
            VStack(spacing: 8) {
                StruisLoadingIndicator()
                configuration.label
                configuration.currentValueLabel
            }
        }
    }
}

struct StruisLoadingIndicator: View {
    @Environment(\.controlSize) private var controlSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGFloat {
        switch controlSize {
        case .mini: 14
        case .small: 18
        case .large: 40
        case .extraLarge: 56
        default: 24
        }
    }

    var body: some View {
        StruisRotatingMark(isAnimating: scenePhase == .active && !reduceMotion)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel("読み込み中")
            .accessibilityIdentifier("struis-loading")
    }
}

/// 止まったロゴマーク(暗い角丸の地に 3 本の線)。ロゴマーク＋`Typography.brandName` の見出しに使う。
struct StruisMark: View {
    var size: CGFloat = 32

    var body: some View {
        StruisRotatingMark(isAnimating: false)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// ロゴマーク＋「Struis」(17/700)。
struct StruisBrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            StruisMark(size: 32)
            Text("Struis")
                .font(Typography.brandName)
                .foregroundStyle(Theme.primaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Struis")
    }
}

private struct StruisRotatingMark: UIViewRepresentable {
    let isAnimating: Bool
    func makeUIView(context: Context) -> StruisLoadingUIView { StruisLoadingUIView() }
    func updateUIView(_ view: StruisLoadingUIView, context: Context) {
        view.isAnimating = isAnimating
    }
    static func dismantleUIView(_ view: StruisLoadingUIView, coordinator: ()) {
        view.isAnimating = false
    }
}

/// Core Animation owns the rotation; no per-frame SwiftUI state updates.
final class StruisLoadingUIView: UIView {
    private let rotationLayer = CALayer()
    private let markLayer = CALayer()
    var isAnimating = true { didSet { updateAnimation() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(red: 33/255, green: 25/255, blue: 20/255, alpha: 1)
        layer.cornerCurve = .continuous
        layer.addSublayer(rotationLayer)
        rotationLayer.addSublayer(markLayer)
        // Exact paths and colors from assets/struis_icon.svg.
        let strokes: [(CGPoint, CGPoint, CGPoint, UIColor)] = [
            (.init(x: 352, y: 294), .init(x: 512, y: 194), .init(x: 672, y: 294), UIColor(red: 1, green: 244/255, blue: 230/255, alpha: 1)),
            (.init(x: 272, y: 456), .init(x: 214, y: 638), .init(x: 382, y: 758), UIColor(red: 1, green: 244/255, blue: 230/255, alpha: 1)),
            (.init(x: 752, y: 456), .init(x: 810, y: 638), .init(x: 642, y: 758), UIColor(red: 184/255, green: 115/255, blue: 58/255, alpha: 1))
        ]
        for (start, control, end, color) in strokes {
            let path = CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(to: end, control: control)
            let stroke = CAShapeLayer()
            stroke.path = path
            stroke.fillColor = nil
            stroke.strokeColor = color.cgColor
            stroke.lineWidth = 164
            stroke.lineCap = .round
            markLayer.addSublayer(stroke)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = bounds.width * 0.22
        rotationLayer.bounds = bounds
        rotationLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        markLayer.bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        markLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        markLayer.setAffineTransform(CGAffineTransform(scaleX: bounds.width / 1024, y: bounds.height / 1024))
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimation()
    }

    private func updateAnimation() {
        guard isAnimating, window != nil else {
            rotationLayer.removeAnimation(forKey: "struis.rotation")
            return
        }
        guard rotationLayer.animation(forKey: "struis.rotation") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = Double.pi * 2
        animation.duration = 3
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotationLayer.add(animation, forKey: "struis.rotation")
    }
}

extension View {
    func struisRefreshable(action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        modifier(StruisRefreshModifier(action: action))
    }
}

private struct StruisRefreshModifier: ViewModifier {
    let action: @MainActor @Sendable () async -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.background {
            StruisRefreshInstaller(action: { await action() }, animates: scenePhase == .active && !reduceMotion)
                .frame(width: 0, height: 0)
        }
    }
}

private struct StruisRefreshInstaller: UIViewRepresentable {
    let action: @MainActor @Sendable () async -> Void
    let animates: Bool
    func makeUIView(context: Context) -> RefreshAttachment { RefreshAttachment() }
    func updateUIView(_ view: RefreshAttachment, context: Context) {
        view.control.action = action
        view.control.animates = animates
        view.installWhenReady()
    }
    static func dismantleUIView(_ view: RefreshAttachment, coordinator: ()) { view.uninstall() }
}

private final class RefreshAttachment: UIView {
    let control = StruisRefreshControl()
    private weak var scrollView: UIScrollView?
    private var previousControl: UIRefreshControl?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { uninstall() } else { installWhenReady() }
    }

    func installWhenReady() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.scrollView == nil else { return }
            var parent = self.superview
            while let candidate = parent {
                if let scroll = candidate as? UIScrollView {
                    self.scrollView = scroll
                    self.previousControl = scroll.refreshControl
                    scroll.alwaysBounceVertical = true
                    scroll.refreshControl = self.control
                    return
                }
                parent = candidate.superview
            }
        }
    }

    func uninstall() {
        control.task?.cancel()
        control.task = nil
        control.endRefreshing()
        control.mark.isAnimating = false
        if scrollView?.refreshControl === control { scrollView?.refreshControl = previousControl }
        scrollView = nil
        previousControl = nil
    }
}

private final class StruisRefreshControl: UIRefreshControl {
    let mark = StruisLoadingUIView()
    var action: (@MainActor @Sendable () async -> Void)?
    var task: Task<Void, Never>?
    var animates = true { didSet { mark.isAnimating = animates && isRefreshing } }

    override init() {
        super.init()
        tintColor = .clear
        mark.isAnimating = false
        addSubview(mark)
        accessibilityLabel = "読み込み中"
        accessibilityIdentifier = "struis-refresh"
        addTarget(self, action: #selector(refresh), for: .valueChanged)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        mark.frame = CGRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)
    }

    @objc private func refresh() {
        guard task == nil else { return }
        mark.isAnimating = animates
        task = Task { [weak self] in
            guard let self else { return }
            await action?()
            mark.isAnimating = false
            endRefreshing()
            task = nil
        }
    }
}
