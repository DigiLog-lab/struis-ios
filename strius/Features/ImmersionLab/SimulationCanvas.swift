import SwiftUI

/// 汎用シミュレーション canvas — スカラー量の縦ゲージ (タンク風)。
/// 題材の skin は SimulationScenario の emoji / label / tint でパラメータ化され、
/// このビュー自体には題材固有の分岐を持たない。
struct GaugeView: View {
    let scenario: SimulationScenario
    let value: Double
    var prediction: Double? = nil
    var startMarker: SimulationScenario.StartMarker? = nil
    var showGap: Bool = false
    var onPlacePrediction: ((Double) -> Void)? = nil

    @Environment(\.colorScheme) private var scheme

    static let gaugeHeight: CGFloat = 230
    private let gaugeWidth: CGFloat = 104

    private var accent: Color { Theme.accent(scheme) }
    private var growth: Color { Theme.growth(scheme) }

    var body: some View {
        GeometryReader { geo in
            let h = Self.gaugeHeight
            // ゲージ本体 + 右側の目盛り/ギャップブラケット分をまとめて中央寄せ
            let groupWidth = gaugeWidth + 92
            let x0 = max(0, (geo.size.width - groupWidth) / 2)

            ZStack(alignment: .topLeading) {
                gaugeBody(x: x0, height: h)
                ticks(x: x0, height: h)
                if let startMarker {
                    startMarkerView(marker: startMarker, x: x0, height: h)
                }
                if let prediction {
                    predictionView(value: prediction, x: x0, height: h)
                }
                if showGap, let prediction {
                    gapBracket(prediction: prediction, x: x0, height: h)
                }
            }
            .frame(width: geo.size.width, height: h, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard onPlacePrediction != nil else { return }
                        let raw = (h - drag.location.y) / h * scenario.gaugeMax
                        let clamped = min(max(raw.rounded(), 0), scenario.gaugeMax)
                        onPlacePrediction?(clamped)
                    }
            )
        }
        .frame(height: Self.gaugeHeight)
    }

    private func y(for v: Double, height h: CGFloat) -> CGFloat {
        h * (1 - min(max(v, 0), scenario.gaugeMax) / scenario.gaugeMax)
    }

    // MARK: - ゲージ本体 (ガラス枠 + fill)

    private func gaugeBody(x: CGFloat, height h: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let fillHeight = max(0, h - y(for: value, height: h) - 3)

        return ZStack(alignment: .bottom) {
            shape.fill(Color.white.opacity(scheme == .dark ? 0.06 : 0.28))
            if value > 0 {
                LinearGradient(
                    colors: [scenario.tint.opacity(0.7), scenario.tint],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: gaugeWidth - 4, height: fillHeight)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: gaugeWidth - 12, height: 1.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.bottom, 2)
            }
        }
        .frame(width: gaugeWidth, height: h)
        .overlay(shape.stroke(Theme.textPrimary(scheme).opacity(0.32), lineWidth: 1.6))
        .offset(x: x, y: 0)
    }

    // MARK: - 目盛り (右側)

    private func ticks(x: CGFloat, height h: CGFloat) -> some View {
        ForEach(scenario.gaugeTicks, id: \.self) { tick in
            let ty = y(for: tick, height: h)
            Path { p in
                p.move(to: CGPoint(x: x + gaugeWidth + 6, y: ty))
                p.addLine(to: CGPoint(x: x + gaugeWidth + 12, y: ty))
            }
            .stroke(Theme.textPrimary(scheme).opacity(0.25), lineWidth: 1)
            Text(scenario.format(tick))
                .font(Typography.micro)
                .foregroundStyle(Theme.textTertiary(scheme))
                .fixedSize()
                .position(x: x + gaugeWidth + 26, y: ty)
        }
    }

    // MARK: - はじめの量マーカー

    private func startMarkerView(marker: SimulationScenario.StartMarker, x: CGFloat, height h: CGFloat) -> some View {
        let my = y(for: marker.value, height: h)
        return Group {
            Path { p in
                p.move(to: CGPoint(x: x - 4, y: my))
                p.addLine(to: CGPoint(x: x + gaugeWidth + 4, y: my))
            }
            .stroke(Theme.textTertiary(scheme), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            Text(marker.label)
                .font(Typography.micro)
                .foregroundStyle(Theme.textTertiary(scheme))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(scheme == .dark ? 0.1 : 0.85), in: Capsule())
                .fixedSize()
                .position(x: x + gaugeWidth / 2, y: max(my - 10, 8))
        }
    }

    // MARK: - 予想マーカー (破線 + タグ)

    private func predictionView(value pred: Double, x: CGFloat, height h: CGFloat) -> some View {
        let py = y(for: pred, height: h)
        return Group {
            Path { p in
                p.move(to: CGPoint(x: x - 4, y: py))
                p.addLine(to: CGPoint(x: x + gaugeWidth + 4, y: py))
            }
            .stroke(accent, style: StrokeStyle(lineWidth: 2.2, dash: [7, 4]))
            Text("あなたの予想 \(scenario.format(pred))\(scenario.unit)")
                .font(Typography.micro.weight(.semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(scheme == .dark ? 0.12 : 0.9), in: Capsule())
                .overlay(Capsule().stroke(accent, lineWidth: 0.8))
                .fixedSize()
                .position(x: x + gaugeWidth / 2, y: max(py - 28, 12))
        }
    }

    // MARK: - ギャップブラケット (意味ある差)

    private func gapBracket(prediction pred: Double, x: CGFloat, height h: CGFloat) -> some View {
        let gap = value - pred
        guard abs(gap) > 0.001 else { return AnyView(EmptyView()) }
        let y1 = y(for: max(pred, value), height: h)
        let y2 = y(for: min(pred, value), height: h)
        let gx = x + gaugeWidth + 52

        return AnyView(
            Group {
                Path { p in
                    p.move(to: CGPoint(x: gx, y: y1))
                    p.addLine(to: CGPoint(x: gx, y: y2))
                    p.move(to: CGPoint(x: gx - 5, y: y1))
                    p.addLine(to: CGPoint(x: gx, y: y1))
                    p.move(to: CGPoint(x: gx - 5, y: y2))
                    p.addLine(to: CGPoint(x: gx, y: y2))
                }
                .stroke(growth, lineWidth: 2.4)
                Text("\(scenario.format(abs(gap)))\(scenario.unit)")
                    .font(Typography.caption.weight(.bold))
                    .foregroundStyle(growth)
                    .fixedSize()
                    .position(x: gx + 24, y: (y1 + y2) / 2)
            }
        )
    }
}

