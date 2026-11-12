#if DEBUG
import SwiftUI

/// オフライン反復の画面のプロトタイプ(検討の材料。本番の画面ではない)。
///
/// 起動引数 `-offline-drill-lab` で `AppRootView` から直接開く(`-problem-catalog-lab` と同じ仕組み)。DEBUG のビルドにしか
/// 入らず、本番の画面からは辿れない。見せる問題は、実際に書いて点検を通した型(`OfflineDrillLabSamples`)から、
/// 生成器(`DrillGenerator`)がその場で作る。
/// - `-offline-drill-variant answer`(省いた時): 答えは「答え」を押した時だけ見せる。
/// - `-offline-drill-variant next`: 答えを出さず、「次へ」だけ。
/// - `-offline-drill-skill <点の ID>`: 最初に開く型。`-offline-drill-seed <数>`: 乱数の種(同じ種からは同じ問題の並び)。
/// - `-offline-drill-reveal`: 最初から答えを出しておく(スクショ用)。
struct OfflineDrillLabView: View {
    @State private var model: OfflineDrillLabModel = OfflineDrillLabModel.launch()
    @State private var hasInk: Bool = false
    @State private var isDrawing: Bool = false
    @State private var isInkZoomed: Bool = false
    @State private var ink: TimelineInkController = TimelineInkController()
    @State private var inkPassThrough: [CGRect] = []
    @State private var screen: CGSize = CGSize.zero
    /// 問題の列の幅(式がはみ出さない大きさを決めるのに使う)。
    @State private var columnWidth: CGFloat = 0
    @Environment(\.displayScale) private var displayScale: CGFloat
    @Environment(\.horizontalSizeClass) private var sizeClass: UserInterfaceSizeClass?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    private var layout: TimelineLayout { TimelineLayout.resolve(sizeClass: sizeClass, size: screen) }

