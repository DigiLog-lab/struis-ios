import SwiftUI
import UIKit

/// リザルト。撮った一枚ごとの判定の後に出す。上から、正解数と状態の 1 語、演習なら直近 n 問のマス
/// (今回の一枚で埋まったマスを示す)、答案の写真と各問の ○× と一言、次の行動のボタン。
/// 間違えても罰は無い。次の行動(やり直す / 例題に戻る / 質問する)は学習者が選ぶ。判定中はここで待てる。
struct WorkbookVerdictView: View {
    @Environment(WorkbookStore.self) private var store
    @Environment(WorkbookCoordinator.self) private var coordinator
    @Environment(LearnerData.self) private var learnerData
    @Environment(\.colorScheme) private var scheme
    let captureID: String
    /// 答案の写真(何枚かの答案は全ページを縦に並べた 1 枚)。
    @State private var paper: WorkbookCapturePaper?
    private var image: UIImage? { paper?.image }
    /// 写真の高さの上限はページ数に比例させる(並べたページが細くならないように)。
    private var pageCount: CGFloat { CGFloat(max(1, paper?.pageCount ?? 1)) }
    @State private var busyAction: WorkbookResultDTO.Action?
    /// 判定を待つ間の演出(§5)。この画面で判定中を見た時だけ作り、丸をつけ終えるまで結果を出さない。
    @State private var stage: WorkbookGradingStageModel?
    @State private var stageFinished = false
    /// 判定の後に開いた時の、写真の上の丸(領域の検出は覚えた値を使う)。
    @State private var staticRegions: [WorkbookAnswerRegion]?

