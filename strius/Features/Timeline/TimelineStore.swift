import Foundation
import OSLog
import SwiftUI

private let timelineLog = Logger(subsystem: "com.digiloglab.strius", category: "timeline")

/// 学習タイムラインの状態(Issue #46)。台帳(`TimelineMachine`)を読み、正解・間違い・飛ばすでの切り替え・正答率・
/// 2択カードの判定は端末で決める(AI を待たない)。AI を呼ぶのは、次の5枚・採点・知識グラフを作る / 見直すときだけ。
@Observable
@MainActor
final class TimelineStore {
    enum Phase: Equatable {
        case loading
        /// 使い始め: 「単元を作る」へ案内する1枚。
        case guide
        /// 手元にカードが無い(初めて開いた時に5枚を待っている)。
        case waiting
        case solving
        case grading(String)
        case result
        /// 新しい手順の「やり方の確認」。
        case howto
        /// 手が止まりかけた時の2択カード。
        case dip(String, TimelineRules.DipTrigger)
        /// 速攻ラウンド(3問のうち何問目か)。
        case rapid(Int)
        case rapidDone
        /// さわるだけの20秒(次の問題の予習を兼ねる)。
        case toy
        /// 「今日はここまで」。
        case finished
    }

    /// 1枚目に添える印(「↺ 昨日」「時計 30秒」「↺ 2日前 ○」)。
    enum Badge: Equatable {
        case resume
        case rapid
        case history(daysAgo: Int)
    }

    let ledger: Ledger
    let turns: TurnCoordinator
    private(set) var machine = TimelineMachine()
    private(set) var workbook = WorkbookMachine()
    private(set) var phase: Phase = .loading
    private(set) var currentID: String?
    private(set) var lastAttemptID: String?
    private(set) var decided: TimelineRules.Next?
    private(set) var badge: Badge?
    /// 飛ばした直後の帯(理由の2択)。押さなくても消える。
    private(set) var skipBannerAttemptID: String?
    var isStopSheetPresented = false
    private(set) var rapidIDs: [String] = []
    private(set) var rapidStartedAt = Date()
    private(set) var rapidResults: [String: Double] = [:]
    private(set) var actionError: String?

    /// カードを出した時刻(前面にいた時間だけを数える時計)。アプリを離れていた時間は解答時間に入れない
    /// (2026-10-24 の実機では 2287 秒と記録された)。
    private var cardStartedAt = ActiveClock.shared.now
    private var assisted = false
    /// やり方の確認の後に解く「同じ形」の後で戻る、元のカード。
    private var returnToID: String?
    private var awayStartedAt: Date?
    private var observer: UUID?
    private var reloadTask: Task<Void, Never>?
    /// 前に読んだ単元(新しい単元ができたかを見る)。
    private var knownUnitIDs: Set<String>?
    private var bannerTask: Task<Void, Never>?
    private var started = false

    init(ledger: Ledger, turns: TurnCoordinator) {
        self.ledger = ledger
        self.turns = turns
        Task { [weak self] in
            guard let self else { return }
            let id = await ledger.observe { [weak self] events in
                guard events.contains(where: { $0.entity.rawValue.hasPrefix("timeline_") || $0.entity.rawValue.hasPrefix("workbook_") }) else { return }
                Task { @MainActor [weak self] in self?.scheduleReload() }
            }
            self.observer = id
        }
    }

    func reset() {
        reloadTask?.cancel()
        machine = TimelineMachine()
        workbook = WorkbookMachine()
        phase = .loading
        currentID = nil
        lastAttemptID = nil
        decided = nil
        badge = nil
        started = false
        knownUnitIDs = nil
    }

    // MARK: - 読む

    var current: TimelineCardRecord? { currentID.flatMap { machine.cards[$0] } }
    var lastAttempt: TimelineAttemptRecord? { lastAttemptID.flatMap { machine.attempts[$0] } }
    var answeredToday: Int { machine.answeredToday }

