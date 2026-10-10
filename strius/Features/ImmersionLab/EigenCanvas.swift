import SwiftUI

/// S6 固有値 playground — 2D グリッド上でベクトルの向きをドラッグし、
/// 変換後のゴーストベクトルと見比べて「向きが変わらない向き」を探す。
struct EigenFlowView: View {
    let content: EigenContent
    let onExit: () -> Void

    enum Stage {
        case hook, explore, consequence, insight, retryExplore, retryConsequence, transfer, boundary, ended
    }

    @State private var stage: Stage = .hook
    /// ベクトルの角度 (ラジアン、数学座標系)。
    @State private var angle: Double = 0.65
    /// 変換アニメーションの進行 (0 = 元ベクトル、1 = 変換後)。
    @State private var transformProgress: Double = 0
    @State private var retryPick: Int? = nil
    @State private var transferPick: Int? = nil

    @Environment(\.colorScheme) private var scheme

    init(content: EigenContent, initialStageName: String? = nil, onExit: @escaping () -> Void) {
        self.content = content
        self.onExit = onExit
        // デモ用ディープリンク: 途中のステージから開始する
        if let initialStageName {
            let stage: Stage? = switch initialStageName {
            case "explore": .explore
            case "consequence": .consequence
            case "insight": .insight
            case "transfer": .transfer
            case "boundary": .boundary
            default: nil
            }
            if let stage {
                _stage = State(initialValue: stage)
                if stage == .consequence {
                    _transformProgress = State(initialValue: 1)
                }
            }
        }
    }

    /// ステージごとの変換行列 (retry はせん断)。
    private var matrix: (a: Double, b: Double, c: Double, d: Double) {
        stage == .retryExplore || stage == .retryConsequence ? (1, 1, 0, 1) : (2, 0, 0, 1)
    }

    private let vectorLength: Double = 1.8

    private var vector: CGPoint {
        CGPoint(x: cos(angle) * vectorLength, y: sin(angle) * vectorLength)
    }

    private var transformed: CGPoint {
        let m = matrix
        return CGPoint(
            x: m.a * vector.x + m.b * vector.y,
            y: m.c * vector.x + m.d * vector.y
        )
    }

    /// 選んだ向きが不変か (外積 ≈ 0)。
    private var isInvariantPick: Bool {
        abs(vector.x * transformed.y - vector.y * transformed.x) < 0.08
    }

    private var isShearStage: Bool {
        stage == .retryExplore || stage == .retryConsequence
    }

    var body: some View {
        ImmersionShell(sourceLabel: content.sourceLabel, onClose: onExit) {
            canvasContent
        } rail: {
            railContent
        }
    }

    // MARK: Canvas

    @ViewBuilder
    private var canvasContent: some View {
        switch stage {
        case .hook:
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .explore }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(content.hook)
                            .font(Typography.sans(size: 19, weight: .bold))
                            .foregroundStyle(Theme.textPrimary(scheme))
                        Text(content.hookSub)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary(scheme))
                        EigenCanvas(
                            vector: vector,
                            transformed: transformed,
                            transformProgress: 0,
                            highlightAxes: false,
                            tint: Theme.accent(scheme),
                            growth: Theme.growth(scheme),
                            onDragAngle: nil
                        )
                        Text("タップして向きを探りにいく")
                            .font(Typography.micro.weight(.medium))
                            .foregroundStyle(Theme.accent(scheme))
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .glassSurface(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
                }
                .buttonStyle(.plain)
            }

        case .explore, .retryExplore:
            VStack(alignment: .leading, spacing: 12) {
                Text(isShearStage ? content.retryIntro : content.hook)
                    .font(Typography.title)
                Text(content.exploreHint)
                    .font(Typography.bodyCompact)
                    .foregroundStyle(Theme.textSecondary(scheme))
                EigenCanvas(
                    vector: vector,
                    transformed: transformed,
                    transformProgress: 1, // 変換後ゴーストをライブ表示
                    highlightAxes: false,
                    tint: Theme.accent(scheme),
                    growth: Theme.growth(scheme),
                    onDragAngle: { newAngle in angle = newAngle }
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
                Text("実線: いまの向き / 破線: 変換後")
                    .font(Typography.micro)
                    .foregroundStyle(Theme.textTertiary(scheme))
                    .frame(maxWidth: .infinity)
            }

        case .consequence, .retryConsequence:
            VStack(alignment: .leading, spacing: 12) {
                Text(isShearStage ? content.retryIntro : "予想と、結果。")
                    .font(Typography.title)
                EigenCanvas(
                    vector: vector,
                    transformed: transformed,
                    transformProgress: transformProgress,
                    highlightAxes: true,
                    tint: Theme.accent(scheme),
                    growth: Theme.growth(scheme),
                    onDragAngle: nil
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
                .onAppear {
                    transformProgress = 0
                    withAnimation(.easeInOut(duration: 1.2)) { transformProgress = 1 }
                }
                if isShearStage {
                    diffCard(content.retryReveal)
                } else {
                    diffCard((isInvariantPick ? content.consequenceInvariant : content.consequenceRotated) + " " + content.consequenceReveal)
                }
            }

        case .insight:
            VStack(alignment: .leading, spacing: 12) {
                InsightCard(serif: content.insightSerif, note: content.insightNote)
            }

        case .transfer:
            VStack(alignment: .leading, spacing: 14) {
                Text(content.transferQuestion)
                    .font(Typography.title)
                Text("ここにはグリッドも選択肢のヒントもありません。")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
                SegChoiceRow(choices: content.transferChoices, pickedIndex: transferPick) { index in
                    withAnimation(.easeInOut(duration: Theme.Duration.quick)) { transferPick = index }
                }
                if let transferPick {
                    diffCard(
                        transferPick == content.transferCorrectIndex
                            ? content.transferCorrectSerif
                            : content.transferWrongSerif
                    )
                }
            }

        case .boundary:
            BoundaryCanvas(serif: content.boundarySerif)
        case .ended:
            EndedCanvas()
        }
    }

    private func diffCard(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Theme.textPrimary(scheme))
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
    }

    // MARK: Rail

    @ViewBuilder
    private var railContent: some View {
        switch stage {
        case .hook, .insight, .ended:
            if stage == .insight {
                RailPrimaryButton(title: "せん断でも試す") {
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
                        angle = 0.9
                        stage = .retryExplore
                    }
                }
            } else if stage == .ended {
                RailPrimaryButton(title: "ここから続けます", action: onExit)
            }
        case .explore:
            RailPrimaryButton(title: content.predictButton) {
                withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .consequence }
            }
        case .consequence:
            RailPrimaryButton(title: "固有ベクトルを見る") {
                withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .insight }
            }
        case .retryExplore:
            RailPrimaryButton(title: content.predictButton) {
                withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .retryConsequence }
            }
        case .retryConsequence:
            RailPrimaryButton(title: "支援なしで試してみる") {
                withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .transfer }
            }
        case .transfer:
            RailPrimaryButton(title: "区切りを確認する", isDisabled: transferPick == nil) {
                withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .boundary }
            }
        case .boundary:
            VStack(spacing: 8) {
                RailPrimaryButton(title: "もう少し続ける", action: onExit)
                RailSecondaryButton(title: "今日はここまで") {
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .ended }
                }
            }
        }
    }
}