    private var capture: WorkbookCaptureDTO? { store.captures[captureID] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let capture {
                    headline(capture)
                    if isStaging(capture) {
                        gradingStage(capture)
                    } else {
                    switch capture.status {
                    case .identifying:
                        // 写真を読み込むまでの一瞬。
                        stageStatusRow(capture, text: WorkbookGradingStageModel.readingText)
                    case .failed:
                        Text(capture.error.map(WorkbookFormatting.learnerFacingError) ?? "判定できませんでした")
                            .font(Typography.body)
                            .foregroundStyle(Theme.regress(scheme))
                        Button {
                            Task {
                                _ = await learnerData.turns.retryGrading(captureID: capture.id)
                                await store.loadCapture(id: capture.id)
                            }
                        } label: {
                            Label("判定し直す", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("workbook-result-regrade")
                        thumbnail
                    case .triage:
                        Button {
                            coordinator.open(.triage(capture.id))
                        } label: {
                            Label("整理する", systemImage: "tray")
                        }
                        .buttonStyle(.bordered)
                        thumbnail
                    case .graded:
                        if capture.isPartial, let progress = capture.setProgress {
                            // 一枚の全問に判定がそろう前の答案(分割採点 R2)。
                            WorkbookSetProgressSection(progress: progress, partial: true)
                        } else {
                            if let result = capture.result, let window = result.window {
                                windowSection(result, window: window)
                            }
                            if let progress = capture.setProgress {
                                WorkbookSetProgressSection(progress: progress, partial: false)
                            }
                        }
                        markedThumbnail(capture)
                        verdictList(capture)
                    }
                    }
                    if let error = store.actionError {
                        Text(error)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.regress(scheme))
                            .onTapGesture { store.actionError = nil }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let capture, capture.status == .graded, !isStaging(capture) {
                actions(capture)
            }
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle("結果")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: captureID) {
            await store.loadCapture(id: captureID)
            if store.captures[captureID]?.status == .identifying, stage == nil { stage = WorkbookGradingStageModel() }
            // 次の行動が今の小単元の段に合うかを確かめるため、小単元も読み直す。
            if let subunitID = store.captures[captureID]?.subunitId { await store.loadSubunit(id: subunitID) }
            paper = await store.capturePaper(id: captureID)
            await loadStaticRegionsIfGraded()
        }
        .onChange(of: capture?.status) { _, status in
            switch status {
            case .identifying:
                // 「判定し直す」: 新しい演出で待つ。
                if stage == nil || stageFinished {
                    stage = WorkbookGradingStageModel()
                    stageFinished = false
                }
            case .graded:
                if let capture { stage?.deliver(capture.verdicts) }
                Task { await loadStaticRegionsIfGraded() }
            case .failed, .triage:
                // 演出の途中で失敗・中断・整理中になったら、演出を止めてその表示に切り替える(W8)。
                stage?.stop()
                stage = nil
            case nil:
                break
            }
        }
        .struisRefreshable { await store.loadCapture(id: captureID) }
        // `.contain` で子のボタンの識別子を残す(親の識別子で上書きされない)。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workbook-verdict")
    }

    // MARK: 見出し

    private func headline(_ capture: WorkbookCaptureDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let subunitTitle = capture.subunitTitle {
                Text(subunitTitle)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            if let summary = capture.summary, capture.status == .graded, !capture.isPartial, !isStaging(capture) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(summary.correct) / \(summary.total)")
                        .font(Typography.counter.monospacedDigit())
                        .accessibilityIdentifier("workbook-verdict-score")
                    if let status = statusWord(capture) {
                        Text(status.text)
                            .font(Typography.heading2)
                            .foregroundStyle(status.good ? WorkbookPalette.passed : Theme.primaryText)
                            .accessibilityIdentifier("workbook-result-status")
                    }
                }
            }
            WorkbookRelativeTime(iso: capture.createdAt)
                .font(Typography.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    /// 合格まで、あと何問続けて正解すればよいか。窓が埋まっていなければ空いたマスの分も要り、
    /// 埋まっていれば新しい答えが古いマスを押し出す(押し出されるのが正解なら、その分も要る)。
    /// `tiles` は窓のマスの古い順。
    static func remainingToPass(window: WorkbookWindowDTO, tiles: [WorkbookProblemTileDTO.State]) -> Int {
        var slots = tiles.suffix(window.n).map { $0 == .correct }
        for added in 1...(window.n + window.requiredCorrect + 1) {
            slots.append(true)
            if slots.count > window.n { slots.removeFirst(slots.count - window.n) }
            if slots.count >= window.n, slots.filter({ $0 }).count >= window.requiredCorrect { return added }
        }
        return max(1, window.n)
    }

    /// 状態の 1 語。類題: クリア / もう一度。演習: 小単元 合格 / あと ○ 問。
    private func statusWord(_ capture: WorkbookCaptureDTO) -> (text: String, good: Bool)? {
        guard let result = capture.result else { return nil }
        if result.subunitPassed { return (result.unitPassed ? "単元 合格" : "小単元 合格", true) }
        if let window = result.window {
            // 窓は合格ラインに届いているが小単元の合格にはしなかった結果(段が先へ進んだ後に判定し直した古い答案)は、
            // 「あと ○ 問」を出さない。
            guard !window.passed else { return nil }
            let missing = Self.remainingToPass(window: window, tiles: result.windowTiles.map(\.state))
            return ("あと \(missing) 問", false)
        }
        if result.actions.contains(.practice) { return ("クリア", true) }
        if result.actions.contains(.retry) { return ("もう一度", false) }
        return nil
    }

    // MARK: 直近 n 問のマス

    private func windowSection(_ result: WorkbookResultDTO, window: WorkbookWindowDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("直近\(window.n)問で\(window.requiredCorrect)問")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text("\(window.correct) / \(window.count)")
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(window.passed ? WorkbookPalette.passed : Theme.primaryText)
            }
            WorkbookWindowGrid(
                states: result.windowTiles.map(\.state), current: result.windowTiles.map(\.isCurrent),
                n: window.n, size: 26
            )
        }
        .padding(16)
        .struisSurface(radius: Theme.Radius.card)
        .accessibilityIdentifier("workbook-result-window")
    }

    // MARK: 判定を待つ間(§5)

    /// 判定を待つ間の演出を出しているか。丸をつけ終えるまでは、判定が届いていても結果を出さない。
    private func isStaging(_ capture: WorkbookCaptureDTO) -> Bool {
        guard stage != nil, !stageFinished else { return false }
        return capture.status == .identifying || capture.status == .graded
    }

    private func stageStatusRow(_ capture: WorkbookCaptureDTO, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            stageStatusHeader(capture, text: text)
            if capture.status == .identifying {
                // 判定のターンで実際に起きた出来事(読んだ・届いた問題の数。信頼性計画 P2)。「止める」は上の行にある。
                TurnLiveLine(keys: [TurnActivityKey.target(capture.id)])
                    .accessibilityIdentifier("workbook-grading-live")
            }
        }
    }