    /// 下の帯に出す次の 1 枚。答えた後は決めた 1 枚、答える前は手元の次のカード。
    var upcoming: TimelineCardRecord? {
        if case .rapid(let index) = phase { return rapidIDs.dropFirst(index + 1).first.flatMap { machine.cards[$0] } }
        if let decided { return decided.cardID.flatMap { machine.cards[$0] } }
        if let returnToID, current?.origin == "easier" { return machine.cards[returnToID] }
        return machine.queue.first { $0.id != currentID } ?? machine.rapidCards.first { $0.id != currentID }
    }

    /// 単元のチップ(「数学I・平方完成」)。混ぜて出す復習のカードでは隠す(どの解き方を使うかが見えてしまうため)。
    func unitChip(for card: TimelineCardRecord) -> String? {
        if card.origin == "rapid" { return nil }
        if !card.skills.isEmpty, card.skills.allSatisfy({ machine.skills[$0]?.status == "mastered" }) { return nil }
        let unitID = card.unitId ?? card.subunitId.flatMap { workbook.subunits[$0]?.unitId } ?? card.skills.compactMap { machine.skills[$0].flatMap { TimelineGraphSchedule.unitID(of: $0, workbook: workbook) } }.first
        let unit = unitID.flatMap { workbook.units[$0]?.title } ?? card.payload["unit_title"]?.stringValue
        let skill = card.skills.first.flatMap { machine.skills[$0]?.name }
        let parts = [unit, skill].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? (card.typeName.isEmpty ? nil : card.typeName) : parts.joined(separator: "・")
    }

    func skillName(_ id: String) -> String { machine.skills[id]?.name ?? (id.split(separator: ".").last.map(String.init) ?? id) }
    func solvedToday(_ id: String) -> Int { machine.solvedToday(skill: id) }
    func isNewSkill(_ id: String) -> Bool { machine.isNewSkill(id) }

    /// 「さっきの続き」の前のカードの解答(系列のバーの ○)。
    func chainSolved(_ card: TimelineCardRecord) -> Int {
        guard let chainID = TimelineRules.chainID(card) else { return 0 }
        return machine.chainMembers(chainID).filter { member in machine.attempts(cardID: member.id).contains { $0.verdict == "correct" } }.count
    }

    /// 結果の画面で「入試の形」を明かすか。
    var reveals: Bool { decided?.reveal == true && lastAttempt?.verdict == "correct" }

    /// 単元の進み(「4 / 5」と、あと 1 のとき「階段 あと 1」)。単元ホームの進みの数字をそのまま出す。
    func unitProgress(for card: TimelineCardRecord) -> (title: String, passed: Int, total: Int)? {
        let unitID = card.unitId ?? card.subunitId.flatMap { workbook.subunits[$0]?.unitId } ?? card.skills.compactMap { machine.skills[$0].flatMap { TimelineGraphSchedule.unitID(of: $0, workbook: workbook) } }.first
        guard let unitID, let unit = workbook.units[unitID] else { return nil }
        let subunits = workbook.orderedSubunits(unitID: unitID)
        guard !subunits.isEmpty else { return nil }
        return (unit.title, subunits.filter { $0.status == "passed" }.count, subunits.count)
    }

    /// やめようとした時のシート: 今日の問題数と時間、次の1問、その手順のうち済んでいる数。
    var stopSummary: (count: Int, minutes: Int, next: TimelineCardRecord?, done: Int, total: Int) {
        let minutes = machine.firstAnswerToday.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
        let next = upcoming ?? current
        let skills = next?.skills ?? []
        let done = skills.filter { machine.skills[$0]?.status == "mastered" || machine.skills[$0]?.status == "assumed" || machine.solvedToday(skill: $0) > 0 }.count
        return (machine.answeredToday, minutes, next, done, skills.count)
    }

    var rapidBest: Double? { machine.rapidBest }

    /// 通し番号(左下の「No. 21」)。
    var problemNumber: Int { machine.attempts.values.filter { $0.verdict != "skipped" }.count + (phase == .result ? 0 : 1) }

