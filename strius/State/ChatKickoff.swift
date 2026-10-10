import Foundation
import GRDB
import OSLog

private let kickoffLog = Logger(subsystem: "com.digiloglab.strius", category: "chat-kickoff")

/// 学習者が打つ前にモデルが話し始めるターン(§13.12 / §13.13)。起動メッセージは台帳に残すが
/// 学習者には見せない(`messages.metadata.hidden`)。どれも台帳で冪等にし、開き直し・再起動・
/// 二重タップで重複させない。
extension TurnCoordinator {
    nonisolated enum KickoffResult: Sendable, Equatable {
        /// モデルのターンを起こした。
        case started
        /// この段はもう起こしてある。
        case alreadyStarted
        /// 段階 1・2 ではない(起こさない)。
        case notNeeded
        /// 同じ会話で返事を待っている。終わってから起こし直す。
        case busy
        case failed(String)
    }

    // MARK: - 小単元 段階 1・2

    /// 小単元ごとの会話 thread(無ければ作る)。
    func subunitThread(subunitID: String) async throws -> String {
        try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let (threadID, threadEvents) = try machine.ensureThread(subunitID: subunitID)
            return (threadEvents + machine.events, threadID)
        }
    }

    /// 段階 1・2 の小単元を開いた時、その段のモデルのメッセージがまだ無ければ 1 回だけ起こす。
    func kickoffSubunit(subunitID: String) async -> KickoffResult {
        do {
            let threadID = try await subunitThread(subunitID: subunitID)
            let prepared = try await ledger.read { db -> (key: String, text: String, view: LedgerJSON?, stage: Int)? in
                let machine = try WorkbookMachine(loading: db)
                guard let row = machine.subunits[subunitID], let key = WorkbookMachine.kickoffKey(row) else { return nil }
                if row.metadata["kickoffs"]?[key] != nil { return (key, "", nil, row.stage) }
                let text = Self.subunitKickoffText(machine: machine, row: row, profile: OnboardingProfile.load()?.promptSummary)
                return (key, text, machine.currentViewContext(subunitID: subunitID, setID: nil), row.stage)
            }
            guard let prepared else { return .notNeeded }
            if prepared.text.isEmpty { return .alreadyStarted }
            if isChatRunning(threadID: threadID) { return .busy }
            // 段階 2: 先回りの例題があればそれを使う(でき次第。§3.1)。
            if prepared.stage == 2 {
                if await adoptPrefetchedExample(subunitID: subunitID, advancing: false) != nil { return .started }
                if adoptPrefetchWhenReady(subunitID: subunitID) { return .started }
            }
            _ = try await sendChat(ChatSend(
                threadID: threadID, text: prepared.text, attachments: [], workbookView: prepared.view,
                hidden: true, kickoff: (subunitID: subunitID, key: prepared.key), subunitID: subunitID,
                expectsExample: prepared.stage == 2
            ))
            kickoffLog.info("kickoff \(prepared.key, privacy: .public) started for subunit \(subunitID, privacy: .public)")
            return .started
        } catch let error as LedgerError where error.code == "kickoff_exists" {
            return .alreadyStarted
        } catch let error as LedgerError where error.code == "codex_turn_in_progress" {
            return .busy
        } catch {
            kickoffLog.error("kickoff failed: \(String(describing: error), privacy: .public)")
            return .failed(String(describing: error))
        }
    }

    /// 起こした返事が止まった / 失敗した時、同じ段をもう一度起こす(学習者の「もう一度始める」)。
    func restartSubunitKickoff(subunitID: String) async -> KickoffResult {
        do {
            let cleared: Bool = try await ledger.commit { db in
                var machine = try WorkbookMachine(loading: db)
                guard let row = machine.subunits[subunitID], let key = WorkbookMachine.kickoffKey(row),
                      let messageID = row.metadata["kickoffs"]?[key]?.stringValue,
                      let kickoff = try MessageRecord.fetchOne(db, key: messageID)
                else { return ([], false) }
                let reply = try ChatRepository.messages(db, threadID: kickoff.threadId)
                    .drop { $0.id != messageID }.dropFirst().first { $0.role == "assistant" }
                // 例題の段で例題が保存されないまま終わった時(最初の返事を止めて質問した等)も、起こし直せる。
                let missingExample = row.stage == 2 && (try? machine.subunitSummary(id: subunitID))?.exampleProblem == nil
                // 例題が無いだけの時は、返事が終わってから(続けて押された 2 回目が、走っている起動を消さないように)。
                guard reply == nil || reply?.status == "failed" || (missingExample && reply?.status != "pending") else { return ([], false) }
                machine.clearKickoff(subunitID: subunitID, key: key)
                var events = machine.events
                // 失敗した返事の「送り直す」は外す(新しい起動と同じ説明・例題を二重に起こさない)。
                if var failed = reply, failed.status == "failed" {
                    failed.metadata = WorkbookMachine.merge(failed.metadata, ["retryable": .bool(false), "superseded_by_restart": .bool(true)])
                    events.append(.upsert("message.superseded", failed))
                }
                return (events, true)
            }
            return cleared ? await kickoffSubunit(subunitID: subunitID) : .alreadyStarted
        } catch {
            return .failed(String(describing: error))
        }
    }

    nonisolated static func subunitKickoffText(machine: WorkbookMachine, row: WorkbookSubunitRecord, profile: String?) -> String {
        let unitTitle = machine.units[row.unitId]?.title ?? ""
        let outcome = row.outcome.isEmpty ? "(未設定)" : row.outcome
        var lines = [
            "[Struis からの起動メッセージ。学習者が書いたものではありません。学習者には見えません]",
            "学習者が単元「\(unitTitle)」の小単元「\(row.title)」を開きました。到達目標: \(outcome)",
            "学習者はまだ何も書いていません。あなたから始めてください。",
        ]
        if let profile { lines += ["学習者について(オンボーディングの回答):", profile] }
        if row.stage == 1 {
            lines += [
                "いまは段階 1「要点」です。",
                "- この小単元の全体像、身近な現実の具体例、この小単元で何ができるようになるかを、順に短く説明する。必要なら短い式や図の説明を使う。",
                "- 問題は出さない。学習者に答えを求めない。",
                "- 学習者が途中で質問したら、答えてから説明の続きに戻る。",
                "- 説明を出し終えたら、最後の行で「読み終えたら下の「先に進む」で例題へ進もう」のように伝えて止まる。",
            ]
        } else {
            let round = row.metadata["example_round"]?.intValue ?? 0
            let tags = (row.metadata["return_error_tags"]?.arrayValue ?? []).compactMap(\.stringValue)
            lines += [
                "いまは段階 2「例題」です。簡単な例題を 1 問作り、学習者と一緒に一手ずつ解きます。",
                "- 例題の問題文は、見える返信の後に `<struis_workbook_example>{\"prompt\": \"<例題の問題文>\"}</struis_workbook_example>` として 1 回だけ添える。画面の上に固定表示されるので、本文で問題文を長く繰り返さない。",
                "- 1 手目はあなたが示し、「次の 1 行をノートに書いて見せて(撮っても、打ってもよい)」のように学習者の番を明示して止まる。答えを最後まで言わない。",
                "- 学習者の答えを見て、合っていれば次の一手へ、違っていれば短く直してもう一度書かせる。",
                "- 「先に進む」ボタンは、あなたが準備OKを出すまで学習者の画面に出ない。学習者が例題の主要な手を自分で書けて、同じ型の類題を自力で解けそうだと判断したら、その返信の見える本文のすぐ後(`<struis_progress_update>` などのほかの block より前)に `<struis_workbook_example_ready/>` を 1 回だけ添え、本文で「類題へ進もう。下の「先に進む」を押してね」と伝えて止まる。",
                "- まだ自力では難しそうなら準備OKは出さず、次の一手をもう一度書かせる。あなたが代わりに書いた手だけで例題が終わった時も出さない。学習者が「もう分かったので進みたい」と言ったら、要所を 1 つ書かせて確かめてから判断する。",
            ]
            if round > 0 {
                let returned = row.metadata["return_stage"]?.intValue.flatMap { WorkbookMachine.stageLabels[$0] } ?? "類題・演習"
                lines += [
                    "学習者は\(returned)で間違えて、自分で例題に戻ってきました(\(round) 回目)。前の例題とは違う、新しい例題にする。",
                    tags.isEmpty ? "直近の誤りの種類は記録されていない。" : "直近の誤りの種類: \(tags.joined(separator: "、"))。この誤りが起きやすい所を例題の中で扱う。",
                ]
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 単元づくり(オンボーディングの続き / ホームの「単元を作る」)

    /// 単元づくりの会話の題名。「質問」の一覧から単元づくりの会話を外す目印にも使う(BootstrapStore)。
    nonisolated static let unitCreationThreadTitle = "単元を作る"

    nonisolated struct UnitCreationQuestion: Sendable, Equatable {
        let key: String
        let text: String
    }

    /// 単元づくりを開いた直後の問い(待ち時間の体験 §3.3)。情報が無い状態でモデルに作らせても内容が決まっているので、
    /// アプリが待ちなしで出す。オンボーディングの回答(学年・優先したいこと・困っている科目・わからないと感じるとき・
    /// 勉強のしかた)ではどれも分からないので、3 つとも聞く。
    nonisolated static let unitCreationQuestions: [UnitCreationQuestion] = [
        UnitCreationQuestion(key: "current", text: "いま学校では何をやっている？"),
        UnitCreationQuestion(key: "test", text: "次のテストはいつ？"),
        UnitCreationQuestion(key: "stumble", text: "どこでつまずいている？"),
    ]

    /// 単元づくりの会話を始める。作りかけ(提案がまだ始まっていない)の会話があればそれを返し、
    /// 無ければ新しい thread を作って最初の問いを出す。thread が空の時だけ出すので重複しない。
    /// 学習者が答えている間に、裏でゲストと app-server を起こしておく(モデルは答えがそろってから動く)。
    func startUnitCreation(existingThreadID: String?, profile: OnboardingProfile?, attachments: [ChatTurns.Attachment]) async throws -> String {
        Task { await self.runner.warmUp() }
        if let existingThreadID {
            let reusable = try await ledger.read { db -> Bool in
                guard try ThreadRecord.fetchOne(db, key: existingThreadID) != nil else { return false }
                let started = try WorkbookProposalRecord.filter(Column("thread_id") == existingThreadID).filter(Column("status") == "started").fetchCount(db)
                return started == 0
            }
            if reusable {
                try await askFirstUnitQuestionIfEmpty(threadID: existingThreadID, profile: profile, attachments: attachments)
                return existingThreadID
            }
        }
        let threadID = LedgerID.make()
        let (_, event) = ChatRepository.createThread(id: threadID, title: Self.unitCreationThreadTitle)
        try await ledger.append([event])
        // 途中でアプリが終わっても次にこの会話を使い直せるよう、問いを出す前に覚えておく。
        UserDefaults.standard.set(threadID, forKey: OnboardingProfile.unitCreationThreadKey)
        do {
            try await askFirstUnitQuestionIfEmpty(threadID: threadID, profile: profile, attachments: attachments)
        } catch {
            // 作った会話は捨てずに呼び手へ渡す。「再試行」はこの会話を使い直す(空なら問いを出し直す)。
            throw UnitCreationStartError(threadID: threadID, underlying: error)
        }
        return threadID
    }

    /// 単元づくりの用意に失敗した。作った会話(`threadID`)は残っている。
    nonisolated struct UnitCreationStartError: LocalizedError {
        let threadID: String
        let underlying: Error
        var errorDescription: String? { underlying.localizedDescription }
    }

    /// 空の会話に最初の問いを書く(アプリが出す吹き出し。モデルのターンは無い)。オンボーディングで選んだ教材は、
    /// 答えがそろった時にモデルへ渡すため、この問いの metadata に覚えておく。
    private func askFirstUnitQuestionIfEmpty(threadID: String, profile: OnboardingProfile?, attachments: [ChatTurns.Attachment]) async throws {
        try await ledger.commit { db -> ([LedgerEvent], Void) in
            guard try MessageRecord.filter(Column("thread_id") == threadID).fetchCount(db) == 0,
                  let thread = try ThreadRecord.fetchOne(db, key: threadID)
            else { return ([], ()) }
            let first = Self.unitCreationQuestions[0]
            let (_, event) = Self.scriptedQuestionMessage(threadID: threadID, question: first, materials: attachments, profile: profile?.promptSummary)
            return ([event, ChatRepository.touchThread(thread, preview: first.text)], ())
        }
    }

    nonisolated private static func scriptedQuestionMessage(
        threadID: String, question: UnitCreationQuestion, materials: [ChatTurns.Attachment] = [], profile: String? = nil
    ) -> (MessageRecord, LedgerEvent) {
        var metadata: [String: LedgerJSON] = ["handled_as": .string("struis_app"), "scripted_question": .string(question.key)]
        if !materials.isEmpty { metadata["unit_creation_materials"] = .array(materials.map(\.json)) }
        // オンボーディングの回答(学年など)は、答えがそろった時にモデルへ渡す(聞き直さない)。
        if let profile { metadata["onboarding_profile"] = .string(profile) }
        return ChatRepository.createMessage(
            id: LedgerID.make(), threadID: threadID, role: "assistant", status: "completed", plainText: question.text,
            blocks: .array([.object(["kind": .string("text"), "payload": .object(["text": .string(question.text)])])]),
            metadata: .object(metadata)
        )
    }

    /// 単元づくりの最初の問いの進み。問いの無い会話(ふつうの質問・以前の単元づくり)は nil。
    nonisolated struct UnitQuestionState: Sendable {
        /// 答えた問いと答え(問いの順)。
        var answered: [(question: UnitCreationQuestion, text: String, attachments: [ChatTurns.Attachment])]
        /// まだ答えていない問い(最後に出した問い)。
        var pending: UnitCreationQuestion?
        /// オンボーディングで選んだ教材。
        var materials: [ChatTurns.Attachment]
        /// 単元づくりを開いた時のオンボーディングの回答。
        var profile: String? = nil
    }

    nonisolated static func unitQuestionState(_ db: Database, threadID: String) throws -> UnitQuestionState? {
        let rows = try ChatRepository.messages(db, threadID: threadID)
        guard rows.contains(where: { $0.metadata["scripted_question"]?.stringValue != nil }) else { return nil }
        var state = UnitQuestionState(answered: [], pending: nil, materials: [])
        for row in rows {
            if row.role == "assistant", let key = row.metadata["scripted_question"]?.stringValue {
                state.pending = unitCreationQuestions.first { $0.key == key }
                if state.materials.isEmpty {
                    state.materials = (row.metadata["unit_creation_materials"]?.arrayValue ?? []).compactMap(ChatTurns.Attachment.init(json:))
                }
                state.profile = state.profile ?? row.metadata["onboarding_profile"]?.stringValue
            } else if row.role == "user", let pending = state.pending {
                let attachments = (row.metadata["attachments"]?.arrayValue ?? []).compactMap(ChatTurns.Attachment.init(json:))
                state.answered.append((pending, row.plainText ?? "", attachments))
                state.pending = nil
            } else if row.role == "assistant" {
                // モデルが話し始めた後は、問いの段は終わっている。
                state.pending = nil
                break
            }
        }
        return state
    }

    /// 学習者の送信。単元づくりの最初の問いに答えている間は、答えを書いて次の問いを出す(モデルは動かさない)。
    /// 最後の問いへの答えなら、問いと答えをまとめてモデルのターンを起こす(全体像の提案まで進む)。
    /// 問いの段でなければふつうの質問ターン。モデルのターンを起こさなかった時は nil。
    func sendChatHandlingUnitQuestions(_ send: ChatSend) async throws -> ChatSendResult? {
        let state = try await ledger.read { db in try Self.unitQuestionState(db, threadID: send.threadID) }
        guard let state, let pending = state.pending else { return try await sendChat(send) }
        let questions = Self.unitCreationQuestions
        let index = questions.firstIndex(of: pending) ?? 0
        if index + 1 < questions.count {
            let next = questions[index + 1]
            try await ledger.commit { db -> ([LedgerEvent], Void) in
                guard let thread = try ThreadRecord.fetchOne(db, key: send.threadID) else { throw LedgerError.notFound("thread") }
                // 読んでから書くまでの間に同じ問いへ答えが書かれていたら、二重に書かない。
                guard try Self.unitQuestionState(db, threadID: send.threadID)?.pending == pending else {
                    throw LedgerError.rejected(code: "codex_turn_in_progress", message: "前の答えを受け取っています")
                }
                var blocks: [LedgerJSON] = []
                if !send.text.isEmpty { blocks.append(.object(["kind": .string("text"), "payload": .object(["text": .string(send.text)])])) }
                for attachment in send.attachments where attachment.kind != ChatTurns.Attachment.pageImageKind {
                    blocks.append(.object(["kind": .string(attachment.kind == "image" ? "image" : "file"), "payload": attachment.json]))
                }
                let (user, userEvent) = ChatRepository.createMessage(
                    id: LedgerID.make(), threadID: send.threadID, role: "user", status: "completed",
                    plainText: send.text.isEmpty ? nil : send.text, blocks: .array(blocks),
                    metadata: .object([
                        "handled_as": .string("struis_app"), "source": .string("thread_message"),
                        "attachments": .array(send.attachments.map(\.json)), "hidden": .bool(false), "answers_question": .string(pending.key),
                    ])
                )
                let (_, questionEvent) = Self.scriptedQuestionMessage(threadID: send.threadID, question: next)
                return ([userEvent, questionEvent, ChatRepository.touchThread(thread, preview: user.plainText)], ())
            }
            return nil
        }
        let (profile, unitTitles) = try await ledger.read { db in
            (state.profile ?? OnboardingProfile.load()?.promptSummary, try WorkbookMachine(loading: db).orderedUnits().map(\.title))
        }
        let answers = state.answered.map { (question: $0.question.text, answer: $0.text, hasImage: !$0.attachments.isEmpty) }
            + [(question: pending.text, answer: send.text, hasImage: !send.attachments.isEmpty)]
        let modelText = Self.unitCreationAnswersText(answers: answers, profile: profile, existingUnits: unitTitles, hasMaterial: !state.materials.isEmpty)
        var final = send
        final.modelText = modelText
        // オンボーディングで選んだ教材もモデルに渡す(吹き出しには出さない)。前の答えに添えたものは、
        // 1 ターンの画像が増えすぎないよう画像の入力にせず参照に回す(inbox に置き struis.document で読める。信頼性計画 P3 の 6)。
        final.modelAttachments = state.answered.flatMap(\.attachments).compactMap(\.asReference) + state.materials
        final.userMetadata["answers_question"] = .string(pending.key)
        final.userMetadata["model_text"] = .string(modelText)
        return try await sendChat(final)
    }

    nonisolated static func unitCreationAnswersText(
        answers: [(question: String, answer: String, hasImage: Bool)], profile: String?, existingUnits: [String], hasMaterial: Bool
    ) -> String {
        var lines = [
            "[Struis からの単元づくりの依頼。学習者には見えません]",
            "学習者が「単元を作る」を開き、Struis が出した最初の問いに答えました。",
        ]
        for item in answers {
            let answer = item.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("- \(item.question) → \(answer.isEmpty ? "(文字の答えなし)" : answer)\(item.hasImage ? "(写真・資料を添付)" : "")")
        }
        lines += [
            "目的: この答えから、最初に取り組む単元(長期目標)の範囲を決め、この返信で全体像の提案を出す。",
            "- 追加の問いはしない。答えが曖昧でも、答え・写真・オンボーディングの回答から最も妥当な範囲を選ぶ。",
            "- 見える返信では「全体像のカードを出すね。よければ「はじめる」を押してね」とだけ伝え、小単元を自分で並べない。",
            "- 見える返信の後に `<struis_workbook_proposal>{\"request\": \"<学年・科目・単元・テストの日付・つまずきを含む一行の依頼>\"}</struis_workbook_proposal>` を必ず 1 回添える。",
        ]
        if let profile { lines += ["学習者について(オンボーディングの回答。聞き直さない):", profile] }
        if !existingUnits.isEmpty { lines.append("すでにある単元: \(existingUnits.joined(separator: "、"))。これとは別の、新しい単元を作る。") }
        if hasMaterial { lines.append("学習者がオンボーディングで教材の写真・ファイルを添えています。範囲を決める手がかりに使う。") }
        return lines.joined(separator: "\n")
    }
}
