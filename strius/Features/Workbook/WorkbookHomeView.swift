import SwiftUI

enum WorkbookDestination: Hashable {
    case unit(String)
    case subunit(String)
    case set(String)
    case capture(String)
    case problem(String)
    case triage(String)
}

/// 質問画面に乗せる文脈。IDだけ送り、本文はサーバーが組む。
struct WorkbookQuestionContext: Identifiable, Hashable {
    enum Purpose: String, Hashable {
        /// 質問(範囲は縛らない)。
        case question
        /// 単元づくり: 学習者が打つ前にモデルが問いを出し、全体像の提案まで導く(§13.12)。
        case createUnit
    }

    let subunitId: String?
    let setId: String?
    let title: String?
    let stageLabel: String?
    let initialDraft: String?
    /// リザルト画面の「質問する」: この答案と判定を文脈にする。
    var captureId: String? = nil
    var purpose: Purpose = .question

    var id: String { "\(purpose.rawValue)/\(subunitId ?? "-")/\(setId ?? "-")/\(captureId ?? "-")" }
    var viewRef: WorkbookViewRef? {
        guard subunitId != nil || setId != nil || captureId != nil else { return nil }
        return WorkbookViewRef(subunitId: subunitId, setId: setId, captureId: captureId)
    }

    static let free = WorkbookQuestionContext(subunitId: nil, setId: nil, title: nil, stageLabel: nil, initialDraft: nil)
    static let createUnit = WorkbookQuestionContext(subunitId: nil, setId: nil, title: nil, stageLabel: nil, initialDraft: nil, purpose: .createUnit)
}

/// ホーム「単元」以下の画面遷移と、全画面共通の撮影・質問の呼び出し口。
@Observable
@MainActor
final class WorkbookCoordinator {
    var path: [WorkbookDestination] = []
    var question: WorkbookQuestionContext?
    /// カメラ(別ウィンドウ)の表示。撮った紙の束は `pendingPages` に入り、確認画面へ。
    /// 確認画面から撮り足す時は、同じ束にカメラで撮った分を足す。
    var isCameraPresented = false
    var captureContext: WorkbookViewRef?
    var pendingPages: WorkbookPendingPages?
    /// 単元づくりの起動に添える教材(オンボーディングで選んだもの)。
    var unitCreationAttachments: [ComposerAttachment] = []

    func open(_ destination: WorkbookDestination) {
        path.append(destination)
    }

    func capture(context: WorkbookViewRef?) {
        captureContext = context
        isCameraPresented = true
    }

    func ask(_ context: WorkbookQuestionContext = .free) {
        question = context
    }

    /// 単元づくり(オンボーディングの「最初の単元を作る」とホームの「単元を作る」は同じ入口)。
    func createUnit(attachments: [ComposerAttachment] = []) {
        unitCreationAttachments = attachments
        question = .createUnit
    }
}

