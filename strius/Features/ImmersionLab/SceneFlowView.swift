import SwiftUI

/// シーンパッケージ再生フロー (契約 §4.3 のステージ分担)。
/// grammar (hook→predict→explore→consequence→insight→transfer→boundary) はシェルが駆動し、
/// predict / explore / consequence の描画だけを WKWebView のシーンに委ねる。
/// 既存の SimulationFlowView と同じ ImmersionShell・部品・ステージ機械を使う。
struct SceneFlowView: View {
    let package: ScenePackage
    let onExit: () -> Void
    let onChangeCandidate: () -> Void

    enum Stage {
        case hook, predict, explore, consequence, insight, transfer, boundary, ended
    }

    @State private var stage: Stage = .hook
    @State private var prediction: ScenePrediction? = nil
    @State private var bridge = ScenePlayerBridge()
    @State private var isHintOpen = false
    /// explore で一度でもシーンに触れたか (触れるまで結果に進めない。哲学 §2 Step4)。
    @State private var exploreInteracted = false
    @State private var retryPick: Int? = nil
    @State private var retryDone = false
    @State private var transferInput = ""
    /// 置いた答え (置き直し可能。哲学 §3: 誤答で止まらない・再試行1操作以内)。
    @State private var transferSubmitted: String? = nil

    // 文脈 chat (canvas と並存し、「学習に戻る」で同じ状態へ復帰する)
    @State private var chatStore: SceneChatStore?
    @State private var isChatPresented = false
    @State private var composerText = ""
    @State private var contextChipOn = true

    @Environment(APIClient.self) private var apiClient
    @Environment(\.colorScheme) private var scheme

    private var meta: SceneMeta { package.meta }

    init(
        package: ScenePackage,
        initialStageName: String? = nil,
        onChangeCandidate: (() -> Void)? = nil,
        onExit: @escaping () -> Void
    ) {
        self.package = package
        self.onExit = onExit
        self.onChangeCandidate = onChangeCandidate ?? onExit
        // デモ用ディープリンク: 途中のステージから開始する (予想は demoPrediction を事前配置)
        if let initialStageName {
            let stage: Stage? = switch initialStageName {
            case "predict": .predict
            case "explore": .explore
            case "consequence": .consequence
            case "insight": .insight
            case "transfer": .transfer
            case "boundary": .boundary
            default: nil
            }
            if let stage {
                _stage = State(initialValue: stage)
                if stage != .predict, let demo = package.demoPrediction {
                    _prediction = State(initialValue: .number(demo))
                }
            }
        }
    }

