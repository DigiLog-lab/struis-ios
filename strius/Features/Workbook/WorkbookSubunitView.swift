import SwiftUI

/// 小単元。段階 1・2 は小単元ごとの会話が主画面。上に進捗バー(`WorkbookSubunitHeader`)、段階 2 は
/// その下に例題バー(`WorkbookExampleCard`)、いちばん下に入力欄。「先に進む」は会話の右下に浮かせる
/// (入力中は隠す)。開けばモデルが話し始める(§13.13)。
/// 段階 3・4 は一枚(類題 1 問 / 演習 n 問)へ。
struct WorkbookSubunitView: View {
    @Environment(WorkbookStore.self) private var store
    @Environment(WorkbookCoordinator.self) private var coordinator
    @Environment(LearnerData.self) private var learnerData
    @Environment(\.colorScheme) private var scheme
    let subunitID: String
    @State private var isAdvancing = false
    @State private var isRequestingSet = false
    @State private var isReturning = false
    /// この小単元の会話だけを持つ ChatStore(質問シートの会話と混ぜない)。
    @State private var subunitChat: ChatStore?
    /// 例題バーの開閉(入った直後は全文。学習者が手で開閉した後は、その回はその状態のまま)。
    @State private var exampleBar = WorkbookExampleBarState()
    /// 例題が出るまでの待ち(§6)。
    @State private var exampleWait = WorkbookExampleWaitModel()
    @Environment(\.struisAnimatesWaiting) private var animatesWaiting

    /// 例題バーへ運ぶチップの位置を測る座標空間。
    static let coordinateSpace = "workbook-subunit"

    private var subunit: WorkbookSubunitDTO? { store.subunits[subunitID] }

