import SwiftUI

/// 例題の段の「先に進む」の待ち(待ち時間の体験 要件 §6): 要点から運ぶ → 例題 → 解説。
/// 待つのは例題バーだけで、空の吹き出しは出さない。直前の要点の返事から数式と強調を先頭から最大 3 つ
/// 取り出し(書式による機械的な切り出し)、元の箇所に淡い面の色をつけてから、チップとして例題バーへ 1 つずつ運ぶ。
/// 結果が届いたら、チップと要点の色を消し、例題をバーにフェードで入れ、その後に解説の吹き出しを出す(2 か所を同時に変えない)。
@Observable
@MainActor
final class WorkbookExampleWaitModel {
    enum Phase: Equatable { case idle, carrying, waiting, revealing, done, failed }

    static let statusText = "要点から例題を作っています"
    /// 類題が × で「例題に戻る」から来た時(A13: 誤答に合わせて新しい例題を作っている)。
    static let returnStatusText = "類題の答えに合わせて、例題を作り直しています"
    static let maxChips = 3

    private(set) var phase: Phase = .idle
    /// 運ぶ語(数式・強調)。
    private(set) var chips: [StruisMarkedSpans.Span] = []
    /// 要点の返事で色をつけている数。
    private(set) var highlightCount = 0
    /// 例題バーに着いたチップの数。
    private(set) var arrived = 0
    /// バーのチップを出しているか(結果が届いたら消す)。
    private(set) var chipsVisible = true
    /// 飛んでいるチップ(添字と位置)。
    private(set) var flying: (index: Int, position: CGPoint)?
    /// 例題をバーに入れたか。
    private(set) var showsExample = false
    /// 例題の段の返事(解説)を出してよいか。
    private(set) var revealsReply = true
    var animates = true

    /// 要点の返事の吹き出しの位置・バーのチップの位置・画面の大きさ(見た目の計算だけに使い、画面は描き直さない)。
    @ObservationIgnored var sourceFrame: CGRect?
    @ObservationIgnored var slotFrames: [Int: CGRect] = [:]
    @ObservationIgnored var barFrame: CGRect?
    @ObservationIgnored var containerSize: CGSize = .zero
    @ObservationIgnored private var delivered = false

    /// 待ちの間か(例題バーが「要点から例題を作っています」を出す)。
    var isActive: Bool { phase == .carrying || phase == .waiting || phase == .revealing }

    /// 例題が届く前に入った。要点の返事(`source`)から運ぶ語を取り出して運び始める。
    func begin(source: String?) async {
        guard phase == .idle else { return }
        chips = source.map { StruisMarkedSpans.spans($0, limit: Self.maxChips) } ?? []
        revealsReply = false
        delivered = false
        guard animates, !chips.isEmpty else {
            // 動かせない時(W7)・運ぶ語が無い時は、文言だけで待つ。
            phase = .waiting
            if !animates { chips = [] }
            return
        }
        phase = .carrying
        for index in chips.indices {
            guard phase == .carrying, !delivered else { break }
            withAnimation(.easeInOut(duration: 0.35)) { highlightCount = index + 1 }
            try? await Task.sleep(for: .milliseconds(600))
            guard phase == .carrying else { return }
            var start = Transaction()
            start.disablesAnimations = true
            withTransaction(start) { flying = (index, origin(for: index)) }
            try? await Task.sleep(for: .milliseconds(40))
            withAnimation(.easeInOut(duration: 0.7)) { flying = (index, target(for: index)) }
            try? await Task.sleep(for: .milliseconds(720))
            guard phase == .carrying else { return }
            withTransaction(start) {
                arrived = index + 1
                flying = nil
            }
        }
        if phase == .carrying { phase = .waiting }
        if delivered { await reveal() }
    }

    /// 例題が届いた。運んでいる途中なら、今のチップが着いてから出す(演出は結果より先に終わらないが、
    /// 結果が届いた後まで運び続けもしない)。
    func deliver() async {
        guard isActive, !delivered else { return }
        delivered = true
        if phase == .waiting { await reveal() }
    }

    /// 失敗・中断: 演出を止め、失敗の表示にする(W8)。
    func fail() {
        guard phase != .idle, phase != .done else { return }
        phase = .failed
        flying = nil
        highlightCount = 0
        chipsVisible = false
        revealsReply = true
    }

    /// 新しい回(「例題に戻る」)や段が変わった時に、次の待ちに備えて戻す。
    func reset() {
        phase = .idle
        chips = []
        highlightCount = 0
        arrived = 0
        chipsVisible = true
        flying = nil
        showsExample = false
        revealsReply = true
        delivered = false
    }