    var body: some View {
        ImmersionShell(
            sourceLabel: meta.sourceLabel ?? "生成ケース",
            onClose: onExit,
            onChangeCandidate: onChangeCandidate,
            chatPane: (isChatPresented && chatStore != nil)
                ? AnyView(SceneChatPane(store: chatStore!))
                : nil,
            // 確認可能な事実のみ (哲学 §6)。推定した能力・興味は言わない。
            reasonText: "\(meta.sourceLabel ?? "保存済みの教材")から用意された候補です。この候補は勝手には始まりません。"
        ) {
            canvasContent
        } rail: {
            if isChatPresented {
                RailPrimaryButton(title: "学習に戻る") {
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
                        isChatPresented = false
                    }
                }
            } else {
                railContent
            }
        } composer: {
            SceneChatComposer(
                text: $composerText,
                contextChipOn: $contextChipOn,
                isSending: chatStore?.isSending ?? false,
                onSend: handleSend,
                onFocus: {
                    // 会話が既にあるなら、composer への focus で chat を再提示する。
                    if chatStore?.hasConversation == true, !isChatPresented {
                        withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
                            isChatPresented = true
                        }
                    }
                }
            )
        }
        .onAppear {
            if chatStore == nil {
                chatStore = SceneChatStore(
                    client: apiClient,
                    sceneID: package.id,
                    threadTitle: meta.hook?.headline ?? meta.sourceLabel ?? package.id
                )
            }
            bridge.onReady = { syncStageToScene() }
            bridge.onPrediction = { value in
                withAnimation(.easeOut(duration: Theme.Duration.quick)) { prediction = value }
            }
            bridge.onInteraction = {
                if stage == .explore, !exploreInteracted {
                    withAnimation(.easeOut(duration: Theme.Duration.quick)) { exploreInteracted = true }
                }
            }
            // ready が onAppear より先に来た場合に備え、ここでも同期する
            // (未 ready なら bridge が保留し、ready 後に再生される)。
            syncStageToScene()
        }
        .onChange(of: stage) { _, _ in syncStageToScene() }
    }

    /// 現在ステージ名 (immersion_scene_context.stage)。
    private var stageName: String {
        switch stage {
        case .hook: "hook"
        case .predict: "predict"
        case .explore: "explore"
        case .consequence: "consequence"
        case .insight: "insight"
        case .transfer: "transfer"
        case .boundary: "boundary"
        case .ended: "ended"
        }
    }

    /// 「コーチに聞く」— 文脈 chat を開く (canvas は下でマウント維持)。
    private func presentCoachChat() {
        withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
            isChatPresented = true
        }
    }

    private func handleSend() {
        guard let chatStore else { return }
        let text = composerText
        composerText = ""
        withAnimation(.easeInOut(duration: Theme.Duration.standard)) { isChatPresented = true }
        Task {
            let didSend = await chatStore.send(
                text: text,
                stage: stageName,
                prediction: prediction,
                includeSceneContext: contextChipOn
            )
            if !didSend {
                composerText = text
            }
        }
    }

    /// 現在ステージをシーンへ伝える。ready 前の呼び出しは bridge が保留する。
    private func syncStageToScene() {
        switch stage {
        case .predict:
            bridge.enterStage("predict")
        case .explore:
            bridge.enterStage("explore")
        case .consequence:
            var context: [String: Any] = [:]
            if let prediction { context["prediction"] = prediction.jsValue }
            bridge.enterStage("consequence", context: context.isEmpty ? nil : context)
        default:
            break
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvasContent: some View {
        switch stage {
        case .hook:
            hookCanvas
        case .predict, .explore, .consequence:
            // 3 ステージは同じ WebView を使い回す (シーンの状態を壊さない)。
            sceneCanvas
        case .insight:
            insightCanvas
        case .transfer:
            transferCanvas
        case .boundary:
            BoundaryCanvas(
                serif: meta.boundary?.summarySerif ?? "分母を見れば、濃さは読める。",
                line: meta.boundary?.summaryLine
            )
        case .ended:
            EndedCanvas()
        }
    }

    private var hookCanvas: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .predict }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meta.hook?.headline ?? "")
                        .font(Typography.sans(size: 19, weight: .bold))
                        .foregroundStyle(Theme.textPrimary(scheme))
                    if let sub = meta.hook?.sub {
                        Text(sub)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary(scheme))
                    }
                    Text("タップして予想を置きにいく")
                        .font(Typography.micro.weight(.medium))
                        .foregroundStyle(Theme.accent(scheme))
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .glassSurface(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("話したいことがあれば、そのまま下から書けます。この候補は勝手には始まりません。")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
        }
    }

    private var sceneCanvas: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(sceneTitle)
                .font(Typography.title)
            ScenePlayerView(meta: meta, sceneHTML: package.sceneHTML, bridge: bridge)
                .frame(height: 430)
                .frame(maxWidth: .infinity)
                .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
            if stage == .consequence {
                if isHintOpen, let hint = meta.hint {
                    Text("ヒント: \(hint)")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary(scheme))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Theme.accent(scheme))
                                .frame(width: 3)
                        }
                        .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
            }
        }
    }

    private var sceneTitle: String {
        switch stage {
        case .predict:
            return meta.hook?.headline ?? "予想を置いて。"
        case .explore:
            return "動かして、動きを確かめる。"
        case .consequence:
            return "予想と、結果。"
        default:
            return ""
        }
    }

    @ViewBuilder
    private var insightCanvas: some View {
        VStack(alignment: .leading, spacing: 12) {
            if retryDone {
                InsightCard(
                    serif: meta.retry?.successLine ?? meta.insight?.serif ?? "",
                    note: "予想 → 動かす → 比較 → 圧縮。一度掴んだ形は、次から一瞬で読めます。"
                )
            } else {
                if let insight = meta.insight {
                    InsightCard(serif: insight.serif, note: insight.note ?? "")
                }
                if let retry = meta.retry {
                    Text(retry.question)
                        .font(Typography.title)
                        .padding(.top, 4)
                    SegChoiceRow(choices: retry.choices, pickedIndex: retryPick) { index in
                        retryPick = index
                        if index == retry.answerIndex {
                            withAnimation(.easeInOut(duration: Theme.Duration.standard)) { retryDone = true }
                        }
                    }
                    if retryPick != nil, retryPick != retry.answerIndex {
                        Text("もう一度。さっきの発見を使ってみて。")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textPrimary(scheme))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var transferCanvas: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let transfer = meta.transfer {
                Text(transfer.question)
                    .font(Typography.title)
                if let note = transfer.note {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "pencil")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.accent(scheme))
                            .padding(.top, 1)
                        Text(note)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary(scheme))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
                // 入力は答えを置いた後もロックしない (置き直し 1 操作、入力消去なし)。
                TextField("答えだけここに", text: $transferInput)
                    .font(Typography.sans(size: 16))
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(Color.white.opacity(scheme == .dark ? 0.06 : 0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.textPrimary(scheme).opacity(0.14), lineWidth: 0.5))
                if let submitted = transferSubmitted {
                    transferFeedback(transfer, submitted: submitted)
                }
            } else {
                Text("このケースの転移はまだありません。")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
            }
        }
    }

    @ViewBuilder
    private func transferFeedback(_ transfer: SceneMeta.Transfer, submitted: String) -> some View {
        let expected = transfer.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 固定文字列の包含では意味一致を判定できないため、現行の構造化 answer は
        // 前後の空白を除いた回答全体が一致した場合だけ成功とする。
        let normalizedSubmitted = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        let isOK = !expected.isEmpty && normalizedSubmitted == expected
        let serif = isOK ? (transfer.feedbackOk ?? "同じ形が使えました。") : (transfer.feedbackRetry ?? "止まらずに、置き直せます。")
        VStack(alignment: .leading, spacing: 4) {
            Text(serif)
                .font(Typography.serifItalic(size: 16))
                .foregroundStyle(Theme.accent(scheme))
            if !isOK, !expected.isEmpty {
                Text("ひとつの読み方: \(expected)")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textPrimary(scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassSurface(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    // MARK: - Rail

    @ViewBuilder
    private var railContent: some View {
        switch stage {
        case .hook:
            EmptyView()
        case .predict:
            RailPrimaryButton(title: "予想を置く", isDisabled: prediction == nil) {
                withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
                    exploreInteracted = false
                    stage = .explore
                }
            }
        case .explore:
            // 介入 (シーンに触れる) が完了するまで結果に進ませない。
            RailPrimaryButton(title: "この動きを確かめる", isDisabled: !exploreInteracted) {
                withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .consequence }
            }
        case .consequence:
            // 主1 (差の直後の再試行は insight の即答へ) + 補助1 (哲学 §1.2)。
            VStack(spacing: 0) {
                RailPrimaryButton(title: "もう一度予想する") {
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
                        isHintOpen = false
                        retryPick = nil
                        retryDone = false
                        stage = .insight
                    }
                }
                RailAuxRow(
                    showsHint: meta.hint != nil,
                    onHint: { withAnimation(.easeInOut(duration: Theme.Duration.quick)) { isHintOpen.toggle() } },
                    onCoach: presentCoachChat
                )
            }
        case .insight:
            if retryDone || meta.retry == nil {
                RailPrimaryButton(title: "支援なしで試してみる") {
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .transfer }
                }
            }
        case .transfer:
            // 答えを置いたら区切りへ進めるが、入力を変えれば 1 操作で置き直せる
            // (誤答で止めない。哲学 §3)。
            let trimmed = transferInput.trimmingCharacters(in: .whitespaces)
            if let submitted = transferSubmitted, submitted == trimmed {
                RailPrimaryButton(title: "区切りを確認する") {
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .boundary }
                }
            } else {
                RailPrimaryButton(title: "答えを置く", isDisabled: trimmed.isEmpty) {
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) { transferSubmitted = trimmed }
                }
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