    var body: some View {
        Group {
            if let subunit {
                if subunit.stageValue.isModelWork, subunit.status == .active {
                    modelStageScreen(subunit)
                } else {
                    learnerStageScreen(subunit)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle(subunit?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: subunitID) { await store.loadSubunit(id: subunitID) }
        // 新しい回の例題(「先に進む」で例題へ、段階 3・4 から「例題に戻る」)は全文から。段階 3・4 の画面を出している間の
        // 変化も見るため、段で切り替わる画面の外で見る。
        .onChange(of: subunit?.kickoffKey) { _, _ in
            exampleBar.enteredNewRound()
            exampleWait.reset()
        }
        .onChange(of: subunit?.exampleProblem != nil) { _, hasExample in
            if hasExample { Task { await exampleWait.deliver() } }
        }
        .onAppear { exampleWait.animates = animatesWaiting }
        .onChange(of: animatesWaiting) { _, value in exampleWait.animates = value }
    }

    // MARK: 段階 1・2

    private func modelStageScreen(_ subunit: WorkbookSubunitDTO) -> some View {
        VStack(spacing: 0) {
            // 段(と例題の回)が変わったら作り直し、新しい段の初期状態(例題の段は畳んだ 1 行)から始める。
            WorkbookSubunitHeader(subunit: subunit)
                .id(WorkbookSubunitHeader.identity(subunit))
            if subunit.stageValue == .jointExample {
                WorkbookExampleCard(
                    prompt: subunit.exampleProblem,
                    isFailed: subunitChat.map { kickoffState(subunit, chat: $0) == .failed } ?? false,
                    isCollapsed: exampleBar.isCollapsed,
                    onToggle: { withAnimation(Self.barAnimation) { exampleBar.toggled() } },
                    wait: exampleWait,
                    liveKeys: exampleLiveKeys(subunit),
                    waitStatusText: Self.isReturnRound(subunit) ? WorkbookExampleWaitModel.returnStatusText : WorkbookExampleWaitModel.statusText,
                    onStop: subunitChat.map { chat in { Task { await chat.interrupt() } } }
                )
            }
            if let chat = subunitChat {
                let hiddenReply = hiddenExampleReply(subunit, chat: chat)
                let intro = introReply(chat)
                ChatView(
                    workbookContext: WorkbookQuestionContext(
                        subunitId: subunit.id, setId: nil, title: subunit.title,
                        stageLabel: subunit.stageLabel, initialDraft: nil
                    ),
                    embedded: true,
                    threadBootstrap: { chat in
                        let (threadID, result) = await store.kickoff(subunitID: subunitID)
                        if case .failed = result {
                            // 会話はできても起動が失敗した: 空の会話で待たせず、「再試行」を出す(再試行でもう一度起こす)。
                            chat.failBootstrap(SubunitThreadUnavailable())
                        } else if let id = threadID.flatMap(UUID.init(uuidString:)) {
                            await chat.adoptThread(id: id)
                        } else {
                            // 会話を用意できなかった: 読み込み中のまま止めず、「再試行」を出す。
                            chat.failBootstrap(SubunitThreadUnavailable())
                        }
                    },
                    sendsWhileGenerating: true,
                    floatingAccessory: AnyView(advanceControls(subunit, chat: chat)),
                    // 解説を出すまでは送らない(出した時に、その返事まで送る)。
                    followToken: hiddenReply == nil ? Self.kickoffReplyID(messages: chat.allMessages, kickoffMessageID: subunit.kickoffMessageId)?.uuidString : nil,
                    onLearnerActivity: { activity in
                        guard subunit.stageValue == .jointExample else { return }
                        var next = exampleBar
                        guard next.learnerActed(activity, hasPrompt: subunit.exampleProblem != nil) else { return }
                        withAnimation(Self.barAnimation) { exampleBar = next }
                    },
                    hiddenMessageIDs: hiddenReply.map { [$0] } ?? [],
                    highlight: intro.flatMap { id in exampleWait.highlightCount > 0 ? (messageID: id, count: exampleWait.highlightCount) : nil },
                    onHighlightFrame: { exampleWait.sourceFrame = $0 }
                )
                .environment(chat)
                .onAppear { startExampleWaitIfNeeded(subunit, chat: chat) }
                .onChange(of: isWaitingForExample(subunit, chat: chat)) { _, _ in startExampleWaitIfNeeded(subunit, chat: chat) }
                .onChange(of: kickoffState(subunit, chat: chat) == .failed) { _, failed in
                    if failed { exampleWait.fail() } else if exampleWait.phase == .failed { exampleWait.reset(); startExampleWaitIfNeeded(subunit, chat: chat) }
                }
                // 段が変わった(1→2、例題に戻る)・返事が終わった時に、その段のターンがまだなら起こす。
                .task(id: "\(subunit.kickoffKey ?? "-")|\(subunit.kickoffMessageId ?? "-")|\(chat.isSending)") {
                    guard subunit.kickoffKey != nil, subunit.kickoffMessageId == nil, !chat.isSending, chat.threadID != nil else { return }
                    // 前の段の返事の後片付け(ターンの終わりの記録)がまだの間は busy が返る。終わるまで少し待って起こし直す
                    // (「先に進む」をすぐ押した時に、次の段の返事が始まらないままにならないように)。
                    while !Task.isCancelled {
                        let (_, result) = await store.kickoff(subunitID: subunitID)
                        guard result == .busy else { break }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                    await chat.refreshCurrentThread()
                }
            } else {
                Spacer()
            }
        }
        .coordinateSpace(.named(Self.coordinateSpace))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { exampleWait.containerSize = $0 }
        .overlay(alignment: .topLeading) {
            // 要点から例題バーへ運ばれているチップ(1 つずつ)。
            if let flying = exampleWait.flying, exampleWait.chips.indices.contains(flying.index) {
                WorkbookExampleChip(span: exampleWait.chips[flying.index])
                    .position(flying.position)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            if subunitChat == nil { subunitChat = ChatStore(ledger: learnerData.ledger, turns: learnerData.turns) }
        }
    }

    // MARK: 例題の待ち(§6)

    /// 例題の段で、例題がまだ届いていない(起こせなかった時を除く)。
    private func isWaitingForExample(_ subunit: WorkbookSubunitDTO, chat: ChatStore) -> Bool {
        subunit.stageValue == .jointExample && subunit.exampleProblem == nil && kickoffState(subunit, chat: chat) != .failed
    }

    private func startExampleWaitIfNeeded(_ subunit: WorkbookSubunitDTO, chat: ChatStore) {
        guard exampleWait.phase == .idle, isWaitingForExample(subunit, chat: chat) else { return }
        exampleWait.animates = animatesWaiting
        let source = introReply(chat).flatMap { id in chat.allMessages.first { $0.id == id }?.plainText }
            .map { ChatTextReadability.formatAssistantText($0) }
        Task { await exampleWait.begin(source: source) }
    }

    /// 直前の要点の返事: この小単元の会話で最初の起動メッセージ(段階 1)への返事。
    private func introReply(_ chat: ChatStore) -> UUID? {
        let visible = Set(chat.messages.map(\.id))
        guard let first = chat.allMessages.firstIndex(where: { $0.role == .user && !visible.contains($0.id) }) else { return nil }
        return chat.allMessages[(first + 1)...].first { $0.role == .assistant && $0.status == .completed }?.id
    }

    /// 例題を作っているターン: 起動の返事(あれば)と、先回りの例題。
    private func exampleLiveKeys(_ subunit: WorkbookSubunitDTO) -> [String] {
        var keys = [TurnActivityKey.examplePrefetch(subunitID: subunit.id)]
        if let chat = subunitChat, let reply = Self.kickoffReplyID(messages: chat.allMessages, kickoffMessageID: subunit.kickoffMessageId) {
            keys.append(TurnActivityKey.reply(reply))
        }
        return keys
    }

    /// 「例題に戻る」で来た回(例題の回が 1 以上)。
    static func isReturnRound(_ subunit: WorkbookSubunitDTO) -> Bool {
        guard let key = subunit.kickoffKey, key.hasPrefix("2:"), let round = Int(key.dropFirst(2)) else { return false }
        return round > 0
    }

    /// まだ見せない例題の段の返事(例題がバーに入るまで。空の吹き出しも出さない)。
    /// 返事の本文が書かれ始めたら、書かれるそばから見せる(信頼性計画 P2 の 2)。
    private func hiddenExampleReply(_ subunit: WorkbookSubunitDTO, chat: ChatStore) -> UUID? {
        guard subunit.stageValue == .jointExample,
              let reply = Self.kickoffReplyID(messages: chat.allMessages, kickoffMessageID: subunit.kickoffMessageId)
        else { return nil }
        if let streaming = TurnActivityBoard.shared.activity(TurnActivityKey.reply(reply)), !streaming.visibleReply.isEmpty { return nil }
        if exampleWait.isActive, !exampleWait.revealsReply { return reply }
        if exampleWait.phase == .idle, isWaitingForExample(subunit, chat: chat) { return reply }
        return nil
    }

    /// 進捗バーと例題バーの開閉(高さのアニメーション)。
    static let barAnimation: Animation = .snappy(duration: 0.3)

    enum KickoffState: Equatable { case waiting, done, failed }

    /// その段のモデルの返事(起動メッセージの次の返事)の id。まだ無ければ nil。
    static func kickoffReplyID(messages: [ChatMessage], kickoffMessageID: String?) -> UUID? {
        guard let id = kickoffMessageID.flatMap(UUID.init(uuidString:)), let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        return messages[(index + 1)...].first { $0.role == .assistant }?.id
    }

    /// その段のモデルのターン(起動メッセージへの返事)の状態。「先に進む」は done の時だけ。
    /// 説明の途中で学習者が送ると最初の返事は止まる(§13.13 の 3)。その後の返事が出来上がっていれば済んだとみなす。
    private func kickoffState(_ subunit: WorkbookSubunitDTO, chat: ChatStore) -> KickoffState {
        guard let id = subunit.kickoffMessageId.flatMap(UUID.init(uuidString:)),
              let index = chat.allMessages.firstIndex(where: { $0.id == id })
        else { return .waiting }
        let replies = chat.allMessages[(index + 1)...].filter { $0.role == .assistant }
        return Self.kickoffState(
            // 返事が記録だけを書いている間は、説明は出終わっている(「先に進む」を押せる。記録は裏で続く)。
            replies: replies.map(\.status), isSending: chat.isReplyBusy,
            missingExample: subunit.stageValue == .jointExample && subunit.exampleProblem == nil
        )
    }

    /// `missingExample`: 例題の段で、まだ例題が保存されていない。返事が出来上がっても例題が無ければ
    /// (最初の返事を止めて質問した場合など)済んだとはみなさず、「例題をもう一度始める」を出す。
    static func kickoffState(replies: [MessageStatus], isSending: Bool, missingExample: Bool = false) -> KickoffState {
        guard !isSending else { return .waiting }
        if replies.contains(.completed) { return missingExample ? .failed : .done }
        if replies.last == .failed { return .failed }
        return .waiting
    }

    /// 会話の右下に浮かせる「先に進む」と、起こせなかった時の「もう一度始める」(その左隣)。
    /// 自作の装飾は付けず、システムのガラスのボタンにする。
    private func advanceControls(_ subunit: WorkbookSubunitDTO, chat: ChatStore) -> some View {
        let state = kickoffState(subunit, chat: chat)
        return HStack(spacing: 8) {
            if state == .failed {
                Button {
                    Task { await store.restartKickoff(subunitID: subunit.id); await chat.refreshCurrentThread() }
                } label: {
                    Label(subunit.stageValue == .jointExample ? "例題をもう一度始める" : "説明をもう一度始める", systemImage: "arrow.clockwise")
                        .font(Typography.caption)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityIdentifier("workbook-kickoff-restart")
            }
            // 段階 2 は、モデルがこの回の例題に準備OKを出すまでボタン自体を出さない(§13.13 の 5)。
            if Self.showsAdvance(stage: subunit.stageValue, exampleReady: subunit.exampleReady == true) {
                Button {
                    guard !isAdvancing else { return }
                    isAdvancing = true
                    Task {
                        await store.advance(subunitID: subunit.id)
                        isAdvancing = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("先に進む")
                        Image(systemName: "chevron.right")
                    }
                    .font(Typography.bodyEmphasized)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(isAdvancing || state != .done)
                .accessibilityIdentifier("workbook-advance")
            }
        }
    }

    /// 「先に進む」を出すか。段階 1 は常に(押せるのは説明が出終わってから)。段階 2 はモデルの準備OKの後だけ。
    static func showsAdvance(stage: WorkbookStage, exampleReady: Bool) -> Bool {
        stage != .jointExample || exampleReady
    }

    // MARK: 段階 3・4 / 合格

    private func learnerStageScreen(_ subunit: WorkbookSubunitDTO) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(subunit)
                    .padding(.horizontal, 20)
                if let error = store.actionError {
                    Text(error)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.regress(scheme))
                        .padding(.horizontal, 20)
                        .onTapGesture { store.actionError = nil }
                }
                tilesSection(subunit)
                if subunit.status == .active {
                    setSection(subunit)
                    returnToExampleButton(subunit)
                }
                capturesSection(subunit)
            }
            .padding(.top, 8)
            .padding(.bottom, 96)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                WorkbookQuestionPill {
                    coordinator.ask(WorkbookQuestionContext(
                        subunitId: subunit.id, setId: subunit.openSetId, title: subunit.title,
                        stageLabel: subunit.stageLabel, initialDraft: nil
                    ))
                }
            }
        }
        .workbookCaptureInset(context: WorkbookViewRef(subunitId: subunit.id, setId: subunit.openSetId)) {
            coordinator.capture(context: $0)
        }
        .struisRefreshable { await store.loadSubunit(id: subunit.id) }
    }

    private func header(_ subunit: WorkbookSubunitDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subunit.unitTitle)
                .font(Typography.micro)
                .foregroundStyle(Theme.secondaryText)
            WorkbookStageSteps(stage: subunit.stage, passed: subunit.status == .passed)
                .padding(.vertical, 6)
            if !subunit.outcome.isEmpty {
                Text(subunit.outcome)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tilesSection(_ subunit: WorkbookSubunitDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("マス")
                    .font(Typography.eyebrow)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                WorkbookPassLine(window: subunit.window)
            }
            // 演習の答えだけを n 個まで(新しい答えが古いものを押し出す)。5 列でそろえる。
            let tiles = subunit.windowTiles ?? []
            let columns = Array(repeating: GridItem(.fixed(34), spacing: 6, alignment: .leading), count: WorkbookWindowGrid.columns(n: subunit.n))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(tiles) { tile in
                    Button {
                        coordinator.open(.problem(tile.id))
                    } label: {
                        WorkbookTile(state: tile.state, assisted: tile.assisted, size: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workbook-tile-\(tile.id)")
                }
                ForEach(0..<max(0, subunit.n - tiles.count), id: \.self) { _ in
                    WorkbookTile(state: .notStarted, size: 34)
                }
            }
            .accessibilityIdentifier("workbook-subunit-tiles")
        }
        .padding(16)
        .struisSurface(radius: Theme.Radius.card)
        .padding(.horizontal, 20)
    }

    private func setSection(_ subunit: WorkbookSubunitDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let openSetID = subunit.openSetId {
                let set = store.sets[openSetID]
                Button {
                    coordinator.open(.set(openSetID))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(set?.kind.label ?? subunit.stageLabel)
                                .font(Typography.title)
                            Text(set.map { "\($0.count ?? $0.problems.count)問" } ?? (subunit.stageValue == .soloExample ? "1問" : "\(subunit.n)問"))
                                .font(Typography.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        if set?.status == .generating || set == nil {
                            ProgressView().controlSize(.small)
                        }
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .padding(16)
                    .struisSurface(radius: Theme.Radius.card)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workbook-open-set")
                .task(id: openSetID) { await store.loadSet(id: openSetID) }
            } else {
                Button {
                    guard !isRequestingSet else { return }
                    isRequestingSet = true
                    Task {
                        if let set = await store.requestSet(subunitID: subunit.id) {
                            coordinator.open(.set(set.id))
                        }
                        isRequestingSet = false
                    }
                } label: {
                    HStack {
                        Text(subunit.stageValue == .soloExample ? "類題 1問" : "演習 \(subunit.n)問")
                            .font(Typography.bodyEmphasized)
                        Spacer()
                        if isRequestingSet {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "doc.text")
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .controlSize(.large)
                .disabled(isRequestingSet)
                .accessibilityIdentifier("workbook-request-set")
            }
        }
        .padding(.horizontal, 20)
    }

    /// 「例題に戻る」。学習者が選んだ時だけ段階 2 へ(戻る前の段は記録され、例題の後にそこへ戻る)。
    private func returnToExampleButton(_ subunit: WorkbookSubunitDTO) -> some View {
        Button {
            guard !isReturning else { return }
            isReturning = true
            Task {
                await store.returnToExample(subunitID: subunit.id)
                isReturning = false
            }
        } label: {
            Label("例題に戻る", systemImage: "arrow.uturn.backward")
                .font(Typography.caption)
        }
        .buttonStyle(.bordered)
        .disabled(isReturning)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("workbook-return-to-example")
    }

    private func capturesSection(_ subunit: WorkbookSubunitDTO) -> some View {
        let captures = store.recentCaptures.filter { $0.subunitId == subunit.id }
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
                .padding(.horizontal, 20)
            }
        }
    }
}

struct WorkbookCaptureRow: View {
    let capture: WorkbookCaptureDTO

    var body: some View {
        HStack(spacing: 12) {
            switch capture.status {
            case .identifying:
                ProgressView().controlSize(.small)
                Text("判定中").font(Typography.body)
            case .graded:
                if let summary = capture.summary {
                    Text("\(summary.correct) / \(summary.total)")
                        .font(Typography.bodyEmphasized.monospacedDigit())
                    if summary.passed {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(WorkbookPalette.passed)
                    }
                } else {
                    Text("判定済み").font(Typography.body)
                }
            case .triage:
                Image(systemName: "tray").foregroundStyle(Theme.secondaryText)
                Text("整理中").font(Typography.body)
            case .failed:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(WorkbookPalette.wrong)
                Text("判定できず").font(Typography.body)
            }
            Spacer()
            WorkbookRelativeTime(iso: capture.createdAt)
                .font(Typography.caption)
                .foregroundStyle(Theme.tertiaryText)
            Image(systemName: "chevron.right").foregroundStyle(Theme.tertiaryText)
        }
        .padding(14)
        .struisSurface(radius: Theme.Radius.stat)
        .contentShape(Rectangle())
    }
}

/// 段階 2 の例題バー。進捗バーの下に固定し、会話はその下を通らない。
/// 入った直後は「例題」と問題文の全文(長ければバーの中でスクロール)。会話のスクロール・入力欄へのフォーカス・
/// 送信で 1 行(「例題」・問題文の頭・﹀)にしまう。学習者は手でも開閉できる: 1 行をタップすると全文に、
/// 全文の見出しの行(「例題」・︿)をタップすると 1 行に。開閉は高さのアニメーション。
struct WorkbookExampleCard: View {
    static let collapsedHeight: CGFloat = 40

    let prompt: String?
    var isFailed = false
    var isCollapsed = false
    /// 学習者が手で開閉した(1 行のタップで全文に、全文の見出しの行のタップで 1 行に)。
    var onToggle: () -> Void = {}
    /// 例題が届くまでの待ち(§6)。例題をバーに入れるまでは待ちの中身を出す。
    var wait: WorkbookExampleWaitModel? = nil
    /// 例題を作っているターン(信頼性計画 P2: 実際に起きた出来事を待ちの中に出す)。
    var liveKeys: [String] = []
    var waitStatusText = WorkbookExampleWaitModel.statusText
    var onStop: (() -> Void)? = nil
    /// 全文の高さ(測った値)。0 はまだ測っていない。
    @State private var expandedHeight: CGFloat = 0

    /// 待ちの中身を出している(例題が届いても、フェードで入れるまでは出さない)。
    private var isWaiting: Bool { (wait?.isActive ?? false) && !(wait?.showsExample ?? false) }
    private var displayedPrompt: String? { isWaiting ? nil : prompt }
    private var showsCollapsed: Bool { isCollapsed && displayedPrompt != nil }

    var body: some View {
        ZStack(alignment: .top) {
            expandedContent
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { expandedHeight = $0 }
                .opacity(showsCollapsed ? 0 : 1)
                .accessibilityHidden(showsCollapsed)
                .allowsHitTesting(!showsCollapsed)
            if showsCollapsed, let prompt = displayedPrompt {
                collapsedContent(prompt)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: expandedHeight > 0 ? (showsCollapsed ? Self.collapsedHeight : expandedHeight) : nil, alignment: .top)
        .clipped()
        .struisSurface(radius: Theme.Radius.card)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.ground)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WorkbookSubunitView.coordinateSpace)) } action: { wait?.barFrame = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workbook-example-card")
        .accessibilityValue(showsCollapsed ? "collapsed" : "expanded")
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if displayedPrompt != nil {
                // 問題文が出ている間は、見出しの行で 1 行にしまえる(手で開閉する)。
                Button(action: onToggle) {
                    HStack(spacing: 8) {
                        Text("例題")
                            .font(Typography.eyebrow)
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -6)
                .accessibilityLabel("例題")
                .accessibilityHint("1 行にしまう")
                .accessibilityIdentifier("workbook-example-collapse")
            } else {
                Text("例題")
                    .font(Typography.eyebrow)
                    .foregroundStyle(Theme.secondaryText)
            }
            if isWaiting, let wait {
                WorkbookExampleWaitingContent(model: wait, liveKeys: liveKeys, statusText: waitStatusText, onStop: onStop)
            } else if let prompt = displayedPrompt {
                ScrollView {
                    WorkbookPromptText(text: prompt, lineLimit: nil)
                        .foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            } else {
                HStack(spacing: 8) {
                    if !isFailed { StruisLoadingIndicator().controlSize(.small) }
                    Text(isFailed ? "例題を出せませんでした" : "例題を用意しています")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                if !isFailed, !liveKeys.isEmpty { TurnLiveLine(keys: liveKeys, onStop: onStop) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func collapsedContent(_ prompt: String) -> some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Text("例題")
                    .font(Typography.eyebrow)
                    .foregroundStyle(Theme.secondaryText)
                Text(Self.headline(prompt))
                    .font(Typography.caption)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 14)
            .frame(height: Self.collapsedHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("例題 \(Self.headline(prompt))")
        .accessibilityHint("全文を開く")
        .accessibilityIdentifier("workbook-example-collapsed")
    }

    /// 1 行にしまった時の問題文の頭。数式の区切り(`$`・`\(`・`\)`)を外し、改行と連続する空白を 1 つにまとめる。
    static func headline(_ prompt: String) -> String {
        var text = prompt
        for token in ["$$", "$", "\\(", "\\)", "\\[", "\\]"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// 小単元の会話を用意できなかった(台帳の読み書きに失敗した等)。
nonisolated struct SubunitThreadUnavailable: LocalizedError {
    var errorDescription: String? { "会話を用意できませんでした。もう一度試してください。" }
}

/// 例題バーの開閉。入った直後は全文。学習者が会話を動かす(スクロール・入力欄へのフォーカス・送信)と
/// 1 行にしまう。学習者は手でも開閉でき(1 行のタップで全文、全文の見出しの行のタップで 1 行)、手で開閉した後は
/// その回のあいだ会話の操作では動かさない(読み比べている全文を勝手にしまわない)。問題文がまだ無い間はしまわない。
/// 新しい回の例題はまた全文から。
struct WorkbookExampleBarState: Equatable {
    private(set) var isCollapsed = false
    /// この回で学習者が手で開閉した。
    private(set) var isManual = false

    /// しまったら true。
    @discardableResult
    mutating func learnerActed(_ activity: ChatLearnerActivity, hasPrompt: Bool) -> Bool {
        guard hasPrompt, !isCollapsed, !isManual else { return false }
        isCollapsed = true
        return true
    }

    /// 手で開閉した(1 行のタップ・全文の見出しの行のタップ)。
    mutating func toggled() {
        isCollapsed.toggle()
        isManual = true
    }

    mutating func enteredNewRound() {
        isCollapsed = false
        isManual = false
    }
}
