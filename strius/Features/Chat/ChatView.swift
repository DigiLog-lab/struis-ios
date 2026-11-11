import SwiftUI
import UIKit

/// 学習者が会話を動かした操作。小単元の例題バーはこれで 1 行にしまう。
enum ChatLearnerActivity: Equatable {
    case scrolled
    case focusedComposer
    case sent
}

struct ChatView: View {
    @Environment(ChatStore.self) private var chat
    @Environment(BootstrapStore.self) private var bootstrap
    @Environment(APIClient.self) private var apiClient
    @Environment(LearnerData.self) private var learnerData
    @Environment(\.colorScheme) private var scheme

    /// 問題集からの文脈(小単元・一枚)。nil なら自由な質問。
    let workbookContext: WorkbookQuestionContext?
    /// 小単元の段階 1・2 に埋め込まれている時は true。履歴・書き出し・設定を出さない。
    let embedded: Bool
    let onClose: (() -> Void)?
    /// 決まった thread を開く(小単元の会話・単元づくり)。nil なら最近の会話。
    let threadBootstrap: ((ChatStore) async -> Void)?
    /// 開いた所から渡された下書き(タイムラインの「解説」「質問」: 問題文つき)。開いた時に 1 回だけ入力欄に入れる。
    let initialDraft: String?
    /// 全体像カードの「はじめる」の後。
    let onProposalStarted: ((WorkbookProposalDTO) -> Void)?
    /// 返事の生成中に送ったら、止めてから送る(説明の途中の質問)。
    let sendsWhileGenerating: Bool
    /// 会話の右下に浮かせる部品(小単元の「先に進む」)。入力欄にフォーカスがある間(キーボードが出ている間)は隠す。
    let floatingAccessory: AnyView?
    /// 段の区切り。変わったら新しい段の返事まで会話を送る(`ChatTimeline.followToken`)。
    let followToken: String?
    /// 学習者が会話をスクロールした・入力欄にフォーカスした・送った時。
    let onLearnerActivity: ((ChatLearnerActivity) -> Void)?
    /// まだ見せない返事(§6: 例題が出るまでの例題の段の返事)。
    let hiddenMessageIDs: Set<UUID>
    /// 数式・強調に色をつける返事(§6: 例題へ運ぶ語の元の箇所)。
    let highlight: (messageID: UUID, count: Int)?
    let onHighlightFrame: ((CGRect) -> Void)?

    @State private var exportSnapshot: ConversationExportSnapshot?
    @State private var exportCopied = false
    @State private var composer: String = ""
    /// 送信を処理している最中(止めてから送る間も含む)。続けて押された送信は受けない(下書きを取り違えない)。
    @State private var isSubmitting = false
    @State private var attachments: [ComposerAttachment] = []
    @State private var didAdoptThread = false
    @State private var didApplyInitialDraft = false
    @State private var isHistoryPresented = false
    @State private var isSettingsPresented = false
    @State private var activeLearningSessionID: UUID?
    @State private var learningContextEnabled = true
    @State private var emptyPaneMinHeight: CGFloat = 0
    @State private var composerPrefillGlow = false
    /// 入力欄の段の高さ(浮かせた部品をその上に置くため)。
    @State private var composerInsetHeight: CGFloat = 0
    /// 右下に浮かせた部品の高さ(会話の最後の行をその上まで上げる余白に使う。D8)。
    @State private var floatingAccessoryHeight: CGFloat = 0
    /// 単元づくりの待ちの画面を出している(その間は下の会話を描かない。全体像カードが二重にならないように)。
    @State private var unitWaitVisible = false
    @FocusState private var composerFocused: Bool

    init(
        workbookContext: WorkbookQuestionContext? = nil,
        embedded: Bool = false,
        onClose: (() -> Void)? = nil,
        threadBootstrap: ((ChatStore) async -> Void)? = nil,
        initialDraft: String? = nil,
        onProposalStarted: ((WorkbookProposalDTO) -> Void)? = nil,
        sendsWhileGenerating: Bool = false,
        floatingAccessory: AnyView? = nil,
        followToken: String? = nil,
        onLearnerActivity: ((ChatLearnerActivity) -> Void)? = nil,
        hiddenMessageIDs: Set<UUID> = [],
        highlight: (messageID: UUID, count: Int)? = nil,
        onHighlightFrame: ((CGRect) -> Void)? = nil
    ) {
        self.hiddenMessageIDs = hiddenMessageIDs
        self.highlight = highlight
        self.onHighlightFrame = onHighlightFrame
        self.workbookContext = workbookContext
        self.embedded = embedded
        self.onClose = onClose
        self.threadBootstrap = threadBootstrap
        self.initialDraft = initialDraft
        self.onProposalStarted = onProposalStarted
        self.sendsWhileGenerating = sendsWhileGenerating
        self.floatingAccessory = floatingAccessory
        self.followToken = followToken
        self.onLearnerActivity = onLearnerActivity
    }

