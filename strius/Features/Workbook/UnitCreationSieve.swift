import SwiftUI

/// 単元づくりの待ち(待ち時間の体験 要件 §4): 言葉の分解 → ふるい → 本物の全体像カード。
/// 対象は、学習者が最後の問いに答えてから全体像カードが出るまで(質問ターンと単元生成ターンの一続きの待ち)。
/// 規則で決まる絞り込み(学年・科目・単元名)は結果を待たずに実際に行い、決められない絞り込みは結果が届くまで
/// 「絞り込み中」の揺れを続ける(W3)。カードの値はすべて結果の値。
@Observable
@MainActor
final class UnitSieveModel {
    /// 結果の進み(台帳から画面が渡す)。
    enum Outcome: Equatable {
        /// モデルが範囲を決めている(質問ターンの返事待ち)。
        case deciding
        /// 全体像を組んでいる(単元生成ターン)。
        case arranging
        /// 全体像ができた。
        case ready(WorkbookProposalDTO)
        /// 失敗・中断・提案の無い返事(演出を止めて会話に戻す)。
        case ended
    }

    enum Phase: Equatable { case idle, running, done, stopped }

    static let receivedText = "答えを受け取りました"
    static let splittingText = "言葉を分けています"
    static let decidingText = "範囲を決めています"
    static let arrangingText = "小単元を並べています"
    static let readyText = "全体像ができました"
    static func sievingText(_ chip: String) -> String { "〈\(chip)〉で絞っています" }

    /// 画面に並べる候補の数。
    static let maxShown = 16

    private(set) var phase: Phase = .idle
    private(set) var status = UnitSieveModel.receivedText
    private(set) var answers: [UnitCreationDecomposer.Answer] = []
    private(set) var chips: [UnitCreationDecomposer.Chip] = []
    /// 色をつけたチップの数(先頭から)。
    private(set) var colored = 0
    /// 残りの部分を薄くしたか。
    private(set) var dimmed = false
    /// 抜き出して上段に並べたチップ。
    private(set) var extracted: Set<String> = []
    private(set) var bubblesVisible = true
    private(set) var candidatesVisible = false
    private(set) var shown: [UnitCatalog.Candidate] = []
    private(set) var falling: Set<String> = []
    /// ふるいに使っているチップ。
    private(set) var activeChip: String?
    /// 「絞り込み中」に揺れている候補(一度に 1 つ)。
    private(set) var swaying: String?
    /// 結果と一致した候補(縦に並べる)。
    private(set) var arranged: [UnitCatalog.Candidate]?
    /// 本物の全体像カードを出したか。
    private(set) var showsCard = false
    private(set) var replyID: UUID?

    var outcome: Outcome = .deciding
    var animates = true

    private var pool: [UnitCatalog.Candidate] = []

    func reset() {
        phase = .idle
        status = Self.receivedText
        colored = 0
        dimmed = false
        extracted = []
        bubblesVisible = true
        candidatesVisible = false
        shown = []
        falling = []
        activeChip = nil
        swaying = nil
        arranged = nil
        showsCard = false
        outcome = .deciding
    }

    /// 失敗・中断・提案の無い返事: 演出を止めて会話に戻す(W8)。
    func stop() {
        guard phase == .running else { return }
        phase = .stopped
    }

