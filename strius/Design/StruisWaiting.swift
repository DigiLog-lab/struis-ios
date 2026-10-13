import SwiftUI
import UIKit

/// 待ちの演出の共通部品(待ち時間の体験 要件 2026-09-26)。
/// W4: 動きは 1 つずつ、文言の切り替えはフェード。W7: 「視差効果を減らす」・バックグラウンドでは動かさない。

extension EnvironmentValues {
    /// 待ちの演出が動いてよいか(`scenePhase == .active` かつ「視差効果を減らす」がオフ)。
    var struisAnimatesWaiting: Bool {
        scenePhase == .active && !accessibilityReduceMotion
    }
}

/// 左から右へゆっくり光が流れ続ける文字(§7「考えています」、§6 の例題バーの文言)。
/// 動かせない時は、ただの文字になる。
struct StruisShimmerText: View {
    let text: String
    var font: Font = Typography.body
    var color: Color = Theme.secondaryText
    /// 光が 1 回通る秒数。
    var period: Double = 2.4
    @Environment(\.struisAnimatesWaiting) private var animates

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .overlay {
                if animates {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let phase = CGFloat((t.truncatingRemainder(dividingBy: period)) / period)
                        GeometryReader { proxy in
                            let width = proxy.size.width
                            let band = max(36, width * 0.45)
                            LinearGradient(
                                colors: [.clear, Theme.primaryText.opacity(0.85), .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: band)
                            .offset(x: -band + (width + band) * phase)
                        }
                        .mask(Text(text).font(font))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

/// 状態の文言。少数の決まった文言だけを出し、切り替えはフェード(W4)。VoiceOver には読ませる(W7)。
struct StruisWaitingStatus: View {
    let text: String
    var font: Font = Typography.caption
    var color: Color = Theme.secondaryText

    var body: some View {
        ZStack {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .id(text)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.35), value: text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.updatesFrequently)
        .onChange(of: text) { _, new in
            UIAccessibility.post(notification: .announcement, argument: new)
        }
    }
}

/// §7 質問の返事待ち: 返事が出る位置に、読み込みのアイコン・「考えています」・経過秒数を 1 行で並べる。
/// 経過秒数は学習者が送った時点(このターンが始まった時刻)から数え、3 秒を過ぎたら「12秒」の形で添える。
/// 文言は「考えています」だけに固定する(内容を装った文言は出さない)。
struct ChatThinkingRow: View {
    let startedAt: Date
    /// Codex から推論の要約が取れるようになったら、ここで差し替える(今は常に nil)。
    var summary: String? = nil

    static let label = "考えています"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = Self.elapsedSeconds(from: startedAt, now: context.date)
            HStack(spacing: 8) {
                StruisLoadingIndicator()
                    .controlSize(.mini)
                StruisShimmerText(text: summary ?? Self.label, font: Typography.body)
                if let seconds = Self.visibleSeconds(elapsed) {
                    Text("\(seconds)秒")
                        .font(Typography.caption.monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.visibleSeconds(elapsed).map { "\(summary ?? Self.label) \($0)秒" } ?? (summary ?? Self.label))
            .accessibilityIdentifier("chat-thinking-row")
        }
    }

    static func elapsedSeconds(from start: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(start)))
    }

    /// 3 秒を過ぎたら出す。
    static func visibleSeconds(_ elapsed: Int) -> Int? {
        elapsed > 3 ? elapsed : nil
    }
}

/// 待ちの間に、そのターンで実際に起きた出来事を出す 1〜2 行(待ち時間の体験 W11、信頼性計画 P2)。
/// 上の行は最後の出来事(コマンド・途中経過の文・委任・圧縮・届いた部分の結果)、下の行は出来事が 10 秒以上来ない時の事実。
/// 60 秒を超えたら「止める」「このまま待つ」を出す(`onStop` がある時)。文字だけなので「視差効果を減らす」でも変わらない(W7)。
struct TurnLiveLine: View {
    /// 見るターン(先に書いたものほど優先しない。始まりがいちばん新しい、終わっていないもの)。
    let keys: [String]
    var onStop: (() -> Void)? = nil
    /// 出来事の言葉を部分の結果の数から作り直す(例: 「15 問中 6 問できました」)。
    var partialText: ((Int) -> String)? = nil
    /// 返事の本文が隠れている画面(単元づくり・例題の待ち)で、書かれている最後の一文を添える。
    var showsReplyExcerpt = false
    var font: Font = Typography.caption

    private var board: TurnActivityBoard { TurnActivityBoard.shared }
    @Environment(\.turnLiveHidesHeadline) private var hidesHeadline
    @Environment(\.turnLiveRevealChoice) private var revealChoice