    var body: some View {
        ZStack(alignment: Alignment.top) {
            LinearGradient(colors: [Theme.card, Theme.ground], startPoint: UnitPoint.top, endPoint: UnitPoint.bottom).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, layout.isPad ? 24 : 20)
                    .padding(.top, 8)
                ZStack(alignment: Alignment.bottomTrailing) {
                    problemColumn
                        .padding(.leading, layout.isPad ? TimelineLayout.columnLeading : 24)
                        .padding(.trailing, layout == TimelineLayout.padLandscape ? 0 : contentTrailing)
                        .padding(.top, 16)
                        .frame(width: layout == TimelineLayout.padLandscape ? TimelineLayout.columnLeading + TimelineLayout.columnWidth : nil)
                        .frame(maxWidth: CGFloat.infinity, maxHeight: CGFloat.infinity, alignment: Alignment.topLeading)
                    actions
                        .timelineInkPassThrough()
                        .padding(.trailing, layout.isPad ? 28 : 20)
                        .padding(.bottom, layout == TimelineLayout.padLandscape ? 32 : 16)
                        // 書いている間はボタンを薄くして、下に書いた字を透かす(タイムラインと同じ)。
                        .opacity(isDrawing ? 0.35 : 1)
                }
            }
            inkLayer
        }
        // 指を通す区画(ボタン)は、画面全体の座標で集める(`TimelineInkCanvas` の決まり)。
        .coordinateSpace(name: TimelineInkSpace.name)
        .onPreferenceChange(TimelineInkPassThroughKey.self) { (frames: [CGRect]) -> Void in inkPassThrough = frames }
        .onGeometryChange(for: CGSize.self) { (proxy: GeometryProxy) -> CGSize in proxy.size } action: { (size: CGSize) -> Void in screen = size }
        .onChange(of: model.generation) { (_: Int, _: Int) -> Void in ink.clear() }
        .accessibilityElement(children: AccessibilityChildBehavior.contain)
        .accessibilityIdentifier("offline-drill-lab")
    }

    /// 文字サイズが大きい時は、右下のボタンの列に問題文を重ねない(タイムラインと同じ幅)。
    private var contentTrailing: CGFloat {
        guard dynamicTypeSize.isAccessibilitySize else { return 24 }
        return layout.isPad ? 116 : 104
    }

    // MARK: 上端

    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("型", selection: Binding<Int>(get: { () -> Int in model.index }, set: { (index: Int) -> Void in model.select(index) })) {
                    ForEach(Array(model.templates.enumerated()), id: \.offset) { (entry: EnumeratedSequence<[DrillTemplate]>.Element) in
                        Text(entry.element.title).tag(entry.offset)
                    }
                }
                Picker("答えの出し方", selection: Binding<OfflineDrillLabModel.Variant>(get: { () -> OfflineDrillLabModel.Variant in model.variant },
                                                                              set: { (variant: OfflineDrillLabModel.Variant) -> Void in model.setVariant(variant) })) {
                    Text("押した時だけ答えを見せる").tag(OfflineDrillLabModel.Variant.answer)
                    Text("答えを出さない(次へだけ)").tag(OfflineDrillLabModel.Variant.next)
                }
            } label: {
                Label("オフライン", systemImage: "wifi.slash")
                    .font(Typography.sans(size: 16, weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .foregroundStyle(Theme.primaryText)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .timelineInkPassThrough()
            .accessibilityIdentifier("offline-drill-menu")
            Spacer()
            Text("\(model.count)問目")
                .font(Typography.sans(size: 15, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
                .accessibilityIdentifier("offline-drill-count")
        }
    }

    // MARK: 問題

    private var problemColumn: some View {
        VStack(alignment: HorizontalAlignment.leading, spacing: 16) {
            TimelineChip(text: model.template.title, tinted: true)
                .accessibilityIdentifier("offline-drill-skill")
            if let failure: String = model.failure {
                Text(failure).font(Typography.sans(size: 15, weight: .medium)).foregroundStyle(Theme.secondaryText)
            } else if let problem: DrillProblem = model.problem {
                TimelineQuestionText(text: problem.prompt, size: fitted(text: problem.prompt, base: promptSize(problem.prompt), weight: 700))
                    .accessibilityIdentifier("offline-drill-prompt")
                if !problem.math.isEmpty {
                    KaTeXMathText(problem.math, display: true, foregroundColor: UIColor(Theme.primaryText),
                                  fontSize: fitted(maths: [problem.math], display: true, base: mathSize(problem.math), weight: 500), fontWeight: 500)
                        .accessibilityIdentifier("offline-drill-math")
                }
                if model.isAnswerShown {
                    answer(problem.answer)
                        .transition(.opacity)
                }
            }
            Label("余白に書いて解く", systemImage: TimelineSymbol.pencil)
                .font(Typography.sans(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: CGFloat.infinity, alignment: Alignment.leading)
        .onGeometryChange(for: CGFloat.self) { (proxy: GeometryProxy) -> CGFloat in proxy.size.width } action: { (width: CGFloat) -> Void in columnWidth = width }
        .animation(.easeInOut(duration: Theme.Duration.standard), value: model.isAnswerShown)
    }

    /// 大きく出す式の大きさ。タイムラインの問題の式(`TimelineMath`)と同じ決め方: 34pt、長い式は文字数に合わせて小さくする。
    private func mathSize(_ latex: String) -> CGFloat {
        let length: Int = TimelineMath.plain(latex).count
        return length > 14 ? max(18, 34 * 14 / CGFloat(length) * 1.25) : 34
    }

    /// 文の中の式が列の幅に収まる文字の大きさ。
    private func fitted(text: String, base: CGFloat, weight: Int) -> CGFloat {
        fitted(maths: DrillLint.split(text)?.maths ?? [], display: false, base: base, weight: weight)
    }

    /// 式が列の幅に収まる文字の大きさ。書く面が上に乗っていて式を横にスクロールできないので、はみ出す時は小さくする
    /// (文字サイズを大きくした時に、式の右側が切れていた)。
    private func fitted(maths: [String], display: Bool, base: CGFloat, weight: Int) -> CGFloat {
        guard columnWidth > 0 else { return base }
        let style: NativeMathStyle = NativeMathStyle(color: UIColor(Theme.primaryText), fontSize: base, fontWeight: weight, scale: displayScale,
                                                     category: UIContentSizeCategory(dynamicTypeSize))
        var widest: CGFloat = 0
        for math: String in maths {
            if let glyph: NativeMathGlyph = NativeMathRenderer.shared.glyph(latex: math, display: display, style: style, highlighted: false) {
                widest = max(widest, glyph.size.width)
            }
        }
        guard widest > columnWidth - 4 else { return base }
        return max(11, floor(base * (columnWidth - 6) / widest * 10) / 10)
    }

    /// 物理・化学の問題文は長いので、少し小さくして余白を残す(タイムラインの問題文は 22pt)。
    private func promptSize(_ prompt: String) -> CGFloat {
        prompt.count > 48 ? 18 : 22
    }

    private func answer(_ text: String) -> some View {
        VStack(alignment: HorizontalAlignment.leading, spacing: 8) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("答え").font(Typography.sans(size: 13, weight: .bold)).foregroundStyle(Theme.accentColor)
            TimelineRichText(text: text, size: fitted(text: text, base: 20, weight: 700), weight: .bold)
        }
        .padding(.top, 4)
        .accessibilityElement(children: AccessibilityChildBehavior.combine)
        .accessibilityIdentifier("offline-drill-answer")
    }

    // MARK: 右下のボタン

    private var actions: some View {
        VStack(spacing: 22) {
            if model.variant == OfflineDrillLabModel.Variant.answer {
                TimelineActionButton(symbol: model.isAnswerShown ? "eye.slash" : "eye", label: model.isAnswerShown ? "隠す" : "答え",
                                     identifier: "offline-drill-answer-button") { model.toggleAnswer() }
            }
            TimelineActionButton(symbol: TimelineSymbol.next, label: "次へ", prominent: true, identifier: "offline-drill-next") { model.next() }
        }
    }

    // MARK: 書く面

    /// 余白は常に指で書ける。上の帯から下端まで、端から端まで覆い、ボタンの上だけ指を通す。問題を変えると消える。
    private var inkLayer: some View {
        ZStack(alignment: Alignment.bottomLeading) {
            TimelineInkCanvas(hasInk: $hasInk, isDrawing: $isDrawing, isZoomed: $isInkZoomed, controller: ink, passThrough: inkPassThrough)
                .frame(maxWidth: CGFloat.infinity, maxHeight: CGFloat.infinity)
            if hasInk || isInkZoomed {
                HStack(spacing: 14) {
                    Image(systemName: TimelineSymbol.pencil).foregroundStyle(Theme.tertiaryText)
                    if hasInk {
                        Button("1つ戻す") { ink.undo() }.accessibilityIdentifier("offline-drill-ink-undo")
                        Button("全部消す") { ink.clear() }.accessibilityIdentifier("offline-drill-ink-clear")
                    }
                    if isInkZoomed {
                        Button("元の大きさ") { ink.resetZoom() }.accessibilityIdentifier("offline-drill-ink-zoom-reset")
                    }
                }
                .font(Typography.sans(size: 13, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Theme.card.opacity(0.92), in: Capsule())
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                .timelineInkPassThrough()
                .padding(.leading, layout.isPad ? 24 : 20)
                .padding(.bottom, 16)
            }
        }
    }
}

/// プロトタイプの状態: どの型を開いているか、今の問題、答えを出しているか。
@MainActor
@Observable
final class OfflineDrillLabModel {
    enum Variant: String, Hashable {
        /// 答えは押した時だけ見せる。
        case answer
        /// 答えを出さず、「次へ」だけ。
        case next
    }

    let templates: [DrillTemplate]
    private(set) var index: Int
    private(set) var variant: Variant
    private(set) var problem: DrillProblem? = nil
    private(set) var failure: String? = nil
    private(set) var isAnswerShown: Bool = false
    /// 何問目か。
    private(set) var count: Int = 0
    /// 問題を変えるたびに増やす(書いた線を消す合図)。
    private(set) var generation: Int = 0
    private var random: DrillSeededRandom

    var template: DrillTemplate { templates[index] }

    init(templates: [DrillTemplate], index: Int, variant: Variant, seed: UInt64, revealsAnswer: Bool) {
        precondition(!templates.isEmpty, "プロトタイプに入れた型が 1 つも読めない")
        self.templates = templates
        self.index = min(max(index, 0), templates.count - 1)
        self.variant = variant
        self.random = DrillSeededRandom(seed: seed)
        next()
        if revealsAnswer, variant == Variant.answer { isAnswerShown = true }
    }

    /// 起動引数から作る。
    static func launch(arguments: [String] = ProcessInfo.processInfo.arguments) -> OfflineDrillLabModel {
        let templates: [DrillTemplate] = OfflineDrillLabSamples.sources.compactMap { (source: (path: String, json: String)) -> DrillTemplate? in
            try? DrillTemplate.decode(json: source.json)
        }
        func value(after flag: String) -> String? {
            guard let position: Int = arguments.firstIndex(of: flag), position + 1 < arguments.count else { return nil }
            return arguments[position + 1]
        }
        let variant: Variant = value(after: "-offline-drill-variant").flatMap { (text: String) -> Variant? in Variant(rawValue: text) } ?? Variant.answer
        let skill: String? = value(after: "-offline-drill-skill")
        let index: Int = templates.firstIndex { (template: DrillTemplate) -> Bool in template.skillId == skill } ?? 0
        let seed: UInt64 = value(after: "-offline-drill-seed").flatMap { (text: String) -> UInt64? in UInt64(text) } ?? UInt64.random(in: UInt64.min...UInt64.max)
        return OfflineDrillLabModel(templates: templates, index: index, variant: variant, seed: seed, revealsAnswer: arguments.contains("-offline-drill-reveal"))
    }

    /// 次の問題(直前と同じ問題は出さない)。
    func next() {
        do {
            problem = try DrillGenerator(template: template).next(using: &random, avoiding: problem)
            failure = nil
        } catch {
            problem = nil
            failure = "問題を作れませんでした"
        }
        isAnswerShown = false
        count += 1
        generation += 1
    }

    func toggleAnswer() {
        guard variant == Variant.answer else { return }
        isAnswerShown.toggle()
    }

    func select(_ index: Int) {
        guard templates.indices.contains(index), index != self.index else { return }
        self.index = index
        problem = nil
        count = 0
        next()
    }

    func setVariant(_ variant: Variant) {
        self.variant = variant
        if variant == Variant.next { isAnswerShown = false }
    }
}
#endif