    private func reveal() async {
        phase = .revealing
        withAnimation(.easeOut(duration: animates ? 0.3 : 0)) {
            chipsVisible = false
            highlightCount = 0
        }
        if animates { try? await Task.sleep(for: .milliseconds(320)) }
        withAnimation(.easeIn(duration: animates ? 0.45 : 0)) { showsExample = true }
        if animates { try? await Task.sleep(for: .milliseconds(550)) }
        withAnimation(.easeOut(duration: animates ? 0.35 : 0)) { revealsReply = true }
        phase = .done
    }

    /// チップの出どころ: 色をつけた要点の吹き出し(見えていれば)。見えていなければ会話のいちばん上。
    private func origin(for index: Int) -> CGPoint {
        let top = (barFrame?.maxY ?? 120) + 24
        let bottom = containerSize.height > 0 ? containerSize.height - 80 : top + 200
        if let frame = sourceFrame, frame.maxY > top, frame.minY < bottom {
            let x = min(frame.minX + 70 + CGFloat(index) * 36, frame.maxX - 40)
            let y = min(max(frame.minY + 32, top), bottom)
            return CGPoint(x: x, y: y)
        }
        return CGPoint(x: max(80, containerSize.width * 0.35) + CGFloat(index) * 36, y: top + 16)
    }

    /// 行き先: 例題バーの中のチップの場所。
    private func target(for index: Int) -> CGPoint {
        if let frame = slotFrames[index] { return CGPoint(x: frame.midX, y: frame.midY) }
        let bar = barFrame ?? CGRect(x: 12, y: 60, width: containerSize.width - 24, height: 80)
        return CGPoint(x: bar.minX + 60 + CGFloat(index) * 80, y: bar.midY)
    }
}

/// 例題バーへ運ぶ語。数式は数式として描く。
struct WorkbookExampleChip: View {
    let span: StruisMarkedSpans.Span

    var body: some View {
        Group {
            switch span.kind {
            case .math:
                // 数式は WebView で描くので、幅を決めて渡す(fixedSize だと幅 0 で何も描かれない)。
                KaTeXMathText(span.chipSource, foregroundColor: UIColor(Theme.primaryText), fontSize: 13)
                    .frame(width: Self.mathWidth(span.body), height: 22)
            case .bold:
                Text(span.body)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.accentColor.opacity(0.16), in: Capsule())
        .accessibilityHidden(true)
    }

    /// 数式チップの幅の見込み(LaTeX の命令は短く描かれるので、文字数から命令分を引いて数える)。
    static func mathWidth(_ latex: String) -> CGFloat {
        let visible = latex.replacingOccurrences(of: #"\\[A-Za-z]+"#, with: "x", options: .regularExpression)
            .filter { !"{}^_ ".contains($0) }
        return min(170, max(28, CGFloat(visible.count) * 8 + 6))
    }
}

/// 例題バーの待ちの中身: 運ばれてきたチップと、ゆっくり明滅する「要点から例題を作っています」。
struct WorkbookExampleWaitingContent: View {
    let model: WorkbookExampleWaitModel
    /// 例題を作っているターン(起動の返事・先回り)。実際に起きた出来事をこの下に出す(信頼性計画 P2)。
    var liveKeys: [String] = []
    /// 「例題に戻る」から来た時の文言(A13: 誤答から作り直している)。
    var statusText = WorkbookExampleWaitModel.statusText
    var onStop: (() -> Void)? = nil
    @Environment(\.struisAnimatesWaiting) private var animates

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.chipsVisible, !model.chips.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(model.chips.enumerated()), id: \.offset) { index, span in
                        WorkbookExampleChip(span: span)
                            .opacity(index < model.arrived ? 1 : 0)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WorkbookSubunitView.coordinateSpace)) } action: { frame in
                                model.slotFrames[index] = frame
                            }
                    }
                }
                .transition(.opacity)
            }
            breathingStatus
            if !liveKeys.isEmpty {
                TurnLiveLine(keys: liveKeys, onStop: onStop, showsReplyExcerpt: true)
                    .accessibilityIdentifier("workbook-example-live")
            }
        }
    }

    /// ゆっくり明滅する状態の文言(動かせない時は止める)。
    private var breathingStatus: some View {
        TimelineView(.animation(paused: !animates || model.phase != .waiting)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let opacity = animates && model.phase == .waiting ? 0.55 + 0.45 * (0.5 + 0.5 * cos(t * 2 * .pi / 2.6)) : 1
            Text(statusText)
                .font(Typography.caption)
                .foregroundStyle(Theme.secondaryText)
                .opacity(opacity)
        }
        .accessibilityLabel(statusText)
        .accessibilityIdentifier("workbook-example-waiting")
    }
}