/// ホーム「単元」。いま / 最近 / すべて の三段。説明文は置かない。
struct WorkbookHomeView: View {
    @Environment(WorkbookStore.self) private var store
    @Environment(WorkbookCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    let onOpenSettings: () -> Void
    /// タイムラインの上に重ねている時、左上の「タイムライン」で閉じて戻る(Issue #46)。中身は変えない。
    var onCloseTimeline: (() -> Void)? = nil
    @State private var deletionTarget: WorkbookUnitDTO?

    private func remove(_ id: String) {
        Task {
            guard let fact = await store.deleteUnit(id: id) else { return }
            let removed = fact.scope.all
            let pathContainsDeleted = coordinator.path.contains { destination in
                switch destination {
                case .unit(let id), .subunit(let id), .set(let id), .capture(let id), .problem(let id), .triage(let id): removed.contains(id)
                }
            }
            if pathContainsDeleted { coordinator.path = [] }
            if let question = coordinator.question, [question.subunitId, question.setId, question.captureId].compactMap({ $0 }).contains(where: removed.contains) { coordinator.question = nil }
            if let context = coordinator.captureContext, [context.subunitId, context.setId, context.captureId].compactMap({ $0 }).contains(where: removed.contains) {
                coordinator.isCameraPresented = false
                coordinator.captureContext = nil
                coordinator.pendingPages = nil
            }
        }
    }

    var body: some View {
        @Bindable var coordinator = coordinator
        NavigationStack(path: $coordinator.path) {
            content
                .background(Theme.ground.ignoresSafeArea())
                .navigationTitle("単元")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    if let onCloseTimeline {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: onCloseTimeline) {
                                Label("タイムライン", systemImage: "chevron.down")
                                    .labelStyle(.titleAndIcon)
                                    .font(Typography.bodyEmphasized)
                                    .fixedSize()
                            }
                            .accessibilityIdentifier("workbook-close-timeline")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                onOpenSettings()
                            } label: {
                                Label("設定", systemImage: "gearshape")
                            }
                            .accessibilityIdentifier("workbook-open-settings")
                        }
                    } else {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                onOpenSettings()
                            } label: {
                                Label("設定", systemImage: "gearshape")
                            }
                            .accessibilityIdentifier("workbook-open-settings")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        WorkbookQuestionPill { coordinator.ask() }
                    }
                }
                .workbookCaptureInset(context: nil) { coordinator.capture(context: $0) }
                .navigationDestination(for: WorkbookDestination.self) { destination in
                    destinationView(destination)
                }
        }
        .alert("単元を削除しますか？", isPresented: Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } })) {
            Button("キャンセル", role: .cancel) { deletionTarget = nil }
                .keyboardShortcut(.cancelAction)
            Button("削除", role: .destructive) {
                if let target = deletionTarget { remove(target.id) }
                deletionTarget = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("「\(deletionTarget?.title ?? "")」の学習記録を削除します。この操作は取り消せません。")
        }
        .overlay(alignment: .bottom) {
            if let error = store.deletionError {
                VStack(spacing: 8) {
                    Text(error).font(.callout)
                    if let pending = store.pendingDeletion { Button("削除を再開") { remove(pending.unitID) } }
                    else if let id = store.failedDeletionUnitID {
                        Button("もう一度削除") { remove(id) }
                        Button("閉じる") { store.dismissDeletionError() }
                    }
                }
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
            }
        }
        .task { await store.loadHomeIfNeeded() }
        .background {
            ChatCameraPresentation(isPresented: $coordinator.isCameraPresented, batch: ChatCameraBatch(
                existingCount: coordinator.pendingPages?.pages.count ?? 0, limit: WorkbookPendingPages.limit
            ) { photos in
                let pages = photos.map { WorkbookPendingPages.Page(data: $0) }
                if coordinator.pendingPages != nil {
                    coordinator.pendingPages?.pages += pages
                } else {
                    coordinator.pendingPages = WorkbookPendingPages(pages: pages, context: coordinator.captureContext)
                }
            })
        }
        .sheet(item: $coordinator.question) { context in
            WorkbookQuestionScreen(context: context)
        }
        .fullScreenCover(item: $coordinator.pendingPages) { _ in
            WorkbookCaptureFlow {
                coordinator.pendingPages = nil
            }
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: WorkbookDestination) -> some View {
        switch destination {
        case .unit(let id): WorkbookUnitView(unitID: id)
        case .subunit(let id): WorkbookSubunitView(subunitID: id)
        case .set(let id): WorkbookSetView(setID: id)
        case .capture(let id): WorkbookVerdictView(captureID: id)
        case .problem(let id): WorkbookProblemView(problemID: id)
        case .triage(let id): WorkbookTriageView(captureID: id)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.loadState {
        case .idle, .loading:
            VStack {
                Spacer()
                ProgressView().progressViewStyle(StruisProgressViewStyle()).controlSize(.large)
                Spacer()
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Spacer()
                if let pending = store.pendingDeletion {
                    Text(pending.title)
                        .font(Typography.heading2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .struisSurface(radius: Theme.Radius.card)
                        .padding(.horizontal, 20)
                }
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary(scheme))
                Button("もう一度") { Task { await store.loadHome() } }
                    .buttonStyle(.bordered)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .loaded:
            loadedContent
        }
    }

    private var loadedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let error = store.actionError {
                    Text(error)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.regress(scheme))
                        .padding(.horizontal, 20)
                        .onTapGesture { store.actionError = nil }
                }
                if !store.hasAnyUnit, store.recentCaptures.isEmpty, store.uploadingCaptures.isEmpty {
                    createUnitHero
                } else if TimelineLayout.isPad(sizeClass) {
                    // iPad(横幅が広い時): 左の列に いま・最近、右の列に すべて(中身は変えない)。
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 28) {
                            nowSection
                            recentSection
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        unitsSection
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    nowSection
                    recentSection
                    unitsSection
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 96)
        }
        .struisRefreshable { await store.refreshHome() }
        .accessibilityIdentifier("workbook-home")
    }

    // MARK: いま

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("いま")
            let now = store.activeSubunits
            if now.isEmpty {
                emptyLine("まだありません")
            } else {
                ForEach(now) { subunit in
                    Button {
                        coordinator.open(.subunit(subunit.id))
                    } label: {
                        WorkbookSubunitRow(subunit: subunit, showsUnitTitle: true)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    // MARK: 最近

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("最近")
                Spacer()
                if store.home?.triageCount ?? 0 > 0 {
                    Text("整理中 \(store.home?.triageCount ?? 0)")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.trailing, 20)
                }
            }
            let recent = store.recentCaptures
            if recent.isEmpty, store.uploadingCaptures.isEmpty {
                emptyLine("まだありません")
            } else {
                VStack(spacing: 0) {
                    ForEach(store.uploadingCaptures) { _ in
                        WorkbookRecentRow.uploading
                        rowRule
                    }
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, capture in
                        if index > 0 { rowRule }
                        Button {
                            coordinator.open(capture.status == .triage ? .triage(capture.id) : .capture(capture.id))
                        } label: {
                            WorkbookRecentRow(capture: capture)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .struisSurface(radius: Theme.Radius.card)
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: すべて

    /// 単元が 1 つも無い時の中心。単元づくりの会話を開く。
    private var createUnitHero: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 80)
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Theme.accentColor)
            Button {
                coordinator.createUnit()
            } label: {
                Label("単元を作る", systemImage: "plus")
                    .font(Typography.bodyEmphasized)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("workbook-create-unit")
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private var unitsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("すべて")
                Spacer()
                Button {
                    coordinator.createUnit()
                } label: {
                    Label("単元を作る", systemImage: "plus")
                        .font(Typography.caption)
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 20)
                .accessibilityIdentifier("workbook-create-unit")
            }
            let units = store.home?.units ?? []
            if units.isEmpty {
                emptyLine("まだありません")
            } else {
                ForEach(units) { unit in
                    Button {
                        coordinator.open(.unit(unit.id))
                    } label: {
                        WorkbookUnitCard(unit: unit)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.deletingUnitID == unit.id)
                    .contextMenu {
                        Button("削除", role: .destructive) { deletionTarget = unit }
                    }
                    .accessibilityAction(named: "削除") { deletionTarget = unit }
                    .overlay(alignment: .bottomTrailing) {
                        if store.deletingUnitID == unit.id {
                            HStack { ProgressView(); Text("削除中…") }
                                .font(.callout).padding(12).background(.regularMaterial, in: Capsule()).padding(8)
                        }
                    }
                    .accessibilityIdentifier("workbook-unit-card-\(unit.id)")
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private var rowRule: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Typography.eyebrow)
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 20)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(Typography.body)
            .foregroundStyle(Theme.tertiaryText)
            .padding(.horizontal, 20)
    }
}

