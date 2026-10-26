import SwiftUI

/// 手が止まりかけたら、2択のカード(画面 12)。上が速攻、下が続き(縁取りで目立たせる)。「疲れた？」とは聞かない。
struct TimelineDipChoiceView: View {
    let store: TimelineStore
    let trigger: TimelineRules.DipTrigger

    var body: some View {
        let rapid = store.machine.rapidCards.prefix(TimelineRules.rapidCount)
        let next = store.upcoming ?? store.current
        VStack(alignment: .leading, spacing: 16) {
            Text("次に解くものを選びなさい。").font(Typography.sans(size: 24, weight: .bold)).foregroundStyle(Theme.primaryText)
            if rapid.isEmpty, store.toyCard != nil {
                Button { Task { await store.chooseToy() } } label: {
                    HStack {
                        Label("さわるだけ", systemImage: TimelineSymbol.hand).font(Typography.sans(size: 17, weight: .bold))
                        Spacer()
                        Label("20秒", systemImage: TimelineSymbol.clock).font(Typography.sans(size: 13, weight: .bold))
                    }
                    .foregroundStyle(Theme.primaryText)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("timeline-dip-toy")
            }
            if !rapid.isEmpty {
                Button { Task { await store.chooseRapid() } } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("速攻", systemImage: TimelineSymbol.bolt).font(Typography.sans(size: 17, weight: .bold))
                            Spacer()
                            Label("10秒 × \(rapid.count)", systemImage: TimelineSymbol.clock).font(Typography.sans(size: 13, weight: .bold))
                        }
                        ForEach(Array(rapid.enumerated()), id: \.offset) { index, card in
                            Text(card.math.isEmpty ? MathPlainText.preview(card.prompt) : TimelineMath.plain(card.math))
                                .font(Typography.sans(size: 17, weight: .medium))
                                .opacity(1 - Double(index) * 0.3)
                        }
                        if let best = store.rapidBest {
                            Label("自己ベスト \(String(format: "%.1f", best))秒", systemImage: TimelineSymbol.trophy).font(Typography.sans(size: 13, weight: .medium))
                        }
                    }
                    .foregroundStyle(Theme.primaryText)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("timeline-dip-rapid")
            }
            Button { Task { await store.chooseContinue() } } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(trigger == .away ? "さっきの問題に戻る" : "続き", systemImage: trigger == .away ? TimelineSymbol.past : TimelineSymbol.chain)
                            .font(Typography.sans(size: 17, weight: .bold))
                        Spacer()
                        if let next, let chain = TimelineRules.chainPosition(next) { TimelineChainBar(position: chain.position, total: chain.total) }
                    }
                    if let next {
                        Text(TimelineMath.previewLine(next))
                            .font(Typography.sans(size: 16, weight: .medium)).lineLimit(2)
                        if next.level < 4, let chain = TimelineRules.chainPosition(next), chain.total - chain.position <= 1 {
                            Label("入試の形まで あと \(max(1, chain.total - chain.position))", systemImage: TimelineSymbol.exam).font(Typography.sans(size: 13, weight: .bold))
                        }
                    }
                }
                .foregroundStyle(Theme.primaryText)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.cardLarge).stroke(Theme.accentColor, lineWidth: 1.4))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timeline-dip-continue")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-dip")
    }
}

/// 速攻ラウンド(画面 13): 経過秒数を大きく、1問目の結果と自己ベスト。残り時間を数える形にはしない(焦らせるため)。
struct TimelineRapidHeader: View {
    let store: TimelineStore
    let index: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("速攻", systemImage: TimelineSymbol.bolt).font(Typography.sans(size: 15, weight: .bold))
                    Spacer()
                    Text("\(index + 1) / \(store.rapidIDs.count)").font(Typography.sans(size: 13, weight: .bold)).monospacedDigit()
                }
                Text(String(format: "%.1f", context.date.timeIntervalSince(store.rapidStartedAt)))
                    .font(Typography.sans(size: 54, weight: .bold)).monospacedDigit()
                    .accessibilityIdentifier("timeline-rapid-clock")
                HStack(spacing: 14) {
                    ForEach(Array(store.rapidIDs.prefix(index).enumerated()), id: \.offset) { _, id in
                        if let result = store.rapidVerdict(id) {
                            HStack(spacing: 4) {
                                if result.verdict == "grading" { ProgressView().controlSize(.mini) } else { TimelineMark(correct: result.verdict == "correct", size: 11) }
                                Text(String(format: "%.1f秒", result.seconds)).font(Typography.sans(size: 13, weight: .medium)).monospacedDigit()
                            }
                        }
                    }
                    Spacer()
                    if let best = store.rapidBest {
                        Label("ベスト \(String(format: "%.1f", best))秒", systemImage: TimelineSymbol.trophy).font(Typography.sans(size: 13, weight: .medium))
                    }
                }
                .foregroundStyle(Theme.secondaryText)
            }
            .foregroundStyle(Theme.primaryText)
        }
    }
}

