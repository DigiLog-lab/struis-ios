import SwiftUI

/// Immersion Lab — 「適応型没頭体験」動作プロトタイプ。
/// 起動引数 `-immersion-lab` で AppRootView から全面表示される (DEBUG ゲート)。
struct ImmersionLabView: View {
    /// デモ用ディープリンク: `-immersion-scene tank.predict` のような起動引数で
    /// 任意のシナリオ・ステージから直接始められる (画面キャプチャ検証用)。
    /// web シーンは `-immersion-scene web.<id>.<stage>` (例: web.iced-tea-dilution.consequence)。
    private static var deepLink: (scenarioID: String, stage: String, isWebScene: Bool)? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-immersion-scene"), args.count > index + 1 else { return nil }
        let parts = args[index + 1].split(separator: ".").map(String.init)
        guard let first = parts.first else { return nil }
        if first == "web", parts.count > 1 {
            return (parts[1], parts.count > 2 ? parts[2] : "", true)
        }
        return (first, parts.count > 1 ? parts[1] : "", false)
    }

    @State private var activeScenario: ImmersionScenario? = ImmersionLabView.deepLink.flatMap { link in
        link.isWebScene ? nil : ImmersionScenarios.all.first { $0.id == link.scenarioID }
    }
    /// 生成ケース (シーンパッケージ) のアクティブパッケージ。ディープリンクはバンドル同梱分から即時解決する。
    @State private var activePackage: ScenePackage? = ImmersionLabView.deepLink.flatMap { link in
        link.isWebScene ? BundledScenes.samples.first { $0.id == link.scenarioID } : nil
    }
    @State private var initialStageName: String? = ImmersionLabView.deepLink?.stage
    /// GET /v1/immersion-lab/scenes から取得したリモートシーン (取得失敗時は空のまま)。
    @State private var remotePackages: [ScenePackage] = []

    @Environment(APIClient.self) private var apiClient
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LiquidWallpaper()
            if let activeScenario {
                ImmersionSessionView(scenario: activeScenario, initialStageName: initialStageName) {
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
                        self.activeScenario = nil
                        initialStageName = nil
                    }
                }
                .id(activeScenario.id)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let activePackage {
                SceneFlowView(package: activePackage, initialStageName: initialStageName) {
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
                        self.activePackage = nil
                        initialStageName = nil
                    }
                }
                .id(activePackage.id)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                home
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
    }

    // MARK: - シナリオ選択ホーム

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Struis")
                        .font(Typography.brand)
                        .foregroundStyle(Theme.accent(scheme))
                    Text("適応型没頭体験 — Immersion Lab")
                        .font(Typography.heading2)
                    Text("同じ循環 (予想 → 介入 → 意味ある差 → 圧縮 → 転移 → 境界) が、題材を変えて回ります。プロトタイプです。")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary(scheme))
                }
                .padding(.top, 24)

                // 生成ケース (シーンパッケージ): バンドル同梱サンプル + リモート取得分。
                // リモートは backend 未起動・認証失敗のとき静かにバンドル分だけになる。
                VStack(alignment: .leading, spacing: 10) {
                    Text("生成ケース")
                        .font(Typography.eyebrow)
                        .foregroundStyle(Theme.textTertiary(scheme))
                        .padding(.top, 10)
                    ForEach(generatedPackages) { package in
                        Button {
                            withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
                                initialStageName = nil
                                activePackage = package
                            }
                        } label: {
                            HStack(spacing: 14) {
                                Text("🧊")
                                    .font(.system(size: 30))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(package.meta.sourceLabel ?? "生成ケース")
                                        .font(Typography.micro)
                                        .foregroundStyle(Theme.textTertiary(scheme))
                                    Text(package.meta.hook?.headline ?? package.id)
                                        .font(Typography.bodyEmphasized)
                                        .foregroundStyle(Theme.textPrimary(scheme))
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary(scheme))
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                            .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                ForEach(ImmersionScenarios.all) { scenario in
                    Button {
                        withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
                            activeScenario = scenario
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Text(scenario.emoji)
                                .font(.system(size: 30))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(scenario.sourceLabel)
                                    .font(Typography.micro)
                                    .foregroundStyle(Theme.textTertiary(scheme))
                                Text(scenario.hook.replacingOccurrences(of: "\n", with: ""))
                                    .font(Typography.bodyEmphasized)
                                    .foregroundStyle(Theme.textPrimary(scheme))
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary(scheme))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .task {
            await loadRemoteScenes()
        }
    }

    /// バンドル同梱 → リモート (id がバンドルと重なるものはバンドルを優先)。
    private var generatedPackages: [ScenePackage] {
        let bundled = BundledScenes.samples
        let bundledIDs = Set(bundled.map(\.id))
        return bundled + remotePackages.filter { !bundledIDs.contains($0.id) }
    }

    /// リモートシーン一覧の取得。失敗 (未起動・認証・デコード) はすべて静かに無視する。
    private func loadRemoteScenes() async {
        let endpoint = APIEndpoint(method: .get, path: "/v1/immersion-lab/scenes")
        guard let (data, _) = try? await apiClient.fetchData(endpoint),
              let response = try? JSONDecoder().decode(SceneListResponse.self, from: data) else {
            return
        }
        remotePackages = response.scenes.map(\.package)
    }
}

/// 実行シェルへの振り分け。題材 kind ごとのフローを起動する。
private struct ImmersionSessionView: View {
    let scenario: ImmersionScenario
    let initialStageName: String?
    let onExit: () -> Void

    var body: some View {
        switch scenario {
        case .simulation(let scenario):
            SimulationFlowView(scenario: scenario, initialStageName: initialStageName, onExit: onExit)
        case .eigen(let content):
            EigenFlowView(content: content, initialStageName: initialStageName, onExit: onExit)
        case .textTransform(let content):
            TextTransformFlowView(content: content, initialStageName: initialStageName, onExit: onExit)
        }
    }
}

// MARK: - シェル (FixedHeader / Canvas / ActionRail / Composer)

/// HTML モックの shell 構造に対応する共通レイアウト。
/// `chatPane` を渡すと canvas 領域に chat が並存する (canvas は下でマウント維持
/// されたまま不可視になり、復帰時に同じ状態へ戻る)。
struct ImmersionShell<Canvas: View, Rail: View, Composer: View>: View {
    let sourceLabel: String
    let onClose: () -> Void
    let onChangeCandidate: () -> Void
    var chatPane: AnyView? = nil
    /// 「なぜ今これ？」で開く理由 (確認可能な事実のみ。哲学 §6)。nil なら導線を出さない。
    var reasonText: String? = nil
    @ViewBuilder var canvas: Canvas
    @ViewBuilder var rail: Rail
    @ViewBuilder var composer: Composer

    @State private var isReasonOpen = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LiquidWallpaper()
            VStack(spacing: 0) {
                header
                if isReasonOpen, let reasonText {
                    Text(reasonText)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary(scheme))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                        .transition(.opacity)
                }
                ZStack {
                    ScrollView {
                        canvas
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                            .padding(.bottom, 18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .opacity(chatPane == nil ? 1 : 0)
                    .allowsHitTesting(chatPane == nil)
                    .accessibilityHidden(chatPane != nil)
                    if let chatPane {
                        chatPane
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                rail
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                composer
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .frame(width: 30, height: 30)
                    .glassSurface(.thin, in: Circle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 0) {
                Text(sourceLabel)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .lineLimit(1)
                if reasonText != nil {
                    Button("なぜ今これ？") {
                        withAnimation(.easeInOut(duration: Theme.Duration.quick)) {
                            isReasonOpen.toggle()
                        }
                    }
                    .font(Typography.micro)
                    .foregroundStyle(Theme.accent(scheme))
                }
            }
            .frame(maxWidth: .infinity)

            Button("別のものにする", action: onChangeCandidate)
                .font(Typography.micro.weight(.medium))
                .foregroundStyle(Theme.accent(scheme))
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }
}

/// 旧来の 2 スロット呼び出し (モック composer・chat なし) を維持する。
extension ImmersionShell where Composer == ImmersionComposer {
    init(
        sourceLabel: String,
        onClose: @escaping () -> Void,
        @ViewBuilder canvas: () -> Canvas,
        @ViewBuilder rail: () -> Rail
    ) {
        self.init(
            sourceLabel: sourceLabel,
            onClose: onClose,
            onChangeCandidate: onClose,
            chatPane: nil,
            canvas: canvas,
            rail: rail,
            composer: { ImmersionComposer() }
        )
    }
}

/// 常設 composer のモック。chip の着脱以外は実際には動かない。
struct ImmersionComposer: View {
    @State private var chipOn = true

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if chipOn {
                HStack(spacing: 6) {
                    Text("この画面について")
                    Button {
                        withAnimation(.easeInOut(duration: Theme.Duration.quick)) { chipOn = false }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Theme.accent(scheme).opacity(0.18), in: Circle())
                    }
                }
                .font(Typography.micro.weight(.medium))
                .foregroundStyle(Theme.accent(scheme))
                .padding(.leading, 11)
                .padding(.trailing, 6)
                .frame(height: 26)
                .background(Theme.accent(scheme).opacity(0.14), in: Capsule())
            } else {
                HStack(spacing: 8) {
                    Button("この画面について") {
                        withAnimation(.easeInOut(duration: Theme.Duration.quick)) { chipOn = true }
                    }
                    .font(Typography.micro)
                    .foregroundStyle(Theme.textTertiary(scheme))
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .overlay(Capsule().stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Theme.textTertiary(scheme).opacity(0.6)))
                    Text("別のことを聞く")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }

            HStack(spacing: 8) {
                TextField("聞きたいことを書く", text: .constant(""))
                    .font(Typography.bodyCompact)
                    .disabled(true)
                Button {} label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Theme.textPrimary(scheme).opacity(0.18), in: Circle())
                }
                .disabled(true)
            }
        }
        .padding(.top, 7)
        .padding(.bottom, 8)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous))
    }
}

