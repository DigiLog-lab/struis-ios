import SwiftUI

/// 会話の本文。自動で下へ送るのは、学習者が送った直後と、返事が出来上がった時(学習者が下の方を
/// 見ている時)だけ。内容の高さの変化には反応しない: `LazyVStack` は画面外の行(数式の WebView や
/// 全体像カード)の高さを見積もりで持つので、高さの変化に合わせて下へ送ると「送る → 行の実体化・
/// 破棄で高さが変わる → また送る」の帰還ループになる(E2E 2026-09-23 H2)。
///
/// 読み返している間の位置は、画面の下端の吹き出しを基準に保つ(`scrollPosition(id:anchor: .bottom)`)。画面の上の外で
/// 行が実体化して数式の高さが決まっても、見えている会話を押し下げない(2026-10-07)。SwiftUI の基準が打ち消さない
/// 時があるので、指を離した後は `ChatAnchorKeeper` でも下端の吹き出しの位置を保つ(2026-10-16)。
///
/// 小単元で段が変わった直後は、学習者がどこを読んでいても、新しい段の返事(作られている最中の吹き出し)の
/// 頭まで送る。`followToken` はその段のモデルの返事の id で、新しい返事が現れて値が変わった時に送る
/// (段の変化と返事の現れる順番に左右されない)。
struct ChatTimeline: View {
    let messages: [ChatMessage]
    let threadID: UUID?
    var onProposalStarted: ((WorkbookProposalDTO) -> Void)?
    /// その段のモデルの返事の id。新しい返事に変わったら、その位置まで送る。
    var followToken: String?
    /// 会話の下端に空ける高さ(右下に浮かせたボタンの分)。
    var bottomInset: CGFloat = 0
    /// 学習者が自分で会話を動かした時。
    var onLearnerScroll: (() -> Void)?
    /// 数式・強調に色をつける返事と、その数(§6)。
    var highlight: (messageID: UUID, count: Int)?
    var onHighlightFrame: ((CGRect) -> Void)?
    @State private var isNearBottom = true
    /// 今の返事が始まってから、学習者が自分で動かしたか(読み返し中は引き戻さない)。
    @State private var learnerScrolled = false
    /// いま送っている先(新しい段の返事)。次の段へ進んだら、前の段の送り直しはやめる。
    @State private var followTarget: UUID?
    /// 画面の下端にある吹き出し(スクロールの位置の基準)。行の高さが変わっても、この吹き出しの位置を保つ。
    @State private var anchorMessageID: UUID?
    /// 指を離した後に、画面の上の外の行の高さが変わっても、見えている会話を動かさない(状態ではないので書いても描き直さない)。
    @State private var keeper = ChatAnchorKeeper()
    @State private var timelineWidth: CGFloat = 0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        messages: [ChatMessage], threadID: UUID? = nil, onProposalStarted: ((WorkbookProposalDTO) -> Void)? = nil,
        followToken: String? = nil, bottomInset: CGFloat = 0, onLearnerScroll: (() -> Void)? = nil,
        highlight: (messageID: UUID, count: Int)? = nil, onHighlightFrame: ((CGRect) -> Void)? = nil
    ) {
        self.highlight = highlight
        self.onHighlightFrame = onHighlightFrame
        self.threadID = threadID
        self.messages = messages
        self.onProposalStarted = onProposalStarted
        self.followToken = followToken
        self.bottomInset = bottomInset
        self.onLearnerScroll = onLearnerScroll
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Color.clear.frame(height: 8)
                    let folded = Self.foldedReplyIDs(messages)
                    ForEach(messages) { message in
                        MessageBubble(
                            message: message, threadID: threadID, onProposalStarted: onProposalStarted,
                            highlightCount: highlight?.messageID == message.id ? highlight?.count ?? 0 : 0,
                            onHighlightFrame: highlight?.messageID == message.id ? onHighlightFrame : nil,
                            folded: folded.contains(message.id)
                        )
                            .id(message.id)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).maxY } action: { maxY in
                                keeper.rowMoved(message.id, maxY: maxY)
                            }
                            .onDisappear { keeper.rowGone(message.id) }
                    }
                    Color.clear.frame(height: 12 + bottomInset).id(Self.bottomAnchor)
                }
                .scrollTargetLayout()
                .background(ChatScrollViewFinder { keeper.scrollView = $0 })
                // 会話の行の幅。画面に出る前に数式の高さを測る幅(`prefetchMath`)。
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { timelineWidth = $0 }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            // 位置は画面の下端の吹き出しを基準に保つ。上へ読み返すと、画面の上の外で行が実体化し、数式が描き終えて
            // 高さが変わる(初めて描く数式は高さが前もって分からない)。上端や中身の先頭を基準にすると、指を離した後に
            // 見えている会話が丸ごと押し下げられる(2026-10-07 の計測で 17〜51pt)。下端の吹き出しは描き終えているので動かない。
            .scrollPosition(id: $anchorMessageID, anchor: .bottom)
            // 開いた時は最初から下端に置く。上端から始めると、`LazyVStack` が会話の先頭の行を作ってから下端へ送るので、
            // 長い会話では見えない先頭の行の数式の WebView(とその中身のプロセス)がいくつも作られ、開いてから数十秒
            // 端末が重くなっていた(先頭の行は画面に全部見えることが無いので画像にも残らず、開くたびに繰り返していた)。
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // 基準は学習者のスクロールでだけ付く。基準が変わるたびにこちらから書き換えない(SwiftUI が付け直す値と打ち消し合い、
            // 更新が止まらず画面が固まる)。こちらから送る時だけ、送る直前に外す(`releaseAnchor`)。
            .scrollDismissesKeyboard(.interactively)
            // 返事待ちで「止める」「このまま待つ」が出た時に 1 回だけ下端まで送る(入力欄の帯に隠れないように。
            // 信頼性計画 P2 の 4)。学習者が読み返している時は動かさない。高さの変化には反応しない。
            .environment(\.turnLiveRevealChoice, {
                guard !learnerScrolled else { return }
                scrollToEnd(reader, animated: !reduceMotion)
            })
            // 位置の記録だけ(ここから scrollTo は呼ばない)。値が変わった時だけ状態を書く。
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height) < 120
            } action: { _, nearBottom in
                if isNearBottom != nearBottom { isNearBottom = nearBottom }
            }
            .onScrollPhaseChange { _, phase in
                keeper.phaseChanged(idle: phase == .idle, interacting: phase == .interacting)
                if phase == .interacting {
                    learnerScrolled = true
                    onLearnerScroll?()
                }
            }
            .task {
                await Task.yield()
                scrollToEnd(reader, animated: false)
            }
            // 読み返す前に、まだ描いていない数式の高さを新しい返事から測る。行が画面に出た後で高くなって会話が動かないように。
            .onChange(of: timelineWidth, initial: true) { prefetchMath() }
            .onChange(of: messages.count) { prefetchMath() }
            .onChange(of: followToken) { _, token in
                // 段が変わった: 前の段の返事への送り直しはここでやめる(新しい返事がまだ無い間も戻さない)。
                followTarget = nil
                // 新しい段の返事が現れた(「先に進む」「例題に戻る」の後)。読み返しの途中でも、その返事まで送る。
                guard let token, let target = messages.first(where: { $0.id.uuidString == token })?.id else { return }
                learnerScrolled = false
                follow(target, reader)
            }
            .onChange(of: messages.last?.id) { _, _ in
                // 学習者が送った直後は、自分のメッセージ(と返事待ち)が見える位置まで送る。
                // それ以外(モデルが話し始めた等)は、下の方を見ている時だけ。
                // 新しいターンが始まった(学習者の送信、またはモデルが段を始めた)。ここからの動きを数え直す。
                learnerScrolled = false
                let sentByLearner = messages.suffix(2).contains { $0.role == .user }
                guard sentByLearner || isNearBottom else { return }
                scrollToEnd(reader, animated: !reduceMotion)
            }
            .onChange(of: messages.last?.status) { old, new in
                // 返事が出来上がった: 生成中に学習者が読み返していなければ、返事の頭から読めるように送る。
                guard old == .pending, new != .pending, isNearBottom || !learnerScrolled, let lastID = messages.last?.id else { return }
                releaseAnchor()
                withAnimation(reduceMotion ? nil : .easeOut(duration: Theme.Duration.standard)) {
                    reader.scrollTo(lastID, anchor: .top)
                }
            }
        }
    }

    /// 最後のメッセージの下端へ送る。`LazyVStack` は画面外の行の高さを見積もりで持つので、1 回の
    /// scrollTo では行き過ぎて何も無い所に止まることがある。行が実体化した後に決まった回数(2 回)だけ
    /// 送り直す。高さの変化を監視して送り続けることはしない(帰還ループにしない)。
    private func scrollToEnd(_ reader: ScrollViewProxy, animated: Bool) {
        guard let lastID = messages.last?.id else { return }
        // 最後の行の下の余白(右下に浮かせたボタンの分)まで送る。最後の行がボタンの下に隠れないように。
        if animated {
            releaseAnchor()
            withAnimation(.easeOut(duration: Theme.Duration.standard)) { reader.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        } else {
            releaseAnchor()
            reader.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
        Task { @MainActor in
            // 上の行(数式など)の高さが決まると下端がずれるので、決まった回数だけ送り直す(D8。監視はしない)。
            for delay in [120, 400, 900, 1600] {
                try? await Task.sleep(for: .milliseconds(delay))
                // 学習者が読み返し始めたら引き戻さない。
                guard messages.last?.id == lastID, !learnerScrolled else { return }
                releaseAnchor()
                reader.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    /// 段が変わった直後: 新しい段の返事(の頭)まで送る。読み返していた位置が遠いと、間の行(数式など)が
    /// 実体化して高さが決まるまで行き先がずれるので、決まった回数だけ間を空けて送り直す(高さの変化は監視しない)。
    /// 学習者が自分で動かしたら、そこでやめる。
    private func follow(_ target: UUID, _ reader: ScrollViewProxy) {
        followTarget = target
        releaseAnchor()
        withAnimation(reduceMotion ? nil : .easeOut(duration: Theme.Duration.standard)) {
            reader.scrollTo(target, anchor: .top)
        }
        Task { @MainActor in
            for delay in [150, 400, 800, 1500] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !learnerScrolled, followTarget == target else { return }
                releaseAnchor()
                reader.scrollTo(target, anchor: .top)
            }
        }
    }

    private static let bottomAnchor = "chat-bottom"

    /// 最後の数件は画面に出ている(出す)ので、行が自分で描いて高さを記録する。測るのはその上の、読み返す行だけ。
    /// 新しい返事のたびに測ると、画面の行の WebView と描く処理を取り合い、段の切り替えが遅れた。
    private static let prefetchSkipsLatest = 3

    private func prefetchMath() {
        guard timelineWidth > 0, messages.count > Self.prefetchSkipsLatest else { return }
        KaTeXPrefetcher.shared.prefetch(messages.dropLast(Self.prefetchSkipsLatest).reversed().flatMap {
            MessageBubble.katexItems($0, scheme: scheme, timelineWidth: timelineWidth)
        })
    }

    /// こちらから送る直前に、学習者のスクロールで付いた位置の基準を外す。残すと、送った後に行の高さが変わった時、
    /// SwiftUI が古い基準の吹き出しの位置へ引き戻す(送り先と取り合う)。
    private func releaseAnchor() {
        keeper.release()
        if anchorMessageID != nil { anchorMessageID = nil }
    }

    /// 畳む返事(D15): 止まった・失敗した返事のうち、その後に次の返事(作っている最中か、出来上がったもの)があるもの。
    /// 生成中に続けて送ると、割り込まれた返事が「停止しました。」になるが、次の返事が続けて送られた文をまとめて踏まえるので、
    /// 「送り直す」を残すと不要な送り直しを促すだけになる。
    static func foldedReplyIDs(_ messages: [ChatMessage]) -> Set<UUID> {
        var folded: Set<UUID> = []
        var laterReplyExists = false
        for message in messages.reversed() where message.role == .assistant {
            if message.status == .failed {
                if laterReplyExists { folded.insert(message.id) }
            } else {
                laterReplyExists = true
            }
        }
        return folded
    }
}

/// 学習者が読み返して指を離した後、画面の下端の吹き出しの位置を保つ。画面の上の外の行は、実体化した時や、同じ本文の
/// 数式が別の行で描き終えて高さが分かった時(`KaTeXLayoutCache`)に高さが変わる。`scrollPosition(id:anchor: .bottom)` が
/// 打ち消すはずだが、打ち消さない時があり、見えている会話が丸ごと動いていた(CI で 31.33pt。返事が出来上がった時に、
/// 同じ本文の上の行が仮の文字から描き終えた高さに変わった)。
///
/// 指を離して止まった時に下端の吹き出しとその下端の位置を覚え、止まっている間にその吹き出しが動いたら、会話の
/// スクロールの位置を同じだけずらして戻す(SwiftUI が打ち消していれば動きは 0 で、何もしない)。指で動かしている間、
/// こちらから送った後(`release`)、会話の枠の大きさが変わった時(キーボードなど)は何もしない。
@MainActor
final class ChatAnchorKeeper {
    weak var scrollView: UIScrollView?
    /// 実体化している行の、会話の枠から見た下端。
    private var rows: [UUID: CGFloat] = [:]
    /// 学習者が自分で動かした後か(こちらから送ると外れる。`scrollPosition` の基準と同じ扱い)。
    private var active = false
    private var idle = true
    private var reference: (id: UUID, maxY: CGFloat, frame: CGRect, inset: UIEdgeInsets)?

    func phaseChanged(idle: Bool, interacting: Bool) {
        if interacting { active = true }
        self.idle = idle
        reference = nil
        if idle, active { pickReference() }
    }

    func release() {
        active = false
        reference = nil
    }

    func rowGone(_ id: UUID) {
        rows[id] = nil
        if reference?.id == id { reference = nil }
    }

    func rowMoved(_ id: UUID, maxY: CGFloat) {
        rows[id] = maxY
        guard let reference, reference.id == id, idle, active, let scrollView else { return }
        guard scrollView.frame == reference.frame, scrollView.adjustedContentInset == reference.inset else {
            // 会話の枠の大きさが変わった(キーボード・回転など): 動いたのは中身ではないので、今の位置を覚え直す。
            self.reference = (id, maxY, scrollView.frame, scrollView.adjustedContentInset)
            return
        }
        let delta = maxY - reference.maxY
        guard abs(delta) >= 0.5 else { return }
        let inset = scrollView.adjustedContentInset
        let lowest = -inset.top
        let highest = max(lowest, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        let target = min(max(scrollView.contentOffset.y + delta, lowest), highest)
        guard abs(target - scrollView.contentOffset.y) >= 0.5 else { return }
        scrollView.contentOffset.y = target
    }

    /// 画面に見えている中で、いちばん下の吹き出し。
    private func pickReference() {
        guard let scrollView else { return }
        let height = scrollView.bounds.height
        guard let bottom = rows.filter({ $0.value > 0 && $0.value <= height }).max(by: { $0.value < $1.value }) else { return }
        reference = (bottom.key, bottom.value, scrollView.frame, scrollView.adjustedContentInset)
    }
}

/// 会話の `ScrollView` の中に置き、それを描いている `UIScrollView` を見つける(`ChatAnchorKeeper` が位置を戻すため)。
private struct ChatScrollViewFinder: UIViewRepresentable {
    let found: (UIScrollView) -> Void

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.found = found
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: FinderView, context: Context) {}

    final class FinderView: UIView {
        var found: ((UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var next = superview
            while let view = next {
                if let scroll = view as? UIScrollView {
                    found?(scroll)
                    return
                }
                next = view.superview
            }
        }
    }
}
