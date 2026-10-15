import SwiftUI

/// 小単元 段階 1・2 の上部ヘッダー。
/// 開いた状態は単元名・段階チップ・到達目標と、下端の取っ手(∧)。
/// 取っ手を上へスワイプ(またはヘッダーをタップ)すると 1 行(単元名・進捗の点・∨)に畳む。
/// 指に追従して縮み、離すと近い方へ寄る。畳んだ行を下へスワイプかタップで戻る。
/// 開閉は小単元ごとに保存し、次に開いたとき前回の状態で出す(初回は開いた状態)。
/// 例題の段(段階 2)では、畳んだ 1 行から始まり(開閉は保存しない)、タップでだけ開閉する
/// (スワイプや会話の操作では動かない)。
/// ヘッダーは不透明で、チャットはその下を通らない。
struct WorkbookSubunitHeader: View {
    static let collapsedHeight: CGFloat = 40
    static func storageKey(subunitID: String) -> String { "workbook.subunitHeaderCollapsed.\(subunitID)" }

    /// 例題の段は畳んだ 1 行から始め、タップでだけ開閉する(指に追従しない)。開閉は保存しない。
    static func opensByTapOnly(_ subunit: WorkbookSubunitDTO) -> Bool { subunit.stageValue == .jointExample }

    /// 表示を作り直す単位。段(と「例題に戻る」の回)が変わったら、その段の初期状態から始める。
    static func identity(_ subunit: WorkbookSubunitDTO) -> String { "\(subunit.id)|\(subunit.kickoffKey ?? String(subunit.stage))" }

    let subunit: WorkbookSubunitDTO
    /// 要点の段の開閉(小単元ごとに保存)。
    @AppStorage private var storedCollapsed: Bool
    /// 例題の段の開閉(保存しない。畳んだ 1 行から始める)。
    @State private var exampleCollapsed = true

    private var isCollapsed: Bool {
        get { Self.opensByTapOnly(subunit) ? exampleCollapsed : storedCollapsed }
        nonmutating set {
            if Self.opensByTapOnly(subunit) { exampleCollapsed = newValue } else { storedCollapsed = newValue }
        }
    }
    @Environment(\.colorScheme) private var scheme
    @State private var expandedHeight: CGFloat = 0
    @State private var dragHeight: CGFloat?
    @State private var dragStartHeight: CGFloat?

    init(subunit: WorkbookSubunitDTO) {
        self.subunit = subunit
        _storedCollapsed = AppStorage(wrappedValue: false, Self.storageKey(subunitID: subunit.id))
    }

    private var restingHeight: CGFloat {
        isCollapsed ? Self.collapsedHeight : max(expandedHeight, Self.collapsedHeight)
    }

    private var currentHeight: CGFloat { dragHeight ?? restingHeight }

    /// 0 = 開いた状態、1 = 畳んだ状態。
    private var progress: CGFloat {
        // まだ開いた高さを測っていない(畳んだ状態で始まった)間は、畳んだ行だけを出す。
        guard expandedHeight > 0 else { return isCollapsed ? 1 : 0 }
        let range = max(1, expandedHeight - Self.collapsedHeight)
        return min(1, max(0, (expandedHeight - currentHeight) / range))
    }