/// 単元カード。小単元の行は名前と、進みを「正解数 / n」と短い横棒で出す(マスはカードに出さない)。
/// まだ演習の答えが 1 つも無い小単元には何も出さない。
struct WorkbookUnitCard: View {
    let unit: WorkbookUnitDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(unit.title)
                    .font(Typography.title)
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                if unit.status == .passed {
                    Text("合格")
                        .font(Typography.micro.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(WorkbookPalette.passed, in: Capsule())
                        .foregroundStyle(Theme.ground)
                } else {
                    Text("\(unit.passedCount) / \(unit.subunitCount)")
                        .font(Typography.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            ForEach(unit.subunits) { subunit in
                HStack(spacing: 8) {
                    Circle()
                        .fill(subunit.status == .passed ? WorkbookPalette.passed : subunit.status == .active ? Theme.Palette.accentLight : Color.secondary.opacity(0.25))
                        .frame(width: 7, height: 7)
                    Text(subunit.title)
                        .font(Typography.bodyCompact)
                        .foregroundStyle(subunit.status == .pending ? Theme.secondaryText : Theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let progress = WorkbookSubunitProgress(subunit) {
                        WorkbookSubunitProgressBar(progress: progress)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .struisSurface(radius: Theme.Radius.card)
    }
}

/// 単元カードの 1 行に出す小単元の進み。合格の窓(直近 n 問の演習の答え)の ○ の数と n。
struct WorkbookSubunitProgress: Equatable {
    let correct: Int
    let n: Int
    let passed: Bool

    /// まだ演習の答えが 1 つも無い(手をつけていない)小単元は nil。
    init?(_ subunit: WorkbookSubunitDTO) {
        let n = max(1, subunit.n)
        let answered = (subunit.windowTiles ?? []).suffix(n)
        guard !answered.isEmpty else { return nil }
        self.correct = answered.filter { $0.state == .correct }.count
        self.n = n
        self.passed = subunit.status == .passed
    }

    var fraction: Double { min(1, Double(correct) / Double(n)) }
    var label: String { "\(correct) / \(n)" }
}

/// 「正解数 / n」と短い横棒。合格した小単元は合格の色。
struct WorkbookSubunitProgressBar: View {
    let progress: WorkbookSubunitProgress
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 44, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(progress.passed ? WorkbookPalette.passed : Theme.accent(scheme))
                        .frame(width: 44 * progress.fraction, height: 4)
                }
            Text(progress.label)
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(Theme.primaryText)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.label)
    }
}

/// 小単元の一行。名前・マス・段階または合格。
struct WorkbookSubunitRow: View {
    let subunit: WorkbookSubunitDTO
    var showsUnitTitle = false

    var body: some View {
        let passed = subunit.status == .passed
        let pending = subunit.status == .pending
        VStack(alignment: .leading, spacing: 12) {
            // 一覧では段階を輪ひとつで示す。4 語の内訳は小単元の画面で見せる。
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    if showsUnitTitle {
                        Text(subunit.unitTitle)
                            .font(Typography.micro)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Text(subunit.title)
                        .font(Typography.title)
                        .foregroundStyle(pending ? Theme.secondaryText : Theme.primaryText)
                    if !pending {
                        HStack(spacing: 6) {
                            Text(passed ? "合格" : subunit.stageLabel)
                                .font(Typography.caption.weight(.bold))
                                .foregroundStyle(passed ? WorkbookPalette.passed : Theme.accentColor)
                            if !passed {
                                Text("\(subunit.stage) / 4")
                                    .font(Typography.caption.monospacedDigit())
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                WorkbookStageRing(stage: pending ? 0 : subunit.stage, passed: passed, size: 44)
            }
            HStack(alignment: .center) {
                WorkbookTileRow(tiles: subunit.windowTiles ?? [], n: subunit.n, size: 14)
                Spacer(minLength: 12)
                if subunit.stageValue == .practice || subunit.status == .passed {
                    WorkbookPassLine(window: subunit.window)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .struisSurface(radius: Theme.Radius.card)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workbook-subunit-\(subunit.id)")
    }
}

/// 最近の一行。左に小単元名と時刻、右に一枚ぶんの結果(問題順の升目)と点数。
struct WorkbookRecentRow: View {
    let capture: WorkbookCaptureDTO?

    static var uploading: WorkbookRecentRow { WorkbookRecentRow(capture: nil) }

    var body: some View {
        // 題名は 1 行目に全部見せる。マスと点数は 2 行目に置き、題名を削らない。
        VStack(alignment: .leading, spacing: 6) {
            Text(capture?.subunitTitle ?? statusText)
                .font(Typography.bodyCompact)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .center, spacing: 8) {
                Group {
                    if let capture {
                        WorkbookRelativeTime(iso: capture.createdAt)
                    } else {
                        Text("たった今")
                    }
                }
                .foregroundStyle(Theme.tertiaryText)
                .font(Typography.micro)
                if capture?.result?.subunitPassed == true {
                    Text("合格").font(Typography.micro).fontWeight(.bold).foregroundStyle(WorkbookPalette.passed)
                }
                Spacer(minLength: 8)
                // 単元カードと同じマス。問題の順に並び、何問目を落としたかが点数の手前で読める。
                if let verdicts = capture?.verdicts, !verdicts.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(Array(verdicts.prefix(20).enumerated()), id: \.offset) { _, item in
                            WorkbookTile(state: item.verdict, size: 8)
                        }
                    }
                    .layoutPriority(-1)
                    .accessibilityHidden(true)
                }
                score
                    .lineLimit(1)
                    .fixedSize()
            }
            if let capture, capture.status == .identifying {
                // 判定の段の言葉(A9): リザルト画面を開かなくても、判定のターンで実際に起きたことが分かる。
                TurnLiveLine(keys: [TurnActivityKey.target(capture.id)], font: Typography.micro)
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(capture.map { "workbook-recent-\($0.id)" } ?? "workbook-recent-uploading")
    }

    private var statusText: String {
        guard let capture else { return "送信中" }
        switch capture.status {
        case .identifying: return "判定中"
        case .graded: return "判定済み"
        case .triage: return "整理中"
        case .failed: return "判定できず"
        }
    }

    /// 右端は点数だけ。分子を主、分母を従にして、数字そのものを結果の表示にする。
    @ViewBuilder
    private var score: some View {
        if let summary = capture?.summary, capture?.status == .graded {
            (Text("\(summary.correct)").foregroundStyle(Theme.primaryText)
                + Text(" / \(summary.total)").foregroundStyle(Theme.tertiaryText))
                .font(Typography.bodyEmphasized.monospacedDigit())
        } else {
            Text(capture == nil ? "送信中" : statusText)
                .font(Typography.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }
}