    func run(replyID: UUID, answers: [UnitCreationDecomposer.Answer]) async {
        guard phase == .idle || phase == .stopped else { return }
        reset()
        self.replyID = replyID
        phase = .running
        self.answers = answers
        chips = UnitCreationDecomposer.chips(answers)
        pool = Self.interleaved(UnitCatalog.candidates)

        guard animates else {
            // 動かせない時(W7): 状態の文言と、確定後の結果だけを出す。
            bubblesVisible = false
            await waitForOutcome(sway: false)
            if case .ready = outcome, phase == .running {
                status = Self.readyText
                showsCard = true
                phase = .done
            }
            return
        }

        // §4.1 分解: 範囲を決める要素に 1 つずつ色をつけ、残りを薄くし、チップとして抜き出して上段に並べる。
        await pause(0.9)
        guard phase == .running else { return }
        if !chips.isEmpty {
            status = Self.splittingText
            for index in chips.indices {
                withAnimation(.easeOut(duration: 0.3)) { colored = index + 1 }
                await pause(0.45)
            }
            withAnimation(.easeInOut(duration: 0.4)) { dimmed = true }
            await pause(0.5)
            for chip in chips {
                guard phase == .running else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { _ = extracted.insert(chip.id) }
                await pause(0.6)
            }
        }
        withAnimation(.easeInOut(duration: 0.45)) { bubblesVisible = false }
        await pause(0.5)
        guard phase == .running else { return }

        // §4.2 ふるい: 候補を並べ、規則で決まるチップで外れる候補を下へ落とす。
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { shown = Array(pool.prefix(Self.maxShown)) }
        withAnimation(.easeOut(duration: 0.45)) { candidatesVisible = true }
        await pause(0.7)
        for chip in chips where chip.filters {
            guard phase == .running else { return }
            status = Self.sievingText(chip.label)
            withAnimation(.easeOut(duration: 0.25)) { activeChip = chip.id }
            await pause(0.5)
            let kept = pool.filter(chip.keeps)
            // 一覧に無い範囲(全部外れる)なら落とさない(作り話の絞り込みをしない)。
            if !kept.isEmpty, kept.count < pool.count {
                await drop(keeping: Set(kept.map(\.id)))
                pool = kept
                await refill()
            } else {
                await pause(0.4)
            }
        }
        withAnimation(.easeOut(duration: 0.25)) { activeChip = nil }

        // 規則で決められない絞り込みは、結果が届くまで揺れを続ける。
        await waitForOutcome(sway: true)
        guard phase == .running, case .ready(let proposal) = outcome else { return }

        // 全体像が届いた: 結果の小単元と一致する候補だけを残して縦に並べ、全体像カードの行へ移す。
        status = Self.readyText
        let titles = proposal.overview?.subunits.map(\.title) ?? []
        let matched = Self.matches(titles: titles, in: shown + pool)
        await drop(keeping: Set(matched.map(\.id)))
        withAnimation(.easeInOut(duration: 0.5)) {
            shown = []
            arranged = matched
        }
        await pause(matched.isEmpty ? 0.1 : 0.7)
        withAnimation(.spring(response: 0.6, dampingFraction: 0.88)) {
            arranged = nil
            showsCard = true
        }
        phase = .done
    }

    private func waitForOutcome(sway: Bool) async {
        var index = 0
        while phase == .running, !Task.isCancelled {
            switch outcome {
            case .deciding: status = Self.decidingText
            case .arranging: status = Self.arrangingText
            case .ready: return
            case .ended:
                stop()
                return
            }
            if sway, animates, !shown.isEmpty {
                withAnimation(.easeInOut(duration: 0.3)) { swaying = shown[index % shown.count].id }
                index += 1
            }
            await pause(0.9)
        }
        swaying = nil
    }