    var body: some View {
        let activity = board.firstLive(keys)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let silence = activity.flatMap { TurnSilence.statement(for: $0, now: context.date) }
            VStack(alignment: .leading, spacing: 6) {
                if !hidesHeadline, let headline = headline(activity) {
                    // 出来事は頻繁に変わるので、VoiceOver には読み上げを押し付けず、要素として読めるようにする。
                    Text(headline)
                        .font(font)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(.easeInOut(duration: 0.25), value: headline)
                        .accessibilityAddTraits(.updatesFrequently)
                        .accessibilityIdentifier("turn-live-headline")
                }
                if let silence {
                    StruisWaitingStatus(text: silence.text, font: Typography.micro, color: Theme.tertiaryText)
                        .accessibilityIdentifier("turn-live-silence")
                    if silence.offersChoice, let onStop, let key = liveKey {
                        HStack(spacing: 8) {
                            Button("止める", action: onStop)
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("turn-live-stop")
                            Button("このまま待つ") { board.keepWaiting(key) }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("turn-live-keep-waiting")
                        }
                        .font(Typography.caption)
                        .onAppear { revealChoice?() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var liveKey: String? {
        keys.filter { board.activity($0).map { !$0.finished } ?? false }
            .max { (board.activity($0)?.startedAt ?? .distantPast) < (board.activity($1)?.startedAt ?? .distantPast) }
    }

    private func headline(_ activity: TurnActivity?) -> String? {
        guard let activity else { return nil }
        if let done = activity.partialDone, done > 0, let partialText { return partialText(done) }
        if showsReplyExcerpt, activity.headline == "返事を書いています", let sentence = TurnReplyStream.lastSentence(activity.visibleReply) {
            return "返事を書いています: \(sentence)"
        }
        return activity.headline
    }
}

/// 返事を待つ間の吹き出し(信頼性計画 P2 の 2): 「考えています」の行(最後の出来事で差し替える)と、書かれている本文。
/// 本文は `struis_*` のタグを除き、閉じた数式まで。書き終わった段落は数式を描き、書いている段落は読める文字で出す。
struct ChatLiveReply: View {
    let messageID: UUID
    let startedAt: Date
    var onStop: (() -> Void)? = nil

    private var key: String { TurnActivityKey.reply(messageID) }

    var body: some View {
        let activity = TurnActivityBoard.shared.activity(key)
        VStack(alignment: .leading, spacing: 6) {
            ChatThinkingRow(startedAt: startedAt, summary: summary(activity))
            // 沈黙の事実と選択は「考えています」のすぐ下に出す(本文が長くなっても入力欄の下に隠れないように)。
            TurnLiveLine(keys: [key], onStop: onStop, font: Typography.micro)
                .padding(.horizontal, 4)
                .modifier(HideHeadline())
            if let text = activity?.visibleReply, !text.isEmpty {
                StreamingReplyText(text: text, complete: activity?.writingPrivateTail == true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .struisSurface(radius: Theme.Radius.bubble)
                    .accessibilityIdentifier("chat-streaming-reply")
            }
        }
    }

    /// 「考えています」の代わりに出す、最後の出来事の言葉(本文を書いている間は「返事を書いています」)。
    private func summary(_ activity: TurnActivity?) -> String? {
        guard let activity, !activity.finished else { return nil }
        return activity.headline
    }

    /// 出来事の言葉は「考えています」の行に出すので、ここでは沈黙の事実と選択だけを出す。
    private struct HideHeadline: ViewModifier {
        func body(content: Content) -> some View {
            content.environment(\.turnLiveHidesHeadline, true)
        }
    }
}

extension EnvironmentValues {
    @Entry var turnLiveHidesHeadline = false
    /// 「止める」「このまま待つ」を出した時に、それが入力欄の帯に隠れないよう会話を下端まで送る(会話の画面が渡す)。
    @Entry var turnLiveRevealChoice: (@MainActor () -> Void)? = nil
}

/// 書かれている途中の返事。書き終わった段落は、いつもの吹き出しと同じく KaTeX で描く(数式・強調)。
/// 書いている途中の段落だけは、閉じた数式を読める文字に直して出す(書かれるたびに WebView の数式を描き直すと、
/// 描き終わるまで空白になるため)。本文を書き終え、後ろの記録だけを書いている間(`complete`)は、出来上がった返事と
/// 同じ 1 つの本文として描く(返事が確定した時に、描き終えた見た目をそのまま使い回せる)。
struct StreamingReplyText: View {
    let text: String
    var complete = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let color = MessageBubble.textPrimaryColor(scheme)
        Group {
            if complete {
                KaTeXMathText(ChatTextReadability.formatAssistantText(text), foregroundColor: color)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        if index < paragraphs.count - 1 {
                            // 後ろに次の段落が来ている = この段落は書き終わっている(文字が変わらないので描き直さない)。
                            KaTeXMathText(ChatTextReadability.formatAssistantText(paragraph), foregroundColor: color)
                        } else {
                            Text(TurnReplyStream.readableMarkdown(paragraph))
                                .font(Typography.sans(size: 15, weight: .medium))
                                .foregroundStyle(Theme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 返事の吹き出しの上に小さく残す「N秒考えました」。
struct ChatThoughtLabel: View {
    let seconds: Int

    var body: some View {
        Text("\(seconds)秒考えました")
            .font(Typography.micro.monospacedDigit())
            .foregroundStyle(Theme.tertiaryText)
            .padding(.leading, 4)
            .accessibilityIdentifier("chat-thought-seconds")
    }
}

/// 左から詰めて、入りきらなければ次の行へ送る並べ方(チップ・候補・答えの文字)。
struct StruisFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x: CGFloat
            switch alignment {
            case .trailing: x = bounds.maxX - row.width
            case .center: x = bounds.minX + (bounds.width - row.width) / 2
            default: x = bounds.minX
            }
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            let extra = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if extra > width, !current.items.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append((index, size))
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