    /// 2日続けて同じ所で止まった(質問へ誘導する)。
    func isStuck(_ card: TimelineCardRecord) -> Bool {
        !TimelineRules.stuckTwoDays(results: machine.skillResults, today: machine.today).isDisjoint(with: card.skills)
    }

    /// 質問を始める時に渡す、その手順の直近の答案(すべて)。
    func recentAnswers(for card: TimelineCardRecord) -> String {
        let attempts = machine.orderedAttempts.filter { attempt in
            attempt.verdict == "correct" || attempt.verdict == "wrong" ? !(machine.cards[attempt.cardId]?.skills ?? []).allSatisfy { !card.skills.contains($0) } : false
        }.suffix(6)
        return attempts.compactMap { attempt -> String? in
            guard let past = machine.cards[attempt.cardId] else { return nil }
            let errors = attempt.errors.arrayValue?.compactMap { error -> String? in
                let wrote = error["wrote"]?.stringValue ?? "", correct = error["correct"]?.stringValue ?? "", detail = error["detail"]?.stringValue ?? ""
                return [wrote.isEmpty ? nil : "書いたもの: \(wrote)", correct.isEmpty ? nil : "正しくは: \(correct)", detail.isEmpty ? nil : detail].compactMap { $0 }.joined(separator: " / ")
            } ?? []
            let day = TimelineRules.day(attempt.createdAt) ?? ""
            return "- \(day) \(TimelineCards.problemLine(prompt: past.prompt, math: past.math)) \(past.question) → \(attempt.verdict == "correct" ? "○" : "×")" + (errors.isEmpty ? "" : "(" + errors.joined(separator: "; ") + ")")
        }.joined(separator: "\n")
    }

    // MARK: - 始める

    /// 起動したらすぐ出す。1枚目は手元から選び、AI を呼ばない。出すと同時に、その日の最初の5枚を頼む。
    func start() async {
        await reload()
        guard !started else { return }
        started = true
        let today = machine.today
        let resume = TimelineRules.resumeCard(cards: Array(machine.cards.values), attempts: machine.orderedAttempts, today: today)
        let keep = Set([resume?.id].compactMap { $0 })
        let past = pastSolved()
        await commit { machine in
            machine.markLegacyExpansion()
            machine.discardStale(keep: keep)
            if resume == nil, machine.rapidCards.isEmpty, machine.historyCards.isEmpty {
                for item in past { machine.insertHistory(prompt: item.prompt, answerKey: item.answerKey, subunitID: item.subunitID, unitTitle: item.unit, solvedAt: item.at) }
            }
        }
        // 前の起動で出したまま答えていないカードがあれば、それから。
        if let shown = machine.cards.values.filter({ $0.status == "shown" && TimelineRules.day($0.updatedAt) == today && $0.origin != "history" }).max(by: { $0.updatedAt < $1.updatedAt }) {
            show(shown.id)
        } else {
            switch TimelineRules.firstCard(cards: Array(machine.cards.values), attempts: machine.orderedAttempts, history: machine.historyCards, today: today) {
            case .resume(let id):
                badge = .resume
                await commit { machine in
                    if var card = machine.cards[id], card.status == "discarded" {
                        card.status = "unused"
                        machine.put("timeline.card_resumed", card)
                    }
                }
                show(id)
            case .rapid(let id):
                badge = .rapid
                show(id)
            case .history(let id):
                let solved = machine.cards[id]?.payload["solved_at"]?.stringValue.flatMap { TimelineRules.day($0) }
                badge = .history(daysAgo: solved.flatMap { TimelineRules.daysBetween($0, today) } ?? 1)
                show(id)
            case .guide:
                if let next = machine.queue.first { show(next.id) } else { phase = workbook.units.isEmpty ? .guide : .waiting }
            }
        }
        // タイムラインを開いた時: グラフを頼むか決める。
        await ensureGraphWork()
        await requestBatch(notes: notesForNextBatch(paused: nil))
    }

    /// 単元ホームで前に解けた問題(新しい順に3つ)。
    private struct PastProblem: Sendable {
        var prompt: String
        var answerKey: String
        var subunitID: String?
        var unit: String
        var at: String
    }