    private func drop(keeping kept: Set<String>) async {
        let leaving = Set(shown.map(\.id)).subtracting(kept)
        guard !leaving.isEmpty else { return }
        withAnimation(.easeIn(duration: 0.55)) { falling = leaving }
        await pause(0.6)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            shown.removeAll { leaving.contains($0.id) }
            falling = []
        }
    }

    private func refill() async {
        let present = Set(shown.map(\.id))
        let more = pool.filter { !present.contains($0.id) }.prefix(Self.maxShown - shown.count)
        guard !more.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.4)) { shown.append(contentsOf: more) }
        await pause(0.45)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// 科目・単元をまたいで順に並べる(最初の並びにいろいろな候補が見えるように)。
    static func interleaved(_ candidates: [UnitCatalog.Candidate]) -> [UnitCatalog.Candidate] {
        var byUnit: [[UnitCatalog.Candidate]] = []
        var order: [String] = []
        var groups: [String: [UnitCatalog.Candidate]] = [:]
        for candidate in candidates {
            let key = candidate.unit.subject + "/" + candidate.unit.name
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(candidate)
        }
        byUnit = order.compactMap { groups[$0] }
        var result: [UnitCatalog.Candidate] = []
        var depth = 0
        while result.count < candidates.count {
            for group in byUnit where depth < group.count { result.append(group[depth]) }
            depth += 1
        }
        return result
    }

    /// 結果の小単元名と一致する候補(結果の順)。正規化して、同じか、片方がもう片方を含むものを一致とする。
    static func matches(titles: [String], in candidates: [UnitCatalog.Candidate]) -> [UnitCatalog.Candidate] {
        var used = Set<String>()
        var result: [UnitCatalog.Candidate] = []
        for title in titles {
            let target = UnitCatalog.normalize(title)
            guard target.count >= 2 else { continue }
            let hit = candidates.first { candidate in
                guard !used.contains(candidate.id) else { return false }
                let name = UnitCatalog.normalize(candidate.title)
                return name == target || (name.count >= 2 && (target.contains(name) || name.contains(target)))
            }
            if let hit {
                used.insert(hit.id)
                result.append(hit)
            }
        }
        return result
    }

    /// 一致した候補と全体像カードの行を結ぶ id(カードの行へ移す)。
    static func rowID(_ title: String) -> String { "sieve-row-" + UnitCatalog.normalize(title) }
}

/// 単元づくりの会話の上に重ねる待ちの画面。最後の問いへの答えの返事を待っている間だけ出す。
struct UnitCreationWaitPane: View {
    @Environment(ChatStore.self) private var chat
    @Environment(WorkbookStore.self) private var store
    @Environment(LearnerData.self) private var learnerData
    @Environment(\.struisAnimatesWaiting) private var animates
    @State private var model = UnitSieveModel()
    @Namespace private var namespace
    var onProposalStarted: ((WorkbookProposalDTO) -> Void)?
    /// 出しているかを呼び手に知らせる(出している間、呼び手は下の会話を描かない)。
    @Binding var isVisible: Bool

    private var lastQuestionKey: String { TurnCoordinator.unitCreationQuestions.last?.key ?? "stumble" }

    /// 最後の問いへの答えと、その返事(会話の最後にある時だけ)。
    private var target: (answers: [UnitCreationDecomposer.Answer], reply: ChatMessage)? {
        let messages = chat.messages
        guard let answerIndex = messages.lastIndex(where: { $0.role == .user && $0.answeredQuestion == lastQuestionKey }),
              answerIndex + 1 < messages.count
        else { return nil }
        let reply = messages[answerIndex + 1]
        guard reply.role == .assistant, messages.last?.id == reply.id else { return nil }
        let answers = messages.filter { $0.role == .user && $0.answeredQuestion != nil }
            .map { UnitCreationDecomposer.Answer(questionKey: $0.answeredQuestion ?? "", text: $0.plainText ?? "") }
        return (answers, reply)
    }

    private func outcome(for reply: ChatMessage) -> UnitSieveModel.Outcome {
        switch reply.status {
        case .pending: return .deciding
        case .failed: return .ended
        case .completed:
            guard let proposalID = reply.workbookProposalID else { return .ended }
            guard let proposal = store.proposals[proposalID] else { return .arranging }
            switch proposal.status {
            case .generating: return .arranging
            case .ready, .started: return proposal.overview == nil ? .ended : .ready(proposal)
            case .failed: return .ended
            }
        }
    }

    private var showsPane: Bool {
        guard let target, target.reply.id == model.replyID else { return false }
        return model.phase == .running || model.phase == .done
    }