// MARK: - Action rail 部品

struct RailPrimaryButton: View {
    let title: String
    var isDisabled = false
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.bodyEmphasized)
                .foregroundStyle(Theme.textOnAccent(scheme))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Theme.accent(scheme), in: Capsule())
                .opacity(isDisabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

struct RailSecondaryButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.bodyEmphasized)
                .foregroundStyle(Theme.textPrimary(scheme))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .glassSurface(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct RailAuxRow: View {
    /// 「少しヒント」を出すか (meta に hint がある場合だけ true)。
    /// 補助操作は 1 つまで (哲学 §1.2 主1+補助1)。hint がある時は hint、
    /// ない時は「コーチに聞く」を出す (コーチは常設 composer からも届く)。
    var showsHint: Bool = true
    let onHint: () -> Void
    let onCoach: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 26) {
            if showsHint {
                auxButton(title: "少しヒント", action: onHint)
            } else {
                auxButton(title: "コーチに聞く", action: onCoach)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    private func auxButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Theme.accent(scheme).opacity(0.6))
                    .frame(width: 4, height: 4)
                Text(title)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 共有 canvas 部品

/// 圧縮カード (serif 見出し + note)。
struct InsightCard: View {
    let serif: String
    let note: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            Text(serif)
                .font(Typography.serifItalic(size: 22))
                .foregroundStyle(Theme.accent(scheme))
                .multilineTextAlignment(.center)
            Text(note)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .glassSurface(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
    }
}

/// 速攻の再予想 (1 タップ即答) の選択肢行。
struct SegChoiceRow: View {
    let choices: [String]
    let pickedIndex: Int?
    let onPick: (Int) -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                Button {
                    onPick(index)
                } label: {
                    Text(choice)
                        .font(Typography.serifItalic(size: 19))
                        .foregroundStyle(pickedIndex == index ? Theme.textOnAccent(scheme) : Theme.textPrimary(scheme))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background {
                            if pickedIndex == index {
                                Capsule().fill(Theme.accent(scheme))
                            }
                        }
                        .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 境界ステージの canvas。「もう少し続ける」/「今日はここまで」の 2 択。
struct BoundaryCanvas: View {
    let serif: String
    /// パッケージ由来のまとめ文。なければ既定の文言。
    var line: String? = nil

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 10) {
            Text("ここまでの区切り")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary(scheme))
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 10) {
                Text(serif)
                    .font(Typography.serifItalic(size: 24))
                    .foregroundStyle(Theme.accent(scheme))
                    .multilineTextAlignment(.center)
                Text(line ?? "予想 → 動かす → 比較 → 圧縮 → 支援なしで転移。\nひとつの循環が閉じました。続けるか終えるかは、あなたが決めます。")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .glassSurface(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
        }
    }
}

/// 「今日はここまで」終了カード。
struct EndedCanvas: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 10) {
            Text("今日はここまで。")
                .font(Typography.serifItalic(size: 24))
                .foregroundStyle(Theme.accent(scheme))
            Text("途中状態は端末に保存されています。")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .glassSurface(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
        .padding(.top, 14)
    }
}

// MARK: - シミュレーションフロー (S1-S5 共通ステージ機械)

struct SimulationFlowView: View {
    let scenario: SimulationScenario
    let onExit: () -> Void

    enum Stage {
        case hook, predict, explore, consequence, insight, transfer, boundary, ended
    }

    @State private var stage: Stage = .hook
    @State private var prediction: Double? = nil
    @State private var param: Double
    /// explore でスライダーに触れたか (触れるまで結果に進めない。哲学 §2 Step4)。
    @State private var exploreMoved = false
    @State private var isHintOpen = false
    @State private var isCoachOpen = false
    @State private var retryPick: Int? = nil
    @State private var retryDone = false
    @State private var transferInput = ""
    /// 置いた答え (置き直し可能。哲学 §3: 誤答で止まらない・再試行1操作以内)。
    @State private var transferSubmitted: String? = nil

    @Environment(\.colorScheme) private var scheme

    init(scenario: SimulationScenario, initialStageName: String? = nil, onExit: @escaping () -> Void) {
        self.scenario = scenario
        self.onExit = onExit
        _param = State(initialValue: scenario.paramInitial)
        // デモ用ディープリンク: 途中のステージから開始する
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
                if stage != .predict {
                    _prediction = State(initialValue: scenario.demoPrediction)
                }
                if stage == .consequence {
                    _param = State(initialValue: scenario.predictAt)
                }
            }
        }
    }

    private var actual: Double { scenario.predictedActual }
    private var gap: Double { actual - (prediction ?? actual) }

    var body: some View {
        ImmersionShell(sourceLabel: scenario.sourceLabel, onClose: onExit) {
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
            hookCanvas
        case .predict:
            predictCanvas
        case .explore:
            exploreCanvas
        case .consequence:
            consequenceCanvas
        case .insight:
            insightCanvas
        case .transfer:
            transferCanvas
        case .boundary:
            BoundaryCanvas(serif: scenario.boundarySerif)
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
                    Text(scenario.hook)
                        .font(Typography.sans(size: 19, weight: .bold))
                        .foregroundStyle(Theme.textPrimary(scheme))
                    Text(scenario.hookSub)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary(scheme))
                    HStack(spacing: 10) {
                        Text(scenario.emoji).font(.system(size: 26))
                        GaugeView(
                            scenario: scenario,
                            value: scenario.value(at: scenario.paramInitial),
                            startMarker: scenario.startMarker
                        )
                    }
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

            Text("話したいことがあれば、そのまま下から書けます。この候補は勝手には始まりません。")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
        }
    }

    private var predictCanvas: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(scenario.hook)
                .font(Typography.title)
            Text("ゲージをタップして、予想の高さを置いて。")
                .font(Typography.bodyCompact)
                .foregroundStyle(Theme.textSecondary(scheme))
            GaugeView(
                scenario: scenario,
                value: scenario.value(at: scenario.paramInitial),
                prediction: prediction,
                startMarker: scenario.startMarker,
                onPlacePrediction: { placed in
                    withAnimation(.easeOut(duration: Theme.Duration.quick)) { prediction = placed }
                }
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
            Text(prediction == nil ? "ゲージの好きな高さをタップ" : "タップし直せば動かせる")
                .font(Typography.micro)
                .foregroundStyle(Theme.textTertiary(scheme))
                .frame(maxWidth: .infinity)
        }
    }

    private var exploreCanvas: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(scenario.paramLabel)を動かして、\(scenario.quantityLabel)の動きを確かめる。")
                .font(Typography.title)
            GaugeView(
                scenario: scenario,
                value: scenario.value(at: param),
                prediction: prediction,
                startMarker: scenario.startMarker
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(scenario.format(param))
                    .font(Typography.serifItalic(size: 22))
                    .foregroundStyle(Theme.accent(scheme))
                Text("\(scenario.paramUnit) → \(scenario.quantityLabel)")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
                Text(scenario.format(scenario.value(at: param)))
                    .font(Typography.serifItalic(size: 22))
                    .foregroundStyle(Theme.accent(scheme))
                Text(scenario.unit)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
            }
            .frame(maxWidth: .infinity)

            Slider(value: $param, in: scenario.paramRange, step: scenario.paramStep)
                .tint(Theme.accent(scheme))
                .onChange(of: param) { _, _ in exploreMoved = true }

            HStack {
                Spacer()
                Button("戻す (\(scenario.format(scenario.paramInitial)) \(scenario.paramUnit))") {
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
                        param = scenario.paramInitial
                    }
                }
                .font(Typography.micro)
                .foregroundStyle(Theme.textTertiary(scheme))
                .underline()
            }
        }
    }

    private var consequenceCanvas: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(scenario.consequenceTitle)
                .font(Typography.title)
            GaugeView(
                scenario: scenario,
                value: actual,
                prediction: prediction,
                startMarker: scenario.startMarker,
                showGap: true
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
            Text("破線: あなたの予想 / ゲージ: 実際 / 緑: その差")
                .font(Typography.micro)
                .foregroundStyle(Theme.textTertiary(scheme))
                .frame(maxWidth: .infinity)

            Text(scenario.diffText(gap: gap))
                .font(Typography.caption)
                .foregroundStyle(Theme.textPrimary(scheme))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))

            if isHintOpen {
                Text("ヒント: \(scenario.hint)")
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
            if isCoachOpen {
                Text("コーチはプロトタイプでは未接続です。")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
        }
    }

    private var insightCanvas: some View {
        VStack(alignment: .leading, spacing: 12) {
            if retryDone {
                InsightCard(
                    serif: scenario.retrySuccessSerif,
                    note: "予想 → 動かす → 比較 → 圧縮。一度掴んだ形は、次から一瞬で読めます。"
                )
                MorphStrip(scenario: scenario)
            } else {
                InsightCard(serif: scenario.insightSerif, note: scenario.insightNote)
                MorphStrip(scenario: scenario)
                Text(scenario.retryQuestion)
                    .font(Typography.title)
                    .padding(.top, 4)
                SegChoiceRow(choices: scenario.retryChoices, pickedIndex: retryPick) { index in
                    retryPick = index
                    if index == scenario.retryCorrectIndex {
                        withAnimation(.easeInOut(duration: Theme.Duration.standard)) { retryDone = true }
                    }
                }
                if retryPick != nil {
                    Text("もう一度。\(scenario.retryNudge)")
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

    private var transferCanvas: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(scenario.transferQuestion)
                .font(Typography.title)
            Text("ここにはゲージもグラフも選択肢もありません。")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent(scheme))
                    .padding(.top, 1)
                Text("紙とペンがあれば、そちらで考えるのがおすすめです。ノートで式を立て、答えだけここに置けます。")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

            // 入力は答えを置いた後もロックしない (置き直し 1 操作、入力消去なし)。
            TextField(scenario.transferPlaceholder, text: $transferInput)
                .font(Typography.sans(size: 16))
                .keyboardType(scenario.transferKind == .numeric ? .numberPad : .default)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Color.white.opacity(scheme == .dark ? 0.06 : 0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.textPrimary(scheme).opacity(0.14), lineWidth: 0.5))

            if let submitted = transferSubmitted {
                transferFeedback(submitted: submitted)
            }
        }
    }

    @ViewBuilder
    private func transferFeedback(submitted: String) -> some View {
        switch scenario.transferKind {
        case .numeric:
            let digits = submitted.filter(\.isNumber)
            if digits == scenario.transferAnswer {
                feedbackCard(serif: scenario.transferCorrectSerif, body: "「はじめの分」と「増える分」に分けて読めました。支援なしでも同じ形が使えています。")
            } else {
                feedbackCard(serif: scenario.transferWrongSerif, body: "止まらずに、置き直せます。")
            }
        case .freeForm:
            feedbackCard(serif: "ノートの一文と見比べてみて。", body: "ひとつの読み方: \(scenario.transferAnswer)")
        }
    }

    private func feedbackCard(serif: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(serif)
                .font(Typography.serifItalic(size: 16))
                .foregroundStyle(Theme.accent(scheme))
            Text(body)
                .font(Typography.caption)
                .foregroundStyle(Theme.textPrimary(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassSurface(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    // MARK: Rail

    @ViewBuilder
    private var railContent: some View {
        switch stage {
        case .hook, .ended:
            if stage == .ended {
                RailPrimaryButton(title: "ここから続けます", action: onExit)
            }
        case .predict:
            RailPrimaryButton(title: "予想を置く", isDisabled: prediction == nil) {
                withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
                    param = scenario.paramInitial
                    exploreMoved = false
                    stage = .explore
                }
            }
        case .explore:
            // 介入 (スライダーを動かす) が完了するまで結果に進ませない。
            RailPrimaryButton(title: scenario.compareLabel, isDisabled: !exploreMoved) {
                withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
                    param = scenario.predictAt
                    stage = .consequence
                }
            }
        case .consequence:
            VStack(spacing: 0) {
                RailPrimaryButton(title: "もう一度予想する") {
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) {
                        isHintOpen = false
                        isCoachOpen = false
                        retryPick = nil
                        retryDone = false
                        stage = .insight
                    }
                }
                RailAuxRow(
                    onHint: { withAnimation(.easeInOut(duration: Theme.Duration.quick)) { isHintOpen.toggle() } },
                    onCoach: { withAnimation(.easeInOut(duration: Theme.Duration.quick)) { isCoachOpen = true } }
                )
            }
        case .insight:
            if retryDone {
                RailPrimaryButton(title: "支援なしで試してみる") {
                    withAnimation(.easeInOut(duration: Theme.Duration.standard)) { stage = .transfer }
                }
            }
        case .transfer:
            // 答えを置いたら区切りへ進めるが、入力を変えれば 1 操作で置き直せる。
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
        }
    }
}

#if DEBUG
#Preview("Immersion Lab — Home") {
    ImmersionLabView()
}
#endif
