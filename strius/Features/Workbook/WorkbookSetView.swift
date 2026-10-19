import SwiftUI

/// 一枚。自力例題は 1 問、練習は n 問の紙カード。右上に「問題数 n」。ここで撮る。
struct WorkbookSetView: View {
    @Environment(WorkbookStore.self) private var store
    @Environment(WorkbookCoordinator.self) private var coordinator
    @Environment(LearnerData.self) private var learnerData
    @Environment(\.colorScheme) private var scheme
    let setID: String
    @State private var isCountSheetPresented = false

    private var currentSet: WorkbookSetDTO? { store.sets[setID] }
    private var subunit: WorkbookSubunitDTO? { currentSet.flatMap { store.subunits[$0.subunitId] } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let set = currentSet {
                    headline(set)
                    if let error = set.error ?? store.actionError {
                        Text(error)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.regress(scheme))
                            .onTapGesture { store.actionError = nil }
                    }
                    switch set.status {
                    case .generating:
                        // 組んでいる様子は問題の上に出す(問題が増えても画面の外へ押し出されないように)。
                        HStack(spacing: 10) {
                            StruisLoadingIndicator()
                                .controlSize(.small)
                            Text(generatingText(set))
                                .font(Typography.body)
                                .foregroundStyle(Theme.secondaryText)
                                .accessibilityIdentifier("workbook-set-generating")
                            Spacer()
                            Button("止める") {
                                Task { await learnerData.turns.interrupt(targetID: set.id) }
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("workbook-set-stop")
                        }
                        .padding(.top, set.problems.isEmpty ? 24 : 8)
                        // 組んでいるターンで実際に起きた出来事と、書き終わった問題の数(A5・信頼性計画 P2)。
                        TurnLiveLine(keys: [TurnActivityKey.target(set.id)], partialText: { done in
                            let total = set.count ?? set.problems.count
                            let made = min(total, set.problems.count + done)
                            return total > 1 ? "\(total) 問中 \(made) 問できました" : "問題ができました。仕上げています"
                        })
                        .padding(.bottom, set.problems.isEmpty ? 24 : 8)
                        .accessibilityIdentifier("workbook-set-live")
                        // §3.2: できた問題から出す(1 問目から解き始められる)。残りは解いている間に届く。
                        ForEach(Array(set.problems.enumerated()), id: \.element.id) { index, tile in
                            problemCard(index: index, tile: tile, set: set)
                                .transition(.opacity)
                        }
                        // A5: 組んでいるターンが書き終えた問題を、届いた順に出す(台帳に書く前でも解き始められる)。
                        ForEach(Array(arrivedPrompts(set).enumerated()), id: \.offset) { offset, prompt in
                            arrivedCard(number: set.problems.count + offset + 1, prompt: prompt)
                                .transition(.opacity)
                        }
                    case .failed:
                        Button("作り直す") {
                            Task {
                                if let subunit, let created = await store.requestSet(subunitID: subunit.id) {
                                    // 待っている間に学習者が戻っていたら、道のりを勝手に書き換えない。
                                    guard coordinator.path.last == .set(setID) else { return }
                                    coordinator.path.removeLast()
                                    coordinator.open(.set(created.id))
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    case .open, .graded, .superseded:
                        ForEach(Array(set.problems.enumerated()), id: \.element.id) { index, tile in
                            problemCard(index: index, tile: tile, set: set)
                        }
                        if set.status == .graded, let result = set.result {
                            resultCard(result, set: set)
                        }
                    }
                    capturesForSet(set)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 96)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle(currentSet?.kind.label ?? "一枚")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let subunit, currentSet?.kind == .practice {
                    Button {
                        isCountSheetPresented = true
                    } label: {
                        Text("問題数 \(subunit.n)")
                            .font(Typography.caption)
                    }
                    .accessibilityIdentifier("workbook-count")
                }
                WorkbookQuestionPill {
                    coordinator.ask(WorkbookQuestionContext(
                        subunitId: currentSet?.subunitId, setId: setID, title: subunit?.title,
                        stageLabel: currentSet?.kind.label, initialDraft: nil
                    ))
                }
            }
        }
        .workbookCaptureInset(context: WorkbookViewRef(subunitId: currentSet?.subunitId, setId: setID)) {
            coordinator.capture(context: $0)
        }
        .sheet(isPresented: $isCountSheetPresented) {
            if let subunit {
                WorkbookCountSheet(subunit: subunit)
                    .presentationDetents([.medium])
            }
        }
        .task(id: setID) {
            // 先回りで組んでいる一枚を開いた: 学習者が待っている処理として通す(§3.1)。
            await learnerData.turns.promote(targetID: setID)
            if let set = await store.loadSet(id: setID) {
                await store.loadSubunit(id: set.subunitId)
            }
        }
        .struisRefreshable { _ = await store.loadSet(id: setID) }
    }

    /// 組んでいる間の一言。1 問目ができていれば、残りの数。
    private func generatingText(_ set: WorkbookSetDTO) -> String {
        let total = set.count ?? set.problems.count
        // 届いて出している問題(台帳に入る前)も数える。
        let shown = set.problems.count + arrivedPrompts(set).count
        guard shown > 0 else { return "組んでいます" }
        guard total > shown else { return "全部の問題が届きました。一枚に綴じています" }
        return "残り \(total - shown) 問を組んでいます"
    }

    private func headline(_ set: WorkbookSetDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(subunit?.unitTitle ?? "")
                .font(Typography.micro)
                .foregroundStyle(Theme.secondaryText)
            Text(subunit?.title ?? "")
                .font(Typography.title)
            HStack(spacing: 8) {
                Text("\(set.count ?? set.problems.count)問")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
                if let subunit, set.kind == .practice {
                    WorkbookPassLine(window: subunit.window)
                }
            }
        }
    }