    private func pastSolved() -> [PastProblem] {
        var seen: Set<String> = []
        return workbook.attempts.values.filter { $0.verdict == "correct" }.sorted { $0.createdAt > $1.createdAt }.compactMap { attempt in
            guard let problem = workbook.problems[attempt.problemId], problem.source != "timeline", seen.insert(problem.id).inserted else { return nil }
            let unit = workbook.subunits[problem.subunitId].flatMap { workbook.units[$0.unitId]?.title } ?? ""
            return PastProblem(prompt: problem.prompt, answerKey: problem.answerKey, subunitID: problem.subunitId, unit: unit, at: attempt.createdAt)
        }.prefix(3).map { $0 }
    }

    // MARK: - 解く

    func show(_ id: String?) {
        guard let id, let card = machine.cards[id] else {
            currentID = nil
            phase = workbook.units.isEmpty && machine.cards.isEmpty ? .guide : .waiting
            Task { await requestBatch(notes: notesForNextBatch(paused: nil)) }
            return
        }
        if card.origin != "rapid" || phase != .rapidDone { if badge != nil, currentID != nil, currentID != id { badge = nil } }
        currentID = id
        lastAttemptID = nil
        decided = nil
        assisted = false
        cardStartedAt = ActiveClock.shared.now
        phase = .solving
        Task {
            await commit { machine in machine.markShown(id) }
            // グラフは頼まない(開いた時・単元ができた時・採点結果を反映した時だけ)。5枚は4枚目で頼む。
            await requestBatch(notes: notesForNextBatch(paused: nil))
        }
    }

    private var elapsed: Double { max(0, ActiveClock.shared.now - cardStartedAt) }

    /// 撮った・指で書いた答案を送る(採点は裏で走る)。
    func submit(image data: Data) async {
        guard let card = current else { return }
        let seconds = elapsed
        do {
            let relative = "timeline-\(LedgerID.make()).jpg"
            try StruisPaths.prepare()
            try data.write(to: StruisPaths.captures.appendingPathComponent(relative), options: .atomic)
            let assisted = self.assisted
            let attemptID = try await ledger.commit { db in
                var machine = try TimelineMachine(loading: db)
                let id = machine.recordCapture(cardID: card.id, capturePath: relative, seconds: seconds, assisted: assisted)
                return (machine.events, id)
            }
            lastAttemptID = attemptID
            phase = .grading(attemptID)
            await reload()
            await turns.startTimeline(kind: .timelineGrading, targetID: attemptID)
        } catch {
            timelineLog.error("timeline capture failed: \(String(describing: error), privacy: .public)")
            actionError = "答案を保存できませんでした。もう一度送ってください。"
        }
    }

    /// タップ・ドラッグ・払うのカード(端末の中で採点する)。
    func answer(_ value: LedgerJSON) async {
        guard let card = current else { return }
        let correct = TimelineCards.grade(card, answer: value)
        let seconds = elapsed
        let id = await commitValue { machine in machine.recordInteractive(cardID: card.id, correct: correct, seconds: seconds, answer: value) }
        lastAttemptID = id
        phase = .result
        await decide()
    }

    /// 飛ばす: 画面の上に理由の2択を出し(押さなくても消える)、同じ続きに属さない別の形へ。
    func skip() async {
        guard let card = current, phase == .solving else { return }
        let seconds = elapsed
        let previousWasSkip = machine.orderedAttempts.last?.verdict == "skipped"
        guard let attemptID = await commitValue({ machine in machine.recordSkip(cardID: card.id, seconds: seconds) }) else { return }
        lastAttemptID = attemptID
        showSkipBanner(attemptID)
        var next = TimelineRules.next(after: card, outcome: .skipped, queue: machine.queue, rapid: machine.rapidCards, wrongBefore: false)
        if next.cardID == nil, card.origin == "rapid" { next.cardID = machine.rapidCards.first?.id }
        decided = next
        if let trigger = TimelineRules.dipAfterAnswer(seconds: seconds, usual: nil, outcome: .skipped, previousWasSkip: previousWasSkip, sinceLastDip: machine.cardsSinceLastDip) {
            await openDip(trigger)
            return
        }
        await goNext()
    }