/// 圧縮カード用のミニグラフ (モデルをパラメータ全域でなぞる)。
struct Sparkline: View {
    let model: SimulationModel
    let range: ClosedRange<Double>
    let color: Color

    var body: some View {
        Canvas { context, size in
            var axes = Path()
            axes.move(to: CGPoint(x: 2, y: 2))
            axes.addLine(to: CGPoint(x: 2, y: size.height - 2))
            axes.addLine(to: CGPoint(x: size.width - 2, y: size.height - 2))
            context.stroke(axes, with: .color(.primary.opacity(0.3)), lineWidth: 1)

            let samples = 24
            var points: [CGPoint] = []
            var maxValue = 0.001
            for i in 0...samples {
                let x = range.lowerBound + (range.upperBound - range.lowerBound) * Double(i) / Double(samples)
                maxValue = max(maxValue, abs(model.value(at: x)))
            }
            for i in 0...samples {
                let x = range.lowerBound + (range.upperBound - range.lowerBound) * Double(i) / Double(samples)
                let px = 4 + (size.width - 8) * Double(i) / Double(samples)
                let py = (size.height - 4) - (size.height - 10) * (model.value(at: x) / maxValue)
                points.append(CGPoint(x: px, y: py))
            }
            var line = Path()
            line.addLines(points)
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
        .frame(width: 76, height: 76)
    }
}

/// 具体物 → 図 → 式 の 3 段 morph 表示。
struct MorphStrip: View {
    let scenario: SimulationScenario

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            morphItem(
                label: scenario.sourceLabel,
                content: AnyView(
                    Text(scenario.emoji)
                        .font(.system(size: 34))
                        .frame(maxWidth: .infinity)
                        .frame(height: 76)
                )
            )
            morphArrow
            morphItem(
                label: "\(scenario.paramLabel)と\(scenario.quantityLabel)を\n点に写すと",
                content: AnyView(Sparkline(model: scenario.model, range: scenario.paramRange, color: Theme.accent(scheme)))
            )
            morphArrow
            morphItem(
                label: "この形に圧縮できる",
                content: AnyView(
                    Text(scenario.formulaText)
                        .font(Typography.serifItalic(size: 15))
                        .foregroundStyle(Theme.accent(scheme))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .frame(height: 76)
                )
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
    }

    private func morphItem(label: String, content: AnyView) -> some View {
        VStack(spacing: 6) {
            content
            Text(label)
                .font(Typography.micro)
                .foregroundStyle(Theme.textTertiary(scheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var morphArrow: some View {
        Text("→")
            .font(Typography.bodyCompact)
            .foregroundStyle(Theme.textTertiary(scheme))
    }
}