    private func stageStatusHeader(_ capture: WorkbookCaptureDTO, text: String) -> some View {
        HStack(spacing: 10) {
            // 識別子は文言にだけ付ける(行に付けると「止める」の識別子を上書きする)。
            StruisWaitingStatus(text: text, font: Typography.body)
                .accessibilityIdentifier("workbook-grading-status")
            Spacer()
            if capture.status == .identifying {
                Button("止める") {
                    Task { await learnerData.turns.interrupt(targetID: capture.id) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("workbook-result-stop")
            }
        }
    }

    @ViewBuilder
    private func gradingStage(_ capture: WorkbookCaptureDTO) -> some View {
        if let stage {
            stageStatusRow(capture, text: stage.status)
            if let paper {
                WorkbookGradingStage(captureID: capture.id, paper: paper, model: stage) {
                    withAnimation(.easeInOut(duration: 0.35)) { stageFinished = true }
                }
                .onAppear {
                    // 開いた時にもう判定が届いていた(読み込みの間に終わった)。
                    if capture.status == .graded { stage.deliver(capture.verdicts) }
                }
            }
        }
    }

    private func loadStaticRegionsIfGraded() async {
        guard staticRegions == nil, let paper, store.captures[captureID]?.status == .graded else { return }
        staticRegions = await WorkbookAnswerRegions.detect(captureID: captureID, paper: paper)
    }

    /// 判定の後の写真。領域に結べた判定には、丸・△・× を描いたまま残す。
    @ViewBuilder
    private func markedThumbnail(_ capture: WorkbookCaptureDTO) -> some View {
        if let image {
            let regions = staticRegions ?? []
            let assignment = WorkbookAnswerRegions.assign(verdictLabels: capture.verdicts.map(\.label), regions: regions)
            let marks = assignment.sorted { $0.key < $1.key }.map { (region: regions[$0.value], verdict: capture.verdicts[$0.key].verdict) }
            WorkbookMarkedPhoto(image: image, model: nil, staticMarks: marks, maxHeight: 320 * pageCount)
                .accessibilityValue(pageCount > 1 ? "\(Int(pageCount)) 枚" : "")
                .accessibilityIdentifier("workbook-result-photo")
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220 * pageCount)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .accessibilityLabel("答案")
        }
    }

    private func verdictList(_ capture: WorkbookCaptureDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(capture.verdicts.enumerated()), id: \.offset) { _, verdict in
                Button {
                    if let problemID = verdict.problemId { coordinator.open(.problem(problemID)) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        WorkbookVerdictMark(verdict: verdict.verdict)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verdict.label.isEmpty ? "問" : verdict.label)
                                .font(Typography.bodyEmphasized)
                            if !verdict.promptText.isEmpty {
                                WorkbookPromptText(text: verdict.promptText, lineLimit: 2)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            if !verdict.errorTag.isEmpty {
                                Text(verdict.errorTag)
                                    .font(Typography.caption)
                                    .foregroundStyle(WorkbookPalette.wrong)
                            }
                            if !verdict.note.isEmpty {
                                Text(verdict.note)
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .struisSurface(radius: Theme.Radius.stat)
                }
                .buttonStyle(.plain)
                .disabled(verdict.problemId == nil)
            }
        }
    }

    // MARK: 次の行動

    /// 段を動かす行動(演習へ・やり直す・例題に戻る)は、小単元がまだ判定の後の段にいる時だけ出す。
    /// ほかの答案で段が進んだ・合格した後に古い結果を開いた時は、行き先の案内と「質問する」だけにする。
    static func currentActions(_ actions: [WorkbookResultDTO.Action], stageAfter: Int?, subunit: WorkbookSubunitDTO?) -> [WorkbookResultDTO.Action] {
        guard let subunit, let stageAfter else { return actions }
        guard subunit.status != .active || subunit.stage != stageAfter else { return actions }
        let kept = actions.filter { $0 == .nextSubunit || $0 == .finishUnit || $0 == .ask }
        return kept.isEmpty ? [.ask] : kept
    }

    private func actions(_ capture: WorkbookCaptureDTO) -> some View {
        let actions = Self.currentActions(
            capture.result?.actions ?? [.ask], stageAfter: capture.result?.stageAfter,
            subunit: capture.subunitId.flatMap { store.subunits[$0] }
        )
        let primary = actions.first { $0 != .ask && $0 != .returnToExample && $0 != .closeSet }
        return VStack(spacing: 10) {
            if let primary {
                actionButton(primary, capture: capture, prominent: true)
            }
            if actions.contains(.closeSet) {
                actionButton(.closeSet, capture: capture, prominent: false)
                Text("結果を出した後でも、残りの問題は一枚に残り、あとで撮れます")
                    .font(Typography.micro)
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 10) {
                if actions.contains(.returnToExample) {
                    actionButton(.returnToExample, capture: capture, prominent: false)
                }
                actionButton(.ask, capture: capture, prominent: false)
            }
            if primary == nil {
                Button {
                    coordinator.path = []
                } label: {
                    Text("閉じる").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("workbook-verdict-close")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.ground)
    }

    private func title(_ action: WorkbookResultDTO.Action, capture: WorkbookCaptureDTO) -> String {
        switch action {
        case .practice: "演習へ"
        case .retry: "やり直す"
        case .returnToExample: "例題に戻る"
        case .nextSubunit: "次の小単元へ"
        case .finishUnit: "単元を終える"
        case .ask: "質問する"
        case .captureMore: "撮り足す"
        case .closeSet: "見つかった \(capture.setProgress?.judgedCount ?? capture.verdicts.count) 問で結果を出す"
        }
    }

    private func identifier(_ action: WorkbookResultDTO.Action) -> String {
        switch action {
        case .practice: "workbook-result-practice"
        case .retry: "workbook-result-retry"
        case .returnToExample: "workbook-result-return"
        case .nextSubunit: "workbook-verdict-next"
        case .finishUnit: "workbook-result-finish"
        case .ask: "workbook-result-ask"
        case .captureMore: "workbook-result-capture-more"
        case .closeSet: "workbook-result-close-set"
        }
    }

    @ViewBuilder
    private func actionButton(_ action: WorkbookResultDTO.Action, capture: WorkbookCaptureDTO, prominent: Bool) -> some View {
        let button = Button {
            perform(action, capture: capture)
        } label: {
            HStack(spacing: 8) {
                if busyAction == action { ProgressView().controlSize(.small) }
                Text(title(action, capture: capture))
            }
            .font(prominent ? Typography.bodyEmphasized : Typography.body)
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(busyAction != nil)
        .accessibilityIdentifier(identifier(action))
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func perform(_ action: WorkbookResultDTO.Action, capture: WorkbookCaptureDTO) {
        guard busyAction == nil else { return }
        switch action {
        case .ask:
            coordinator.ask(WorkbookQuestionContext(
                subunitId: capture.subunitId, setId: capture.setId, title: capture.subunitTitle,
                stageLabel: "結果", initialDraft: nil, captureId: capture.id
            ))
        case .finishUnit:
            coordinator.path = []
        case .captureMore:
            // 同じ一枚を文脈にして撮る。判定は撮った写真に写っている問題だけ(分割採点 R1)。
            coordinator.capture(context: WorkbookViewRef(subunitId: capture.subunitId, setId: capture.setId))
        case .closeSet:
            busyAction = action
            Task {
                await store.closeSet(captureID: capture.id)
                busyAction = nil
            }
        case .nextSubunit:
            guard let next = capture.result?.nextSubunitId else {
                coordinator.path = capture.unitId.map { [.unit($0)] } ?? []
                return
            }
            coordinator.path = [.subunit(next)]
        case .practice, .retry:
            guard let subunitID = capture.subunitId else { return }
            busyAction = action
            Task {
                // 待っている間に学習者がリザルトから離れたら、画面を移さない(一枚は作られて小単元に残る)。
                // 「やり直す」はこのリザルトの答案の誤りを元にする(「演習へ」は元にする答案が無い)。
                let source = action == .retry ? capture.id : nil
                if let set = await store.retry(subunitID: subunitID, captureID: source), coordinator.path.last == .capture(capture.id) {
                    coordinator.path = [.subunit(subunitID), .set(set.id)]
                }
                busyAction = nil
            }
        case .returnToExample:
            guard let subunitID = capture.subunitId else { return }
            busyAction = action
            Task {
                if await store.returnToExample(subunitID: subunitID), coordinator.path.last == .capture(capture.id) {
                    coordinator.path = [.subunit(subunitID)]
                }
                busyAction = nil
            }
        }
    }
}

/// 一枚の n 問のマス(番号入り)と、足りない問題(分割採点 R2・R3)。
/// 途中の答案では見出し「14・15 が見つかりませんでした」と問いかけ、締めた答案では未提出の番号だけを添える。
struct WorkbookSetProgressSection: View {
    let progress: WorkbookSetProgressDTO
    let partial: Bool

    private static let columns = 5
    private static let size: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if partial {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(WorkbookSetProgressDTO.positionsText(progress.missingPositions)) が見つかりませんでした")
                        .font(Typography.heading2)
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityIdentifier("workbook-set-progress-title")
                    Text(progress.isOpen ? "見つかった問題は採点できています。足りない分をどうしますか" : "この一枚はもう結果を出しています")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Text("一枚の \(progress.states.count) 問")
                .font(Typography.caption)
                .foregroundStyle(Theme.secondaryText)
            grid
            if !partial, !progress.missingPositions.isEmpty {
                Text("\(WorkbookSetProgressDTO.positionsText(progress.missingPositions)) は未提出")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("workbook-set-progress-missing")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .struisSurface(radius: Theme.Radius.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workbook-set-progress")
    }

    private var grid: some View {
        let count = progress.states.count
        let rows = (count + Self.columns - 1) / Self.columns
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(0..<rows, id: \.self) { row in
                GridRow {
                    ForEach(0..<Self.columns, id: \.self) { column in
                        let index = row * Self.columns + column
                        if index < count {
                            cell(index)
                        } else {
                            Color.clear.frame(width: Self.size, height: Self.size)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("一枚 \(count) 問中 判定 \(progress.judgedCount) 問 正解 \(progress.states.filter { $0 == .correct }.count) 問")
    }

    private func cell(_ index: Int) -> some View {
        let state = progress.states[index]
        return WorkbookTile(state: state, size: Self.size)
            .overlay {
                Text("\(index + 1)")
                    .font(Typography.micro.monospacedDigit())
                    .foregroundStyle(state == .correct ? Theme.onAccent : Theme.secondaryText)
            }
            .overlay(alignment: .bottom) {
                // この写真で判定した問題。
                if index < progress.capturedHere.count, progress.capturedHere[index] {
                    Capsule().fill(Theme.primaryText.opacity(0.55)).frame(width: Self.size * 0.5, height: 2).offset(y: 6)
                }
            }
    }
}