    private var isCreatingUnit: Bool { workbookContext?.purpose == .createUnit }

    var body: some View {
        GeometryReader { proxy in
            let sidebarWidth = min(proxy.size.width * 0.82, 330)

            ZStack(alignment: .leading) {
                content
                    // 「先に進む」の段(D8): 会話の終わりはこの段の上で止まり、ボタンが最後の吹き出しを隠さない。
                    // 段には面を敷かない(スクロール中の吹き出しを途中で切らず、ガラスのボタンの後ろに透けて見せる)。
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if showsFloatingAccessory {
                            Color.clear
                                .frame(height: floatingAccessoryHeight > 0 ? floatingAccessoryHeight + Self.floatingAccessoryBandPadding * 2 : 0)
                                .transition(.opacity)
                                .accessibilityHidden(true)
                        }
                    }
                    .animation(.snappy(duration: 0.2), value: showsFloatingAccessory)
                    .background(chatBackground.ignoresSafeArea())
                    .safeAreaInset(edge: .bottom, spacing: embedded ? 0 : nil) {  // 小単元では入力欄と会話・「先に進む」の段の間を空けない(会話が透けない)
                        if !isHistoryPresented {
                            composerInset
                        }
                    }
                    .accessibilityIdentifier("chat-page")
                // 浮かせた部品は "chat-page" の識別子の外に置く(親の識別子で子の識別子が上書きされないように)。
                .overlay(alignment: .bottomTrailing) {
                    ZStack(alignment: .bottomTrailing) {
                        if let floatingAccessory, showsFloatingAccessory {
                            floatingAccessory
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { floatingAccessoryHeight = $0 }
                                .padding(.trailing, 12)
                                .padding(.bottom, composerInsetHeight + Self.floatingAccessoryBandPadding)
                                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
                        }
                    }
                    .animation(.snappy(duration: 0.2), value: composerFocused)
                }
                .allowsHitTesting(!isHistoryPresented)
                .accessibilityHidden(isHistoryPresented)

                Color.black
                    .opacity(isHistoryPresented ? (scheme == .dark ? 0.30 : 0.16) : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(isHistoryPresented)
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.24)) {
                            isHistoryPresented = false
                        }
                    }