    /// 組んでいるターンが書き終えた問題文のうち、まだ台帳の一枚に入っていないもの(届いた順)。
    /// 問題文はモデルが実際に書いた値で、答え・採点の観点は出さない。台帳に入ったら、ふつうの問題カードに替わる。
    private func arrivedPrompts(_ set: WorkbookSetDTO) -> [String] {
        guard let activity = TurnActivityBoard.shared.activity(TurnActivityKey.target(set.id)), !activity.finished else { return [] }
        let saved = Set(set.problems.map(\.prompt))
        return activity.partialItems.filter { !saved.contains($0) }
    }

    private func arrivedCard(number: Int, prompt: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(Typography.counter)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                WorkbookPromptText(text: prompt, lineLimit: nil)
                    .foregroundStyle(Theme.primaryText)
                // 一枚に入る前の問題(組み直しで入らないこともある)。撮って採点できるのは一枚に入ってから。
                Text("準備中・一枚に入ったら撮れます")
                    .font(Typography.micro)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .struisSurface(radius: Theme.Radius.card)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workbook-set-arrived-\(number)")
    }

    private func problemCard(index: Int, tile: WorkbookProblemTileDTO, set: WorkbookSetDTO) -> some View {
        Button {
            coordinator.open(.problem(tile.id))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text("\(index + 1)")
                    .font(Typography.counter)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 34, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    WorkbookPromptText(text: tile.prompt, lineLimit: nil)
                        .foregroundStyle(Theme.primaryText)
                    if tile.state != .notStarted {
                        HStack(spacing: 6) {
                            WorkbookVerdictMark(verdict: tile.state)
                            if !tile.errorTag.isEmpty {
                                Text(tile.errorTag)
                                    .font(Typography.caption)
                                    .foregroundStyle(WorkbookPalette.wrong)
                            }
                            if tile.assisted {
                                Text("ヒントあり")
                                    .font(Typography.micro)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .struisSurface(radius: Theme.Radius.card)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workbook-set-problem-\(index + 1)")
    }

    private func resultCard(_ result: WorkbookSetResultDTO, set: WorkbookSetDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(result.correct) / \(result.total)")
                    .font(Typography.heading2.monospacedDigit())
                if result.passed {
                    Text("合格")
                        .font(Typography.micro.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(WorkbookPalette.passed, in: Capsule())
                        .foregroundStyle(Theme.ground)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .struisSurface(radius: Theme.Radius.card)
    }

    private func capturesForSet(_ set: WorkbookSetDTO) -> some View {
        let captures = store.recentCaptures.filter { $0.setId == set.id }
        return Group {
            if !captures.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("答案")
                        .font(Typography.eyebrow)
                        .foregroundStyle(Theme.secondaryText)
                    ForEach(captures) { capture in
                        Button {
                            coordinator.open(capture.status == .triage ? .triage(capture.id) : .capture(capture.id))
                        } label: {
                            WorkbookCaptureRow(capture: capture)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// 問題数シート。「−」無効、「＋」のみ。合格ラインの再計算を同時に表示。
struct WorkbookCountSheet: View {
    @Environment(WorkbookStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let subunit: WorkbookSubunitDTO
    @State private var value: Int
    @State private var isSaving = false

    init(subunit: WorkbookSubunitDTO) {
        self.subunit = subunit
        _value = State(initialValue: subunit.n)
    }

    private var requiredCorrect: Int { Int((Double(value) * subunit.threshold - 1e-9).rounded(.up)) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                HStack(spacing: 28) {
                    Button {
                        value = max(subunit.n, value - 1)
                    } label: {
                        Image(systemName: "minus")
                            .font(.title2.weight(.semibold))
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.bordered)
                    .disabled(value <= subunit.n)
                    .accessibilityLabel("減らす")
                    Text("\(value)")
                        .font(Typography.counter.monospacedDigit())
                        .frame(minWidth: 64)
                        .accessibilityIdentifier("workbook-count-value")
                    Button {
                        value = min(100, value + 1)
                    } label: {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.bordered)
                    .disabled(value >= 100)
                    .accessibilityLabel("増やす")
                }
                Text("直近\(value)問で\(requiredCorrect)問")
                    .font(Typography.body)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("問題数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("決定") {
                        guard !isSaving else { return }
                        isSaving = true
                        Task {
                            if await store.setCount(subunitID: subunit.id, n: value) {
                                dismiss()
                            }
                            isSaving = false
                        }
                    }
                    .disabled(value == subunit.n || isSaving)
                    .accessibilityIdentifier("workbook-count-save")
                }
            }
        }
    }
}
