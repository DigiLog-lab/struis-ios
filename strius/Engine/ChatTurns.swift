import Foundation
import GRDB
import OSLog

private let chatTurnLog = Logger(subsystem: "com.digiloglab.strius", category: "chat-turn")

/// 質問ターン (design §3.3 / §3.4 / §6.3): `run_codex_turn_background` (`codex_runtime.py`)
/// と `post_message` (`routes/threads.py`) の端末移植。準備は `compose`、反映と修復ループは
/// `applyRound`、確定は `finish`。
nonisolated enum ChatTurns {
    static let learnerFacingFailure = "学習の進行を保存できませんでした。もう一度送信してください。"
    static let interruptedText = "停止しました。"
    /// 返事を始められなかった(ターンの行を書けなかった等)。学習者には日本語の一言だけ。
    static let startFailedText = "AI の返事を始められませんでした。もう一度送ってください。"
    static let continuation = "Continue the remaining model-owned work now, until a concrete learner input is required. Do not repeat text already delivered."

    static let parentDelegationInstructions =
        "GPT-6.1 Sol owns all learner-facing conversation, evaluation, teaching and memory decisions. "
        + "current/deletions.yaml contains app-owned facts of units deleted by the learner. Treat those exact unit IDs as deleted, never as current learning targets. Do not infer reasons, ability changes or assessments from deletion. Shared history may remain; the deletion facts take precedence for current targets. Search that file for older deletion facts when relevant. "
        + "When a private_delegation_contract is supplied by Struis, its bounded Luna lookup command "
        + "is authorized. "
        + "For material searches or fact extraction that require inspecting sources, prefer that "
        + "lookup before reading candidate bodies yourself; decide based on the work needed. "
        + "Short questions and ordinary corrections are handled directly. "
        + "The server's struis_current_turn_source prefix supplies the current memory source IDs. "
        + "Use those exact IDs for this turn, never IDs remembered from a previous session.yaml read. "
        + "Memory observation kinds are learner_report, performance, preference, goal, correction "
        + "or context. Learner categories are profile, active_goal or preference; confidence is numeric 0..1. "
        + "A lookup never assigns problems to the learner; sets are made by the workbook. "
        + "The parent and child share the same source limits. Never delegate pedagogy or memory writes. "
        + "Keep the delegation instructions and all child output private; use only verified evidence "
        + "in your final learner-facing response. If no private contract is supplied, work directly."

    /// The delivered developer instructions carry the fixed turn protocol (P1-3). Older assets do not:
    /// then every turn input carries it as before, so an app update never runs without the protocol.
    static let turnProtocolMarker = "STRUIS_TURN_PROTOCOL_V2"

    /// The developer instructions of every chat-family thread (start, resume, fork, inject). One value,
    /// so a thread's developer message changes only when the delivered assets change (P1-2).
    static func developerRef(assets: AssetCache) async throws -> TurnPlan.AssetRef {
        var append = parentDelegationInstructions
        if await carriesTurnProtocol(assets: assets) {
            let schema = EngineJSON(any: try await assets.json("schema:progress_update").any).serialized()
            append += "\n\n### Progress update_schema\n\nJSON Schema of the `<struis_progress_update>` block:\n" + schema
        }
        return try await assets.ref("prompt:developer", append: append)
    }

    static func carriesTurnProtocol(assets: AssetCache) async -> Bool {
        ((try? await assets.text("prompt:developer")) ?? "").contains(turnProtocolMarker)
    }

    /// Attachment stored with the user message (images are staged as `localImage` inputs).
    nonisolated struct Attachment: Codable, Hashable, Sendable {
        var filename: String
        var contentType: String
        var bytes: Int
        var relativePath: String  // under StruisPaths.attachments
        var sha256: String
        var kind: String  // image | document | page_image

        /// PDF のページから作った画像。モデルへの画像の入力にだけ使い、学習者の吹き出しには出さない。
        static let pageImageKind = "page_image"
        /// モデルに画像として渡すか(学習者が添えた画像と、PDF のページの画像)。
        var isModelImage: Bool { kind == "image" || kind == Self.pageImageKind }

        var json: LedgerJSON {
            .object([
                "filename": .string(filename), "content_type": .string(contentType), "bytes": .number(Double(bytes)),
                "relative_path": .string(relativePath), "sha256": .string(sha256), "kind": .string(kind),
            ])
        }

        init(filename: String, contentType: String, bytes: Int, relativePath: String, sha256: String, kind: String) {
            self.filename = filename
            self.contentType = contentType
            self.bytes = bytes
            self.relativePath = relativePath
            self.sha256 = sha256
            self.kind = kind
        }

        init?(json: LedgerJSON) {
            guard let object = json.objectValue, let filename = object["filename"]?.stringValue else { return nil }
            self.init(
                filename: filename, contentType: object["content_type"]?.stringValue ?? "application/octet-stream",
                bytes: object["bytes"]?.intValue ?? 0, relativePath: object["relative_path"]?.stringValue ?? "",
                sha256: object["sha256"]?.stringValue ?? "", kind: object["kind"]?.stringValue ?? "document"
            )
        }
    }

    /// Everything a chat turn carries across rounds.
    nonisolated struct State: Sendable {
        var turnID: String
        var threadID: String
        var userMessageID: String
        var assistantMessageID: String
        var learnerID: String
        var text: String
        var attachments: [Attachment]
        var workbookView: LedgerJSON?
        var codexThreadID: String?
        var progressBefore: ProgressState
        var progressAfter: ProgressState
        /// 小単元の会話なら、その小単元。段階 2 の例題はここへ保存する。
        var subunitID: String? = nil
        /// 段階 2 の起動: 返信に `<struis_workbook_example>` が要る。
        var expectsExample = false
        var exampleProblem: String?
        /// 段階 2 の準備OK(`<struis_workbook_example_ready/>`)がこのターンの返信にあった。
        var exampleReady = false
        var deliveredParts: [String] = []
        var checks: [LedgerJSON] = []
        var embeddedMemoryPayload: String?
        var embeddedMemoryError: String?
        var workbookProposal: LedgerJSON?
        var workbookHint: LedgerJSON?
        var visibleText = ""
        var candidate = ""
        var round = 0
        var codexTurnID: String?
        var executions: [LedgerJSON] = []
        var memoryQueueFiles: [TurnOutcome.CollectedFile] = []
        var rateLimits: LedgerJSON?
        /// The memory evidence (per file) the thread holds after this turn's input (nil: not tracked).
        /// Recorded for the Codex thread once the turn completes, so the next turn sends only changes (P1-3).
        var deliveredMemory: DeliveredMemory?
        /// The learner-facing reply of a rejected round. A repair round returns only the private
        /// blocks; the reply already written is kept (B5).
        var rejectedCandidate: String?

        /// The Codex thread's working directory (P1-1), or this turn's own before the thread exists.
        var workspace: URL {
            HyotanBoot.workspaceRoot.appendingPathComponent(
                codexThreadID.flatMap { TurnPlan.threadWorkspaceKey(codexThreadID: $0) } ?? turnID, isDirectory: true)
        }
    }

    nonisolated enum RoundResult: Sendable {
        case done
        case again(text: String)
        case failed(String, detail: String? = nil)
    }

    static var desk: URL { StruisPaths.memory.appendingPathComponent("tutor_desk", isDirectory: true) }
    static var attachmentsRoot: URL { StruisPaths.root.appendingPathComponent("attachments", isDirectory: true) }

    // MARK: - Compose (§3.4 staging)

    static func compose(ledger: Ledger, assets: AssetCache, state: inout State, roundText: String?) async throws -> TurnPlan {
        let planID = state.turnID
        let learnerID = state.learnerID
        let workspaceKey = state.codexThreadID.flatMap { TurnPlan.threadWorkspaceKey(codexThreadID: $0) }
        let guestRoot = HyotanBoot.workspaceRoot.appendingPathComponent(workspaceKey ?? planID, isDirectory: true).path

        let snapshot = state
        try await ledger.withMemory { db in
            let latest = try ChatRepository.latestProgress(db)?.revision ?? 0
            guard latest == snapshot.progressBefore.revision else { throw LedgerError.conflict("学習の進行が更新されています。もう一度送信してください。") }
            // Canonical memory in the App container; the workspace gets a copy per turn.
            try FileManager.default.createDirectory(at: desk, withIntermediateDirectories: true)
            _ = try TutorMemory.ensureTutorMemoryFiles(desk: desk, learnerID: learnerID)
            try TutorMemory.stageSession(
                desk: desk, learnerID: learnerID, threadID: snapshot.threadID, turnRunID: snapshot.turnID,
                userMessageID: snapshot.userMessageID, latestUserText: snapshot.text
            )
            // plans/current.yaml mirrors the authoritative progress for inspection (mirror_state).
            let plansURL = desk.appendingPathComponent("plans/current.yaml")
            var plans = (try? EngineYAML.load(String(contentsOf: plansURL, encoding: .utf8)))?.objectValue ?? EngineObject()
            plans["learning_progress"] = snapshot.progressBefore.json
            try EngineYAML.dump(.object(plans)).write(to: plansURL, atomically: true, encoding: .utf8)

            // Recent thread history from the ledger.
        }
        let currentThreadID = state.threadID
        let (threadRows, messagesByThread) = try await ledger.read { db in try ChatRepository.contextRows(db, currentThreadID: currentThreadID) }
        let (selected, crossThread) = LearnerText.selectContextThreadRows(currentThreadID: state.threadID, latestUserText: state.text, threadRows: threadRows)
        var messageRows: [MessageRow] = []
        for row in selected { messageRows.append(contentsOf: messagesByThread[row.id] ?? []) }
        let history = LearnerText.renderRecentThreadHistory(
            currentThreadID: state.threadID, threadRows: selected, messageRows: Array(messageRows.prefix(90)),
            latestUserText: state.text, crossThreadContextEnabled: crossThread
        )

        var files: [TurnPlan.FileSpec] = [
            TurnPlan.FileSpec(path: "AGENTS.md", asset: "prompt:agents"),
            // 資料の読み方(Codex の Skill。本文は使う時だけモデルが読む)。
            TurnPlan.FileSpec(path: ".agents/skills/struis-document/SKILL.md", asset: "skill:struis_document"),
            TurnPlan.FileSpec(path: "scripts/struis_delegate.py", asset: "prompt:delegate_py", executable: true),
            TurnPlan.FileSpec(path: "scripts/struis_tutor_memory.py", asset: "prompt:tutor_memory_py", executable: true),
            TurnPlan.FileSpec(path: "scripts/struis_reply_lint.py", asset: "prompt:reply_lint_py", executable: true),
            TurnPlan.FileSpec(path: "struis_context/recent_thread_history.md", inline: history),
        ]
        // 添付は画像の入力・inbox の写し・manifest にする(縦長の分割、1 ターンの枚数の上限、PDF のページ数と
        // struis.document の案内は `AttachmentStaging`)。古い PDF のページ画像は実行時の写しだけ直す。分割を含むので主スレッドの外で。
        let savedAttachments = state.attachments
        let (learnerForManifest, threadForManifest, messageForManifest) = (learnerID, state.threadID, state.userMessageID)
        let staging = try await Task.detached(priority: .userInitiated) {
            try AttachmentStaging.stage(
                savedAttachments,
                learnerID: learnerForManifest, threadID: threadForManifest, messageID: messageForManifest
            )
        }.value
        let images = staging.images
        let manifestPath = staging.manifestPath
        let documentCopies = staging.copies
        if let manifestPath, let manifest = staging.manifest {
            files.append(TurnPlan.FileSpec(path: manifestPath, inline: manifest))
        }

        let inbox = ".struis_delegations/" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let astra = await assets.model("astra")
        let luna = await assets.model("luna")
        let existingThread = state.codexThreadID
        let thread = TurnPlan.ThreadSpec(
            codexThreadID: existingThread, mode: existingThread == nil ? .start : .resume, cwd: guestRoot,
            model: astra.model, effort: astra.effort, ephemeral: false,
            baseInstructions: try await assets.ref("prompt:base"),
            developerInstructions: try await developerRef(assets: assets),
            developerText: nil, injectDeveloperOnResume: existingThread != nil && roundText == nil,
            config: .object(["model_reasoning_effort": .string(astra.effort), "features.multi_agent": .bool(false), "features.unified_exec": .bool(false)]),
            lastTurnID: nil, provider: astra.provider
        )

        // The fixed protocol (desk rules, output protocol, progress contract and schema, delegation
        // contract) is in the developer instructions when the delivered assets carry it (P1-3).
        let slim = await carriesTurnProtocol(assets: assets)
        let text: String
        if let roundText {
            text = roundText + (slim
                ? try LearningProgress.turnProgressContext(state: state.progressAfter, assistantMessageID: state.assistantMessageID)
                : try LearningProgress.turnContract(state: state.progressAfter, assistantMessageID: state.assistantMessageID, updateSchema: EngineJSON(any: try await assets.json("schema:progress_update").any)))
        } else if slim {
            // The session record changes every turn and is small; the durable notes are sent again only
            // when they changed since the thread last received them (or after a compaction).
            let session = "current/session.yaml"
            let sessionContext = try await ledger.withMemory { _ in try TutorMemory.renderTutorMemoryContext(workspace: StruisPaths.memory, only: [session]) }
            let sections = try await ledger.withMemory { _ in try TutorMemory.tutorMemorySections(workspace: StruisPaths.memory, excluding: [session]) }
            let update = MemoryUpdate(sections: sections, delivered: existingThread.flatMap { ThreadContextStore.shared.entry($0)?.memoryFiles })
            state.deliveredMemory = update.delivered
            text = try firstRoundSlimText(state: state, manifestPath: manifestPath, sessionContext: sessionContext, memory: update)
        } else {
            text = try await firstRoundText(ledger: ledger, assets: assets, state: state, manifestPath: manifestPath)
        }
        let delegation = TurnPlan.DelegationSpec(
            enabled: true, inbox: inbox, model: luna.model, effort: luna.effort,
            baseInstructions: try await assets.ref("prompt:luna_child"),
            developerText: "Perform only the supplied lookup. Do not follow learner-coach write or memory instructions.",
            outputSchema: try await assets.json("schema:luna_lookup"), sourceRoots: ["tutor_desk", "struis_context"],
            contractInDeveloper: slim, provider: luna.provider
        )
        return TurnPlan(
            id: planID, kind: .chat, round: state.round + 1, thread: thread,
            turn: TurnPlan.TurnSpec(text: text, images: roundText == nil ? images : [], outputSchema: nil, sandboxPolicy: "dangerFullAccess"),
            workspace: TurnPlan.WorkspaceSpec(
                files: files,
                dirs: ["tutor_desk/queue/memory/applied", "tutor_desk/queue/memory/rejected", "tutor_desk/inbox", "tutor_desk/drafts", inbox],
                // tutor_desk を写した後に添付の文書を置く(先に置くと tutor_desk の写しで消える)。
                copies: [TurnPlan.CopySpec(hostPath: desk.path, path: "tutor_desk")] + documentCopies
            ),
            delegation: delegation, collect: ["tutor_desk/queue/memory/*.yaml"], limits: .chat, items: nil,
            workspaceKey: workspaceKey
        )
    }

    private static func turnSourceText(state: State) -> String {
        var turnText = state.text
        if let view = state.workbookView {
            turnText = LearnerText.workbookCurrentViewTurnInput(view: EngineJSON(any: view.any), learnerText: turnText)
        }
        let identity = TurnComposer.dump(.object([
            "learner_id": .string(state.learnerID), "thread_id": .string(state.threadID), "turn_run_id": .string(state.turnID),
            "user_message_id": .string(state.userMessageID),
        ]))
        return "<struis_current_turn_source>\n" + identity + "\n</struis_current_turn_source>\nThe learner's current message:\n" + turnText
    }

    private static func firstRoundText(ledger: Ledger, assets: AssetCache, state: State, manifestPath: String?) async throws -> String {
        var text = turnSourceText(state: state)
        // The private desk context (memory evidence + output protocol) rides with the first round.
        let memoryContext = (try? TutorMemory.renderTutorMemoryContext(workspace: StruisPaths.memory)) ?? ""
        text += "\n\n" + LearnerText.struisContextInjectedItemText(staged: StagedContext(tutorDeskManifestRelativePath: manifestPath, markdownRelativePath: nil, tutorMemoryContext: memoryContext))
        text += try LearningProgress.turnContract(state: state.progressBefore, assistantMessageID: state.assistantMessageID, updateSchema: EngineJSON(any: try await assets.json("schema:progress_update").any))
        return text
    }

    /// Only what changes per turn (P1-3): identifiers, the learner's message and screen, the latest
    /// attachment manifest, the memory evidence when it changed, and the progress context.
    private static func firstRoundSlimText(state: State, manifestPath: String?, sessionContext: String, memory: MemoryUpdate) throws -> String {
        var text = turnSourceText(state: state)
        var lines: [String] = []
        if let manifestPath { lines.append("The latest attachment inbox manifest is `\(manifestPath)`.") }
        lines += memory.lines(sessionContext: sessionContext)
        if !lines.isEmpty { text += "\n\n" + lines.joined(separator: "\n") }
        text += try LearningProgress.turnProgressContext(state: state.progressBefore, assistantMessageID: state.assistantMessageID)
        return text
    }

    /// What of the durable memory a turn sends (P1-3). Sent input is never rewritten: a thread first gets
    /// every file; later turns append only the files whose model view changed, and name the files that are
    /// no longer part of the evidence. After a compaction, a fork or a restored history the thread has no
    /// record, so it gets everything again.
    nonisolated struct MemoryUpdate: Equatable {
        enum Mode: Equatable {
            case full
            case changes(changed: [TutorMemory.MemorySection], removed: [String])
            case unchanged
        }

        let mode: Mode
        let sections: [TutorMemory.MemorySection]
        let delivered: DeliveredMemory

        init(sections: [TutorMemory.MemorySection], delivered previous: [String: String]?) {
            self.sections = sections
            var files: [String: String] = [:]
            for section in sections { files[section.path] = section.digest }
            delivered = DeliveredMemory(files: files)
            guard let previous else {
                mode = .full
                return
            }
            let changed = sections.filter { previous[$0.path] != $0.digest }
            let removed = previous.keys.filter { files[$0] == nil }.sorted()
            mode = changed.isEmpty && removed.isEmpty ? .unchanged : .changes(changed: changed, removed: removed)
        }

        func lines(sessionContext: String) -> [String] {
            var lines: [String] = []
            switch mode {
            case .full:
                let body = [sessionContext, TutorMemory.render(sections)].filter { !$0.isEmpty }.joined(separator: "\n\n")
                if !body.isEmpty { lines += ["<tutor_memory_evidence>", body, "</tutor_memory_evidence>"] }
            case .changes(let changed, let removed):
                let body = [sessionContext, TutorMemory.render(changed)].filter { !$0.isEmpty }.joined(separator: "\n\n")
                if !body.isEmpty { lines += ["<tutor_memory_evidence>", body, "</tutor_memory_evidence>"] }
                var note = "Tutor Desk memory update: the files above replace their earlier versions in this conversation"
                if !changed.isEmpty { note += " (" + changed.map { "`\($0.path)`" }.joined(separator: ", ") + ")" }
                note += ". Every other file is unchanged since its latest version in this conversation."
                if !removed.isEmpty {
                    note += " No longer part of the memory evidence (deleted or superseded; do not rely on them): "
                        + removed.map { "`\($0)`" }.joined(separator: ", ") + "."
                }
                lines.append(note)
            case .unchanged:
                if !sessionContext.isEmpty { lines += ["<tutor_memory_evidence>", sessionContext, "</tutor_memory_evidence>"] }
                lines.append("Tutor Desk memory evidence other than current/session.yaml: unchanged since the latest full <tutor_memory_evidence> in this conversation.")
            }
            return lines
        }
    }

    // MARK: - Apply one round (§3.3 repair loop)

    static func applyRound(ledger: Ledger, state: inout State, outcome: TurnOutcome) async -> RoundResult {
        state.round += 1
        state.codexThreadID = outcome.codexThreadID ?? state.codexThreadID
        state.codexTurnID = outcome.codexTurnID ?? state.codexTurnID
        state.executions.append(contentsOf: outcome.executions)
        state.memoryQueueFiles.append(contentsOf: outcome.files)
        state.rateLimits = outcome.rateLimits ?? state.rateLimits
        switch outcome.status {
        case .interrupted: return .failed(interruptedText)
        case .failed: return .failed(outcome.error ?? "Codex の応答を受け取れませんでした", detail: outcome.errorDetail)
        case .completed: break
        }
        do {
            let (afterProgress, progressRaw) = try LearningProgress.extractUpdate(outcome.finalText.trimmingCharacters(in: .whitespacesAndNewlines))
            let (afterMemory, memoryPayload, memoryError) = TutorMemory.extractEmbeddedMemoryUpdate(afterProgress)
            let (afterExampleProblem, example) = LearnerText.extractWorkbookExample(afterMemory)
            let (afterExample, exampleReady) = LearnerText.extractWorkbookExampleReady(afterExampleProblem)
            if state.expectsExample, example == nil, state.exampleProblem == nil {
                throw LedgerError.invalid("The reply must include the worked example as <struis_workbook_example>{\"prompt\": \"<the example problem statement in Japanese>\"}</struis_workbook_example> after the visible reply.")
            }
            let (afterBlocks, proposal, hint) = LearnerText.extractWorkbookBlocks(afterExample)
            var candidate = LearnerText.sanitizeLearnerFacingText(afterBlocks)
            // A repair round returns only the corrected private blocks; keep the reply already written (B5).
            if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let kept = state.rejectedCandidate {
                candidate = kept
            }
            let visible = (state.deliveredParts + [candidate]).joined(separator: "\n\n")
            let ids = Self.referencedMessageIDs(progressRaw)
            let sources = try await ledger.read { db in try ChatRepository.sourceMessages(db, ids: ids) }
            let progressAfter = state.progressAfter
            let userMessageID = state.userMessageID
            let assistantMessageID = state.assistantMessageID
            let next = try LearningProgress.applyUpdate(
                before: progressAfter, raw: progressRaw, reply: visible, userMessageID: userMessageID,
                assistantMessageID: assistantMessageID, sourceMessages: sources
            )
            state.checks.append(.object(["round": .number(Double(state.round)), "accepted": .bool(true)]))
            state.rejectedCandidate = nil
            state.progressAfter = next
            if (memoryPayload != nil && memoryPayload != "NO_UPDATE") || state.embeddedMemoryPayload == nil {
                state.embeddedMemoryPayload = memoryPayload
            }
            state.embeddedMemoryError = memoryError ?? state.embeddedMemoryError
            if let proposal { state.workbookProposal = state.workbookProposal ?? LedgerJSON(any: proposal) }
            if let hint { state.workbookHint = state.workbookHint ?? LedgerJSON(any: hint) }
            if let example { state.exampleProblem = state.exampleProblem ?? example }
            if exampleReady { state.exampleReady = true }
            state.candidate = candidate
            state.visibleText = visible
            let disposition = (progressRaw["disposition"] as? String) ?? ""
            if disposition != "continue" { return .done }
            state.deliveredParts.append(candidate)
            if state.round >= 5 { return .failed(learnerFacingFailure) }
            return .again(text: continuation)
        } catch {
            let detail = String(describing: error)
            let round = state.round
            state.checks.append(.object(["round": .number(Double(round)), "accepted": .bool(false), "error": .string(String(detail.prefix(2000)))]))
            chatTurnLog.error("round \(round) rejected: \(detail, privacy: .public)")
            if state.round >= 5 { return .failed(learnerFacingFailure, detail: "validation rejected \(round) rounds: " + String(detail.prefix(300))) }
            // Keep the learner-facing reply and ask only for the private blocks (B5): rewriting the
            // whole reply cost a full model call of 45–65 s for nearly the same text.
            let written = visibleReply(of: outcome.finalText)
            if !written.isEmpty { state.rejectedCandidate = written }
            if state.rejectedCandidate != nil {
                // Keep every private block that was valid, so the repair regenerates only what failed.
                let kept = keepValidBlocks(of: outcome.finalText, state: &state)
                var requested = "exactly one <struis_progress_update>"
                if !kept.contains("struis_memory_update") { requested += " and one <struis_memory_update>" }
                var text = "Your private blocks failed validation, so nothing has been delivered or saved yet. Struis keeps the learner-facing reply you already wrote; do NOT write the reply again. "
                if !kept.isEmpty {
                    text += "Struis also kept your valid " + kept.map { "<\($0)>" }.joined(separator: ", ") + "; do NOT send them again. "
                }
                text += "Return ONLY the corrected private blocks: \(requested) (and a <struis_workbook_*> block only if the correction needs it). "
                    + "To change an existing goal you may send only what changes, instead of the whole goal in \"goals\": "
                    + "\"goal_changes\": [{\"id\": \"<existing goal id>\", <only the changed fields>, \"add_evidence\": [<new evidence>]}] (omitted fields keep their saved values). "
                    + "Progress quotes must be copied from the reply you already wrote. The current base_revision is \(state.progressAfter.revision). "
                    + "Do not change grading standards to bypass validation. Validation error: " + String(detail.prefix(2000))
                return .again(text: text)
            }
            return .again(text:
                "Your reply and progress update have NOT been delivered or saved. Repair both and return a complete reply with both private blocks. "
                + "Do not change grading standards to bypass validation. Validation error: " + String(detail.prefix(2000)))
        }
    }

    /// Private blocks of a rejected round that are valid on their own (memory update, workbook example,
    /// proposal, hint) are kept for the accepted round, as an accepted round keeps the first ones it saw.
    /// Returns the kept tags. The progress update is never kept: it is what the repair replaces.
    static func keepValidBlocks(of text: String, state: inout State) -> [String] {
        var kept: [String] = []
        let (_, memoryPayload, memoryError) = TutorMemory.extractEmbeddedMemoryUpdate(text)
        if let memoryPayload, memoryError == nil, state.embeddedMemoryPayload == nil {
            state.embeddedMemoryPayload = memoryPayload
            kept.append("struis_memory_update")
        }
        let (afterExampleProblem, example) = LearnerText.extractWorkbookExample(text)
        if let example, state.exampleProblem == nil {
            state.exampleProblem = example
            kept.append("struis_workbook_example")
        }
        let (afterExample, ready) = LearnerText.extractWorkbookExampleReady(afterExampleProblem)
        if ready, !state.exampleReady {
            state.exampleReady = true
            kept.append("struis_workbook_example_ready")
        }
        let (_, proposal, hint) = LearnerText.extractWorkbookBlocks(afterExample)
        if let proposal, state.workbookProposal == nil {
            state.workbookProposal = LedgerJSON(any: proposal)
            kept.append("struis_workbook_proposal")
        }
        if let hint, state.workbookHint == nil {
            state.workbookHint = LedgerJSON(any: hint)
            kept.append("struis_workbook_hint")
        }
        return kept
    }

    /// The learner-facing part of a model reply with every private block removed (complete or not).
    static func visibleReply(of text: String) -> String {
        var value = text
        for tag in ["struis_progress_update", "struis_memory_update"] {
            if let regex = try? NSRegularExpression(pattern: "<\(tag)>[\\s\\S]*?(</\(tag)>|$)", options: [.caseInsensitive]) {
                value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
            }
        }
        value = LearnerText.extractWorkbookExample(value).text
        value = LearnerText.extractWorkbookExampleReady(value).text
        value = LearnerText.extractWorkbookBlocks(value).text
        return LearnerText.sanitizeLearnerFacingText(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func referencedMessageIDs(_ raw: JSONObject) -> Set<String> {
        var ids = Set<String>()
        for goal in raw["goals"] as? [JSONObject] ?? [] {
            for evidence in goal["evidence"] as? [JSONObject] ?? [] {
                if let id = evidence["message_id"] as? String { ids.insert(id) }
            }
        }
        for change in raw["goal_changes"] as? [JSONObject] ?? [] {
            for evidence in change["add_evidence"] as? [JSONObject] ?? [] {
                if let id = evidence["message_id"] as? String { ids.insert(id) }
            }
        }
        for attempt in raw["attempts"] as? [JSONObject] ?? [] {
            if let id = attempt["submission_id"] as? String { ids.insert(id) }
        }
        return ids
    }

    // MARK: - Finish (commit reply, progress, memory, workbook blocks)

    nonisolated struct Finished: Sendable {
        var proposalRequest: String?
        /// 準備OKで次に要る一枚(類題、または例題に戻る前の段)を先回りで組む(待ち時間の体験 §3.1)。
        var prefetchSetID: String?
    }

    static func finish(ledger: Ledger, state: State) async throws -> Finished {
        let memorySnapshot = await applyMemory(ledger: ledger, state: state)
        return try await ledger.commit { db in
            guard let assistant = try MessageRecord.fetchOne(db, key: state.assistantMessageID) else { throw LedgerError.notFound("message") }
            var machine = try WorkbookMachine(loading: db)
            let (events, finished) = try finishEvents(db, state: state, memorySnapshot: memorySnapshot, assistant: assistant, machine: &machine)
            return (machine.events + events, finished)
        }
    }

    /// 1. Memory: queue the embedded block, then validate and apply the queue against the canonical desk.
    static func applyMemory(ledger: Ledger, state: State) async -> LedgerJSON {
        let turnWorkspace = state.workspace
        let queue = turnWorkspace.appendingPathComponent("tutor_desk/queue/memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        var memoryError = state.embeddedMemoryError
        var embeddedPath: String?
        if let payload = state.embeddedMemoryPayload, payload != "NO_UPDATE" {
            do {
                let url = try TutorMemory.queueEmbeddedMemoryUpdate(desk: turnWorkspace.appendingPathComponent("tutor_desk", isDirectory: true), turnRunID: state.turnID, payload: payload)
                embeddedPath = String(url.path.dropFirst(turnWorkspace.path.count + 1))
            } catch {
                memoryError = String(describing: error).prefix(1000).description
            }
        }
        var memoryUpdate: LedgerJSON = .emptyObject
        do {
            memoryUpdate = try await ledger.withMemory { db in
                let latest = try ProgressRevisionRecord.order(Column("revision").desc).fetchOne(db)?.revision ?? 0
                guard latest == state.progressBefore.revision else { throw LedgerError.conflict("学習の進行が更新されています。もう一度送信してください。") }
                guard try MessageRecord.fetchOne(db, key: state.userMessageID) != nil || state.subunitID.map({ try? WorkbookSubunitRecord.fetchOne(db, key: $0) }).flatMap({ $0 }) != nil else { throw LedgerError.notFound("会話") }
                var validRefs = Set<String>()
                for message in try MessageRecord.filter(Column("status") == "completed").fetchAll(db) { validRefs.insert("chat_message:" + message.id) }
                for attempt in try WorkbookAttemptRecord.fetchAll(db) { validRefs.insert("attempt:" + attempt.id) }
                let result = try TutorMemory.applyTutorMemoryQueue(
                    queueDirectory: queue, desk: desk, workspaceRootForRelativePaths: turnWorkspace, learnerID: state.learnerID,
                    threadID: state.threadID, turnRunID: state.turnID, userMessageID: state.userMessageID
                ) { type, id in validRefs.contains(type + ":" + id) }
                return LedgerJSON(any: result.json.anyValue)
            }
        } catch {
            memoryUpdate = .object(["status": .string("failed"), "error": .string(String(describing: error).prefix(1000).description)])
        }
        var memoryObject = memoryUpdate.objectValue ?? [:]
        memoryObject["embedded_submission_present"] = .bool(state.embeddedMemoryPayload != nil)
        memoryObject["embedded_submission_no_update"] = .bool(state.embeddedMemoryPayload == "NO_UPDATE")
        memoryObject["embedded_submission_path"] = embeddedPath.map(LedgerJSON.string) ?? .null
        memoryObject["embedded_submission_error"] = memoryError.map(LedgerJSON.string) ?? .null
        return .object(memoryObject)
    }

    /// 2. Reply + progress + thread mapping, as events for one transaction. Workbook changes go to `machine`
    /// (the caller commits `machine.events` before these). `assistant` is the pending reply row.
    /// 小単元の会話の返事が出した準備OKを、今の例題の回に記録する(§13.13 の 5)。初めて記録した時は、
    /// 「先に進む」の後に要る一枚(類題、例題に戻る前の段ならその段)を先回りの行として足し、その id を返す。
    static func markExampleReady(machine: inout WorkbookMachine, state: State) -> String? {
        guard let subunitID = state.subunitID ?? machine.subunitID(threadID: state.threadID) else { return nil }
        // この返事の準備OKはもう記録した(返事の途中で先に記録した後、学習者が先に進んで「例題に戻る」で次の回に
        // 入っていても、前の回の返事の準備OKを新しい回に付けない)。
        if machine.subunits[subunitID]?.metadata["example_ready"]?["message_id"]?.stringValue == state.assistantMessageID { return nil }
        let wasReady = machine.subunits[subunitID].map(WorkbookMachine.isExampleReady) ?? true
        machine.setExampleReady(subunitID: subunitID, messageID: state.assistantMessageID)
        guard !wasReady, let row = machine.subunits[subunitID], WorkbookMachine.isExampleReady(row) else { return nil }
        let next = row.metadata["return_stage"]?.intValue.flatMap { WorkbookMachine.learnerStages.contains($0) ? $0 : nil } ?? 3
        return machine.insertPrefetchedSet(subunitID: subunitID, stage: next)
    }

    static func finishEvents(
        _ db: Database, state: State, memorySnapshot: LedgerJSON, assistant pending: MessageRecord, machine: inout WorkbookMachine
    ) throws -> ([LedgerEvent], Finished) {
        let plainText = LearnerText.sanitizeLearnerFacingText(state.visibleText)
        let blocks: LedgerJSON = plainText.isEmpty ? .emptyArray : .array([.object(["kind": .string("text"), "payload": .object(["text": .string(plainText)])])])
        let trace: LedgerJSON = .object([
            "save_status": .string("saved"), "before_state": LedgerJSON(any: state.progressBefore.json.anyValue),
            "after_state": LedgerJSON(any: state.progressAfter.json.anyValue), "checks": .array(state.checks),
        ])
        let proposalRequest = (state.workbookProposal?["request"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hintIDs = (state.workbookHint?["problem_ids"]?.arrayValue ?? []).compactMap(\.stringValue).prefix(20)
        var assistant = pending
        do {
            let latest = try ChatRepository.latestProgress(db)?.revision ?? 0
            guard latest == state.progressBefore.revision else { throw LedgerError.conflict("学習の進行が更新されています。もう一度送信してください。") }
            var events: [LedgerEvent] = []
            var metadata: [String: LedgerJSON] = [
                "handled_as": .string("codex_app_server"), "codex_turn_id": state.codexTurnID.map(LedgerJSON.string) ?? .null,
                // 実行監査に残った実行先(Claude は API キー)。古い記録は ChatGPT。
                "billing_source": .string(state.executions.lazy.compactMap { $0["billing_source"]?.stringValue }.first ?? "byo_chatgpt"),
                "learning_progress_available": .bool(true), "learning_progress": trace,
                "tutor_memory_update": memorySnapshot, "executions": .array(state.executions),
            ]
            if !hintIDs.isEmpty { machine.markHints(problemIDs: Array(hintIDs)) }
            if let subunitID = state.subunitID, let example = state.exampleProblem {
                machine.setExampleProblem(subunitID: subunitID, prompt: example, messageID: state.assistantMessageID)
            }
            // 準備OKは起動の返事に限らず、小単元の会話のどの返事でも受ける(学習者の答えを見て判断するので)。
            // 返事の途中で書き終わった時に先に記録していれば(`applyExampleReadyEarly`)、ここでは何もしない。
            let prefetchSetID = state.exampleReady ? markExampleReady(machine: &machine, state: state) : nil
            var proposalID: String?
            if !proposalRequest.isEmpty {
                proposalID = machine.insertProposal(request: proposalRequest, threadID: state.threadID, messageID: state.assistantMessageID)
                metadata["workbook_proposal_id"] = .string(proposalID!)
            }
            assistant.metadata = WorkbookMachine.merge(assistant.metadata, metadata)
            events.append(ChatRepository.completeMessage(assistant, plainText: plainText, blocks: blocks, metadataPatch: [:]))
            events.append(contentsOf: try foldInterruptedReplies(db, threadID: state.threadID, before: state.assistantMessageID))
            events.append(ChatRepository.saveProgress(state.progressAfter, messageID: state.assistantMessageID, turnID: state.turnID))
            if let thread = try ThreadRecord.fetchOne(db, key: state.threadID) {
                events.append(ChatRepository.touchThread(thread, preview: plainText.isEmpty ? nil : plainText))
            }
            if let codexThreadID = state.codexThreadID {
                let existing = try CodexThreadRecord.fetchOne(db, key: state.threadID)
                events.append(ChatRepository.mapCodexThread(threadID: state.threadID, codexThreadID: codexThreadID, lastTurnID: state.codexTurnID, existing: existing))
            }
            return (events, Finished(proposalRequest: proposalID == nil ? nil : proposalRequest, prefetchSetID: prefetchSetID))
        }
    }

    /// Replies cut off by a later message (「停止しました。」) are folded once a newer reply arrives (D15,
    /// P4-4): the new reply answers those messages too, and a leftover 「送り直す」 would only resend them.
    static func foldInterruptedReplies(_ db: Database, threadID: String, before replyID: String) throws -> [LedgerEvent] {
        var candidates: [MessageRecord] = []
        for row in try ChatRepository.messages(db, threadID: threadID) {
            if row.id == replyID { break }
            guard row.role == "assistant" else { continue }
            if row.status == "completed" { candidates.removeAll(); continue }
            if row.status == "failed", row.plainText == interruptedText, row.metadata["folded"]?.boolValue != true { candidates.append(row) }
        }
        return candidates.map { row in
            var folded = row
            folded.metadata = WorkbookMachine.merge(folded.metadata, ["folded": .bool(true), "retryable": .bool(false)])
            return .upsert("message.folded", folded)
        }
    }

    /// `detail` は失敗の理由(診断の文)。学習者向けの `error` とは別に `metadata.error_detail` に残し、吹き出しに小さく出す(3.5)。
    static func fail(ledger: Ledger, state: State, error: String, detail: String? = nil) async {
        try? await ledger.commit { db in
            guard let assistant = try MessageRecord.fetchOne(db, key: state.assistantMessageID), assistant.status == "pending" else { return ([], ()) }
            var row = assistant
            if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty, detail != error {
                row.metadata = WorkbookMachine.merge(row.metadata, ["error_detail": .string(String(detail.prefix(600)))])
            }
            // A reply to a subunit kickoff is recovered by the subunit's one 「もう一度始める」 (P4-4):
            // no second 「送り直す」 on the bubble.
            let user = try MessageRecord.fetchOne(db, key: state.userMessageID)
            let kickoff = user?.metadata["hidden"]?.boolValue == true && user?.metadata["source"]?.stringValue == "struis_kickoff"
            row.metadata = WorkbookMachine.merge(row.metadata, ["learning_progress": .object([
                "save_status": .string("rejected"), "before_state": LedgerJSON(any: state.progressBefore.json.anyValue),
                "after_state": LedgerJSON(any: state.progressBefore.json.anyValue), "checks": .array(state.checks),
                "public_issues": .array([.string("返信と進行の整合性を確認できなかったため、進行を更新していません。")]),
            ]), "retryable": .bool(!kickoff)])
            var events = [ChatRepository.failMessage(row, error: error)]
            if let codexThreadID = state.codexThreadID {
                let existing = try CodexThreadRecord.fetchOne(db, key: state.threadID)
                events.append(ChatRepository.mapCodexThread(threadID: state.threadID, codexThreadID: codexThreadID, lastTurnID: nil, existing: existing))
            }
            return (events, ())
        }
    }
}
