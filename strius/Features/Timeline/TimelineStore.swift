import Foundation
import GRDB
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
        /// 待っていた5枚の依頼が失敗した(理由とやり直しのボタンを出す)。
        case batchFailed(String)
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
        /// 利用枠で止まった(#62・#78): 作り置きのカードを出さず、利用枠の案内(`UsageLimitSheet`)へ移る。
        /// 解いている途中のカードは採点まで終えてから、次のカードに替わる時にここへ来る。
        case limitReached(UsageDenial)
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
    /// 解く範囲の一覧(上の帯のチップから下へ伸びるプルダウン)。
    var isScopeSheetPresented = false
    /// 質問・撮る・単元のチップを、引っぱって開く動き(タイムラインと、質問の画面を出す AppRootView が使う)。
    let pullOut = TimelinePullOut()
    /// 解く範囲: 固定した単元の ID(nil は「おまかせ」)。端末ごとに `TimelineScope` に残す。
    private(set) var scopeUnitID: String? = TimelineScope.unitID
    private(set) var rapidIDs: [String] = []
    private(set) var rapidStartedAt = Date()
    private(set) var rapidResults: [String: Double] = [:]
    private(set) var actionError: String?
    /// 書く面から送った答案(端末のメモリにだけ持つ。赤ペンを生徒の線に重ねるため。直近の 1 つだけ)。
    private(set) var inkAnswers: [String: TimelineInkAnswer] = [:]
    private var noticeObserver: UUID?

    /// カードを出した時刻(前面にいた時間だけを数える時計)。アプリを離れていた時間は解答時間に入れない
    /// (2026-10-24 の実機では 2287 秒と記録された)。
    private var cardStartedAt = ActiveClock.shared.now
    private var assisted = false
    /// やり方の確認を開いたカード(「同じ形」を挟んで戻っても、ヒントありのまま)。
    private var assistedIDs: Set<String> = []
    /// 手元にカードが無い間に待っている5枚の依頼(待ちの画面は、この依頼のターンの途中経過を出す)。
    private(set) var awaitedBatchID: String?
    /// やり方の確認の後に解く「同じ形」の後で戻る、元のカード。
    private var returnToID: String?
    private var awayStartedAt: Date?
    private var observer: UUID?
    private var reloadTask: Task<Void, Never>?
    /// 前に読んだ単元(新しい単元ができたかを見る)。
    private var knownUnitIDs: Set<String>?
    private var knownSubunitIDs: Set<String>?
    private var bannerTask: Task<Void, Never>?
    private var started = false
    /// 利用枠の案内のシート(止まった時と、止まった画面のボタンから出す。`AppRootView` が出す)。
    var limitPrompt: UsageLimitPrompt?
    /// 新しい作業(新しいカード・5枚の依頼)を利用枠が止める理由(nil なら出せる)。テストで差し替える。
    var newWorkDenial: @MainActor () -> UsageDenial? = { DeviceUsageGate().usageDenial() }
    private var usageObserver: NSObjectProtocol?

    init(ledger: Ledger, turns: TurnCoordinator) {
        self.ledger = ledger
        self.turns = turns
        // 購入・上げた・期間が替わった: 止まっていたら、手元のカードから続ける。
        usageObserver = NotificationCenter.default.addObserver(forName: .usageMeterChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckUsage() }
        }
        Task { [weak self] in
            guard let self else { return }
            let id = await ledger.observe { [weak self] events in
                guard events.contains(where: { $0.entity.rawValue.hasPrefix("timeline_") || $0.entity.rawValue.hasPrefix("workbook_") }) else { return }
                Task { @MainActor [weak self] in self?.scheduleReload() }
            }
            self.observer = id
            self.noticeObserver = await turns.observe { [weak self] notice in
                guard let target = notice.targetID, notice.status != "running" else { return }
                switch notice.kind {
                case .timelineBatch:
                    // 5枚のターンが 1 つ終わった: 待っている依頼なら、持ち主のいないまま残っていないか確かめる。
                    let finishing: String = notice.turnID
                    Task { @MainActor [weak self] in await self?.batchTurnSettled(target, finishing: finishing) }
                default:
                    break
                }
            }
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
        knownSubunitIDs = nil
        assistedIDs = []
        awaitedBatchID = nil
        inkAnswers = [:]
    }

    // MARK: - 読む

    var current: TimelineCardRecord? { currentID.flatMap { machine.cards[$0] } }
    /// 今のカードをヒントありとして記録するか(やり方の確認を開いた)。
    var isAssisted: Bool { assisted }
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
        // オンボーディングの計画の 1 枚目: 「二次方程式 1 / 6」。
        if card.payload["starter"]?.boolValue == true, let subunit = card.subunitId.flatMap({ workbook.subunits[$0] }), let unit = workbook.units[subunit.unitId] {
            let count = workbook.subunits.values.filter { $0.unitId == subunit.unitId }.count
            let index = workbook.orderedSubunits(unitID: subunit.unitId).firstIndex { $0.id == subunit.id } ?? 0
            return "\(unit.title) \(index + 1) / \(count)"
        }
        if !card.skills.isEmpty, card.skills.allSatisfy({ machine.skills[$0]?.status == "mastered" }) { return nil }
        let unitID = card.unitId ?? card.subunitId.flatMap { workbook.subunits[$0]?.unitId } ?? card.skills.compactMap { machine.skills[$0].flatMap { TimelineGraphSchedule.unitID(of: $0, workbook: workbook) } }.first
        let unit = unitID.flatMap { workbook.units[$0]?.title } ?? card.payload["unit_title"]?.stringValue
        let skill = card.skills.first.flatMap { machine.skills[$0]?.name }
        return Self.chipLabel(unit: unit, skill: skill, typeName: card.typeName)
    }

    /// 札に出す文字。単元名とスキル名を「・」でつなぎ、どちらも無ければ型の名前を使う。
    /// スキル名や型の名前には `$y=a(x-p)^2+q$` のような式が入る。札は 1 行の文字なので、読める文字に直す(`$` や `^` をそのまま出さない)。
    nonisolated static func chipLabel(unit: String?, skill: String?, typeName: String) -> String? {
        let parts: [String] = [unit, skill].compactMap { $0 }.filter { !$0.isEmpty }
        let label: String = parts.isEmpty ? typeName : parts.joined(separator: "・")
        return label.isEmpty ? nil : MathPlainText.preview(label)
    }

    // MARK: - 解く範囲

    /// 固定している単元(単元ホームから消えていれば nil)。
    var pinnedUnit: WorkbookUnitRecord? {
        guard let scopeUnitID, let unit = workbook.units[scopeUnitID], unit.status != "archived" else { return nil }
        return unit
    }

    /// 範囲のシートに並べる単元(単元ホームと同じ順)と、科目の見出し。
    struct ScopeSection: Identifiable {
        let subject: String
        let units: [WorkbookUnitRecord]
        var id: String { subject }
    }

    var scopeSections: [ScopeSection] {
        var order: [String] = []
        var groups: [String: [WorkbookUnitRecord]] = [:]
        for unit in workbook.orderedUnits() {
            let subject = UnitCatalog.subjectFamily(forUnitTitle: unit.title) ?? "その他"
            if groups[subject] == nil { order.append(subject) }
            groups[subject, default: []].append(unit)
        }
        return order.map { ScopeSection(subject: $0, units: groups[$0] ?? []) }
    }

    /// 単元の小単元の合格(マスの並び用)。
    func subunitMarks(_ unitID: String) -> [Bool] {
        workbook.orderedSubunits(unitID: unitID).map { $0.status == "passed" }
    }

    /// 固定中に上の帯の下に出す、次に進める小単元と単元の進み。
    var pinnedFocus: (title: String, marks: [Bool])? {
        guard let unit = pinnedUnit else { return nil }
        let subunits = workbook.orderedSubunits(unitID: unit.id)
        guard !subunits.isEmpty else { return nil }
        let next = subunits.first { $0.status != "passed" } ?? subunits.last
        return (next?.title ?? unit.title, subunits.map { $0.status == "passed" })
    }

    /// 範囲を変える。固定した時は、手元に作り置いた範囲の外のカードを捨て、その単元の5枚を頼む
    /// (前の範囲で頼んでいた5枚は止めない: 届いた時に範囲の外の分を捨てる)。
    /// 解いている途中のカードが範囲の外なら、範囲の中の次のカードに替える。
    func setScope(_ unitID: String?) async {
        isScopeSheetPresented = false
        guard unitID != scopeUnitID else { return }
        scopeUnitID = unitID
        TimelineScope.unitID = unitID
        guard let unitID, workbook.units[unitID] != nil else {
            await requestBatch()
            return
        }
        // 前の範囲で頼んでいる途中の5枚は止めて閉じる(届くのを待つと、範囲の中の5枚を頼むのが1回分遅れる)。
        if await hasOwnPendingBatch(purpose: "cards") {
            let stale: [String] = ownPendingBatchIDs(purpose: "cards")
            awaitedBatchID = nil
            for id in stale { await turns.interrupt(targetID: id) }
            await commit { machine in
                for id in stale where machine.batches[id]?.status == "requested" { machine.failBatch(id: id, error: "interrupted") }
            }
        }
        let outsideCurrent: Bool = current.map { TimelineScope.isOutside($0, unitID: unitID, workbook: workbook, timeline: machine) } ?? false
        let replacesCurrent: Bool = outsideCurrent && phase == .solving
        await discardOutsideScope(keeping: replacesCurrent ? nil : currentID)
        // 結果の画面で決めておいた次の1枚(やさしくした問題を含む)・戻る先が範囲の外なら、決め直す
        // (「次へ」で範囲の中の作り置きから出す)。今の結果はそのまま残す。
        let isOutside: (String?) -> Bool = { [machine = self.machine, workbook = self.workbook] id in
            guard let card = id.flatMap({ machine.cards[$0] }) else { return false }
            return TimelineScope.isOutside(card, unitID: unitID, workbook: workbook, timeline: machine)
        }
        if isOutside(decided?.cardID) { decided?.cardID = nil }
        if isOutside(returnToID) { returnToID = nil }
        // 速攻の途中: 解いている問題までは残し、この後に出す範囲の外の問題を抜く(全部抜けたら、今の問題で速攻を終える)。
        if case .rapid(let index) = phase, index < rapidIDs.count {
            rapidIDs = Array(rapidIDs.prefix(index + 1)) + rapidIDs.dropFirst(index + 1).filter { !isOutside($0) }
        }
        if replacesCurrent {
            if let id = currentID { await commit { machine in machine.discard(ids: [id]) } }
            badge = nil
            show(machine.queue.first?.id ?? machine.rapidCards.first?.id)
        }
        // 5枚を先に頼む(グラフの依頼より前に枠に並べる)。その単元のグラフがまだ無ければ、続けて作る。
        await requestBatch(force: true)
        await ensureGraphWork(units: [unitID])
    }

    /// 作り置きのうち、固定した範囲の外のカードを捨てる(届いたばかりの5枚も、ここで絞る)。
    private func discardOutsideScope(keeping keep: String?) async {
        guard let unit = pinnedUnit else { return }
        let outside: [String] = (machine.queue + machine.rapidCards).filter { $0.id != keep && TimelineScope.isOutside($0, unitID: unit.id, workbook: workbook, timeline: machine) }.map(\.id)
        guard !outside.isEmpty else { return }
        await commit { machine in machine.discard(ids: outside) }
    }

    /// 画面に出すスキル名。名前に入っている式は、読める文字に直す。
    func skillName(_ id: String) -> String { MathPlainText.preview(machine.skills[id]?.name ?? (id.split(separator: ".").last.map(String.init) ?? id)) }
    func solvedToday(_ id: String) -> Int { machine.solvedToday(skill: id) }
    func isNewSkill(_ id: String) -> Bool { machine.isNewSkill(id) }

    /// 「さっきの続き」の前のカードの解答(系列のバーの ○)。
    func chainSolved(_ card: TimelineCardRecord) -> Int {
        guard let chainID = TimelineRules.chainID(card) else { return 0 }
        return machine.chainMembers(chainID).filter { member in machine.attempts(cardID: member.id).contains { $0.verdict == "correct" } }.count
    }

    /// 結果の画面で難しさを明かす言葉(モデルが生徒に合わせて書いたもの)。正解の時だけ。
    var revealText: String? {
        guard lastAttempt?.verdict == "correct", let text = current?.payload["reveal"]?.stringValue, !text.isEmpty else { return nil }
        return text
    }

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

    // MARK: - 赤ペン

    /// 赤ペンを入れている最中か。

    /// 書く面から送った答案(この端末で書いたものだけ)。
    func inkAnswer(_ attemptID: String) -> TimelineInkAnswer? { inkAnswers[attemptID] }

    /// 答案の赤ペンを、書く面の紙の座標に置いたもの。書く面から送っていない答案・赤ペンの無い答案は空。
    func redPen(_ attemptID: String) -> [TimelineRedPen.Placed] {
        guard let answer = inkAnswers[attemptID], let attempt = machine.attempts[attemptID] else { return [] }
        return TimelineRedPen.place(TimelineMachine.redPenMarks(attempt), answer: answer)
    }

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
            let errors = TimelineMachine.errorEntries(attempt).compactMap { error -> String? in
                let wrote = error["wrote"]?.stringValue ?? "", correct = error["correct"]?.stringValue ?? "", detail = error["detail"]?.stringValue ?? ""
                return [wrote.isEmpty ? nil : "書いたもの: \(wrote)", correct.isEmpty ? nil : "正しくは: \(correct)", detail.isEmpty ? nil : detail].compactMap { $0 }.joined(separator: " / ")
            }
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
        // 解く範囲を固定していれば、1枚目もその範囲から選ぶ(固定した時に捨てた昨日の続きを、起動で戻さない)。
        let pinnedID: String? = pinnedUnit?.id
        let inScope: (String) -> Bool = { [machine = self.machine, workbook = self.workbook] id in
            guard let pinnedID, let card = machine.cards[id] else { return true }
            return !TimelineScope.isOutside(card, unitID: pinnedID, workbook: workbook, timeline: machine)
        }
        var first = TimelineRules.firstCard(cards: Array(machine.cards.values), attempts: machine.orderedAttempts, history: machine.historyCards, today: today)
        switch first {
        case .resume(let id), .rapid(let id), .history(let id):
            if !inScope(id) { first = .guide }
        case .guide:
            break
        }
        // 前の起動で出したまま答えていないカードがあれば、それから。
        if let shown = machine.cards.values.filter({ $0.status == "shown" && TimelineRules.day($0.updatedAt) == today && $0.origin != "history" && inScope($0.id) }).max(by: { $0.updatedAt < $1.updatedAt }) {
            show(shown.id)
        } else {
            switch first {
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
                if let next = machine.queue.first(where: { inScope($0.id) }) { show(next.id) } else { phase = workbook.units.isEmpty ? .guide : .waiting }
            }
        }
        // タイムラインを開いた時: グラフを頼むか決める。
        await ensureGraphWork()
        await requestBatch()
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
        // 利用枠を使い切ったら、新しいカードは出さない(前の起動で出したまま解いている途中のカードは出す)。
        // 手元が空で単元も無い時は、使い始めの案内のまま。
        let resuming: Bool = id.flatMap { machine.cards[$0] }?.status == "shown"
        let guide: Bool = id == nil && workbook.units.isEmpty && machine.cards.isEmpty
        if id == nil || id != currentID, !resuming, !guide, let denial = newWorkDenial() {
            stopForUsage(denial)
            return
        }
        guard let id, let card = machine.cards[id] else {
            currentID = nil
            phase = workbook.units.isEmpty && machine.cards.isEmpty ? .guide : .waiting
            Task { await requestBatch() }
            return
        }
        if card.origin != "rapid" || phase != .rapidDone { if badge != nil, currentID != nil, currentID != id { badge = nil } }
        currentID = id
        lastAttemptID = nil
        decided = nil
        assisted = assistedIDs.contains(id)
        cardStartedAt = ActiveClock.shared.now
        phase = .solving
        Task {
            await commit { machine in machine.markShown(id) }
            // グラフは頼まない(開いた時・単元ができた時・採点結果を反映した時だけ)。5枚は4枚目で頼む。
            await requestBatch()
        }
    }

    private var elapsed: Double { max(0, ActiveClock.shared.now - cardStartedAt) }

    private func stopForUsage(_ denial: UsageDenial) {
        timelineLog.notice("usage limit: no new card (\(denial.rawValue, privacy: .public))")
        if phase != .limitReached(denial) { limitPrompt = UsageLimitPrompt(denial: denial) }
        currentID = nil
        lastAttemptID = nil
        decided = nil
        badge = nil
        phase = .limitReached(denial)
    }

    /// 止まった画面のボタン: 案内のシートをもう一度出す。
    func openUsageLimit() {
        guard case .limitReached(let denial) = phase else { return }
        limitPrompt = UsageLimitPrompt(denial: denial)
    }

    /// 利用枠で止まっている時に、もう一度確かめる(前面に戻った時・案内を閉じた時・使用額かプランが変わった時)。続けられるなら手元のカードから。
    func recheckUsage() {
        guard case .limitReached(let previous) = phase else { return }
        if let denial = newWorkDenial() {
            if denial != previous { phase = .limitReached(denial) }
            return
        }
        phase = .waiting
        show(machine.queue.first?.id ?? machine.rapidCards.first?.id)
    }

    /// 撮った・指で書いた答案を送る(採点は裏で走る)。
    func submit(image data: Data, ink: TimelineInkAnswer? = nil) async {
        guard let card = current else { return }
        let seconds = elapsed
        do {
            // 書く面の答案は名前で分ける(採点に赤ペンの場所も頼むため)。
            let relative = (ink == nil ? "timeline-" : TimelineTurns.inkCapturePrefix) + "\(LedgerID.make()).jpg"
            try StruisPaths.prepare()
            try data.write(to: StruisPaths.captures.appendingPathComponent(relative), options: .atomic)
            let assisted = self.assisted
            let attemptID = try await ledger.commit { db in
                var machine = try TimelineMachine(loading: db)
                let id = machine.recordCapture(cardID: card.id, capturePath: relative, seconds: seconds, assisted: assisted)
                return (machine.events, id)
            }
            lastAttemptID = attemptID
            inkAnswers = ink.map { [attemptID: $0] } ?? [:]
            phase = .grading(attemptID)
            await reload()
            // 正しい答えの式があるふつうの問題は、まず答えだけを読む(一致すれば途中を読まずに ○。#101)。
            await turns.startTimeline(kind: TimelineTurns.firstGradingKind(for: card), targetID: attemptID)
        } catch {
            timelineLog.error("timeline capture failed: \(String(describing: error), privacy: .public)")
            actionError = "答案を保存できませんでした。もう一度送ってください。"
        }
    }

    /// 見直しが入れた問い・お知らせに答えた(正誤は無い)。問いの答えは、すぐ見直しに回す。
    func respond(choice: Int?) async {
        guard let card = current else { return }
        let seconds = elapsed
        let id = await commitValue { machine in machine.recordResponse(cardID: card.id, choice: choice, seconds: seconds) }
        if card.kind == TimelineCards.Kind.ask.rawValue, let id { await turns.startTimeline(kind: .timelineReview, targetID: id, prefetch: true) }
        decided = nil
        show(machine.queue.first?.id ?? machine.rapidCards.first?.id)
    }

    /// 結果の画面の「質問」から、判定に納得できないと伝える。その答案を見直しに回す。
    func dispute(_ text: String) async {
        guard let attempt = lastAttempt else { return }
        let attemptID = attempt.id
        await commit { machine in machine.recordDispute(attemptID: attemptID, text: text) }
        await turns.startTimeline(kind: .timelineReview, targetID: attemptID, prefetch: true)
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
        if !next.discardIDs.isEmpty {
            let ids = next.discardIDs
            await commit { machine in machine.discard(ids: ids) }
        }
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

    /// 採点の結果が出た後、次の 1 枚を決める(AI を待たない)。カードの種類(並べ替え・間違い探しなど)は、今日の記録を
    /// 読んだモデルが5枚の中で決める(アプリの決まりで差し込まない)。
    private func decide() async {
        guard let card = current, let attempt = lastAttempt else { return }
        let outcome: TimelineRules.Outcome
        switch attempt.verdict {
        case "correct": outcome = .correct
        case "wrong": outcome = .wrong
        default: return
        }
        let base = card.easierOf.flatMap { machine.cards[$0] }
        let initial = TimelineRules.next(after: card, outcome: outcome, queue: machine.queue.filter { $0.id != card.id }, rapid: machine.rapidCards,
                                         wrongBefore: card.origin == "easier", base: base)
        let returnTo = returnToID
        let next = await commitValue { machine -> TimelineRules.Next in
            var next = initial
            // 1回目の × では下りない: 同じ点を数値だけ変えた問題があればそれを次に出す。数値を変えた問題も × なら、やさしくした問題。
            if let baseID = next.makeEasierOf { next.cardID = machine.makeEasier(of: baseID, preferVariant: card.origin == "batch") }
            // やり方の確認の後の「同じ形」を解いた: 元の問題に戻る。
            if outcome == .correct, card.origin == "easier", let returnTo { next.cardID = returnTo }
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
            await requestBatch(force: next?.requestBatch == true)
        }
        show(next?.cardID ?? machine.queue.first?.id ?? machine.rapidCards.first?.id)
    }

    /// 新しい手順を押した: やり方の確認(ヒントありの扱いになる)。
    func openHowto() {
        assisted = true
        if let id = currentID { assistedIDs.insert(id) }
        phase = .howto
    }

    /// やり方の確認の「同じ形を 1 問解く」: そのカードのやさしい版を出し、解いたら元の問題に戻る。
    func solveSameForm() async {
        guard let card = current else { return }
        let cardID = card.id
        guard let easier = await commitValue({ machine in machine.makeEasier(of: cardID) }) ?? nil else { phase = .solving; return }
        returnToID = card.id
        // やり方を見た直後に解く「同じ形」も、ヒントありとして数える。
        assistedIDs.insert(easier)
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
        if let denial = newWorkDenial() {
            stopForUsage(denial)
            return
        }
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
            await turns.startTimeline(kind: TimelineTurns.firstGradingKind(for: card), targetID: attemptID)
        } catch {
            actionError = "答案を保存できませんでした。"
        }
        if index + 1 < rapidIDs.count, let denial = newWorkDenial() {
            // 送った答案は採点まで終える。次の問題は出さない。
            stopForUsage(denial)
        } else if index + 1 < rapidIDs.count {
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

    /// 5枚を頼む。手元の未使用が1枚以下(5枚のうち4枚目を出した時点)で、この端末が頼んでいる最中でなければ。
    /// 手元にカードが無い(学習者が5枚を待っている)時は先回りにしない: 先回りは知識グラフ・例題の先回りの後ろに並び、
    /// 学習者の処理に枠を譲るので、何も出せないまま待たせることになる(2026-10-31 の実機で「問題を用意しています」のまま進まなかった)。
    func requestBatch(force: Bool = false) async {
        guard !workbook.units.isEmpty || machine.hasGraph else { return }
        // 利用枠を使い切ったら新しいカードを頼まない(頼んでも送られずに失敗するだけ)。待っていたなら、待ちを抜けて案内へ。
        if let denial = newWorkDenial() {
            switch phase {
            case .waiting, .batchFailed: if currentID == nil { stopForUsage(denial) }
            default: break
            }
            return
        }
        let learnerWaiting: Bool = currentID == nil
        let pending: Bool = await hasOwnPendingBatch(purpose: "cards")
        if pending, learnerWaiting {
            let id: String? = ownPendingBatchIDs(purpose: "cards").last
            awaitedBatchID = id
            // 先回りとして頼んでいた依頼を、学習者が待っている依頼として通し直す(枠を待っていれば、先回りを止めて先に通す)。
            if let id { await turns.promote(targetID: id) }
        }
        guard force ? !pending : TimelineRules.shouldRequestBatch(unusedCount: machine.queue.filter { $0.id != currentID }.count, pending: pending) else { return }
        let accuracy = machine.accuracy
        let cap = TimelineRules.levelCap(accuracy: accuracy, currentLevel: machine.currentLevel)
        // 解く範囲を固定していれば、その単元を依頼の行に残す(届いたカードにその単元を付ける)。
        let request: LedgerJSON = pinnedUnit.map { .object(["scope_unit_id": .string($0.id)]) } ?? .emptyObject
        // 行を書いてからターンに渡すまでの間は、まだ誰も働いていない。その間に別の呼び出しが持ち主のいない依頼と見て閉じないように印を付ける。
        batchRequestsInFlight += 1
        batchRequestEpoch += 1
        defer { batchRequestsInFlight -= 1 }
        guard let id = await commitValue({ machine in machine.insertBatchRequest(purpose: "cards", request: request, accuracy: accuracy, levelCap: cap) }) else { return }
        if learnerWaiting {
            awaitedBatchID = id
            // 持ち主のいない依頼を閉じた時に「もう一度」の画面へ移っていても、新しい依頼を待つ画面に戻す。
            if case .batchFailed = phase { phase = .waiting }
        }
        await turns.startTimeline(kind: .timelineBatch, targetID: id, prefetch: !learnerWaiting)
    }

    /// この端末が頼んだ `requested` の依頼(古い順)。
    private func ownPendingBatchIDs(purpose: String) -> [String] {
        ownBatchIDs.filter { id in machine.batches[id].map { $0.purpose == purpose && $0.status == "requested" } ?? false }
            .sorted { (machine.batches[$0]?.createdAt ?? "") < (machine.batches[$1]?.createdAt ?? "") }
    }

    /// `hasOwnPendingBatch` が最後に確かめた、この端末の依頼。
    private var ownBatchIDs: [String] = []
    /// 5枚の依頼の行を書いてターンに渡し終えるまでの呼び出しの数(0 でなければ、持ち主のいない依頼を閉じない)。
    private var batchRequestsInFlight = 0
    /// 5枚の依頼を書き始めるたびに増やす(働いているかを確かめている間に、別の呼び出しが頼み終えていないかを見る)。
    private var batchRequestEpoch = 0

    /// この端末が頼んで、まだ返事が来ていない依頼があるか。iCloud 同期で届いた他の端末の `requested` は数えない
    /// (その端末が閉じたままだと、こちらがいつまでも待つことになる。Issue #57)。
    /// 行は `requested` でも、それに働いているターンがもう無い依頼(組んでいる途中でアプリが止められた・反映に失敗した等)は、
    /// 失敗として閉じてから数える。閉じないと、その日はいつまでも「頼んでいる最中」と見なして次を頼まず、待ちから抜けない。
    private func hasOwnPendingBatch(purpose: String) async -> Bool {
        let ids: [String] = machine.batches.values.filter { $0.purpose == purpose && $0.status == "requested" }.map(\.id)
        guard !ids.isEmpty else {
            ownBatchIDs = []
            return false
        }
        let deviceID: String = ledger.deviceID
        guard let own: [String] = try? await ledger.read({ db in try ids.filter { try Ledger.isLocal(.timelineBatches, $0, deviceID: deviceID, db) } }) else {
            // 読めなかった: 頼み直さない(二重に頼まない)。
            return true
        }
        var live: [String] = []
        var orphaned: [String] = []
        let epoch: Int = batchRequestEpoch
        for id in own {
            if await turns.isWorking(on: id) { live.append(id) } else { orphaned.append(id) }
        }
        if batchRequestsInFlight > 0 || batchRequestEpoch != epoch {
            // 今まさに頼んでいる(行は書いたがターンに渡す前の)依頼かもしれない: 閉じずに、頼んでいる最中として数える。
            live += orphaned
            orphaned = []
        }
        if !orphaned.isEmpty {
            timelineLog.error("timeline: closing \(orphaned.count, privacy: .public) requested batch(es) with no turn working on them")
            let closing: [String] = orphaned
            await commit { machine in
                for id in closing where machine.batches[id]?.status == "requested" { machine.failBatch(id: id, error: TimelineTurns.abandonedBatch) }
            }
        }
        ownBatchIDs = live
        return !live.isEmpty
    }

    /// 5枚のターンが終わった(頼み直しの行は、終わりを知らせる前に書かれる)。待っている依頼が `requested` のまま、
    /// 働いているターンも無ければ、失敗として閉じて「もう一度」を出す(待ちの画面に置き去りにしない)。
    /// - Parameter finishing: 終わりを知らせたターン(まだ外れていないので、働いているターンに数えない)。
    private func batchTurnSettled(_ batchID: String, finishing: String? = nil) async {
        guard batchID == awaitedBatchID else { return }
        await reload()
        guard phase == .waiting, awaitedBatchID == batchID, machine.batches[batchID]?.status == "requested", batchRequestsInFlight == 0 else { return }
        let epoch: Int = batchRequestEpoch
        guard !(await turns.isWorking(on: batchID, excluding: finishing)), batchRequestEpoch == epoch, batchRequestsInFlight == 0 else { return }
        timelineLog.error("timeline: awaited batch \(batchID, privacy: .public) ended with no result; closing it")
        await commit { machine in
            if machine.batches[batchID]?.status == "requested" { machine.failBatch(id: batchID, error: TimelineTurns.abandonedBatch) }
        }
    }

    /// 待ちの画面の「止める」: 待っている5枚の依頼を止める(止まった依頼は失敗になり、「もう一度」を出す)。
    func stopBatch() async {
        guard phase == .waiting, let id = awaitedBatchID else { return }
        await turns.interrupt(targetID: id)
        // 枠を待つ前・組んでいる途中に止まって、ターンの行が残らなかった時も、待ちを抜ける。
        await batchTurnSettled(id)
    }

    /// 知識グラフを作る(初めて開いた時・新しい単元ができた時)・丸ごと見直す(きっかけが起きた時)。頼んだかは台帳の行で見る。
    /// 1段下りる依頼は、採点結果を反映する時に `TimelineTurns.apply` が出す。
    /// - Parameter units: 単元の分を頼むのを、この単元だけにする(nil なら全部の単元)。
    private func ensureGraphWork(units: Set<String>? = nil) async {
        // 利用枠を使い切ったら頼まない(枠が戻った後の、開いた時・単元ができた時・採点の後に頼む)。
        guard newWorkDenial() == nil else { return }
        guard let request = TimelineGraphSchedule.next(timeline: machine, workbook: workbook, units: units) else { return }
        let profile = OnboardingProfile.load()
        let workbook = self.workbook
        // 判定から行を書くまでの間に、別の判定が同じものを頼んでいないか(書き込みの中で確かめ直す)。
        guard let id = await commitValue({ machine in
            TimelineTurns.insertGraphRequest(request, timeline: &machine, workbook: workbook, profile: profile)
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
        // この端末で単元ができた: その単元の分のグラフを頼むか決める。iCloud 同期で他の端末の単元が届いただけなら頼まない
        // (作った端末が頼む。2台で同じ依頼を重ねない。Issue #57)。
        let unitIDs = Set(workbook.units.keys)
        let added = knownUnitIDs.map { unitIDs.subtracting($0) } ?? []
        knownUnitIDs = unitIDs
        // 今ある単元に、この端末で小単元が足された(撮り足した授業の回。#132): その単元の分も頼む。
        let subunitIDs = Set(workbook.subunits.keys)
        let addedSubunits = knownSubunitIDs.map { subunitIDs.subtracting($0) } ?? []
        knownSubunitIDs = subunitIDs
        if started, !added.isEmpty || !addedSubunits.isEmpty {
            let deviceID = ledger.deviceID
            let workbook = self.workbook
            let own = Set((try? await ledger.read { db in
                try added.filter { try Ledger.isLocal(.workbookUnits, $0, deviceID: deviceID, db) }
                    + addedSubunits.filter { try Ledger.isLocal(.workbookSubunits, $0, deviceID: deviceID, db) }.compactMap { workbook.subunits[$0]?.unitId }
            }) ?? [])
            if !own.isEmpty { await ensureGraphWork(units: own) }
        }
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
        // 範囲を固定している: 届いた5枚のうち範囲の外の分を捨てる(固定する前に頼んでいた5枚)。
        await discardOutsideScope(keeping: currentID)
        // 5枚が届いた。
        let waiting: Bool
        switch phase {
        case .waiting, .batchFailed: waiting = true
        default: waiting = false
        }
        if waiting, let next = machine.queue.first ?? machine.rapidCards.first {
            awaitedBatchID = nil
            show(next.id)
        } else if phase == .waiting, let id = awaitedBatchID, let batch = machine.batches[id], batch.status == "failed" {
            // 待っていた5枚の依頼が失敗した: 待ちを抜けて、理由とやり直しのボタンを出す。
            awaitedBatchID = nil
            phase = .batchFailed(batch.error ?? "")
        }
        // 届いた5枚が全部範囲の外だった: 待ったまま止まらないよう、範囲の中の5枚を頼み直す。
        if phase == .waiting, pinnedUnit != nil, machine.queue.isEmpty, machine.rapidCards.isEmpty,
           awaitedBatchID.flatMap({ machine.batches[$0]?.status }) != "requested" {
            await requestBatch()
        }
        if phase == .guide, !workbook.units.isEmpty {
            phase = .waiting
            await requestBatch()
        }
    }

    func dismissError() { actionError = nil }

    /// 5枚の依頼が失敗した画面の「もう一度」。
    func retryBatch() async {
        guard case .batchFailed = phase else { return }
        phase = .waiting
        await requestBatch(force: true)
    }

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