                HistorySidebar(
                    threads: bootstrap.threads,
                    activeThreadID: chat.threadID,
                    onNewChat: {
                        Task { await chat.adoptThread(nil) }
                    },
                    onSelect: { thread in
                        Task { await chat.adoptThread(thread) }
                    },
                    onClose: {
                        withAnimation(.snappy(duration: 0.24)) {
                            isHistoryPresented = false
                        }
                    }
                )
                .frame(width: sidebarWidth)
                .offset(x: isHistoryPresented ? 0 : -sidebarWidth)
                .allowsHitTesting(isHistoryPresented)
            }
            .animation(.snappy(duration: 0.24), value: isHistoryPresented)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if onClose != nil || !embedded {
                    HStack(spacing: 12) {
                        if let onClose {
                            Button("閉じる") { onClose() }
                                .accessibilityIdentifier("question-close")
                        }
                        if !embedded {
                            Button {
                                dismissKeyboard()
                                withAnimation(.snappy(duration: 0.24)) {
                                    isHistoryPresented.toggle()
                                }
                            } label: {
                                Label("履歴", systemImage: "clock.arrow.circlepath")
                            }
                        }
                    }
                }
            }
            ToolbarItem(placement: .principal) {
                Text(embedded ? (workbookContext?.stageLabel ?? "質問") : isCreatingUnit ? "単元を作る" : "質問")
                    .font(Typography.navBrand)
                    .foregroundStyle(Theme.secondaryText)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !embedded {
                    Button {
                        let text = chat.messages.map { message in
                            let role = message.role == .user ? "あなた" : message.role == .assistant ? "Struis" : "システム"
                            return "[\(role)]\n\(message.conversationExportText)"
                        }.joined(separator: "\n\n")
                        exportCopied = false
                        exportSnapshot = ConversationExportSnapshot(text: text)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("会話を書き出す")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !embedded {
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Label("設定", systemImage: "gearshape")
                    }
                }
            }
        }
        .sheet(item: $exportSnapshot) { snapshot in
            NavigationStack {
                ScrollView {
                    Text(snapshot.text.isEmpty ? "会話がまだありません" : snapshot.text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("会話の書き出し")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("閉じる") { exportSnapshot = nil }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(exportCopied ? "コピーしました" : "コピー") {
                            UIPasteboard.general.string = snapshot.text
                            exportCopied = true
                        }
                        .disabled(snapshot.text.isEmpty)
                    }
                }
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheet()
                .presentationDetents([.large])
        }
        .onAppear { chat.start() }
        .task { await prepareInitialThread() }
        .onDisappear { chat.stop() }
        .onChange(of: isHistoryPresented) { _, presented in
            if presented {
                dismissKeyboard()
            }
        }
        .onAppear {
            applyInitialDraft()
            consumePendingComposerDraft()
        }
        .onChange(of: chat.pendingComposerDraft) { _, _ in
            consumePendingComposerDraft()
        }
        // iPad の右の欄は開いたまま、別の問題の「質問」「解説」を押すと下書きだけが替わる(欄は作り直されない)。
        // 新しい問題の下書きに入れ替える(前の問題の下書きのまま送らせない)。
        .onChange(of: initialDraft) { _, draft in
            guard let draft, !draft.isEmpty else { return }
            chat.pendingComposerDraft = draft
        }
        .onChange(of: composerFocused) { _, focused in
            if focused { onLearnerActivity?(.focusedComposer) }
        }
    }

    /// 右下の部品の段の上下の余白。
    static let floatingAccessoryBandPadding: CGFloat = 6

    /// 「先に進む」の段を出すか。入力欄にフォーカスがある間(キーボードが出ている間)と履歴を開いている間は出さない。
    private var showsFloatingAccessory: Bool {
        floatingAccessory != nil && !composerFocused && !isHistoryPresented
    }

    private func prepareInitialThread() async {
        guard !didAdoptThread else { return }
        if let threadBootstrap {
            await threadBootstrap(chat)
            // 用意できなかった時は、「再試行」でもう一度同じ用意をやり直す。
            if case .failed = chat.loadState { return }
            didAdoptThread = true
            return
        }
        if bootstrap.user == nil { await bootstrap.refresh() }
        guard !Task.isCancelled else { return }
        // 会話は台帳と Claude への直接の送信だけで動く。サーバーの bootstrap が通らない(圏外・認証切れ)ときも台帳の会話一覧で開く。
        if bootstrap.user == nil { await bootstrap.refreshThreads() }
        // 質問は開くたびに空の新しい会話で始める(前に開いていた会話・いちばん新しい会話は出さない)。
        // 前の会話は消さず、左上の履歴から開ける。
        await chat.adoptThread(nil)
        didAdoptThread = true
    }


    private func applyInitialDraft() {
        guard !didApplyInitialDraft, let initialDraft, !initialDraft.isEmpty else { return }
        didApplyInitialDraft = true
        chat.pendingComposerDraft = initialDraft
    }

    /// 相談(入口 A)などから渡された下書きを入力欄へ流し込む。
    /// あとは送信ボタンを押すだけの状態にして、ガラスをひと呼吸光らせる。
    private func consumePendingComposerDraft() {
        let pendingAttachments = chat.pendingComposerAttachments
        if !pendingAttachments.isEmpty {
            chat.pendingComposerAttachments = []
            attachments.append(contentsOf: pendingAttachments)
        }
        guard let draft = chat.pendingComposerDraft, !draft.isEmpty else { return }
        chat.pendingComposerDraft = nil
        composer = draft
        composerFocused = true
        withAnimation(.easeOut(duration: 0.45)) {
            composerPrefillGlow = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeOut(duration: 0.9)) {
                composerPrefillGlow = false
            }
        }
    }

    private var composerInset: some View {
        VStack(spacing: 8) {
            if let sendError = chat.sendError {
                errorPill(sendError)
            }
            if let workbookContext, !embedded, let title = workbookContext.title {
                Text([title, workbookContext.stageLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(Typography.micro)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Theme.card, in: Capsule())
                    .accessibilityIdentifier("question-context-chip")
            }
            ChatComposer(
                text: $composer,
                attachments: $attachments,
                focused: $composerFocused,
                // 返事が見える本文を書き終えて記録だけを書いている間は、停止ボタンにせず送れるままにする(送った質問は記録の後に答える)。
                isSending: chat.isReplyBusy,
                learningSessionAvailable: activeLearningSessionID != nil,
                learningContextEnabled: $learningContextEnabled,
                onSend: handleSend,
                onStop: { Task { await chat.interrupt() } },
                sendsWhileBusy: sendsWhileGenerating
            )
            .disabled(!didAdoptThread || chat.loadState != .loaded)
            .overlay {
                // 解き直しの下書きが入った瞬間、ガラスの縁がアクセント色で
                // ひと呼吸だけ光る。常時装飾ではなくイベントの合図。
                RoundedRectangle(cornerRadius: 27, style: .continuous)
                    .stroke(
                        Theme.accent(scheme).opacity(composerPrefillGlow ? 0.75 : 0),
                        lineWidth: 1.5
                    )
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerInsetHeight = $0 }
        .background {
            if embedded {
                // 小単元では入力欄を最下段の段にし、会話の上に重ねない(会話の文字が透けない)。
                Theme.ground.ignoresSafeArea()
            } else {
            LinearGradient(
                colors: [
                    chatBackground.opacity(0),
                    chatBackground.opacity(scheme == .dark ? 0.48 : 0.34)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
                .ignoresSafeArea()
            }
        }
    }

    private var chatBackground: Color {
        scheme == .dark ? Theme.ground : Theme.ground
    }

    @ViewBuilder
    private var content: some View {
        if !didAdoptThread, threadBootstrap == nil, case .failed = bootstrap.loadState {
            loadingPane
        } else {
        switch chat.loadState {
        case .idle, .loading:
            loadingPane
        case .loaded:
            timelinePane
        case .failed(let message):
            failurePane(message)
        }
        }
    }

    private var loadingPane: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().progressViewStyle(StruisProgressViewStyle()).tint(Theme.accent(scheme))
            Text("会話を読み込んでいます…")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
            Spacer()
        }
    }

    private var timelinePane: some View {
        ZStack {
        Group {
            if isCreatingUnit, unitWaitVisible {
                Color.clear
            } else if chat.messages.isEmpty {
                emptyPane
            } else {
                ChatTimeline(
                    messages: hiddenMessageIDs.isEmpty ? chat.messages : chat.messages.filter { !hiddenMessageIDs.contains($0.id) },
                    threadID: chat.threadID, onProposalStarted: onProposalStarted,
                    followToken: followToken,
                    bottomInset: 0,
                    onLearnerScroll: onLearnerActivity.map { callback -> () -> Void in { callback(.scrolled) } },
                    highlight: highlight, onHighlightFrame: onHighlightFrame
                )
                    .id(chat.threadID)
            }
        }
            // 単元づくり: 最後の問いに答えてから全体像カードが出るまでは、言葉の分解とふるいで待つ(§4)。
            if isCreatingUnit {
                UnitCreationWaitPane(onProposalStarted: onProposalStarted, isVisible: $unitWaitVisible)
            }
        }
    }

    @ViewBuilder
    private var emptyPane: some View {
        if embedded || isCreatingUnit {
            // モデルが話し始めるまでの一瞬。説明文は置かない。
            VStack {
                Spacer()
                ProgressView().progressViewStyle(StruisProgressViewStyle()).tint(Theme.accent(scheme))
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("chat-kickoff-waiting")
        } else {
            freeEmptyPane
        }
    }

    private var freeEmptyPane: some View {
        // キーボードが出て高さが足りなくなると、この縦積みが枠からあふれて
        // コンポーザーをキーボードの下へ押し出してしまう。スクロールに逃がす。
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 0)
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Theme.accent(scheme))
                    .symbolRenderingMode(.hierarchical)
                Text("今日は何から始めましょうか")
                    .font(Typography.heading2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textPrimary(scheme))
                    .padding(.horizontal, 32)
                Text("問題文、途中式、写真のどれでも送れます。")
                    .font(Typography.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .padding(.horizontal, 32)
                LearningFeedV2EntryCard { sessionID in
                    activeLearningSessionID = sessionID
                    learningContextEnabled = sessionID != nil
                }
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: emptyPaneMinHeight)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            emptyPaneMinHeight = height
        }
    }

    private func failurePane(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(Theme.regress(scheme))
            Text(message)
                .font(Typography.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textPrimary(scheme))
                .padding(.horizontal, 28)
            Button("再試行") {
                Task {
                    if !didAdoptThread {
                        await prepareInitialThread()
                    } else if threadBootstrap == nil {
                        // 質問の「再試行」も、開いた時と同じく空の新しい会話で始める。
                        await chat.adoptThread(nil)
                    } else {
                        await chat.adoptThread(bootstrap.threads.first)
                    }
                }
            }
            .font(Typography.bodyEmphasized)
            .foregroundStyle(Theme.accent(scheme))
            LearningFeedV2EntryCard { sessionID in
                activeLearningSessionID = sessionID
                learningContextEnabled = sessionID != nil
            }
            Spacer()
        }
    }

    private func errorPill(_ message: String) -> some View {
        Text(message)
            .font(Typography.caption)
            .foregroundStyle(Theme.regress(scheme))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Theme.card, in: Capsule())
            .padding(.horizontal, 14)
    }

    private func handleSend() {
        // 前の送信(返事を止めてから送る間も含む)が終わるまで、次の送信は受けない。入力欄の下書きはそのまま残る。
        guard !isSubmitting else { return }
        isSubmitting = true
        let text = composer
        let pendingAttachments = attachments
        composer = ""
        attachments = []
        onLearnerActivity?(.sent)
        Task {
            defer { isSubmitting = false }
            let didSend: Bool
            if sendsWhileGenerating, chat.isSending {
                didSend = await chat.interruptAndSend(text: text, attachments: pendingAttachments, workbookView: workbookContext?.viewRef)
            } else {
                didSend = await chat.send(
                    text: text,
                    attachments: pendingAttachments,
                    learningFeedSessionID: learningContextEnabled ? activeLearningSessionID : nil,
                    workbookView: workbookContext?.viewRef
                )
            }
            // 送れなかった時は下書きに戻す。待っている間に新しく打った下書きがあれば、そちらを消さない。
            if !didSend, composer.isEmpty, attachments.isEmpty {
                composer = text
                attachments = pendingAttachments
            }
        }
    }

    private func dismissKeyboard() {
        composerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsView()
                .navigationTitle("設定")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("閉じる") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

private struct HistorySidebar: View {
    let threads: [ThreadSummary]
    let activeThreadID: UUID?
    let onNewChat: () -> Void
    let onSelect: (ThreadSummary) -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("履歴")
                    .font(Typography.title)
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 34, height: 34)
                .background(Theme.card, in: Circle())
            }

            Button {
                onNewChat()
                onClose()
            } label: {
                Label("新しい会話", systemImage: "plus.message")
                    .font(Typography.bodyEmphasized)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent(scheme))
            .background(Theme.card, in: Capsule())

            VStack(alignment: .leading, spacing: 10) {
                Text("会話履歴")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .textCase(.uppercase)

                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(threads) { thread in
                            historyRow(thread)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(.regularMaterial)
                .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.separator(scheme))
                .frame(width: 0.5)
                .ignoresSafeArea()
        }
    }

    private func historyRow(_ thread: ThreadSummary) -> some View {
        Button {
            onSelect(thread)
            onClose()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle(for: thread))
                        .font(activeThreadID == thread.id ? Typography.bodyEmphasized : Typography.body)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    // 一覧では数式を描かないので、LaTeX を読める文字に直す(D7: `\(D>0\)` → `D > 0`)。
                    if let preview = thread.latestPreview.map(MathPlainText.preview), !preview.isEmpty {
                        Text(preview)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if activeThreadID == thread.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent(scheme))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                activeThreadID == thread.id
                    ? Theme.card
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func displayTitle(for thread: ThreadSummary) -> String {
        let title = thread.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty, title != "新しい会話" {
            return MathPlainText.preview(title)
        }
        let preview = thread.latestPreview.map(MathPlainText.preview)
        if let preview, !preview.isEmpty {
            return preview
        }
        return "無題の会話"
    }
}

private struct ConversationExportSnapshot: Identifiable {
    let id = UUID()
    let text: String
}