    var body: some View {
        // 畳み切った / 開き切った状態ではもう一方を置かない(不可視の要素を残さない)。
        // 途中(指に追従中・アニメーション中)だけ両方を重ねてクロスフェードする。
        ZStack(alignment: .top) {
            if progress < 1 {
                expandedContent
                    .opacity(expandedHeight > 0 ? 1 - progress : (isCollapsed ? 0 : 1))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { expandedHeight = $0 }
            }
            if progress > 0 {
                collapsedContent
                    .opacity(progress)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: expandedHeight > 0 ? currentHeight : (isCollapsed ? Self.collapsedHeight : nil), alignment: .top)
        .background(alignment: .top) {
            // 畳んだ状態で始まった時も、開くアニメーションの行き先(開いた高さ)を見えないところで測っておく。
            if expandedHeight == 0, isCollapsed {
                expandedContent
                    .hidden()
                    .accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { expandedHeight = $0 }
            }
        }
        .clipped()
        .background(Theme.ground)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workbook-subunit-header")
        .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
    }

    // MARK: - 開いた状態

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subunit.unitTitle)
                .font(Typography.micro)
                .foregroundStyle(Theme.secondaryText)
            WorkbookStageSteps(stage: subunit.stage, passed: subunit.status == .passed)
                .padding(.vertical, 6)
            if !subunit.outcome.isEmpty {
                Text(subunit.outcome)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            grabber(systemName: "chevron.up", label: "説明を畳む")
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 畳んだ状態

    private var collapsedContent: some View {
        HStack(spacing: 12) {
            Text(subunit.unitTitle)
                .font(Typography.micro)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            progressDots
            grabber(systemName: "chevron.down", label: "説明を開く")
        }
        .padding(.horizontal, 20)
        .frame(height: Self.collapsedHeight)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(WorkbookStage.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(dotColor(for: item))
                    .frame(width: item.rawValue == subunit.stage && !isPassed ? 18 : 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPassed ? "合格" : "段階 \(subunit.stageValue.label)")
    }

    private var isPassed: Bool { subunit.status == .passed }

    private func dotColor(for item: WorkbookStage) -> Color {
        if isPassed { return WorkbookPalette.passed }
        if item.rawValue == subunit.stage { return Theme.accent(scheme) }
        if item.rawValue < subunit.stage { return Theme.accent(scheme).opacity(0.45) }
        return Color.secondary.opacity(0.25)
    }

    // MARK: - 取っ手

    private func grabber(systemName: String, label: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.tertiaryText)
            .frame(width: 44, height: 24)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            .accessibilityIdentifier("workbook-subunit-header-grabber")
    }

    // MARK: - 操作

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !Self.opensByTapOnly(subunit), expandedHeight > Self.collapsedHeight else { return }
                let start = dragStartHeight ?? restingHeight
                dragStartHeight = start
                dragHeight = min(expandedHeight, max(Self.collapsedHeight, start + value.translation.height))
            }
            .onEnded { value in
                defer { dragStartHeight = nil }
                let dy = value.translation.height
                if Self.opensByTapOnly(subunit) {
                    // タップ(ほとんど動かさずに離した)だけで開閉する。畳んだ状態から始まるので、
                    // まだ開いた高さを測っていなくても開ける。
                    if abs(dy) < 6, abs(value.translation.width) < 6 { toggle() }
                    return
                }
                guard expandedHeight > Self.collapsedHeight else { return }
                if abs(dy) < 6 {
                    // 横へのドラッグ(縦にほとんど動かない)はタップとして扱わない。会話の数式を横に動かそうとして
                    // ヘッダーの上から始めた指で開閉すると、会話全体が上下にずれる。
                    if abs(value.translation.width) < 6 {
                        toggle()
                    } else {
                        withAnimation(.snappy(duration: 0.28)) { dragHeight = nil }
                    }
                    return
                }
                let collapsed = abs(dy) > 24 ? dy < 0 : progress > 0.5
                withAnimation(.snappy(duration: 0.28)) {
                    isCollapsed = collapsed
                    dragHeight = nil
                }
            }
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.28)) {
            isCollapsed.toggle()
            dragHeight = nil
        }
    }
}

#if DEBUG
private extension WorkbookSubunitDTO {
    static var previewIntroduction: WorkbookSubunitDTO {
        WorkbookSubunitDTO(
            id: "preview-sub", unitId: "preview-unit",
            unitTitle: "フーリエ解析の基本を理解して基本問題を自力で解ける",
            title: "正弦波の振幅と周期と周波数を読み取れる",
            outcome: "正弦波の式から振幅、周期、周波数、角周波数を求め、それぞれの意味を説明できる。",
            position: 0, stage: 1, stageLabel: "要点", status: .active, n: 15, threshold: 0.8,
            scoringUnit: "1問ごとに正誤",
            window: WorkbookWindowDTO(n: 15, threshold: 0.8, count: 0, correct: 0, score: nil, passed: false, requiredCorrect: 12),
            tiles: [], openSetId: nil, lastResult: nil, canAdvance: true, updatedAt: "2026-09-17T00:00:00Z"
        )
    }
}

#Preview("ヘッダー 開いた状態") {
    VStack(spacing: 0) {
        WorkbookSubunitHeader(subunit: .previewIntroduction)
        Color.clear
    }
    .onAppear { UserDefaults.standard.set(false, forKey: WorkbookSubunitHeader.storageKey(subunitID: "preview-sub")) }
}

#Preview("ヘッダー 畳んだ状態 / ダーク") {
    VStack(spacing: 0) {
        WorkbookSubunitHeader(subunit: .previewIntroduction)
        Color.clear
    }
    .onAppear { UserDefaults.standard.set(true, forKey: WorkbookSubunitHeader.storageKey(subunitID: "preview-sub")) }
    .preferredColorScheme(.dark)
}
#endif
