import SwiftUI

/// S7 英語の文変形 — 選択肢ベースのシンプルな canvas で
/// 同じ循環 (予想 → 意味ある差 → 圧縮 → 再試行 → 転移 → 境界) を回す。
struct TextTransformFlowView: View {
    let content: TextTransformContent
    let onExit: () -> Void

    enum Stage {
        case hook, predict, consequence, insight, transfer, boundary, ended
    }

    @State private var stage: Stage = .hook
    @State private var predictPick: Int? = nil
    @State private var retryPick: Int? = nil
    @State private var retryDone = false
    @State private var transferPick: Int? = nil

    @Environment(\.colorScheme) private var scheme

    init(content: TextTransformContent, initialStageName: String? = nil, onExit: @escaping () -> Void) {
        self.content = content
        self.onExit = onExit
        // デモ用ディープリンク: 途中のステージから開始する
        if let initialStageName {
            let stage: Stage? = switch initialStageName {
            case "predict": .predict
            case "consequence": .consequence
            case "insight": .insight
            case "transfer": .transfer
            case "boundary": .boundary
            default: nil
            }
            if let stage {
                _stage = State(initialValue: stage)
                if stage != .predict {
                    _predictPick = State(initialValue: 1) // 典型的な誤予想 (②)
                }
            }
        }
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
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .predict }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(content.baseSentence)
                            .font(Typography.serifItalic(size: 20))
                            .foregroundStyle(Theme.accent(scheme))
                        Text(content.hook)
                            .font(Typography.sans(size: 17, weight: .bold))
                            .foregroundStyle(Theme.textPrimary(scheme))
                        Text(content.hookSub)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary(scheme))
                        Text("タップして予想を置きにいく")
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

        case .predict:
            VStack(alignment: .leading, spacing: 12) {
                Text(content.hook)
                    .font(Typography.title)
                Text("3 つのうち、正しいと思う文を選んで。")
                    .font(Typography.bodyCompact)
                    .foregroundStyle(Theme.textSecondary(scheme))
                choiceList(content.predictChoices, picked: predictPick, revealCorrect: nil) { index in
                    predictPick = index
                }
            }

        case .consequence:
            VStack(alignment: .leading, spacing: 12) {
                Text("予想と、結果。")
                    .font(Typography.title)
                choiceList(content.predictChoices, picked: predictPick, revealCorrect: content.correctIndex) { _ in }
                diffCard(
                    (predictPick == content.correctIndex ? "ぴったり。" : "あなたの予想は \(Self.choiceMarkers[predictPick!])。実際の並びは \(Self.choiceMarkers[content.correctIndex])。 ")
                        + content.diffText
                )
            }

        case .insight:
            VStack(alignment: .leading, spacing: 12) {
                if retryDone {
                    InsightCard(
                        serif: content.retrySuccessSerif,
                        note: "時を表す語 → 動詞が過去に。一度掴んだ形は、次から一瞬で読めます。"
                    )
                } else {
                    InsightCard(serif: content.insightSerif, note: content.insightNote)
                    Text(content.retryQuestion)
                        .font(Typography.title)
                        .padding(.top, 4)
                    SegChoiceRow(choices: content.retryChoices, pickedIndex: retryPick) { index in
                        retryPick = index
                        if index == content.retryCorrectIndex {
                            withAnimation(.easeInOut(duration: Theme.Duration.standard)) { retryDone = true }
                        }
                    }
                    if retryPick != nil {
                        diffCard("もう一度。\(content.retryNudge)")
                    }
                }
            }

        case .transfer:
            VStack(alignment: .leading, spacing: 14) {
                Text(content.transferQuestion)
                    .font(Typography.title)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent(scheme))
                        .padding(.top, 1)
                    Text("紙とペンがあれば、そちらで考えるのがおすすめです。ノートで文を完成させ、答えだけここに置けます。")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary(scheme))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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

    /// 文の選択肢リスト。revealCorrect が非 nil のとき正解を緑で示す (意味ある差)。
    private static let choiceMarkers = ["①", "②", "③"]

    private func choiceList(
        _ choices: [String],
        picked: Int?,
        revealCorrect: Int?,
        onPick: @escaping (Int) -> Void
    ) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                Button {
                    if revealCorrect == nil { onPick(index) }
                } label: {
                    HStack(spacing: 10) {
                        Text(Self.choiceMarkers[index])
                            .font(Typography.bodyCompact)
                            .foregroundStyle(Theme.textTertiary(scheme))
                        Text(choice)
                            .font(Typography.bodyCompact)
                            .foregroundStyle(Theme.textPrimary(scheme))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        if revealCorrect == index {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.growth(scheme))
                        } else if revealCorrect != nil, picked == index {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.regress(scheme))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background {
                        if picked == index, revealCorrect == nil {
                            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                .fill(Theme.accent(scheme).opacity(0.14))
                        }
                    }
                    .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
            }
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
        case .hook:
            EmptyView()
        case .predict:
            RailPrimaryButton(title: "予想を置く", isDisabled: predictPick == nil) {
                withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .consequence }
            }
        case .consequence:
            RailPrimaryButton(title: "なぜ変わるのか見る") {
                withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .insight }
            }
        case .insight:
            if retryDone {
                RailPrimaryButton(title: "支援なしで試してみる") {
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .transfer }
                }
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
        case .ended:
            RailPrimaryButton(title: "ここから続けます", action: onExit)
        }
    }
}
