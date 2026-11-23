import SwiftUI

/// iPad の問題のパネル(#176)。紙は画面全体に敷き、問題はその上に浮かぶこのパネルに出す(Apple マップの iPad の左のパネルと同じ形)。
///
/// - 横幅は変えず、高さだけが変わる。下端は「次」の帯のすぐ上に留め、上の縁が指に付いて動く。
/// - つまみ(上端)を引くと、指を止めた位置でパネルも止まる。勢いよく払った時と、端の近くで離した時だけ、畳む・広げきる。
/// - 畳むと左下に帯だけが残り、帯には太字の問いを 1 行だけ出す。帯を押すか上に引くと広がる。
/// - 広げる・畳むの状態は呼び手が持つ(新しい問題は毎回広げて出す、を呼び手が決める)。`height` が nil なら広げきった状態。
struct TimelineProblemPanel<Content: View>: View {
    @Binding var height: CGFloat?
    /// 畳んだ帯に出す 1 行(`$…$` の式は数式として組む)。
    let collapsedLine: String
    /// パネルの形の場所(`TimelineInkSpace` の座標)が変わった時。呼び手は書く面のこの部分を抜く。
    let onFrameChange: (CGRect) -> Void
    let content: Content

    init(height: Binding<CGFloat?>, collapsedLine: String, onFrameChange: @escaping (CGRect) -> Void = { _ in },
         @ViewBuilder content: () -> Content) {
        _height = height
        self.collapsedLine = collapsedLine
        self.onFrameChange = onFrameChange
        self.content = content()
    }

    /// パネルが使える高さ(上の帯の下から「次」の帯の上まで)。
    @State private var available: CGFloat = 0
    /// 引き始めた時の高さ。
    @State private var dragStart: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var collapsed: CGFloat { TimelineLayout.panelCollapsedHeight }
    private static var handleHeight: CGFloat { 22 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: TimelineLayout.panelCorner, style: .continuous) }

    /// 今の高さ。使える高さが分かる前は広げきった形にする。
    private var shownHeight: CGFloat {
        guard available > 0 else { return Self.collapsed }
        return min(max(height ?? available, Self.collapsed), max(available, Self.collapsed))
    }

    /// 広がり具合(0 = 畳んだ帯、1 = 中身が見えている)。帯から 120pt 引くまでに、帯の 1 行から中身へ入れ替える。
    private var openness: CGFloat {
        min(1, max(0, (shownHeight - Self.collapsed) / 120))
    }

    private var isCollapsed: Bool { openness < 0.5 }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { available = $0 }
            .overlay(alignment: .bottomLeading) { panel }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            handle
            ZStack(alignment: .topLeading) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(Double(openness))
                    .allowsHitTesting(!isCollapsed)
                    .accessibilityHidden(isCollapsed)
                collapsedRow
                    .opacity(Double(1 - openness))
                    .allowsHitTesting(isCollapsed)
                    .accessibilityHidden(!isCollapsed)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: TimelineLayout.panelWidth, height: shownHeight, alignment: .top)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TimelineInkSpace.name)) } action: { onFrameChange($0) }
        .clipShape(shape)
        .glassEffect(.regular.tint(Theme.card.opacity(0.55)), in: shape)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        .contentShape(shape)
        // 書く面はこのパネルより上に乗っているので、パネルの上では指も Apple Pencil も通す(パネルの上には書かない)。
        .timelineInkPassThrough()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-problem-panel")
        .accessibilityValue(isCollapsed ? "畳んでいる" : "広げている")
    }

    /// 上端のつまみ。引くと高さが指に付いて動き、押すと畳む・広げるを切り替える。
    private var handle: some View {
        Capsule()
            .fill(Theme.tertiaryText.opacity(0.55))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: Self.handleHeight)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onTapGesture { toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isCollapsed ? "問題を広げる" : "問題を畳む")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            .accessibilityIdentifier("timeline-problem-panel-handle")
    }

    /// 畳んだ時の帯: 太字の問いの 1 行。押すか上に引くと広がる。
    private var collapsedRow: some View {
        // 問題文と同じ太字で組み、1 行に入らない分は切る(帯の高さは変えない)。
        TimelineRichText(text: collapsedLine, size: 16, weight: .bold)
            .frame(height: 28, alignment: .topLeading)
            .padding(.top, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .padding(.horizontal, 22)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onTapGesture { setHeight(nil) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(MathPlainText.readable(collapsedLine))
            .accessibilityHint("押すと問題を広げる")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { setHeight(nil) }
            .accessibilityIdentifier("timeline-problem-panel-collapsed")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let start: CGFloat = dragStart ?? shownHeight
                if dragStart == nil { dragStart = start }
                // 下端は留めたまま、上の縁が指に付いて動く(上に引くと高くなる)。
                height = min(max(start - value.translation.height, Self.collapsed), max(available, Self.collapsed))
            }
            .onEnded { value in
                let start: CGFloat = dragStart ?? shownHeight
                dragStart = nil
                let released: CGFloat = min(max(start - value.translation.height, Self.collapsed), available)
                // 払った勢いの行き先。端の近くまで行くなら、端まで送る。それ以外は離した位置で止める。
                let predicted: CGFloat = start - value.predictedEndTranslation.height
                if predicted < Self.collapsed + 56 {
                    setHeight(Self.collapsed)
                } else if predicted > available - 48 {
                    setHeight(nil)
                } else {
                    height = released
                }
            }
    }

    private func toggle() {
        setHeight(isCollapsed ? nil : Self.collapsed)
    }

    private func setHeight(_ value: CGFloat?) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.86)) {
            height = value
        }
    }
}
