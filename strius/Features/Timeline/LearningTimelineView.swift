import SwiftUI

/// 起動したら最初に出る、1問ずつの全画面の「タイムライン」(Issue #46)。ブランド名は出さない。
/// 操作は右下の縦並び(上から 質問・飛ばす・撮る)、下の帯に次の問題の1行目を常に見せ、上に送ると次へ進む。
/// 余白にはいつでも指で書ける(書いている間は、余白で上に送る操作を止め、下の帯を上に送ったときだけ次へ進む)。
struct LearningTimelineView: View {
    let store: TimelineStore
    let onOpenUnits: () -> Void
    @Environment(WorkbookCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasInk = false
    @State private var ink = TimelineInkController()
    @State private var inkGeneration = 0
    @State private var isCameraPresented = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Theme.card, Theme.ground], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                ZStack(alignment: .bottomTrailing) {
                    content
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    actions
                        .padding(.trailing, 20)
                        .padding(.bottom, 16)
                }
                .offset(y: min(0, dragOffset) * 0.35)
                nextStrip
            }
            if store.skipBannerAttemptID != nil { skipBanner.transition(.move(edge: .top).combined(with: .opacity)) }
            if let error = store.actionError {
                Text(error)
                    .font(Typography.sans(size: 14, weight: .medium))
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 60)
                    .onTapGesture { store.dismissError() }
                    .accessibilityIdentifier("timeline-error")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-screen")
        .animation(.easeInOut(duration: Theme.Duration.standard), value: store.phase)
        .animation(.easeInOut(duration: Theme.Duration.standard), value: store.currentID)
        .task { await store.start() }
        .onChange(of: scenePhase) { _, phase in Task { await store.scenePhaseChanged(phase) } }
        .onChange(of: store.currentID) { _, _ in clearInk() }
        .background {
            ChatCameraPresentation(isPresented: $isCameraPresented) { data in
                Task { await store.submit(image: data) }
            }
        }
        .sheet(isPresented: Binding(get: { store.isStopSheetPresented }, set: { store.isStopSheetPresented = $0 })) {
            TimelineStopSheet(store: store)
                .presentationDetents([.medium])
                .presentationBackground(Theme.card)
        }
    }

    // MARK: 上端

    private var topBar: some View {
        HStack {
            Button(action: onOpenUnits) {
                Label("単元", systemImage: TimelineSymbol.units)
                    .font(Typography.sans(size: 16, weight: .bold))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .foregroundStyle(Theme.primaryText)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timeline-units-button")
            Spacer()
            Button { store.isStopSheetPresented = true } label: {
                Text("今日 \(store.answeredToday)問").font(Typography.sans(size: 15, weight: .medium)).foregroundStyle(Theme.secondaryText).monospacedDigit()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timeline-today-count")
        }
        // 下に引いたら、やめようとしたとみなしてシートを出す。
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.height > 80 { store.isStopSheetPresented = true }
        })
    }

    // MARK: 中身

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .guide:
            guide
        case .waiting:
            VStack(alignment: .leading, spacing: 12) {
                ProgressView()
                Text("問題を用意しています").font(Typography.sans(size: 17, weight: .bold)).foregroundStyle(Theme.primaryText)
            }
            .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-waiting")
        case .finished:
            VStack(alignment: .leading, spacing: 16) {
                Text("今日はここまで").font(Typography.sans(size: 26, weight: .bold))
                Text("✓ \(store.answeredToday) 問").font(Typography.sans(size: 17, weight: .medium)).foregroundStyle(Theme.secondaryText)
                Button("続ける") { store.resumeAfterFinish() }.buttonStyle(.bordered).accessibilityIdentifier("timeline-resume")
            }
            .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-finished")
        case .dip(_, let trigger):
            TimelineDipChoiceView(store: store, trigger: trigger)
        case .rapidDone:
            TimelineRapidDoneView(store: store)
        case .toy:
            TimelineToyView(store: store)
        case .howto:
            if let card = store.current { TimelineHowtoView(card: card, store: store) { ask(card) } }
        case .rapid(let index):
            if let card = store.current {
                VStack(alignment: .leading, spacing: 18) {
                    TimelineRapidHeader(store: store, index: index)
                    TimelineMath(latex: card.math.isEmpty ? card.prompt : card.math, size: 30)
                    Text(card.prompt).font(Typography.sans(size: 17, weight: .bold))
                    inkArea
                }
            }
        case .result:
            if let card = store.current, let attempt = store.lastAttempt {
                ScrollView { TimelineResultView(card: card, attempt: attempt, store: store).padding(.trailing, 60).padding(.bottom, 24) }
                    .scrollIndicators(.hidden)
            }
        case .solving, .grading:
            if let card = store.current {
                VStack(alignment: .leading, spacing: 14) {
                    header(card)
                    if TimelineCards.Kind(rawValue: card.kind)?.needsReading ?? true {
                        if card.kind != "solve" { TimelineWritingPrompt(card: card) }
                        inkArea
                        footnote(card)
                    } else {
                        TimelineInteractiveCard(card: card, store: store).padding(.trailing, 64)
                        Spacer(minLength: 0)
                    }
                }
                .overlay {
                    if case .grading = store.phase {
                        Color.clear.contentShape(Rectangle())
                    }
                }
            }
        }
    }

    /// 問題の上の部分は、上に送ると次へ(書いている間は止める)。
    private func header(_ card: TimelineCardRecord) -> some View {
        TimelineProblemView(card: card, store: store)
            .padding(.trailing, card.kind == "solve" ? 0 : 0)
            .contentShape(Rectangle())
            .gesture(hasInk ? nil : swipeUp)
    }

    private func footnote(_ card: TimelineCardRecord) -> some View {
        HStack(spacing: 8) {
            switch store.badge {
            case .resume?: Label("昨日", systemImage: TimelineSymbol.past)
            case .history(let days)?: Label(days <= 1 ? "昨日" : "\(days)日前", systemImage: TimelineSymbol.past); TimelineMark(correct: true, size: 11)
            default: EmptyView()
            }
            Spacer()
        }
        .font(Typography.sans(size: 14, weight: .medium))
        .foregroundStyle(Theme.secondaryText)
        .padding(.trailing, 90)
    }

    /// 余白(枠は置かない)。鉛筆のアイコンの横に「1つ戻す」「全部消す」。
    private var inkArea: some View {
        ZStack(alignment: .topLeading) {
            TimelineInkCanvas(hasInk: $hasInk, controller: ink)
                .id(inkGeneration)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, 84)
            if hasInk {
                HStack(spacing: 14) {
                    Image(systemName: TimelineSymbol.pencil).foregroundStyle(Theme.tertiaryText)
                    Button("1つ戻す") { ink.undo() }.accessibilityIdentifier("timeline-ink-undo")
                    Button("全部消す") { ink.clear() }.accessibilityIdentifier("timeline-ink-clear")
                }
                .font(Typography.sans(size: 13, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(minHeight: 160)
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 16) {
            TimelineChip(text: "はじめに", symbol: TimelineSymbol.new, tinted: true)
            Text("まず、勉強する単元を作りましょう").font(Typography.sans(size: 24, weight: .bold)).foregroundStyle(Theme.primaryText)
            Text("教科書のページや、いま習っている所を教えてください。そこから1問ずつ、タイムラインに出していきます。")
                .font(Typography.sans(size: 15, weight: .medium)).foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button { coordinator.createUnit() } label: {
                Label("単元を作る", systemImage: "plus")
                    .font(Typography.sans(size: 16, weight: .bold))
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .foregroundStyle(Theme.onAccent)
                    .background(Theme.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timeline-guide-create-unit")
        }
        .padding(.trailing, 40)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-guide")
    }

    // MARK: 右下の縦並び

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 18) {
            switch store.phase {
            case .solving:
                if let card = store.current {
                    TimelineActionButton(symbol: TimelineSymbol.ask, label: "質問", identifier: "timeline-ask") { ask(card) }
                    if TimelineCards.Kind(rawValue: card.kind)?.needsReading ?? true {
                        if hasInk {
                            TimelineActionButton(symbol: TimelineSymbol.camera, label: "撮る", identifier: "timeline-capture") { isCameraPresented = true }
                            TimelineActionButton(symbol: TimelineSymbol.send, label: "送る", prominent: true, identifier: "timeline-send") { sendInk() }
                        } else {
                            TimelineActionButton(symbol: TimelineSymbol.skip, label: "飛ばす", identifier: "timeline-skip") { Task { await store.skip() } }
                            TimelineActionButton(symbol: TimelineSymbol.camera, label: "撮る", prominent: true, identifier: "timeline-capture") { isCameraPresented = true }
                        }
                    } else {
                        TimelineActionButton(symbol: TimelineSymbol.skip, label: "飛ばす", identifier: "timeline-skip") { Task { await store.skip() } }
                    }
                }
            case .rapid:
                TimelineActionButton(symbol: TimelineSymbol.send, label: "送る", prominent: true, identifier: "timeline-send") { sendRapid() }
            case .grading:
                VStack(spacing: 6) {
                    ProgressView().controlSize(.large).frame(width: 72, height: 72)
                    Text("採点中").font(Typography.sans(size: 12, weight: .bold)).foregroundStyle(Theme.secondaryText)
                }
                .accessibilityIdentifier("timeline-grading")
            case .result:
                if let card = store.current {
                    TimelineActionButton(symbol: TimelineSymbol.ask, label: "質問", identifier: "timeline-ask") { ask(card) }
                    if TimelineCards.Kind(rawValue: card.kind)?.needsReading ?? false {
                        TimelineActionButton(symbol: TimelineSymbol.explain, label: "解説", identifier: "timeline-explain") { explain(card) }
                    }
                    TimelineActionButton(symbol: TimelineSymbol.next, label: "次へ", prominent: true, identifier: "timeline-next") { Task { await store.goNext() } }
                }
            case .rapidDone:
                TimelineActionButton(symbol: TimelineSymbol.next, label: "次へ", prominent: true, identifier: "timeline-next") { store.finishRapid() }
            default:
                EmptyView()
            }
        }
    }

    // MARK: 下の帯

    private var nextStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if hasInk, store.phase == .solving || isRapid {
                    Label("ここを上へ", systemImage: "arrow.up").font(Typography.sans(size: 13, weight: .bold))
                } else if let next = store.upcoming {
                    Label(stripLabel(next), systemImage: stripSymbol(next)).font(Typography.sans(size: 13, weight: .bold))
                }
                Spacer()
                Text("Next").font(Typography.ordinal).foregroundStyle(Theme.tertiaryText)
            }
            .foregroundStyle(Theme.secondaryText)
            Text(stripLine)
                .font(Typography.sans(size: 16, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26))
        .background(alignment: .bottom) { Theme.card.frame(height: 40).offset(y: 40).ignoresSafeArea(edges: .bottom) }
        .shadow(color: .black.opacity(0.06), radius: 8, y: -2)
        .contentShape(Rectangle())
        .gesture(swipeUp)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("timeline-next-strip")
        .accessibilityAction(named: "次へ") { Task { await advance() } }
    }

    private var isRapid: Bool { if case .rapid = store.phase { true } else { false } }

    private var stripLine: String {
        guard let next = store.upcoming else { return store.phase == .waiting ? "用意しています" : "" }
        let line = [TimelineMath.plain(next.math), next.question].filter { !$0.isEmpty }.joined(separator: "  ")
        return next.kind == "solve" ? (line.isEmpty ? next.prompt : line) : next.prompt
    }

    private func stripLabel(_ next: TimelineCardRecord) -> String {
        if next.origin == "easier" { return "一段戻す" }
        if let current = store.current, let chain = TimelineRules.chainID(next), chain == TimelineRules.chainID(current) { return "続き" }
        if next.origin == "rapid" || next.level <= 1 { return "\(next.estimatedSeconds)秒" }
        if let kind = TimelineCards.Kind(rawValue: next.kind), kind != .solve { return kind.title }
        return TimelineRules.chainPosition(next) != nil ? "続き" : "次"
    }

    private func stripSymbol(_ next: TimelineCardRecord) -> String {
        if next.origin == "easier" { return TimelineSymbol.past }
        if next.origin == "rapid" || next.level <= 1 { return TimelineSymbol.clock }
        return TimelineSymbol.chain
    }

    private var swipeUp: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in dragOffset = value.translation.height }
            .onEnded { value in
                defer { withAnimation(.spring) { dragOffset = 0 } }
                guard value.translation.height < -70 else { return }
                Task { await advance() }
            }
    }

    // MARK: 動作

    private func advance() async {
        switch store.phase {
        case .solving:
            // 書いている間は、下の帯を上に送ったら書いたものを送る(紙に切り替えた人は飛ばす)。
            if hasInk { sendInk() } else { await store.skip() }
        case .result:
            await store.goNext()
        case .rapid:
            if hasInk { sendRapid() }
        case .rapidDone:
            store.finishRapid()
        default:
            break
        }
    }

    private func sendInk() {
        guard let data = ink.image() else { return }
        Task { await store.submit(image: data) }
    }

    private func sendRapid() {
        guard let data = ink.image() else { return }
        clearInk()
        Task { await store.submitRapid(image: data) }
    }

    private func clearInk() {
        ink.clear()
        hasInk = false
        inkGeneration += 1
    }

    private func problemText(_ card: TimelineCardRecord) -> String {
        [card.payload["problem"]?.stringValue ?? card.prompt, card.math, card.question].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func ask(_ card: TimelineCardRecord) {
        coordinator.ask(WorkbookQuestionContext(subunitId: card.subunitId, setId: nil, title: "タイムライン", stageLabel: nil,
                                                initialDraft: "この問題について質問です。\n" + problemText(card)))
    }

    private func explain(_ card: TimelineCardRecord) {
        coordinator.ask(WorkbookQuestionContext(subunitId: card.subunitId, setId: nil, title: "タイムライン", stageLabel: nil,
                                                initialDraft: "この問題の解き方を説明してください。\n" + problemText(card) + "\n答え: " + card.answerKey))
    }

    private var skipBanner: some View {
        VStack(spacing: 10) {
            Text("飛ばしました").font(Typography.sans(size: 15, weight: .bold))
            HStack(spacing: 10) {
                Button("難しそう") { Task { await store.setSkipReason("too_hard") } }
                    .accessibilityIdentifier("timeline-skip-too-hard")
                Button("簡単すぎる") { Task { await store.setSkipReason("too_easy") } }
                    .accessibilityIdentifier("timeline-skip-too-easy")
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-skip-banner")
    }
}

/// やめようとしたとき(画面 7)。「あと 1 つ」と「今日はここまで」を同じ大きさで並べる。
struct TimelineStopSheet: View {
    let store: TimelineStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let summary = store.stopSummary
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                Label("\(summary.count) 問", systemImage: "checkmark").accessibilityIdentifier("timeline-stop-count")
                Label("\(summary.minutes)分", systemImage: TimelineSymbol.clock)
            }
            .font(Typography.sans(size: 20, weight: .bold))
            if let next = summary.next {
                VStack(alignment: .leading, spacing: 8) {
                    Label(TimelineRules.chainPosition(next) != nil ? "続き" : "次の1問", systemImage: TimelineSymbol.chain).font(Typography.sans(size: 13, weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                    Text([TimelineMath.plain(next.math), next.question].filter { !$0.isEmpty }.joined(separator: "  ").isEmpty ? next.prompt : [TimelineMath.plain(next.math), next.question].filter { !$0.isEmpty }.joined(separator: "  "))
                        .font(Typography.sans(size: 16, weight: .medium)).lineLimit(2)
                    if summary.total > 0 {
                        HStack(spacing: 8) {
                            TimelineMark(correct: true, size: 11)
                            Text("\(summary.done) / \(summary.total)").font(Typography.sans(size: 14, weight: .bold)).monospacedDigit()
                            ProgressView(value: Double(summary.done), total: Double(summary.total)).tint(Theme.accentColor)
                        }
                    }
                }
                .padding(14)
                .background(Theme.ground, in: RoundedRectangle(cornerRadius: 16))
            }
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Text("あと 1 つ").frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("timeline-one-more")
                Button { store.stopForToday() } label: {
                    Text("今日はここまで").frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("timeline-stop-today")
            }
            .font(Typography.sans(size: 16, weight: .bold))
        }
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-stop-sheet")
    }
}