/// 速攻の 3 問を送り終えた。
struct TimelineRapidDoneView: View {
    let store: TimelineStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("速攻", systemImage: TimelineSymbol.bolt).font(Typography.sans(size: 20, weight: .bold))
            ForEach(store.rapidIDs, id: \.self) { id in
                if let card = store.machine.cards[id], let result = store.rapidVerdict(id) {
                    HStack {
                        if result.verdict == "grading" { ProgressView().controlSize(.small) } else { TimelineMark(correct: result.verdict == "correct") }
                        Text(card.math.isEmpty ? MathPlainText.preview(card.prompt) : TimelineMath.plain(card.math)).font(Typography.sans(size: 15, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f秒", result.seconds)).font(Typography.sans(size: 15, weight: .bold)).monospacedDigit()
                    }
                }
            }
            if let best = store.rapidBest {
                Label("自己ベスト \(String(format: "%.1f", best))秒", systemImage: TimelineSymbol.trophy).font(Typography.sans(size: 15, weight: .bold))
            }
        }
        .foregroundStyle(Theme.primaryText)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-rapid-done")
    }
}

/// さわるだけの20秒(画面 14): a のつまみを動かすと、範囲(銅色の帯)が放物線の上をすべり、最小になる点(黒丸)が
/// 右端 → 頂点 → 左端 と移る。今どの場合かを下の3つのチップで光らせる。次に出す問題の予習を兼ねる。
struct TimelineToyView: View {
    let store: TimelineStore
    @State private var a: Double = -1

    /// 軸は x = 2、範囲は a ≤ x ≤ a + 1。
    private var position: String { a + 1 < 2 ? "left" : (a > 2 ? "right" : "straddle") }

    var body: some View {
        let cases = store.toyCard?.payload["howto"]?["diagram"]?["cases"]?.arrayValue ?? []
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                TimelineChip(text: "さわるだけ", symbol: TimelineSymbol.hand, tinted: true)
                TimelineChip(text: "20秒", symbol: TimelineSymbol.clock)
            }
            Canvas { context, size in
                let w = size.width, h = size.height
                func px(_ x: Double) -> CGFloat { CGFloat((x + 1) / 6) * w }
                func py(_ x: Double) -> CGFloat { h * 0.9 - CGFloat(pow(x - 2, 2)) / 9 * h * 0.8 }
                var curve = Path()
                for step in 0...60 {
                    let x = -1 + Double(step) / 10
                    let point = CGPoint(x: px(x), y: py(x))
                    step == 0 ? curve.move(to: point) : curve.addLine(to: point)
                }
                context.stroke(curve, with: .color(Theme.secondaryText), lineWidth: 2)
                var axis = Path()
                axis.move(to: CGPoint(x: px(2), y: 0)); axis.addLine(to: CGPoint(x: px(2), y: h))
                context.stroke(axis, with: .color(Theme.hairline), lineWidth: 1)
                var band = Path()
                for step in 0...20 {
                    let x = a + Double(step) / 20
                    let point = CGPoint(x: px(x), y: py(x))
                    step == 0 ? band.move(to: point) : band.addLine(to: point)
                }
                context.stroke(band, with: .color(Theme.accentColor), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                let minX = position == "left" ? a + 1 : (position == "right" ? a : 2)
                context.fill(Path(ellipseIn: CGRect(x: px(minX) - 7, y: py(minX) - 7, width: 14, height: 14)), with: .color(Theme.primaryText))
            }
            .frame(height: 220)
            .accessibilityHidden(true)
            HStack {
                Text("a").font(Typography.sans(size: 17, weight: .bold))
                Slider(value: $a, in: -1...4).tint(Theme.accentColor).accessibilityIdentifier("timeline-toy-slider")
            }
            HStack(spacing: 8) {
                ForEach(Array(["left", "straddle", "right"].enumerated()), id: \.offset) { index, item in
                    let label = cases.first { $0["position"]?.stringValue == item }?["label"]?.stringValue ?? ["a + 1 < 2", "a ≤ 2 ≤ a + 1", "2 < a"][index]
                    TimelineChip(text: label, tinted: position == item)
                }
            }
            Button { store.solveToyForm() } label: {
                Text("この形を解く").font(Typography.sans(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .foregroundStyle(Theme.onAccent).background(Theme.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timeline-toy-solve")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-toy")
    }
}
