import CryptoKit
import Foundation
import GRDB
import ImageIO
import OSLog
import PDFKit
import UIKit

private let chatLog = Logger(subsystem: "com.digiloglab.strius", category: "chat")

/// Drives the 質問 screen from the device ledger (design §6.3). Threads, messages
/// and the pending reply are ledger rows; the turn itself runs on the
/// device through `TurnCoordinator`, so there is no server request or realtime
/// subscription. The view surface is unchanged.
@Observable
@MainActor
final class ChatStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle
    private(set) var threadID: UUID?
    /// 学習者に見せるメッセージ。モデルを起こす起動メッセージ(`metadata.hidden`)は含まない。
    private(set) var messages: [ChatMessage] = []
    /// 起動メッセージも含む全メッセージ(段の起動の返事を探すため)。
    private(set) var allMessages: [ChatMessage] = []
    private(set) var isSending = false
    /// 学習者の送信で始まった返事(いちばん新しいもの)。台帳で出来上がったかを見る。
    private var sentReplyID: UUID?
    private(set) var sendError: String?
    /// 「GPT に切り替える」が、この会話の送り直しに効くか(勉強を止めない仕組み 3.5)。
    /// Codex のスレッドは始めた実行先に固定される(`CodexTurnRunner.resolvingProvider`: 別の実行先では履歴の reasoning を
    /// 読めない)ので、切り替えが効くのは、まだ返事を一度も受け取っていない会話(最初のターンが Claude の準備で失敗した時)だけ。
    /// 返事を受け取った後の会話で実行先を変えるには新しい会話が要る(3.3 の範囲、保留)。
    private(set) var retryFollowsProviderSetting = true
    /// 答案の写真を添えた会話と答案(`thread|capture`)。同じ会話で同じ答案を何度も送らない。
    /// 進行中の返信に付く進捗ラベル (`codex.turn.status` の端末版)。
    private(set) var progressLabel: String?

    /// 動いている返事が、見える本文を書き終えて後ろの記録(進み具合・記憶など)だけを書いている。
    /// この間の送信は返事を止めず、その後ろに並べる(記録が終わってから答える)。
    /// 学習者が送った返事が台帳で出来上がってから、終わりの知らせで `isSending` が下りるまでの間も含める。含めないと、
    /// 記録を書き終えた直後だけ入力欄が停止ボタンに戻り、ちょうど押した送信が断られて下書きに戻る(並べた送信は、
    /// 前の返事が終わっていればそのまま始まる)。
    var replyFinishingInBackground: Bool {
        guard isSending, sendPreparations.isEmpty,
              let reply = allMessages.last(where: { $0.role == .assistant }) else { return false }
        guard reply.status == .pending else { return reply.id == sentReplyID }
        guard let activity = TurnActivityBoard.shared.activity(TurnActivityKey.reply(reply.id)) else { return false }
        return activity.writingPrivateTail && !activity.queuedBehindReply
    }

    /// 入力欄を「返事を書いている最中」として扱うか(停止ボタン・送信を止める)。記録だけを書いている間は扱わない。
    var isReplyBusy: Bool { isSending && !replyFinishingInBackground }
    /// 問題カタログの「解き直す」等から渡される、コンポーザーへの下書き。
    var pendingComposerDraft: String?
    var pendingComposerAttachments: [ComposerAttachment] = []

    private let ledger: Ledger
    private let turns: TurnCoordinator
    private var observer: UUID?
    private var noticeObserver: UUID?
    private var sessionGeneration = UUID()
    private var refreshTask: Task<Void, Never>?
    // Attachment storage/fork preparation precedes coordinator registration. A delayed
    // terminal notice must not enable another send while that work is still in flight.
    private var sendPreparations: Set<UUID> = []
    private var sendStateRevision = UUID()

    /// サインアウトで片づける(`AuthStore.sessionEndedNotification`)。
    nonisolated(unsafe) private var sessionEndObserver: NSObjectProtocol?

    init(ledger: Ledger, turns: TurnCoordinator) {
        self.ledger = ledger
        self.turns = turns
        // 小単元ごとに作る ChatStore も含め、どの会話もサインアウトで世代を進める(送信の途中の処理を無効にする)。
        sessionEndObserver = NotificationCenter.default.addObserver(forName: AuthStore.sessionEndedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
    }

    deinit {
        if let sessionEndObserver { NotificationCenter.default.removeObserver(sessionEndObserver) }
    }

    // MARK: - Lifecycle

    func reset() {
        stop()
        sessionGeneration = UUID()
        threadID = nil
        messages = []
        allMessages = []
        pendingComposerDraft = nil
        isSending = false
        sendPreparations.removeAll()
        sendError = nil
        progressLabel = nil
        loadState = .idle
    }

    func start() {
        guard observer == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            let ledger = self.ledger
            let id = await ledger.observe { [weak self] events in
                // ターンの終わり(`turns.completed_at`)も読む: 「N秒考えました」は返事が出来上がった後に確定する。
                guard events.contains(where: { $0.entity == .messages || $0.entity == .threads || $0.entity == .turns }) else { return }
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }
            let notice = await self.turns.observe { [weak self] notice in
                guard notice.kind == .chat else { return }
                Task { @MainActor [weak self] in await self?.handleTurnNotice(notice) }
            }
            self.observer = id
            self.noticeObserver = notice
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        if let observer, let noticeObserver {
            let ledger = self.ledger
            let turns = self.turns
            Task {
                await ledger.unobserve(observer)
                await turns.unobserve(noticeObserver)
            }
        }
        observer = nil
        noticeObserver = nil
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self else { return }
            self.refreshTask = nil
            await self.refreshCurrentThread()
        }
    }

    func handleTurnNotice(_ notice: TurnCoordinator.Notice) async {
        guard notice.kind == .chat, notice.status != "running", let targetID = notice.targetID else { return }
        let generation = sessionGeneration
        let sendRevision = sendStateRevision
        // MainActor delivery can lag behind a new send. Read the current reservation
        // rather than treating an old terminal notification as permission to send.
        let running = await turns.isChatRunning(threadID: targetID)
        guard sessionGeneration == generation else { return }
        if targetID == threadID?.uuidString.lowercased(), sendStateRevision == sendRevision {
            isSending = running || !sendPreparations.isEmpty
            if !isSending { progressLabel = nil }
        }
    }

    private func beginSendPreparation() -> UUID {
        let id = UUID()
        sendPreparations.insert(id)
        sendStateRevision = id
        return id
    }

    private func endSendPreparation(_ id: UUID) {
        if sendPreparations.remove(id) != nil { sendStateRevision = UUID() }
    }

    func refreshCurrentThread() async {
        guard let threadID else { return }
        await loadMessages(for: threadID)
    }

    // MARK: - Thread

    func adoptThread(_ summary: ThreadSummary?) async {
        if let summary {
            await loadMessages(for: summary.id)
        } else {
            threadID = nil
            messages = []
            allMessages = []
            loadState = .loaded
        }
    }

    /// 決まった thread(小単元の会話・単元づくりの会話)を開く。
    /// 決まった thread を用意できなかった(単元づくりの起動など)。画面は「再試行」を出す。
    func failBootstrap(_ error: Error) {
        threadID = nil
        messages = []
        allMessages = []
        loadState = .failed(Self.message(for: error))
    }

    func adoptThread(id: UUID) async {
        guard threadID != id || loadState != .loaded else {
            await loadMessages(for: id)
            return
        }
        await loadMessages(for: id)
    }

    private func loadMessages(for id: UUID) async {
        let generation = sessionGeneration
        if threadID != id || loadState != .loaded { loadState = .loading }
        threadID = id
        let key = id.uuidString.lowercased()
        do {
            let (rows, all) = try await ledger.read { db in
                let rows = try ChatRepository.messages(db, threadID: key)
                return (rows, try ChatRepository.chatMessages(db, rows: rows))
            }
            guard threadID == id, sessionGeneration == generation else { return }
            // Kickoff messages are hidden; replies cut off and answered by a later reply are folded (D15).
            let hidden = Set(rows.filter { $0.metadata["hidden"]?.boolValue == true || $0.metadata["folded"]?.boolValue == true }.compactMap { UUID(uuidString: $0.id) })
            let loaded = all.filter { !hidden.contains($0.id) }
            if allMessages != all { allMessages = all }
            if messages != loaded { messages = loaded }
            retryFollowsProviderSetting = await Self.retryFollowsProviderSetting(ledger: ledger, threadID: key)
            let revision = sendStateRevision
            let running = await turns.isChatRunning(threadID: key)
            guard threadID == id, sessionGeneration == generation else { return }
            // A new send may start or finish preparation while the actor query suspends.
            if sendStateRevision == revision { isSending = running || !sendPreparations.isEmpty }
            loadState = .loaded
        } catch {
            guard threadID == id, sessionGeneration == generation else { return }
            chatLog.error("loadMessages failed: \(String(describing: error), privacy: .public)")
            if loadState != .loaded { loadState = .failed(Self.message(for: error)) } else { sendError = Self.message(for: error) }
        }
    }

    /// この会話の送り直しが設定の実行先で動くか: Codex のスレッドが無い(まだ始めていない)か、スレッドはあるが
    /// 返事を一度も受け取っていない(`ThreadContextStore` の `answered == false`)。
    nonisolated static func retryFollowsProviderSetting(ledger: Ledger, threadID: String, contexts: ThreadContextStore = .shared) async -> Bool {
        let codexThreadID = try? await ledger.read { db in try CodexThreadRecord.fetchOne(db, key: threadID)?.codexThreadId }
        guard let codexThreadID else { return true }
        return contexts.entry(codexThreadID)?.answered == false
    }

    func ensureActiveThread() async throws -> UUID {
        try await ensureThread()
    }

    private func ensureThread(title: String? = nil) async throws -> UUID {
        if let threadID { return threadID }
        let generation = sessionGeneration
        let id = UUID()
        let created = ChatRepository.createThread(id: id.uuidString.lowercased(), title: title ?? "会話")
        try await ledger.append([created.1])
        guard generation == sessionGeneration else { throw CancellationError() }
        threadID = id
        loadState = .loaded
        return id
    }

    // MARK: - Send

    @discardableResult
    func send(
        text rawText: String,
        attachments: [ComposerAttachment] = [],
        learningFeedSessionID: UUID? = nil,
        workbookView: WorkbookViewRef? = nil
    ) async -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 記録だけを書いている返事の後ろには並べて送る(返事は止めない)。
        let queuesBehindReply = isSending && replyFinishingInBackground
        guard (!text.isEmpty || !attachments.isEmpty), !isSending || queuesBehindReply else { return false }
        let generation = sessionGeneration
        let preparationID = beginSendPreparation()
        defer { endSendPreparation(preparationID) }
        isSending = true
        sendError = nil
        progressLabel = nil
        do {
            let thread = try await ensureThread(title: text.isEmpty ? nil : String(text.prefix(40)))
            guard generation == sessionGeneration, threadID == thread else { return false }
            // リザルトの「質問する」: 質問しているその答案の写真を、この会話で最初の 1 回だけ添える(モデルが答案を見られるように)。
            // 添えたかどうかは台帳のこの会話のメッセージで見る(アプリを開き直しても二重に添えない)。
            var outgoing = attachments
            if let captureID = workbookView?.captureId,
               !(await Self.captureAlreadyAttached(ledger: ledger, threadID: thread.uuidString.lowercased(), captureID: captureID)),
               let answer = await Self.captureAttachment(ledger: ledger, captureID: captureID) {
                outgoing.append(answer)
            }
            // PDF のページの画像化と書き込み・ハッシュは主スレッドの外で行う(大きな PDF で画面を止めない)。
            let stored = try await Self.storeAttachmentsInBackground(outgoing)
            var view: LedgerJSON?
            if let workbookView {
                view = try await ledger.read { db in
                    try WorkbookMachine(loading: db).currentViewContext(
                        subunitID: workbookView.subunitId, setID: workbookView.setId, captureID: workbookView.captureId
                    )
                }
            }
            // 保存・読み出しの間にサインアウトや会話の切り替えがあったら、前の会話へは送らない(保存した添付も消す)。
            guard generation == sessionGeneration, threadID == thread else {
                Self.removeStoredAttachments(stored)
                if generation == sessionGeneration { isSending = false }
                return false
            }
            // 単元づくりの最初の問いへの答えは、次の問いを出すだけのことがある(モデルは動かない。§3.3)。
            var outgoingSend = TurnCoordinator.ChatSend(
                threadID: thread.uuidString.lowercased(), text: text, attachments: stored, workbookView: view
            )
            outgoingSend.queuesBehindReply = queuesBehindReply
            guard let result = try await turns.sendChatHandlingUnitQuestions(outgoingSend) else {
                guard generation == sessionGeneration else { return false }
                endSendPreparation(preparationID)
                isSending = false
                if self.threadID == thread { await loadMessages(for: thread) }
                return true
            }
            // 送信を登録している間にサインアウトされた: 始まったターンを止め、前の学習者の会話を読み込み直さない。
            guard generation == sessionGeneration else {
                await turns.interruptChat(threadID: thread.uuidString.lowercased())
                return false
            }
            sentReplyID = UUID(uuidString: result.assistantMessageID)
            await turns.setProgressHandler(turnID: result.turnID) { [weak self] event in
                Task { @MainActor [weak self] in self?.progressLabel = event.label }
            }
            // 別の会話へ切り替わった・サインアウトされた後は、この会話を読み込み直さない(送った返事はその会話で続く)。
            guard generation == sessionGeneration, threadID == thread else { return generation == sessionGeneration }
            endSendPreparation(preparationID)
            await loadMessages(for: thread)
            return true
        } catch {
            guard generation == sessionGeneration else { return false }
            chatLog.error("send failed: \(String(describing: error), privacy: .public)")
            sendError = Self.message(for: error)
            endSendPreparation(preparationID)
            isSending = false
            if let threadID { await loadMessages(for: threadID) }
            return false
        }
    }

    func interrupt() async {
        guard let threadID else { return }
        await turns.interruptChat(threadID: threadID.uuidString.lowercased())
    }

    /// 返事の生成中に送る: いまの返事を止めてから送る(説明の途中の質問)。
    @discardableResult
    func interruptAndSend(text: String, attachments: [ComposerAttachment] = [], workbookView: WorkbookViewRef? = nil) async -> Bool {
        guard let threadID else { return await send(text: text, attachments: attachments, workbookView: workbookView) }
        // 止まるのを待っている間にサインアウトされたり会話が変わったりしたら、読み直しも送信もしない。
        // 見える返事を書き終えて記録だけを書いている返事は止めない(止めると記録が残らない)。後ろに並べて送る。
        if replyFinishingInBackground { return await send(text: text, attachments: attachments, workbookView: workbookView) }
        let generation = sessionGeneration
        let key = threadID.uuidString.lowercased()
        if await turns.isChatRunning(threadID: key) {
            await turns.interruptChat(threadID: key)
            // 停止が返るまで待つ(区切りは設けない: 止まらなければ送信は前の返事を待つ旨を返す)。
            for _ in 0..<150 {
                if !(await turns.isChatRunning(threadID: key)) { break }
                guard generation == sessionGeneration, self.threadID == threadID else { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard generation == sessionGeneration, self.threadID == threadID else { return false }
            await loadMessages(for: threadID)
            let running = await turns.isChatRunning(threadID: key)
            guard generation == sessionGeneration, self.threadID == threadID else { return false }
            isSending = running
        }
        guard generation == sessionGeneration, self.threadID == threadID else { return false }
        return await send(text: text, attachments: attachments, workbookView: workbookView)
    }

    /// 「送り直す」 on a failed reply (`ChatMessage.isRetryable`): re-runs the learner message behind it.
    @discardableResult
    func retry(assistantMessageID: UUID) async -> Bool {
        guard !isSending else { return false }
        let preparationID = beginSendPreparation()
        defer { endSendPreparation(preparationID) }
        isSending = true
        sendError = nil
        progressLabel = nil
        let generation = sessionGeneration
        // 送り直しを始めた会話。待っている間に履歴から別の会話へ切り替えたら、その会話には手を付けない。
        let originThread = threadID
        do {
            // 待っている間にサインアウトされたら、前の学習者の返事を送り直さない(台帳を書き換える直前に確かめる)。
            let result = try await turns.retryChat(
                assistantMessageID: assistantMessageID.uuidString.lowercased(),
                isCurrent: { @MainActor [weak self] in self?.sessionGeneration == generation }
            )
            guard generation == sessionGeneration else { return false }
            endSendPreparation(preparationID)
            await turns.setProgressHandler(turnID: result.turnID) { [weak self] event in
                Task { @MainActor [weak self] in self?.progressLabel = event.label }
            }
            if let threadID, threadID == originThread {
                await loadMessages(for: threadID)
                guard generation == sessionGeneration, self.threadID == threadID else { return true }
            }
            return true
        } catch is CancellationError {
            // 送り直しを始める前に止められた・サインアウトされた(失敗した返事はそのまま)。
            guard generation == sessionGeneration else { return false }
            if threadID == originThread { isSending = false }
            return false
        } catch {
            chatLog.error("retry failed: \(String(describing: error), privacy: .public)")
            guard generation == sessionGeneration else { return false }
            if threadID == originThread {
                sendError = Self.message(for: error); isSending = false
            }
            return false
        }
    }

    func clearSendError() {
        sendError = nil
    }


    /// Attachments are kept in the App container and staged into the disposable workspace per turn.
    nonisolated static func storeAttachments(_ attachments: [ComposerAttachment]) throws -> [ChatTurns.Attachment] {
        guard !attachments.isEmpty else { return [] }
        let batch = UUID().uuidString.lowercased()
        let directory = ChatTurns.attachmentsRoot.appendingPathComponent(batch, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 途中で書けなかったら、書きかけの束ごと消す(呼び出し側は束を知らないので、送り直すたびに残ってしまう)。
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        var stored: [ChatTurns.Attachment] = []
        for (index, attachment) in attachments.enumerated() {
            let safeName = attachment.filename.replacingOccurrences(of: "/", with: "_")
            let relative = "\(batch)/\(index + 1)-\(safeName)"
            // 入口で一時フォルダに置いた写しを複製する(同じボリュームならクローン)。中身はメモリに載せない(C14)。
            let target = ChatTurns.attachmentsRoot.appendingPathComponent(relative)
            try FileManager.default.copyItem(at: attachment.fileURL, to: target)
            stored.append(ChatTurns.Attachment(
                filename: attachment.filename, contentType: attachment.contentType, bytes: attachment.bytes,
                relativePath: relative, sha256: try fileSHA256(target), kind: attachment.isImage ? "image" : "document"
            ))
            // PDF はゲストの中で読む手段が無いので、最初のページを画像にしてモデルが見られる入力として添える
            // (ほかのページはモデルが struis.document で読む)。縦長のページは読める解像度で分割する。
            // ページの画像はモデルにだけ渡し、学習者の吹き出しには元の PDF だけを出す(`pageImageKind`)。
            if attachment.contentType == "application/pdf" || safeName.lowercased().hasSuffix(".pdf") {
                for page in pdfPageImages(at: target) {
                    let pageName = "\((safeName as NSString).deletingPathExtension)-\(page.name).jpg"
                    stored.append(try write(page.jpeg, relative: "\(batch)/\(index + 1)-\(pageName)", filename: pageName, contentType: "image/jpeg", kind: ChatTurns.Attachment.pageImageKind))
                }
            }
        }
        completed = true
        return stored
    }

    nonisolated private static func write(_ data: Data, relative: String, filename: String, contentType: String, kind: String) throws -> ChatTurns.Attachment {
        try data.write(to: ChatTurns.attachmentsRoot.appendingPathComponent(relative), options: .atomic)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ChatTurns.Attachment(filename: filename, contentType: contentType, bytes: data.count, relativePath: relative, sha256: sha, kind: kind)
    }

    /// ファイルを 1MB ずつ読んで SHA-256 を求める(大きなファイルを丸ごとメモリに載せない)。
    nonisolated static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static let runtimePageImageLock = NSLock()

    /// Older PDF thumbnails may have saved more pixels than their point size
    /// implied. Preserve the saved attachment and normalize only its runtime input.
    nonisolated static func runtimePageImageAttachment(_ attachment: ChatTurns.Attachment) throws -> ChatTurns.Attachment {
        guard attachment.kind == ChatTurns.Attachment.pageImageKind else { return attachment }
        return try autoreleasepool {
            let root = ChatTurns.attachmentsRoot.resolvingSymlinksInPath().standardizedFileURL
            let ownedRoot = StruisPaths.root.resolvingSymlinksInPath().standardizedFileURL
            guard root.path.hasPrefix(ownedRoot.path + "/") else { throw CocoaError(.fileReadNoPermission) }
            let parts = attachment.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw CocoaError(.fileReadNoPermission)
            }
            let sourceURL = try TurnPlan.storedHostURL(ChatTurns.attachmentsRoot.appendingPathComponent(attachment.relativePath).path)
                .resolvingSymlinksInPath().standardizedFileURL
            guard sourceURL.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadNoPermission) }
            let original = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            guard let source = CGImageSourceCreateWithData(original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // Inspect headers only; neither re-encode nor change this reference.
            guard !DocumentReader.fitsModelBudget(width: width, height: height) else { return attachment }
            let sourceHash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
            let relative = "runtime-page-images-v1/\(sourceHash).jpg"
            let cacheURL = root.appendingPathComponent(relative)
            let checksumURL = cacheURL.appendingPathExtension("sha256")

            // Serialize validation/publication so another compose cannot observe a
            // half-published derivative/checksum pair. Data writes remain atomic.
            runtimePageImageLock.lock()
            defer { runtimePageImageLock.unlock() }
            let directory = cacheURL.deletingLastPathComponent()
            // A cache symlink must never redirect publication onto a saved input,
            // even when its target also happens to be in the attachments folder.
            for url in [directory, cacheURL, checksumURL] {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                   attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
            guard directory.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/"),
                  cacheURL.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/"),
                  checksumURL.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/") else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            func hash(_ data: Data) -> String {
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            func boundedJPEG(_ data: Data) -> Bool {
                guard let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetType(image) as String? == "public.jpeg",
                      CGImageSourceGetStatus(image) == .statusComplete,
                      let info = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let w = (info[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                      let h = (info[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                      w > 0, h > 0, max(w, h) <= 1600 else { return false }
                let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                let rotated = (5...8).contains(orientation)
                let expectedWidth = Double(rotated ? height : width) * 1600 / Double(max(width, height))
                let expectedHeight = Double(rotated ? width : height) * 1600 / Double(max(width, height))
                return abs(Double(w) - max(1, expectedWidth)) <= 1 && abs(Double(h) - max(1, expectedHeight)) <= 1
            }
            let jpeg: Data
            if let cached = try? Data(contentsOf: cacheURL, options: .mappedIfSafe),
               let checksum = try? String(contentsOf: checksumURL, encoding: .utf8),
               checksum == hash(cached), boundedJPEG(cached) {
                jpeg = cached
            } else {
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary), max(thumbnail.width, thumbnail.height) <= 1600 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let encoded = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                jpeg = encoded as Data
                guard boundedJPEG(jpeg) else { throw CocoaError(.fileReadCorruptFile) }
                try jpeg.write(to: cacheURL, options: .atomic)
                try hash(jpeg).write(to: checksumURL, atomically: true, encoding: .utf8)
            }
            return ChatTurns.Attachment(
                filename: attachment.filename, contentType: "image/jpeg", bytes: jpeg.count,
                relativePath: relative, sha256: hash(jpeg), kind: attachment.kind
            )
        }
    }

    /// モデルに画像で渡す PDF のページ数(と、1 つの PDF から渡す画像の数)の上限。ほかは struis.document で読む。
    nonisolated static let pdfPageImageLimit = 8

    /// PDF の先頭のページを JPEG にする(cropBox と回転を反映し、Codex の枠に収める。縦長のページは分割する)。
    /// 名前は実際のページ番号で付ける(`p3`、分割したものは `p1-2`)。読めない PDF は空。
    nonisolated static func pdfPageImages(at url: URL, limit: Int = pdfPageImageLimit) -> [(name: String, jpeg: Data)] {
        guard let document = PDFDocument(url: url), !document.isLocked else { return [] }
        var images: [(String, Data)] = []
        for index in 0..<min(document.pageCount, limit) where images.count < limit {
            guard let page = document.page(at: index) else { continue }
            let total = DocumentReader.pagePartCount(page)
            let rendered = DocumentReader.renderPage(page, parts: Set(0..<min(total, limit - images.count)))
            for (part, image) in rendered.images {
                guard let jpeg = autoreleasepool(invoking: { DocumentReader.jpeg(image) }) else { continue }
                images.append((total > 1 ? "p\(index + 1)-\(part + 1)" : "p\(index + 1)", jpeg))
            }
        }
        return images
    }

    /// UIImage.size is measured in points; its JPEG retains the backing pixels.
    /// Keep the PDF input limit independent of the thumbnail's display scale.
    nonisolated static func pdfThumbnailJPEG(_ thumbnail: UIImage) -> Data? {
        guard let pixels = thumbnail.cgImage, thumbnail.size.width > 0, thumbnail.size.height > 0 else { return nil }
        guard max(pixels.width, pixels.height) > 1600 else { return thumbnail.jpegData(compressionQuality: 0.8) }
        let ratio = 1600 / max(thumbnail.size.width, thumbnail.size.height)
        let size = CGSize(width: max(1, floor(thumbnail.size.width * ratio)), height: max(1, floor(thumbnail.size.height * ratio)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            thumbnail.draw(in: CGRect(origin: .zero, size: size))
        }
        return normalized.jpegData(compressionQuality: 0.8)
    }

    /// 教材は大きいことがある(最大 40 MB)。書き込みとハッシュ(と PDF のページの画像化)は主スレッドの外で行う。
    @concurrent
    nonisolated static func storeAttachmentsInBackground(_ attachments: [ComposerAttachment]) async throws -> [ChatTurns.Attachment] {
        try storeAttachments(attachments)
    }

    /// リザルトから質問する時に添える答案の写真。
    /// この会話で、もうその答案の写真を添えたか(学習者のメッセージの添付に `answer-<id>.jpg` がある)。
    nonisolated private static func captureAlreadyAttached(ledger: Ledger, threadID: String, captureID: String) async -> Bool {
        let filename = captureAttachmentFilename(captureID)
        return (try? await ledger.read { db in
            try ChatRepository.messages(db, threadID: threadID).contains { message in
                message.role == "user" && (message.metadata["attachments"]?.arrayValue ?? []).contains { $0["filename"]?.stringValue == filename }
            }
        }) ?? false
    }

    nonisolated private static func captureAttachmentFilename(_ captureID: String) -> String { "answer-\(captureID).jpg" }

    nonisolated private static func captureAttachment(ledger: Ledger, captureID: String) async -> ComposerAttachment? {
        guard let row = try? await ledger.read({ db in try WorkbookCaptureRecord.fetchOne(db, key: captureID) }), !row.imagePath.isEmpty,
              let data = try? Data(contentsOf: StruisPaths.captures.appendingPathComponent(row.imagePath))
        else { return nil }
        return AttachmentIntake.staged(data: data, filename: captureAttachmentFilename(captureID), contentType: row.contentType.isEmpty ? "image/jpeg" : row.contentType, source: .files)
    }

    /// 保存した添付を消す(使われなかった時)。`storeAttachments` の 1 回分は 1 つのフォルダに入っている。
    nonisolated static func removeStoredAttachments(_ stored: [ChatTurns.Attachment]) {
        let batches = Set(stored.compactMap { $0.relativePath.split(separator: "/").first.map(String.init) })
        for batch in batches {
            try? FileManager.default.removeItem(at: ChatTurns.attachmentsRoot.appendingPathComponent(batch, isDirectory: true))
        }
    }

    private static func message(for error: Error) -> String {
        if let ledgerError = error as? LedgerError {
            switch ledgerError.code {
            case "codex_turn_in_progress": return "前の返信を待っています"
            case "codex_app_server_error": return ledgerError.localizedDescription
            default: return ledgerError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
