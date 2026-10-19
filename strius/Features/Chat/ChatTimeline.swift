import SwiftUI

/// 会話の本文。自動で下へ送るのは、学習者が送った直後と、返事が出来上がった時(学習者が下の方を
/// 見ている時)だけ。内容の高さの変化には反応しない。
///
/// 数式は SwiftMath で描き、行の高さはレイアウトの時に決まる(Issue #28)。以前は数式の WebView の高さが描き終えてから
/// 決まり、そのずれを補正するために送り直し・`ChatAnchorKeeper`・`KaTeXPrefetcher`・snapshot の差し替えを重ねていた。
/// 高さが後から変わらなくなったので、それらは外した。残しているのは、読み返している間の位置を画面の下端の吹き出しを
/// 基準に保つ `scrollPosition(id:anchor: .bottom)` と、開いた時に下端から始める `defaultScrollAnchor(.bottom)` だけ。
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
    /// 画面の下端にある吹き出し(スクロールの位置の基準)。行の高さが変わっても、この吹き出しの位置を保つ。
    @State private var anchorMessageID: UUID?
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
                    }
                    Color.clear.frame(height: 12 + bottomInset).id(Self.bottomAnchor)
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            // 位置は画面の下端の吹き出しを基準に保つ。上へ読み返して画面の上の外で行が実体化しても、見えている会話を
            // 押し下げない(2026-10-07)。
            .scrollPosition(id: $anchorMessageID, anchor: .bottom)
            // 開いた時は最初から下端に置く(上端から始めると、会話の先頭の行を作ってから下端へ送ることになる)。
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // 基準は学習者のスクロールでだけ付く。基準が変わるたびにこちらから書き換えない(SwiftUI が付け直す値と打ち消し合い、
            // 更新が止まらず画面が固まる)。こちらから送る時だけ、送る直前に外す(`releaseAnchor`)。
            .scrollDismissesKeyboard(.interactively)
            // 返事待ちで「止める」「このまま待つ」が出た時に 1 回だけ下端まで送る(入力欄の帯に隠れないように。
            // 信頼性計画 P2 の 4)。学習者が読み返している時は動かさない。
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
                if phase == .interacting {
                    learnerScrolled = true
                    onLearnerScroll?()
                }
            }
            .task {
                await Task.yield()
                scrollToEnd(reader, animated: false)
            }
            .onChange(of: followToken) { _, token in
                // 新しい段の返事が現れた(「先に進む」「例題に戻る」の後)。読み返しの途中でも、その返事まで送る。
                guard let token, let target = messages.first(where: { $0.id.uuidString == token })?.id else { return }
                learnerScrolled = false
                releaseAnchor()
                withAnimation(reduceMotion ? nil : .easeOut(duration: Theme.Duration.standard)) {
                    reader.scrollTo(target, anchor: .top)
                }
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

    /// 最後のメッセージの下端へ送る(1 回。行の高さはレイアウトで決まっているので送り直さない)。
    private func scrollToEnd(_ reader: ScrollViewProxy, animated: Bool) {
        guard messages.last != nil else { return }
        // 最後の行の下の余白(右下に浮かせたボタンの分)まで送る。最後の行がボタンの下に隠れないように。
        releaseAnchor()
        if animated {
            withAnimation(.easeOut(duration: Theme.Duration.standard)) { reader.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        } else {
            reader.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    private static let bottomAnchor = "chat-bottom"

    /// こちらから送る直前に、学習者のスクロールで付いた位置の基準を外す。残すと、送った後に SwiftUI が古い基準の
    /// 吹き出しの位置へ引き戻す(送り先と取り合う)。
    private func releaseAnchor() {
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