    var body: some View {
        ZStack {
            if showsPane {
                content
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showsPane)
        .onChange(of: showsPane, initial: true) { _, value in isVisible = value }
        .onAppear { model.animates = animates }
        .onChange(of: animates) { _, value in model.animates = value }
        .task(id: stateKey) { await sync() }
    }

    /// 返事の状態が変わるたびに見直す(返事が出来上がった・全体像ができた・失敗した・送り直した)。
    private var stateKey: String {
        guard let target else { return "none" }
        let proposalStatus = target.reply.workbookProposalID.flatMap { store.proposals[$0]?.status.rawValue } ?? "-"
        return "\(target.reply.id)|\(target.reply.status.rawValue)|\(proposalStatus)"
    }

    private func sync() async {
        guard let target else {
            model.stop()
            return
        }
        if let proposalID = target.reply.workbookProposalID, store.proposals[proposalID] == nil {
            await store.loadProposal(id: proposalID)
        }
        let outcome = outcome(for: target.reply)
        model.outcome = outcome
        switch model.phase {
        case .idle, .stopped:
            // この画面で待ちを見た時だけ演出する(開き直した時に、もうできている全体像で演出し直さない)。
            guard outcome == .deciding || outcome == .arranging else { return }
            let answers = target.answers
            let replyID = target.reply.id
            Task { await model.run(replyID: replyID, answers: answers) }
        case .running, .done:
            if model.replyID != target.reply.id { model.stop() }
        }
    }

    private func liveKeys(_ reply: ChatMessage) -> [String] {
        // 返事の途中で先に組み始めた全体像(A12)も見る(始まりがいちばん新しい、終わっていないものを出す)。
        var keys = [TurnActivityKey.reply(reply.id), TurnActivityKey.unitPrefetch(messageID: reply.id)]
        if let proposalID = reply.workbookProposalID { keys.append(TurnActivityKey.target(proposalID)) }
        return keys
    }

    /// 「止める」: 範囲を決める返事なら会話のターンを、全体像を組んでいる間ならそのターンを止める。
    private func stop(_ reply: ChatMessage) {
        if reply.status == .pending {
            Task { await chat.interrupt() }
        } else if let proposalID = reply.workbookProposalID {
            Task { await learnerData.turns.interrupt(targetID: proposalID) }
        }
    }

    // MARK: - 見た目

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            chipRow
            StruisWaitingStatus(text: model.status, font: Typography.body)
                .accessibilityIdentifier("unit-sieve-status")
            if !model.showsCard, let target {
                // 範囲を決める返事・全体像を組むターンで、実際に起きた出来事(信頼性計画 P2)。
                TurnLiveLine(keys: liveKeys(target.reply), onStop: { stop(target.reply) }, showsReplyExcerpt: true)
                    .accessibilityIdentifier("unit-sieve-live")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.showsCard, case .ready(let proposal) = model.outcome {
                        WorkbookProposalCard(
                            proposalID: proposal.id, onStarted: onProposalStarted,
                            rowGeometry: WorkbookProposalCard.RowGeometry(namespace: namespace)
                        )
                        .transition(.opacity)
                    } else if let arranged = model.arranged {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(arranged) { candidate in
                                candidatePill(candidate)
                                    .matchedGeometryEffect(id: UnitSieveModel.rowID(candidate.title), in: namespace)
                            }
                        }
                    } else if model.candidatesVisible {
                        candidates
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            if model.bubblesVisible, !model.answers.isEmpty, model.animates {
                answerBubbles
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unit-sieve")
    }

    /// 上段のチップ(抜き出したもの)。
    private var chipRow: some View {
        StruisFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(model.chips.filter { model.extracted.contains($0.id) }) { chip in
                chipView(chip)
                    .matchedGeometryEffect(id: "chip-" + chip.id, in: namespace)
            }
        }
        .frame(maxWidth: .infinity, minHeight: model.extracted.isEmpty ? 0 : 30, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("unit-sieve-chips")
    }

    private func chipView(_ chip: UnitCreationDecomposer.Chip) -> some View {
        let active = model.activeChip == chip.id
        return Text(chip.label)
            .font(Typography.caption)
            .foregroundStyle(active ? Theme.onAccent : Theme.primaryText)
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(active ? Theme.accentColor : Theme.accentColor.opacity(0.18), in: Capsule())
    }

    private var candidates: some View {
        StruisFlowLayout(spacing: 6, lineSpacing: 8) {
            ForEach(model.shown) { candidate in
                let isFalling = model.falling.contains(candidate.id)
                let isSwaying = model.swaying == candidate.id
                candidatePill(candidate)
                    .rotationEffect(.degrees(isSwaying ? -2.5 : 0))
                    .scaleEffect(isSwaying ? 1.04 : 1)
                    .offset(y: isFalling ? 90 : 0)
                    .opacity(isFalling ? 0 : 1)
                    .transition(.opacity)
            }
        }
        .accessibilityHidden(true)
    }

    private func candidatePill(_ candidate: UnitCatalog.Candidate) -> some View {
        Text(candidate.title)
            .font(Typography.caption)
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 学習者の答え(吹き出し)。範囲を決める要素に色をつけ、残りを薄くし、色の部分はチップとして抜ける。
    private var answerBubbles: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(model.answers.enumerated()), id: \.offset) { index, answer in
                if !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    answerBubble(index: index, text: answer.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityHidden(true)
    }

    private func answerBubble(index: Int, text: String) -> some View {
        let chips = model.chips.enumerated().filter { $0.element.answerIndex == index }
        let segments = Self.segments(text: text, chips: chips.map { ($0.offset, $0.element) })
        return StruisFlowLayout(spacing: 0, lineSpacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                segmentView(segment)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .frame(maxWidth: 300, alignment: .trailing)
    }

    @ViewBuilder
    private func segmentView(_ segment: Segment) -> some View {
        if let chipIndex = segment.chipIndex, model.chips.indices.contains(chipIndex) {
            let chip = model.chips[chipIndex]
            let isColored = chipIndex < model.colored
            if model.extracted.contains(chip.id) {
                // 抜けた後の跡(薄く)。
                Text(segment.text)
                    .font(Typography.body)
                    .foregroundStyle(Theme.onAccent.opacity(0.3))
            } else {
                Text(segment.text)
                    .font(Typography.body)
                    .foregroundStyle(isColored ? Theme.primaryText : Theme.onAccent)
                    .padding(.horizontal, isColored ? 3 : 0)
                    .background(isColored ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .matchedGeometryEffect(id: "chip-" + chip.id, in: namespace)
            }
        } else {
            Text(segment.text)
                .font(Typography.body)
                .foregroundStyle(Theme.onAccent.opacity(model.dimmed ? 0.4 : 1))
        }
    }

    struct Segment: Equatable {
        let text: String
        let chipIndex: Int?
    }

    /// 答えの文字を、チップの部分(1 つの塊)と残り(1 文字ずつ。折り返せるように)に分ける。
    static func segments(text: String, chips: [(Int, UnitCreationDecomposer.Chip)]) -> [Segment] {
        let characters = Array(text)
        var result: [Segment] = []
        var cursor = 0
        for (index, chip) in chips.sorted(by: { $0.1.range.lowerBound < $1.1.range.lowerBound }) {
            let lower = max(cursor, min(chip.range.lowerBound, characters.count))
            let upper = min(chip.range.upperBound, characters.count)
            while cursor < lower {
                result.append(Segment(text: String(characters[cursor]), chipIndex: nil))
                cursor += 1
            }
            if upper > lower {
                result.append(Segment(text: String(characters[lower..<upper]), chipIndex: index))
                cursor = upper
            }
        }
        while cursor < characters.count {
            result.append(Segment(text: String(characters[cursor]), chipIndex: nil))
            cursor += 1
        }
        return result
    }
}

extension ChatMessage {
    /// 単元づくりの最初の問いのどれに答えたか(§3.3)。
    var answeredQuestion: String? {
        metadata?.value["answers_question"]?.stringValue
    }
}