/// 2D グリッド + ドラッグで回るベクトル + 変換後ゴーストベクトル。
struct EigenCanvas: View {
    let vector: CGPoint          // 数学座標
    let transformed: CGPoint     // A・v (数学座標)
    let transformProgress: Double
    let highlightAxes: Bool
    let tint: Color
    let growth: Color
    let onDragAngle: ((Double) -> Void)?

    private let scale: CGFloat = 42
    private let gridRange = 3

    var body: some View {
        GeometryReader { geo in
            canvasContent(size: geo.size)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard let onDragAngle else { return }
                            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                            let dx = drag.location.x - center.x
                            let dy = center.y - drag.location.y
                            guard abs(dx) > 4 || abs(dy) > 4 else { return }
                            onDragAngle(atan2(dy, dx))
                        }
                )
        }
        .frame(height: 270)
    }

    private func canvasContent(size: CGSize) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func toView(_ p: CGPoint) -> CGPoint {
                CGPoint(x: center.x + p.x * scale, y: center.y - p.y * scale)
            }

            // グリッド
            for i in -gridRange...gridRange {
                let f = CGFloat(i)
                var vLine = Path()
                vLine.move(to: toView(CGPoint(x: f, y: CGFloat(-gridRange))))
                vLine.addLine(to: toView(CGPoint(x: f, y: CGFloat(gridRange))))
                var hLine = Path()
                hLine.move(to: toView(CGPoint(x: CGFloat(-gridRange), y: f)))
                hLine.addLine(to: toView(CGPoint(x: CGFloat(gridRange), y: f)))
                let isAxis = i == 0
                context.stroke(vLine, with: .color(.primary.opacity(isAxis ? 0.35 : 0.12)), lineWidth: isAxis ? 1.2 : 0.5)
                context.stroke(hLine, with: .color(.primary.opacity(isAxis ? 0.35 : 0.12)), lineWidth: isAxis ? 1.2 : 0.5)
            }

            // 不変方向のハイライト (意味ある差)
            if highlightAxes {
                for dir in [CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1)] {
                    let end = CGPoint(x: dir.x * 2.6, y: dir.y * 2.6)
                    drawArrow(&context, from: center, to: toView(end), color: growth, dashed: false, width: 2.4)
                }
            }

            // 変換後ゴースト (破線)
            let shownTransformed = CGPoint(
                x: vector.x + (transformed.x - vector.x) * transformProgress,
                y: vector.y + (transformed.y - vector.y) * transformProgress
            )
            drawArrow(&context, from: center, to: toView(shownTransformed), color: tint.opacity(0.55), dashed: true, width: 1.8)

            // いまのベクトル (実線)
            drawArrow(&context, from: center, to: toView(vector), color: tint, dashed: false, width: 2.6)
        }
    }

    private func drawArrow(_ context: inout GraphicsContext, from start: CGPoint, to end: CGPoint, color: Color, dashed: Bool, width: CGFloat) {
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        let style = dashed ? StrokeStyle(lineWidth: width, dash: [6, 4]) : StrokeStyle(lineWidth: width, lineCap: .round)
        context.stroke(line, with: .color(color), style: style)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = 9
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle - .pi / 6),
            y: end.y - headLength * sin(angle - .pi / 6)
        ))
        head.move(to: end)
        head.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle + .pi / 6),
            y: end.y - headLength * sin(angle + .pi / 6)
        ))
        context.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}