    func setSkipReason(_ reason: String) async {
        guard let id = skipBannerAttemptID else { return }
        await commit { machine in machine.setSkipReason(attemptID: id, reason: reason) }
        skipBannerAttemptID = nil
    }

    private func showSkipBanner(_ attemptID: String) {
        skipBannerAttemptID = attemptID
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation { self?.skipBannerAttemptID = nil }
        }
    }

    /// 採点の結果が出た後、次の 1 枚を決める(AI を待たない)。
    private func decide() async {
        guard let card = current, let attempt = lastAttempt else { return }
        let outcome: TimelineRules.Outcome
        switch attempt.verdict {
        case "correct": outcome = .correct
        case "wrong": outcome = .wrong
        default: return
        }
        let initial = TimelineRules.next(after: card, outcome: outcome, queue: machine.queue.filter { $0.id != card.id }, rapid: machine.rapidCards,
                                         wrongBefore: card.origin == "easier")
        let returnTo = returnToID
        let firstCause = machine.attempts(cardID: card.easierOf ?? "").first?.cause
        let next = await commitValue { machine -> TimelineRules.Next in
            var next = initial
            if let base = next.makeEasierOf { next.cardID = machine.makeEasier(of: base) }
            if outcome == .correct {
                if card.origin == "easier", let returnTo {
                    // やり方の確認の後の「同じ形」を解いた: 元の問題に戻る。
                    next.cardID = returnTo
                } else if card.origin == "easier", let base = card.easierOf, let firstCause {
                    // やさしい版で ○: 最初の × の答案から原因を見分けて、流れを分ける。
                    switch firstCause {
                    case "connection":
                        // 繋がりを理解していない: 左右に仕分け → 次の一手(作れるものだけ)。
                        let nextStep = machine.insertDerived(.nextStep, from: base)
                        let sort = machine.insertDerived(.sort, from: base)
                        next.cardID = sort ?? nextStep ?? next.cardID
                    case "unknown":
                        // 原因が分からない: 理由を選ぶカードを 1 枚挟む。
                        next.cardID = machine.insertDerived(.reason, from: base) ?? next.cardID
                    default:
                        break
                    }
                } else if card.kind == "solve", card.origin == "batch", card.payload["reason"]?.objectValue != nil, machine.answeredToday % 3 == 0 {
                    // 正解の後に「なぜ？」を3択で(時々)。
                    next.cardID = machine.insertDerived(.reason, from: card.id) ?? next.cardID
                } else if card.kind == "solve", card.origin == "batch", machine.answeredToday % 7 == 5 {
                    // 間違い探しは好感度が下がるので、たまに混ぜる程度にする。
                    next.cardID = machine.insertDerived(.findError, from: card.id) ?? next.cardID
                }
            } else if card.origin == "easier", let base = card.easierOf {
                // やさしい版も ×: 並べ替えで手順を確かめてから、その前提の段1へ。
                if let order = machine.insertDerived(.order, from: base) { next.cardID = order }
            }
            if !next.discardIDs.isEmpty { machine.discard(ids: next.discardIDs) }
            return next
        } ?? initial
        if card.origin == "easier", returnTo != nil, outcome == .correct { returnToID = nil }
        decided = next
    }

    /// 結果の画面の「次へ」・下の帯を上に送る。
    func goNext() async {
        if phase == .solving, current != nil, decided == nil {
            await skip()
            return
        }
        let next = decided
        if phase == .result, let attempt = lastAttempt, let card = current {
            // 撮るか飛ばすかした直後に、本人のいつもの2倍を超えていたら2択カード。
            let usual = TimelineRules.usualSeconds(level: card.level, history: machine.secondsHistory.dropLast().map { $0 }, estimatedSeconds: card.estimatedSeconds)
            if card.origin != "rapid",
               let trigger = TimelineRules.dipAfterAnswer(seconds: attempt.seconds, usual: usual, outcome: attempt.verdict == "correct" ? .correct : .wrong,
                                                          previousWasSkip: false, sinceLastDip: machine.cardsSinceLastDip) {
                await openDip(trigger)
                return
            }
        }
        if next?.requestBatch == true || TimelineRules.twoWrongInARow(machine.orderedAttempts) {
            await requestBatch(force: next?.requestBatch == true, notes: notesForNextBatch(paused: next?.pausedChain))
        }
        show(next?.cardID ?? machine.queue.first?.id ?? machine.rapidCards.first?.id)
    }

    /// 新しい手順を押した: やり方の確認(ヒントありの扱いになる)。
    func openHowto() {
        assisted = true
        phase = .howto
    }

    /// やり方の確認の「同じ形を 1 問解く」: そのカードのやさしい版を出し、解いたら元の問題に戻る。
    func solveSameForm() async {
        guard let card = current else { return }
        let cardID = card.id
        guard let easier = await commitValue({ machine in machine.makeEasier(of: cardID) }) ?? nil else { phase = .solving; return }
        returnToID = card.id
        show(easier)
    }

    func closeHowto() { phase = .solving }

    // MARK: - 2択カード

    private func openDip(_ trigger: TimelineRules.DipTrigger) async {
        guard let id = await commitValue({ machine in machine.recordDip(trigger: trigger) }) else { return }
        phase = .dip(id, trigger)
    }

    func chooseRapid() async {
        guard case .dip(let id, _) = phase else { return }
        await commit { machine in machine.chooseDip(id: id, chosen: "rapid") }
        rapidIDs = Array(machine.rapidCards.prefix(TimelineRules.rapidCount).map(\.id))
        if rapidIDs.isEmpty { await chooseContinue(); return }
        rapidResults = [:]
        rapidStartedAt = Date()
        let first = rapidIDs[0]
        currentID = first
        cardStartedAt = ActiveClock.shared.now
        phase = .rapid(0)
        await commit { machine in machine.markShown(first) }
    }

    /// さわるだけの20秒を出せるか: 次に出す問題に、範囲と軸の図(場合分け)がある。
    var toyCard: TimelineCardRecord? {
        let candidates = [upcoming, current].compactMap { $0 } + machine.queue
        return candidates.first { $0.payload["howto"]?["diagram"]?["kind"]?.stringValue == "range_vs_axis" }
    }

    func chooseToy() async {
        guard case .dip(let id, _) = phase else { return }
        await commit { machine in machine.chooseDip(id: id, chosen: "toy") }
        phase = .toy
    }

    /// さわるだけの後の「この形を解く」: 図のあった問題へ。
    func solveToyForm() {
        show(toyCard?.id ?? decided?.cardID ?? machine.queue.first?.id)
    }

    func chooseContinue() async {
        guard case .dip(let id, let trigger) = phase else { return }
        await commit { machine in machine.chooseDip(id: id, chosen: "continue") }
        if trigger == .away {
            // さっきの問題に戻る(時間は戻った時から数え直さない)。
            phase = .solving
            return
        }
        show(decided?.cardID ?? machine.queue.first?.id)
    }

    /// 速攻: 余白に書いてすぐ送る。採点は裏で走り、次の問題へすぐ進む(自分の記録との勝負)。
    func submitRapid(image data: Data) async {
        guard case .rapid(let index) = phase, let card = current else { return }
        let seconds = elapsed
        rapidResults[card.id] = seconds
        do {
            let relative = "timeline-\(LedgerID.make()).jpg"
            try StruisPaths.prepare()
            try data.write(to: StruisPaths.captures.appendingPathComponent(relative), options: .atomic)
            let attemptID = try await ledger.commit { db in
                var machine = try TimelineMachine(loading: db)
                let id = machine.recordCapture(cardID: card.id, capturePath: relative, seconds: seconds, assisted: false)
                return (machine.events, id)
            }
            await turns.startTimeline(kind: .timelineGrading, targetID: attemptID)
        } catch {
            actionError = "答案を保存できませんでした。"
        }
        if index + 1 < rapidIDs.count {
            let nextID = rapidIDs[index + 1]
            currentID = nextID
            cardStartedAt = ActiveClock.shared.now
            phase = .rapid(index + 1)
            await commit { machine in machine.markShown(nextID) }
        } else {
            phase = .rapidDone
            await commit { machine in machine.countAfterDip() }
        }
    }

    /// 速攻の結果(○ と秒数)。採点が済んでいなければ verdict は grading。
    func rapidVerdict(_ cardID: String) -> (verdict: String, seconds: Double)? {
        guard let attempt = machine.attempts(cardID: cardID).last else { return rapidResults[cardID].map { ("grading", $0) } }
        return (attempt.verdict, attempt.seconds)
    }

    func finishRapid() {
        decided = nil
        show(machine.queue.first?.id ?? machine.rapidCards.first?.id)
    }

    // MARK: - やめどき

    func stopForToday() {
        isStopSheetPresented = false
        phase = .finished
    }

    func resumeAfterFinish() {
        if let current, current.status != "answered" { phase = .solving } else { show(machine.queue.first?.id ?? machine.rapidCards.first?.id) }
    }

    /// 他のアプリに移って、30秒以上たって戻ってきた(SwiftUI の scenePhase)。
    func scenePhaseChanged(_ scenePhase: ScenePhase) async {
        switch scenePhase {
        case .background:
            awayStartedAt = Date()
        case .active:
            guard let away = awayStartedAt else { return }
            awayStartedAt = nil
            let seconds = Date().timeIntervalSince(away)
            if let trigger = TimelineRules.dipOnReturn(awaySeconds: seconds, isSolving: phase == .solving && current?.kind == "solve", sinceLastDip: machine.cardsSinceLastDip) {
                await openDip(trigger)
            }
        default:
            break
        }
    }

    // MARK: - 裏で頼むもの

    private func notesForNextBatch(paused: String?) -> [String] {
        var notes: [String] = []
        if paused != nil { notes.append("やさしい版も × だったので、さっきの続きは保留した。前提の段1から上げ直す。") }
        if TimelineRules.twoWrongInARow(machine.orderedAttempts) { notes.append("× が2回続いた。次は定着済みの前提の段1を挟む。") }
        if let last = machine.orderedAttempts.last(where: { $0.verdict == "wrong" }), last.cause == "practice" {
            notes.append("練習不足の間違い(考え方の確認点は ○、計算だけ ×)。展開と代入を段1〜2で数問反復し、翌日同じ形に戻る。")
        }
        if let last = machine.orderedAttempts.last(where: { $0.verdict == "wrong" }), last.cause == "connection" {
            notes.append("繋がりを理解していない間違い。やり方の確認→仕分け→次の一手→段3 を経てから、早くても翌日に元の段へ戻る。")
        }
        if let last = machine.orderedAttempts.last(where: { $0.skipReason != nil }), last.skipReason == "too_hard" {
            notes.append("前に「難しそう」で飛ばした。保留した続きは、やさしい版から始める。")
        }
        return notes
    }

    /// 5枚を頼む。手元の未使用が1枚以下(5枚のうち4枚目を出した時点)で、頼んでいる最中でなければ。
    func requestBatch(force: Bool = false, notes: [String] = []) async {
        guard !workbook.units.isEmpty || machine.hasGraph else { return }
        let pending = machine.pendingBatch(purpose: "cards") != nil
        guard force ? !pending : TimelineRules.shouldRequestBatch(unusedCount: machine.queue.filter { $0.id != currentID }.count, pending: pending) else { return }
        let accuracy = machine.accuracy
        let cap = TimelineRules.levelCap(accuracy: accuracy, currentLevel: machine.currentLevel)
        let request: LedgerJSON = .object(["notes": .array(notes.map(LedgerJSON.string))])
        guard let id = await commitValue({ machine in machine.insertBatchRequest(purpose: "cards", request: request, accuracy: accuracy, levelCap: cap) }) else { return }
        await turns.startTimeline(kind: .timelineBatch, targetID: id, prefetch: true)
    }

    /// 知識グラフを作る(初めて開いた時・新しい単元ができた時)・丸ごと見直す(きっかけが起きた時)。頼んだかは台帳の行で見る。
    private func ensureGraphWork() async {
        guard let request = TimelineGraphSchedule.next(timeline: machine, workbook: workbook) else { return }
        let profile = OnboardingProfile.load()
        let purpose: String, body: LedgerJSON
        switch request {
        case .build:
            purpose = "graph_build"
            body = TimelineTurns.graphRequest(purpose: purpose, unitID: nil, workbook: workbook, timeline: machine, profile: profile)
        case .extend(let unitID):
            purpose = "graph_extend"
            body = TimelineTurns.graphRequest(purpose: purpose, unitID: unitID, workbook: workbook, timeline: machine, profile: profile)
        case .review(let changeIDs):
            purpose = "graph_review"
            body = TimelineTurns.graphRequest(purpose: purpose, unitID: nil, changeIDs: changeIDs, workbook: workbook, timeline: machine, profile: profile)
        }
        // 判定から行を書くまでの間に、別の判定が同じものを頼んでいないか(書き込みの中で確かめ直す)。
        guard let id = await commitValue({ machine -> String? in
            TimelineGraphSchedule.isBlocked(request, timeline: machine) ? nil : machine.insertBatchRequest(purpose: purpose, request: body, accuracy: nil, levelCap: nil)
        }) ?? nil else { return }
        await turns.startTimeline(kind: .timelineGraph, targetID: id, prefetch: true)
    }

    // MARK: - 台帳

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func reload() async {
        do {
            let (timeline, workbook) = try await ledger.read { db in (try TimelineMachine(loading: db), try WorkbookMachine(loading: db)) }
            machine = timeline
            self.workbook = workbook
        } catch {
            timelineLog.error("timeline reload failed: \(String(describing: error), privacy: .public)")
            return
        }
        // 単元ができた: その単元の分のグラフを頼むか決める。
        let unitIDs = Set(workbook.units.keys)
        let newUnit = knownUnitIDs.map { !unitIDs.subtracting($0).isEmpty } ?? false
        knownUnitIDs = unitIDs
        if newUnit, started { await ensureGraphWork() }
        // 採点の結果が届いた。
        if case .grading(let attemptID) = phase, let attempt = machine.attempts[attemptID], attempt.verdict != "grading" {
            if attempt.verdict == "correct" || attempt.verdict == "wrong" {
                phase = .result
                await decide()
                // 採点結果を反映した: 見直し・1段下りるのきっかけを見る。
                await ensureGraphWork()
            } else {
                // 読めなかった・採点できなかった: 撮り直してもらう。
                actionError = attempt.feedback.isEmpty ? TimelineTurns.gradingFailure : attempt.feedback
                lastAttemptID = nil
                phase = .solving
            }
        }
        // 5枚が届いた。
        if phase == .waiting, let next = machine.queue.first ?? machine.rapidCards.first {
            show(next.id)
        }
        if phase == .guide, !workbook.units.isEmpty {
            phase = .waiting
            await requestBatch(notes: notesForNextBatch(paused: nil))
        }
    }

    func dismissError() { actionError = nil }

    private func commit(_ block: @escaping @Sendable (inout TimelineMachine) -> Void) async {
        do {
            try await ledger.commit { db in
                var machine = try TimelineMachine(loading: db)
                block(&machine)
                return (machine.events, ())
            }
            await reload()
        } catch {
            timelineLog.error("timeline commit failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func commitValue<T: Sendable>(_ block: @escaping @Sendable (inout TimelineMachine) -> T) async -> T? {
        do {
            let value = try await ledger.commit { db in
                var machine = try TimelineMachine(loading: db)
                let value = block(&machine)
                return (machine.events, value)
            }
            await reload()
            return value
        } catch {
            timelineLog.error("timeline commit failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
