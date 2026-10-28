import Foundation
import GRDB

/// 学習タイムラインの状態(Issue #46)。`WorkbookMachine` と同じく、台帳の射影を読んで、変更はイベントとして積む
/// (`Ledger.commit` で一度に書く)。次に出す 1 枚の判断は `TimelineRules`、点検は `TimelineGraph`・`TimelineCards` が持つ。
nonisolated struct TimelineMachine {
    var skills: [String: TimelineSkillRecord] = [:]
    var edges: [String: TimelineSkillEdgeRecord] = [:]
    var changes: [String: TimelineMapChangeRecord] = [:]
    var batches: [String: TimelineBatchRecord] = [:]
    var cards: [String: TimelineCardRecord] = [:]
    var attempts: [String: TimelineAttemptRecord] = [:]
    var dips: [String: TimelineDipRecord] = [:]
    var log: [String: TimelineLogRecord] = [:]
    private(set) var events: [LedgerEvent] = []

    var now: () -> String = { LedgerClock.now() }
    var newID: () -> String = { LedgerID.make() }
    var calendar: Calendar = .current

    init() {}

    init(loading db: Database) throws {
        skills = Dictionary(uniqueKeysWithValues: try TimelineSkillRecord.fetchAll(db).map { ($0.id, $0) })
        edges = Dictionary(uniqueKeysWithValues: try TimelineSkillEdgeRecord.fetchAll(db).map { ($0.id, $0) })
        changes = Dictionary(uniqueKeysWithValues: try TimelineMapChangeRecord.fetchAll(db).map { ($0.id, $0) })
        batches = Dictionary(uniqueKeysWithValues: try TimelineBatchRecord.fetchAll(db).map { ($0.id, $0) })
        cards = Dictionary(uniqueKeysWithValues: try TimelineCardRecord.fetchAll(db).map { ($0.id, $0) })
        attempts = Dictionary(uniqueKeysWithValues: try TimelineAttemptRecord.fetchAll(db).map { ($0.id, $0) })
        dips = Dictionary(uniqueKeysWithValues: try TimelineDipRecord.fetchAll(db).map { ($0.id, $0) })
        log = Dictionary(uniqueKeysWithValues: try TimelineLogRecord.fetchAll(db).map { ($0.id, $0) })
    }

    mutating func put(_ kind: String, _ row: TimelineSkillRecord) { skills[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: TimelineSkillEdgeRecord) { edges[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: TimelineMapChangeRecord) { changes[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: TimelineBatchRecord) { batches[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: TimelineCardRecord) { cards[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: TimelineAttemptRecord) { attempts[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: TimelineDipRecord) { dips[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: TimelineLogRecord) { log[row.id] = row; events.append(.upsert(kind, row)) }

    // MARK: - 読む

    var today: String { TimelineRules.day(now(), calendar: calendar) ?? "" }

    /// 解答(古い順)。
    var orderedAttempts: [TimelineAttemptRecord] {
        attempts.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    func attempts(cardID: String) -> [TimelineAttemptRecord] {
        orderedAttempts.filter { $0.cardId == cardID }
    }

    /// 手元の、まだ出していないカード(出す順)。速攻用とやさしい版は別に持つ。
    var queue: [TimelineCardRecord] {
        cards.values.filter { $0.status == "unused" && ($0.origin == "batch" || $0.origin == "derived" || $0.origin == "review") }
            .sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) }
    }

    var rapidCards: [TimelineCardRecord] {
        cards.values.filter { $0.status == "unused" && $0.origin == "rapid" }.sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) }
    }

    var activeSkills: [TimelineSkillRecord] {
        skills.values.filter(\.isActive).sorted { $0.id < $1.id }
    }

    var hasGraph: Bool { !skills.isEmpty }

    func pendingBatch(purpose: String) -> TimelineBatchRecord? {
        batches.values.filter { $0.purpose == purpose && $0.status == "requested" }.max { $0.createdAt < $1.createdAt }
    }

    /// 今日の解答(飛ばした問題は除く)の数。上端の「今日 N問」。
    var answeredToday: Int {
        let today = today
        return attempts.values.filter { TimelineRules.day($0.createdAt, calendar: calendar) == today && $0.verdict != "skipped" }.count
    }

    /// 今日の最初の解答の時刻(「時計 14分」)。
    var firstAnswerToday: Date? {
        let today = today
        return orderedAttempts.first { TimelineRules.day($0.createdAt, calendar: calendar) == today }.flatMap { LedgerClock.parse($0.createdAt) }
    }

    /// 今日まだ 1 問も解いていない(次の解答はその日の最初の 1 問で、正答率に数えない)。
    var isFirstOfDay: Bool {
        let today = today
        return !attempts.values.contains { TimelineRules.day($0.createdAt, calendar: calendar) == today }
    }

    var accuracy: Double? { TimelineRules.accuracy(orderedAttempts) }

    /// 今の段: 数に入った直近の解答のカードの段。無ければ 1。
    var currentLevel: Int {
        orderedAttempts.last { $0.countsForAccuracy }.flatMap { cards[$0.cardId]?.level } ?? 1
    }

    /// 答案ごとのスキルの ○×。採点で決めた印(`skill_marks`)があればそれ。新しい採点で印が無い(スキルが 0 個、または
    /// 見直し待ち)なら無し。前の版の答案は、カードの skills に答案全体の正誤を付けたものとして読む。
    func skillMarks(_ attempt: TimelineAttemptRecord) -> [(skill: String, correct: Bool)] {
        if let marks = attempt.skillMarks { return marks.keys.sorted().map { (skill: $0, correct: marks[$0] == "correct") } }
        guard attempt.grade == nil, attempt.verdict == "correct" || attempt.verdict == "wrong", let card = cards[attempt.cardId] else { return [] }
        return card.skills.map { (skill: $0, correct: attempt.verdict == "correct") }
    }

    /// 同じ段の解答にかかった秒数(2択カードの「いつも」)。
    var secondsHistory: [(level: Int, seconds: Double)] {
        orderedAttempts.compactMap { attempt in
            guard attempt.verdict == "correct" || attempt.verdict == "wrong", let card = cards[attempt.cardId], card.kind == "solve", card.origin != "rapid" else { return nil }
            return (card.level, attempt.seconds)
        }
    }

    /// 前の2択カードの後に解いたカードの数(無ければ nil)。
    var cardsSinceLastDip: Int? {
        guard let last = dips.values.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        return attempts.values.filter { $0.createdAt > last.createdAt }.count
    }

    /// 点ごとの結果(誤りの記録・止まり防止に使う)。
    var skillResults: [(skill: String, correct: Bool, day: String)] {
        orderedAttempts.flatMap { attempt -> [(skill: String, correct: Bool, day: String)] in
            let day = TimelineRules.day(attempt.createdAt, calendar: calendar) ?? ""
            return skillMarks(attempt).map { (skill: $0.skill, correct: $0.correct, day: day) }
        }
    }

    /// その手順を今日解いた回数(「○○」)。
    func solvedToday(skill: String) -> Int {
        let today = today
        return orderedAttempts.filter { attempt in
            TimelineRules.day(attempt.createdAt, calendar: calendar) == today && skillMarks(attempt).contains { $0.skill == skill && $0.correct }
        }.count
    }

    /// まだ一度も解いていない手順か(「新しい手順」)。
    func isNewSkill(_ id: String) -> Bool {
        guard let skill = skills[id] else { return true }
        return skill.attempts == 0 && skill.status != "mastered" && skill.status != "assumed"
    }

    func directPrerequisites(of id: String) -> [String] {
        edges.values.filter { $0.skillId == id && $0.relation == "prerequisite" && $0.requiresSkillId != id }.map(\.requiresSkillId).sorted()
    }

    func allPrerequisites(of id: String) -> [String] {
        var seen: Set<String> = []
        var stack = directPrerequisites(of: id)
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            stack.append(contentsOf: directPrerequisites(of: next))
        }
        return seen.sorted()
    }

    /// 前の問題の、続きのカード(「さっきの続き」の何問目か)。
    func chainMembers(_ chainID: String) -> [TimelineCardRecord] {
        cards.values.filter { TimelineRules.chainID($0) == chainID }.sorted { (TimelineRules.chainPosition($0)?.position ?? 0) < (TimelineRules.chainPosition($1)?.position ?? 0) }
    }

    /// 前に解けた過去の問題(1枚目の候補)。古い順に新しい日の物から。
    var historyCards: [TimelineCardRecord] {
        let solved = Set(orderedAttempts.filter { $0.verdict == "correct" }.map(\.cardId))
        return cards.values.filter { $0.origin == "history" && $0.status == "unused" && !solved.contains($0.id) }.sorted { $0.position < $1.position }
    }

    var nextPosition: Int { (cards.values.map(\.position).max() ?? 0) + 1 }

    // MARK: - 5枚を頼む

    mutating func insertBatchRequest(purpose: String, request: LedgerJSON, accuracy: Double?, levelCap: Int?) -> String {
        let id = newID()
        put("timeline.batch_requested", TimelineBatchRecord(
            id: id, purpose: purpose, status: "requested", reason: "", accuracy: accuracy, levelCap: levelCap, request: request, model: "",
            inputTokens: 0, outputTokens: 0, cacheWriteTokens: 0, cacheReadTokens: 0, retries: 0, rejected: [], error: nil,
            createdAt: now(), updatedAt: now()
        ))
        return id
    }

    mutating func failBatch(id: String, error: String) {
        guard var row = batches[id] else { return }
        row.status = "failed"
        row.error = error
        row.updatedAt = now()
        put("timeline.batch_failed", row)
    }

    /// 頼んだ分のトークン数(実行監査の `turn_tokens`)を記録する。
    mutating func noteUsage(batchID: String, model: String, executions: [LedgerJSON]) {
        guard var row = batches[batchID] else { return }
        let tokens = executions.compactMap { $0["turn_tokens"]?.objectValue }.last ?? [:]
        let input = tokens["input_tokens"]?.intValue ?? 0
        let cached = tokens["cached_input_tokens"]?.intValue ?? 0
        let written = tokens["cache_write_input_tokens"]?.intValue ?? 0
        row.model = model
        row.inputTokens += max(0, input - cached - written)
        row.cacheReadTokens += cached
        row.cacheWriteTokens += written
        row.outputTokens += tokens["output_tokens"]?.intValue ?? 0
        row.updatedAt = now()
        put("timeline.batch_usage", row)
    }

    nonisolated enum BatchResult: Equatable, Sendable {
        case applied(cards: Int)
        /// 欠けがあって 1 回だけ作り直させる。
        case retry
        case failed(String)
    }

    /// 5枚の結果を受け取る。skills の ID・段の上限・検算に欠けがあれば 1 回だけ作り直させ、それでも欠けていれば欠けたカードを捨てる。
    mutating func applyBatch(id: String, batch: TimelineCards.Batch) -> BatchResult {
        guard var row = batches[id], row.status == "requested" else { return .failed("batch is not requested") }
        let allowed = Set(activeSkills.map(\.id))
        let cap = row.levelCap
        var accepted: [TimelineCards.Draft] = []
        var rejected: [String] = []
        for (index, draft) in batch.cards.enumerated() {
            let defects = TimelineCards.defects(draft, allowedSkills: allowed, levelCap: cap)
            if defects.isEmpty { accepted.append(draft) } else { rejected.append("card \(index + 1): " + defects.joined(separator: "; ")) }
        }
        if !rejected.isEmpty, row.retries < 1 {
            row.retries += 1
            row.rejected = rejected
            row.updatedAt = now()
            put("timeline.batch_rejected", row)
            return .retry
        }
        guard !accepted.isEmpty else {
            failBatch(id: id, error: "no acceptable cards: " + rejected.joined(separator: " | "))
            return .failed("no acceptable cards")
        }
        // 手元の古いカードの後ろに並べる。
        var position = nextPosition
        var previousChain: (id: String, position: Int, total: Int)?
        for draft in accepted {
            var chain: LedgerJSON?
            if let c = draft.chain, c.total > 1 {
                let chainID: String
                if c.position > 1, let previous = previousChain, previous.position == c.position - 1 {
                    chainID = previous.id
                } else if c.position > 1, let continued = continuingChain(position: c.position, total: c.total) {
                    chainID = continued
                } else {
                    chainID = newID()
                }
                var object: [String: LedgerJSON] = ["chain_id": .string(chainID), "position": .number(Double(c.position)), "total": .number(Double(c.total))]
                if let changed = c.changed, !changed.isEmpty { object["changed"] = .string(changed) }
                if let previous = c.previous, !previous.isEmpty { object["previous"] = .string(previous) }
                chain = .object(object)
                previousChain = (chainID, c.position, c.total)
            } else {
                previousChain = nil
            }
            _ = insertCard(from: draft, batchID: id, position: position, chain: chain)
            position += 1
        }
        // 速攻用の 3 問(手元に置いておく)。古い未使用の速攻は 6 問まで残す。
        for rapid in batch.rapid.prefix(TimelineRules.rapidCount) where !rapid.prompt.isEmpty {
            put("timeline.card_added", TimelineCardRecord(
                id: newID(), batchId: id, position: position, kind: "solve", level: 1, skills: [rapid.skill].filter { allowed.isEmpty || allowed.contains($0) },
                typeName: "速攻", prompt: rapid.prompt, math: rapid.math ?? "", question: "", answerKey: rapid.answerKey, answerExpr: rapid.answerExpr ?? "",
                checkpoints: [], commonMistakes: [], estimatedSeconds: 10, chain: nil, easierOf: nil, subunitId: nil, unitId: nil,
                payload: .emptyObject, origin: "rapid", status: "unused", createdAt: now(), updatedAt: now()
            ))
            position += 1
        }
        for stale in rapidCards.dropLast(6) { discard(ids: [stale.id]) }
        // グラフにない前提の申告は、見直しの材料にする。
        for wanted in batch.wantedPrerequisites where !wanted.name.isEmpty {
            recordChange(kind: "wanted_prerequisite", detail: .object(["name": .string(wanted.name), "kind": .string(wanted.kind), "required_by": .string(wanted.requiredBy)]), attemptIDs: [], source: "batch")
        }
        if !batch.graphOps.isEmpty { _ = applyGraphOps(batch.graphOps, source: "app") }
        row = batches[id] ?? row
        row.status = "ready"
        row.reason = batch.reason
        row.rejected = rejected
        row.updatedAt = now()
        put("timeline.batch_ready", row)
        return .applied(cards: accepted.count)
    }

    /// 頼み直しの前に止まった「さっきの続き」(同じ全体の数で、1 つ前の位置まで解いたもの)。
    private func continuingChain(position: Int, total: Int) -> String? {
        cards.values.filter { card in
            guard let c = TimelineRules.chainPosition(card) else { return false }
            return c.total == total && c.position == position - 1
        }.max { $0.createdAt < $1.createdAt }.flatMap(TimelineRules.chainID)
    }

    /// 材料からカードを 1 枚作る。解いて撮る以外の種類は、材料から中身を組み替える(作れなければ解いて撮る問題にする)。
    @discardableResult
    mutating func insertCard(from draft: TimelineCards.Draft, batchID: String?, position: Int, chain: LedgerJSON?) -> String {
        var payload: [String: LedgerJSON] = [
            "steps": .array(draft.steps.map(LedgerJSON.string)),
            "mistake_steps": .array(draft.mistakeSteps.map { .object(["step": .number(Double($0.step)), "wrong": .string($0.wrong)]) }),
            "checks": .array(draft.checks.map { .object(["left": .string($0.left), "right": .string($0.right)]) }),
        ]
        if let facts = draft.facts {
            var object: [String: LedgerJSON] = [:]
            if let value = facts.answerValue { object["answer_value"] = .number(value) }
            if let vertex = facts.vertex, vertex.count == 2 { object["vertex"] = .array(vertex.map { .number($0) }) }
            if let axis = facts.axis { object["axis"] = .number(axis) }
            payload["facts"] = .object(object)
        }
        if let easier = draft.easier { payload["easier"] = LedgerEvent.encode(easier) }
        if !draft.reveal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { payload["reveal"] = .string(draft.reveal) }
        if let variant = draft.variant, !(variant.prompt.isEmpty && variant.math.isEmpty) { payload["variant"] = LedgerEvent.encode(variant) }
        for (key, value) in [("compare", draft.compare), ("reason", draft.reason), ("howto", draft.howto), ("diagnostic", draft.diagnostic)] {
            if let value, value != .null { payload[key] = value }
        }
        let unitID: String? = nil
        var card = TimelineCardRecord(
            id: newID(), batchId: batchID, position: position, kind: TimelineCards.Kind.solve.rawValue, level: min(4, max(1, draft.level)),
            skills: draft.skills, typeName: draft.typeName, prompt: draft.prompt, math: draft.math, question: draft.question,
            answerKey: draft.answerKey, answerExpr: draft.answerExpr, checkpoints: draft.checkpoints, commonMistakes: draft.commonMistakes,
            estimatedSeconds: max(5, draft.estimatedSeconds), chain: chain, easierOf: nil, subunitId: draft.subunitId, unitId: unitID,
            payload: .object(payload), origin: "batch", status: "unused", createdAt: now(), updatedAt: now()
        )
        if let kind = TimelineCards.Kind(rawValue: draft.kind), kind != .solve, let derived = TimelineCards.derive(kind, from: card) {
            card.kind = kind.rawValue
            card.payload = .object(payload.merging(derived.payload) { _, new in new }.merging(["problem": .string(TimelineCards.problemLine(prompt: draft.prompt, math: draft.math))]) { old, _ in old })
            card.prompt = derived.prompt
            if !kind.needsReading { card.subunitId = nil }
        }
        put("timeline.card_added", card)
        return card.id
    }

    /// 元のカードから組み替えたカードを、次に出す位置へ差し込む。
    @discardableResult
    mutating func insertDerived(_ kind: TimelineCards.Kind, from baseID: String) -> String? {
        guard let base = cards[baseID], let derived = TimelineCards.derive(kind, from: base) else { return nil }
        let first = queue.first?.position ?? nextPosition
        var payload = base.payload.objectValue ?? [:]
        payload.merge(derived.payload) { _, new in new }
        payload["problem"] = .string(TimelineCards.problemLine(prompt: base.payload["problem"]?.stringValue ?? base.prompt, math: base.math))
        payload["derived_from"] = .string(base.id)
        let card = TimelineCardRecord(
            id: newID(), batchId: base.batchId, position: first - 1, kind: kind.rawValue, level: base.level, skills: base.skills,
            typeName: base.typeName, prompt: derived.prompt, math: kind == .predict ? base.math : "", question: "", answerKey: base.answerKey,
            answerExpr: base.answerExpr, checkpoints: [], commonMistakes: base.commonMistakes, estimatedSeconds: 20, chain: nil, easierOf: nil,
            subunitId: nil, unitId: base.unitId, payload: .object(payload), origin: "derived", status: "unused", createdAt: now(), updatedAt: now()
        )
        put("timeline.card_derived", card)
        return card.id
    }

    /// 間違えた時に出すやさしい版(AI を待たない)。元のカードの `easier` から作る。`preferVariant` なら、同じ点を数値だけ
    /// 変えた問題(`variant`)があればそちら(1回目の × では下りず、同じ形をもう 1 問)。数値だけ変えた問題は origin を
    /// variant、やさしくした問題は easier にして分けて記録する(「一段戻す」は easier だけ)。
    @discardableResult
    mutating func makeEasier(of cardID: String, preferVariant: Bool = false) -> String? {
        guard let base = cards[cardID] else { return nil }
        let variant = preferVariant ? base.payload["variant"]?.objectValue : nil
        guard let easier = variant ?? base.payload["easier"]?.objectValue else { return nil }
        let origin = variant != nil ? "variant" : "easier"
        if let existing = cards.values.first(where: { $0.easierOf == cardID && $0.origin == origin }) { return existing.id }
        let first = queue.first?.position ?? nextPosition
        let card = TimelineCardRecord(
            id: newID(), batchId: base.batchId, position: first - 1, kind: "solve", level: max(1, easier["level"]?.intValue ?? (variant != nil ? base.level : base.level - 1)),
            skills: base.skills, typeName: base.typeName, prompt: easier["prompt"]?.stringValue ?? base.prompt, math: easier["math"]?.stringValue ?? "",
            question: easier["question"]?.stringValue ?? "", answerKey: easier["answer_key"]?.stringValue ?? "",
            answerExpr: easier["answer_expr"]?.stringValue ?? "", checkpoints: easier["checkpoints"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            commonMistakes: base.commonMistakes, estimatedSeconds: max(20, base.estimatedSeconds / 2), chain: base.chain, easierOf: base.id,
            subunitId: nil, unitId: base.unitId, payload: .object(["steps": base.payload["steps"] ?? .emptyArray, "variant": .bool(variant != nil)]), origin: origin, status: "unused",
            createdAt: now(), updatedAt: now()
        )
        put("timeline.card_easier", card)
        return card.id
    }

    /// 前に解けた問題(単元ホームの ○)を、1枚目の候補として置く。
    @discardableResult
    mutating func insertHistory(prompt: String, answerKey: String, subunitID: String?, unitTitle: String, solvedAt: String) -> String {
        let card = TimelineCardRecord(
            id: newID(), batchId: nil, position: nextPosition, kind: "solve", level: 1, skills: [], typeName: unitTitle, prompt: prompt, math: "",
            question: "", answerKey: answerKey, answerExpr: "", checkpoints: [], commonMistakes: [], estimatedSeconds: 30, chain: nil, easierOf: nil,
            subunitId: nil, unitId: nil, payload: .object(["solved_at": .string(solvedAt), "unit_title": .string(unitTitle)]),
            origin: "history", status: "unused", createdAt: now(), updatedAt: now()
        )
        put("timeline.card_history", card)
        return card.id
    }

    mutating func markShown(_ id: String) {
        guard var card = cards[id], card.status == "unused" else { return }
        card.status = "shown"
        card.updatedAt = now()
        put("timeline.card_shown", card)
    }

    mutating func discard(ids: [String]) {
        for id in ids {
            guard var card = cards[id], card.status == "unused" || card.status == "shown" else { continue }
            card.status = "discarded"
            card.updatedAt = now()
            put("timeline.card_discarded", card)
        }
    }

    /// 前の日に頼んだ未使用の5枚は捨てる(続きの残りと速攻用は残す)。
    mutating func discardStale(keep: Set<String>) {
        let today = today
        let stale = queue.filter { TimelineRules.day($0.createdAt, calendar: calendar).map { $0 < today } ?? false && !keep.contains($0.id) }
        discard(ids: stale.map(\.id))
        for batch in batches.values where batch.status == "requested" && batch.purpose == "cards" && (TimelineRules.day(batch.createdAt, calendar: calendar).map { $0 < today } ?? false) {
            failBatch(id: batch.id, error: "stale")
        }
    }

    // MARK: - 解答

    /// 撮った・指で書いた答案を綴じる(採点は裏で走る)。
    mutating func recordCapture(cardID: String, capturePath: String, seconds: Double, assisted: Bool) -> String {
        let id = newID()
        let firstTry = attempts(cardID: cardID).isEmpty
        let card = cards[cardID]
        put("timeline.attempt_grading", TimelineAttemptRecord(
            id: id, cardId: cardID, capturePath: capturePath, verdict: "grading", checkpointResults: .emptyArray, errors: .emptyArray,
            learnerAnswer: "", cause: "unknown", seconds: seconds, firstTry: firstTry, assisted: assisted, skipReason: nil, keySuspect: false,
            countsForAccuracy: card.map { TimelineRules.countsForAccuracy(card: $0, isFirstOfDay: isFirstOfDay, verdict: "correct") } ?? false,
            feedback: "", createdAt: now(), gradedAt: nil
        ))
        markAnswered(cardID)
        return id
    }

    /// 端末の中で採点したカード(タップ・ドラッグ・払う)。
    @discardableResult
    mutating func recordInteractive(cardID: String, correct: Bool, seconds: Double, answer: LedgerJSON) -> String {
        let id = newID()
        let firstTry = attempts(cardID: cardID).isEmpty
        put("timeline.attempt_recorded", TimelineAttemptRecord(
            id: id, cardId: cardID, capturePath: nil, verdict: correct ? "correct" : "wrong", checkpointResults: .array([answer]), errors: .emptyArray,
            learnerAnswer: "", cause: "unknown", seconds: seconds, firstTry: firstTry, assisted: false, skipReason: nil, keySuspect: false,
            countsForAccuracy: false, feedback: "", createdAt: now(), gradedAt: now()
        ))
        markAnswered(cardID)
        if let card = cards[cardID] { applySkills(card: card, correct: correct, assisted: false, withinTime: true, firstTry: firstTry, attemptID: id) }
        logAttempt(id)
        return id
    }

    mutating func recordSkip(cardID: String, seconds: Double) -> String {
        let id = newID()
        put("timeline.attempt_skipped", TimelineAttemptRecord(
            id: id, cardId: cardID, capturePath: nil, verdict: "skipped", checkpointResults: .emptyArray, errors: .emptyArray, learnerAnswer: "",
            cause: "unknown", seconds: seconds, firstTry: attempts(cardID: cardID).isEmpty, assisted: false, skipReason: nil, keySuspect: false,
            countsForAccuracy: false, feedback: "", createdAt: now(), gradedAt: now()
        ))
        markAnswered(cardID)
        logAttempt(id)
        return id
    }

    /// 飛ばした理由(難しそう too_hard / 簡単すぎる too_easy)。押さなくてもよい。
    mutating func setSkipReason(attemptID: String, reason: String) {
        guard var row = attempts[attemptID], row.verdict == "skipped" else { return }
        row.skipReason = reason
        put("timeline.skip_reason", row)
        appendLog(kind: "skip_reason", attemptID: attemptID, text: TimelineLogText.skipReason(row))
    }

    private mutating func markAnswered(_ cardID: String) {
        guard var card = cards[cardID], card.status != "answered", card.status != "broken" else { return }
        card.status = "answered"
        card.updatedAt = now()
        put("timeline.card_answered", card)
    }

    // MARK: - 採点

    /// 採点の答え(2026-10-25)。決まった形で出させるのは、正誤(correct・partial・wrong)、生徒の答え、関係するスキルの ID。
    /// メモと書き起こしは今日の記録に載せる(中身の書き方は決めない)。前の版の答え(verdict・checkpoints・errors)も読める。
    nonisolated struct Grading: Codable, Sendable {
        nonisolated struct Checkpoint: Codable, Sendable { var text: String; var result: String }
        nonisolated struct Error: Codable, Sendable {
            var kind: String
            var `where`: String
            var wrote: String
            var correct: String
            var detail: String
        }
        var readable: Bool
        var grade: String
        var learnerAnswer: String
        var skillIds: [String]?
        var transcript: String
        var notes: String
        var comment: String
        var keySuspect: Bool
        var solvedAnswer: String
        var learnerExpr: String
        var checkpoints: [Checkpoint]
        var errors: [Error]
        var cause: String
        enum CodingKeys: String, CodingKey {
            case readable, grade, verdict, transcript, notes, comment, checkpoints, errors, cause, feedback
            case learnerAnswer = "learner_answer"
            case skillIds = "skill_ids"
            case keySuspect = "key_suspect"
            case solvedAnswer = "solved_answer"
            case learnerExpr = "learner_expr"
        }
        init(readable: Bool = true, grade: String, learnerAnswer: String = "", skillIds: [String]? = [], transcript: String = "", notes: String = "",
             comment: String = "", keySuspect: Bool = false) {
            self.readable = readable
            self.grade = grade
            self.learnerAnswer = learnerAnswer
            self.skillIds = skillIds
            self.transcript = transcript
            self.notes = notes
            self.comment = comment
            self.keySuspect = keySuspect
            solvedAnswer = ""
            learnerExpr = ""
            checkpoints = []
            errors = []
            cause = "unknown"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            readable = try c.decodeIfPresent(Bool.self, forKey: .readable) ?? true
            let legacy = try c.decodeIfPresent(String.self, forKey: .verdict)
            let grade = try c.decodeIfPresent(String.self, forKey: .grade) ?? legacy ?? "wrong"
            self.grade = ["correct", "partial", "wrong"].contains(grade) ? grade : "wrong"
            learnerAnswer = try c.decodeIfPresent(String.self, forKey: .learnerAnswer) ?? ""
            // 前の版の答え(skill_ids が無い)は、カードの skills に正誤を付ける。
            skillIds = try c.decodeIfPresent([String].self, forKey: .skillIds)
            transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
            notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
            comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? c.decodeIfPresent(String.self, forKey: .feedback) ?? ""
            keySuspect = try c.decodeIfPresent(Bool.self, forKey: .keySuspect) ?? false
            solvedAnswer = try c.decodeIfPresent(String.self, forKey: .solvedAnswer) ?? ""
            learnerExpr = try c.decodeIfPresent(String.self, forKey: .learnerExpr) ?? ""
            checkpoints = try c.decodeIfPresent([Checkpoint].self, forKey: .checkpoints) ?? []
            errors = try c.decodeIfPresent([Error].self, forKey: .errors) ?? []
            cause = try c.decodeIfPresent(String.self, forKey: .cause) ?? "unknown"
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(readable, forKey: .readable)
            try c.encode(grade, forKey: .grade)
            try c.encode(learnerAnswer, forKey: .learnerAnswer)
            try c.encodeIfPresent(skillIds, forKey: .skillIds)
            try c.encode(transcript, forKey: .transcript)
            try c.encode(notes, forKey: .notes)
            try c.encode(comment, forKey: .comment)
            try c.encode(keySuspect, forKey: .keySuspect)
        }
        static func parse(_ text: String) throws -> Grading {
            try TimelineReply.decode(Grading.self, from: text)
        }
    }

    nonisolated struct GradingOutcome: Equatable, Sendable {
        var verdict: String
        /// 答えが間違っていた問題(捨てて、以後の復習にも使わない)。
        var broken = false
        /// 単元ホームの合格に数える(段3以上・初回・ヒントなし)。
        var countsForUnitHome = false
    }

    /// 採点の結果を綴じる。正誤は correct・partial(答えは合うが途中に誤り)・wrong の 3 つで、partial は切り替え・正答率・
    /// 定着では × として数える。スキルの ○× は、採点したモデルが挙げた ID で付ける: 1 つならその点に、2 つ以上なら付けずに
    /// 置いて見直しで決める。答えが間違っていた疑い(key_suspect)で、学習者が正解なら、壊れていたのは問題の方。
    mutating func applyGrading(attemptID: String, grading: Grading) -> GradingOutcome {
        guard var row = attempts[attemptID], let card = cards[row.cardId] else { return GradingOutcome(verdict: "failed") }
        row.gradedAt = now()
        guard grading.readable else {
            row.verdict = "unreadable"
            row.countsForAccuracy = false
            row.feedback = grading.comment.isEmpty ? "字が読めませんでした。撮り直してください。" : grading.comment
            row.transcript = grading.transcript
            row.notes = grading.notes
            put("timeline.attempt_unreadable", row)
            reopen(card.id)
            logAttempt(attemptID)
            return GradingOutcome(verdict: "unreadable")
        }
        var grade = grading.grade
        // 04・09 は読み取った式を数式で判定する(何通りもある答えも、頂点を計算すれば判定できる)。読めなければモデルの判定のまま。
        if let kind = TimelineCards.Kind(rawValue: card.kind), kind == .fillLine || kind == .inverse,
           let written = TimelineCards.gradeWritten(card, learnerExpr: grading.learnerExpr.isEmpty ? grading.learnerAnswer : grading.learnerExpr) {
            grade = written ? (grade == "partial" ? "partial" : "correct") : "wrong"
        }
        let verdict = grade == "correct" ? "correct" : "wrong"
        var broken = false
        if grading.keySuspect, verdict == "correct", card.kind == "solve" {
            broken = true
            var bad = card
            bad.status = "broken"
            bad.updatedAt = now()
            put("timeline.card_broken", bad)
            recordChange(kind: "broken_problem", detail: .object(["card_id": .string(card.id), "type_name": .string(card.typeName),
                                                                   "answer_key": .string(card.answerKey), "learner_answer": .string(grading.learnerAnswer)]),
                         attemptIDs: [attemptID], source: "app", reviewed: true)
            // 同じ元のやさしい版も使わない。
            discard(ids: cards.values.filter { $0.easierOf == card.id }.map(\.id))
        }
        row.verdict = verdict
        row.grade = grade
        row.learnerAnswer = grading.learnerAnswer
        row.transcript = grading.transcript
        row.notes = grading.notes
        row.checkpointResults = .array(grading.checkpoints.map { .object(["text": .string($0.text), "result": .string($0.result)]) })
        row.errors = .array(grading.errors.map { LedgerEvent.encode($0) })
        row.cause = ["practice", "connection"].contains(grading.cause) ? grading.cause : "unknown"
        row.keySuspect = grading.keySuspect
        row.feedback = grading.comment
        if broken { row.countsForAccuracy = false }
        // 関係するスキル: グラフにある点だけ(ID が実在するかの確認)。前の版の答え(skill_ids が無い)はカードの skills。
        let known = Set(activeSkills.map(\.id))
        let named = grading.skillIds.map { ids in ids.map(TimelineGraph.normalizedID).filter { known.isEmpty || known.contains($0) } }
        var ids = named ?? card.skills
        var seen: Set<String> = []
        ids = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        row.skillIds = ids
        row.skillsPending = ids.count >= 2
        if ids.count == 1, !broken || verdict == "correct" { row.skillMarks = [ids[0]: verdict] }
        put("timeline.attempt_graded", row)
        let withinTime = row.seconds <= Double(card.estimatedSeconds)
        if let marks = row.skillMarks {
            for (id, mark) in marks.sorted(by: { $0.key < $1.key }) {
                applySkill(id: id, card: card, correct: mark == "correct", assisted: row.assisted, withinTime: withinTime, firstTry: row.firstTry, attemptID: attemptID)
            }
        }
        if verdict == "wrong" { applyWrongFixes(card: card, grading: grading, attemptID: attemptID) }
        logAttempt(attemptID)
        return GradingOutcome(verdict: verdict, broken: broken,
                              countsForUnitHome: !broken && TimelineRules.countsForUnitHome(card: card, firstTry: row.firstTry, assisted: row.assisted))
    }

    mutating func failGrading(attemptID: String) {
        guard var row = attempts[attemptID] else { return }
        row.verdict = "failed"
        row.countsForAccuracy = false
        row.gradedAt = now()
        row.feedback = "採点できませんでした。もう一度撮ってください。"
        put("timeline.attempt_failed", row)
        reopen(row.cardId)
        logAttempt(attemptID)
    }

    /// 撮り直せるように、カードを出した状態に戻す。
    private mutating func reopen(_ cardID: String) {
        guard var card = cards[cardID], card.status == "answered" else { return }
        card.status = "shown"
        card.updatedAt = now()
        put("timeline.card_reopened", card)
    }

    // MARK: - 「できること」と知識グラフ

    /// 端末の中で採点したカード(タップ・ドラッグ・払う)の解答を、カードの「できること」全部に反映する。
    private mutating func applySkills(card: TimelineCardRecord, correct: Bool, assisted: Bool, withinTime: Bool, firstTry: Bool, attemptID: String) {
        for id in card.skills where !id.isEmpty {
            applySkill(id: id, card: card, correct: correct, assisted: assisted, withinTime: withinTime, firstTry: firstTry, attemptID: attemptID)
        }
    }

    /// 1 つの「できること」に ○× を付ける。グラフにない ID(グラフを作る前)は、仮の点として足す。
    mutating func applySkill(id: String, card: TimelineCardRecord, correct: Bool, assisted: Bool, withinTime: Bool, firstTry: Bool, attemptID: String) {
        guard !id.isEmpty else { return }
        let skill = skills[id] ?? TimelineSkillRecord(
            id: id, name: id.split(separator: ".").last.map(String.init) ?? id, kind: "procedure", unitId: card.unitId, status: "practicing",
            correctDates: [], masteryThreshold: TimelineRules.masteryThreshold, attempts: 0, lastCorrectAt: nil, nextReviewAt: nil, reviewCount: 0,
            replacedBy: [], source: "batch", createdAt: now(), updatedAt: now()
        )
        let wasMastered = skill.status == "mastered"
        let updated = TimelineRules.record(skill, correct: correct, assisted: assisted, withinTime: withinTime, at: now(), calendar: calendar)
        put(correct ? "timeline.skill_correct" : "timeline.skill_wrong", updated)
        if wasMastered, !correct {
            recordChange(kind: "back_to_practice", detail: .object(["skill_id": .string(id), "mastery_threshold": .number(Double(updated.masteryThreshold))]), attemptIDs: [attemptID], source: "app")
        }
        // 前提が未定着なのに、上の問題が一発で ○: 前提を「できると推定」にする(後日、30秒問題と混ぜて確かめる)。
        if correct, firstTry, !assisted, card.kind == "solve", card.level >= 2 {
            for prerequisite in allPrerequisites(of: id) {
                guard let skill = skills[prerequisite], let assumed = TimelineRules.assume(skill, at: now()) else { continue }
                put("timeline.skill_assumed", assumed)
                recordChange(kind: "assume", detail: .object(["skill_id": .string(prerequisite), "because": .string(id)]), attemptIDs: [attemptID], source: "app")
            }
        }
        // 同じ点の中で、問題の形によって ○ と × が分かれる: 2つに分けさせる(次の5枚の呼び出しで)。
        let results = orderedAttempts.compactMap { attempt -> (typeName: String, correct: Bool)? in
            guard let mark = skillMarks(attempt).first(where: { $0.skill == id }), let c = cards[attempt.cardId] else { return nil }
            return (c.typeName, mark.correct)
        }
        if let split = TimelineRules.splitCandidate(results: results),
           !changes.values.contains(where: { $0.kind == "split_requested" && $0.detail["skill_id"]?.stringValue == id }) {
            recordChange(kind: "split_requested", detail: .object(["skill_id": .string(id), "good_type": .string(split.good), "bad_type": .string(split.bad)]), attemptIDs: [attemptID], source: "app")
        }
    }

    /// × のときにアプリがその場で直すこと: 組み合わせのミス・原因の候補の 30秒問題。
    private mutating func applyWrongFixes(card: TimelineCardRecord, grading: Grading, attemptID: String) {
        // 原因の候補の 30秒問題を × → グラフにない前提を足してそこへ下りる。
        if let diagnostic = card.payload["diagnostic"]?.objectValue, let skillID = diagnostic["skill_id"]?.stringValue, !skillID.isEmpty {
            let requiredBy = diagnostic["required_by"]?.stringValue ?? card.skills.first ?? ""
            addPrerequisite(id: TimelineGraph.normalizedID(skillID), name: diagnostic["skill_name"]?.stringValue ?? skillID,
                            kind: diagnostic["skill_kind"]?.stringValue ?? "procedure", requiredBy: requiredBy, attemptID: attemptID)
        }
        // 前提が全部定着しているのに組み合わせのミス: 前提へ下りず、「組み合わせ」の点を足す。
        if grading.errors.contains(where: { $0.kind == "combination" }), card.skills.count >= 2 {
            let parts = Array(card.skills.prefix(2))
            let id = TimelineGraph.normalizedID(parts.joined(separator: "+"))
            if skills[id] == nil {
                let names = parts.map { skills[$0]?.name ?? $0 }
                put("timeline.skill_added", TimelineSkillRecord(
                    id: id, name: names.joined(separator: "と") + "を両方使う", kind: "combination", unitId: card.unitId, status: "practicing",
                    correctDates: [], masteryThreshold: TimelineRules.masteryThreshold, attempts: 0, lastCorrectAt: nil, nextReviewAt: nil,
                    reviewCount: 0, replacedBy: [], source: "app", createdAt: now(), updatedAt: now()
                ))
                for part in parts where skills[part] != nil { addEdge(skillID: id, requires: part, relation: "prerequisite", source: "app", note: "") }
                recordChange(kind: "combination", detail: .object(["skill_id": .string(id), "parts": .array(parts.map(LedgerJSON.string))]), attemptIDs: [attemptID], source: "app")
            }
        }
    }

    mutating func addPrerequisite(id: String, name: String, kind: String, requiredBy: String, attemptID: String) {
        if skills[id] == nil {
            put("timeline.skill_added", TimelineSkillRecord(
                id: id, name: name, kind: TimelineGraph.kinds.contains(kind) ? kind : "procedure", unitId: skills[requiredBy]?.unitId, status: "practicing",
                correctDates: [], masteryThreshold: TimelineRules.masteryThreshold, attempts: 0, lastCorrectAt: nil, nextReviewAt: nil,
                reviewCount: 0, replacedBy: [], source: "app", createdAt: now(), updatedAt: now()
            ))
        }
        guard skills[requiredBy] != nil, requiredBy != id else { return }
        let existing = edges.values.map { (from: $0.requiresSkillId, to: $0.skillId) }
        guard TimelineGraph.cycle(in: existing + [(from: id, to: requiredBy)]) == nil else { return }
        if !edges.values.contains(where: { $0.skillId == requiredBy && $0.requiresSkillId == id && $0.relation == "prerequisite" }) {
            addEdge(skillID: requiredBy, requires: id, relation: "prerequisite", source: "app", note: "")
        }
        recordChange(kind: "add_prerequisite", detail: .object(["skill_id": .string(id), "required_by": .string(requiredBy)]), attemptIDs: [attemptID], source: "app")
    }

    mutating func addEdge(skillID: String, requires: String, relation: String, source: String, note: String) {
        put("timeline.edge_added", TimelineSkillEdgeRecord(id: newID(), skillId: skillID, requiresSkillId: requires, relation: relation, source: source, note: note, createdAt: now()))
    }

    mutating func recordChange(kind: String, detail: LedgerJSON, attemptIDs: [String], source: String, reviewed: Bool = false) {
        put("timeline.map_changed", TimelineMapChangeRecord(id: newID(), kind: kind, detail: detail, attemptIds: attemptIDs, reviewed: reviewed, source: source, createdAt: now()))
    }

    /// 最初に作るグラフ・単元の分の点と線を足す。点検に通らなければ問題の一覧を返す(何も足さない)。
    mutating func applyGraph(_ output: TimelineGraph.Output, source: String, unitID: String?) -> [TimelineGraph.Problem] {
        let nodes = output.nodes.map { node -> TimelineGraph.Node in
            var copy = node
            copy.id = TimelineGraph.normalizedID(node.id)
            if copy.unitId == nil { copy.unitId = unitID }
            return copy
        }
        let edgesIn = output.edges.map { edge -> TimelineGraph.Edge in
            var copy = edge
            copy.from = TimelineGraph.normalizedID(edge.from)
            copy.to = TimelineGraph.normalizedID(edge.to)
            return copy
        }
        // 仮の点(グラフを作る前のカードで足したもの)は、同じ ID の点で置き換えてよい。
        let provisional = skills.filter { $0.value.source == "batch" }
        let existing = skills.filter { $0.value.source != "batch" }
        let problems = TimelineGraph.validate(nodes: nodes, edges: edgesIn, existing: existing, existingEdges: Array(edges.values))
        guard problems.isEmpty else { return problems }
        for node in nodes {
            var row = provisional[node.id] ?? TimelineSkillRecord(
                id: node.id, name: node.name, kind: node.kind, unitId: node.unitId, status: "practicing", correctDates: [],
                masteryThreshold: TimelineRules.masteryThreshold, attempts: 0, lastCorrectAt: nil, nextReviewAt: nil, reviewCount: 0,
                replacedBy: [], source: source, createdAt: now(), updatedAt: now()
            )
            row.name = node.name
            row.kind = node.kind
            row.unitId = node.unitId
            row.source = source
            row.updatedAt = now()
            put("timeline.skill_added", row)
        }
        for edge in edgesIn {
            addEdge(skillID: edge.to, requires: edge.from, relation: edge.relation, source: source, note: edge.note)
        }
        recordChange(kind: "build", detail: .object(["nodes": .number(Double(nodes.count)), "edges": .number(Double(edgesIn.count)),
                                                     "start_node_id": output.startNodeId.map { .string(TimelineGraph.normalizedID($0)) } ?? .null,
                                                     "unit_id": unitID.map(LedgerJSON.string) ?? .null]), attemptIDs: [], source: "build", reviewed: true)
        return []
    }

    /// 操作の列(見直し・5枚の呼び出しの分割)を点検してから反映する。分けた・まとめた点の記録は引き継ぐ。
    mutating func applyGraphOps(_ ops: [TimelineGraph.Operation], source: String) -> [TimelineGraph.Problem] {
        let normalized = ops.map { op -> TimelineGraph.Operation in
            var copy = op
            copy.node = op.node.map { var n = $0; n.id = TimelineGraph.normalizedID(n.id); return n }
            copy.nodeIds = op.nodeIds.map(TimelineGraph.normalizedID)
            copy.into = op.into.map { var n = $0; n.id = TimelineGraph.normalizedID(n.id); return n }
            copy.edge = op.edge.map { var e = $0; e.from = TimelineGraph.normalizedID(e.from); e.to = TimelineGraph.normalizedID(e.to); return e }
            return copy
        }
        let plan = TimelineGraph.plan(normalized, existing: skills, existingEdges: Array(edges.values))
        guard plan.problems.isEmpty else { return plan.problems }
        for node in plan.addNodes {
            // 分けた・まとめた先は、元の点の記録を引き継ぐ。
            let sources = plan.replacements.filter { $0.value.contains(node.id) }.keys.compactMap { skills[$0] }
            let inherited = sources.first
            put("timeline.skill_added", TimelineSkillRecord(
                id: node.id, name: node.name, kind: node.kind, unitId: node.unitId ?? inherited?.unitId, status: inherited?.status ?? "practicing",
                correctDates: Array(Set(sources.flatMap(\.correctDates))).sorted(), masteryThreshold: sources.map(\.masteryThreshold).max() ?? TimelineRules.masteryThreshold,
                attempts: sources.map(\.attempts).reduce(0, +), lastCorrectAt: sources.compactMap(\.lastCorrectAt).max(), nextReviewAt: inherited?.nextReviewAt,
                reviewCount: inherited?.reviewCount ?? 0, replacedBy: [], source: source, createdAt: now(), updatedAt: now()
            ))
        }
        for (id, targets) in plan.replacements {
            guard var row = skills[id] else { continue }
            row.replacedBy = targets
            row.updatedAt = now()
            put("timeline.skill_replaced", row)
            // 元の点の線を外す(付け替えた線は addEdges にある)。
            for edge in edges.values where edge.skillId == id || edge.requiresSkillId == id {
                events.append(.delete("timeline.edge_removed", entity: .timelineSkillEdges, entityID: edge.id))
                edges[edge.id] = nil
            }
            // 記録を引き継ぐ: カードの skills も先へ付け替える。
            for var card in cards.values where card.skills.contains(id) {
                card.skills = card.skills.flatMap { $0 == id ? targets : [$0] }
                card.updatedAt = now()
                put("timeline.card_reskilled", card)
            }
        }
        for id in plan.removeNodes {
            guard var row = skills[id] else { continue }
            row.replacedBy = ["removed"]
            row.updatedAt = now()
            put("timeline.skill_removed", row)
            for edge in edges.values where edge.skillId == id || edge.requiresSkillId == id {
                events.append(.delete("timeline.edge_removed", entity: .timelineSkillEdges, entityID: edge.id))
                edges[edge.id] = nil
            }
        }
        for edge in plan.removeEdges {
            for row in edges.values where row.requiresSkillId == edge.from && row.skillId == edge.to && row.relation == edge.relation {
                events.append(.delete("timeline.edge_removed", entity: .timelineSkillEdges, entityID: row.id))
                edges[row.id] = nil
            }
        }
        for edge in plan.addEdges where !edges.values.contains(where: { $0.requiresSkillId == edge.from && $0.skillId == edge.to && $0.relation == edge.relation }) {
            addEdge(skillID: edge.to, requires: edge.from, relation: edge.relation, source: source, note: edge.note)
        }
        for op in normalized {
            recordChange(kind: op.op, detail: LedgerEvent.encode(op), attemptIDs: op.evidence, source: source, reviewed: source == "review")
        }
        return []
    }

    // MARK: - 1段ずつ分解する(2026-10-24)

    /// 点の初期値。
    private func newSkill(_ node: TimelineGraph.Node, source: String, expansion: String) -> TimelineSkillRecord {
        TimelineSkillRecord(
            id: node.id, name: node.name, kind: node.kind, unitId: node.unitId, status: "practicing", correctDates: [],
            masteryThreshold: TimelineRules.masteryThreshold, attempts: 0, lastCorrectAt: nil, nextReviewAt: nil, reviewCount: 0,
            replacedBy: [], source: source, createdAt: now(), updatedAt: now(), expansion: expansion
        )
    }

    /// 小単元の到達目標を一番上の点にする(小単元 ID を持つ)。もうある小単元は足さない。足した点の ID を返す。
    @discardableResult
    mutating func addGoalNodes(_ subunits: [WorkbookSubunitRecord]) -> [String] {
        var added: [String] = []
        for subunit in subunits where !skills.values.contains(where: { $0.unitId == subunit.id && $0.isActive }) {
            let id = TimelineGraph.normalizedID("goal." + subunit.id)
            guard skills[id] == nil else { continue }
            let title = subunit.title.trimmingCharacters(in: .whitespacesAndNewlines)
            // 仮の点(グラフを作る前のカードで足したもの)と同じ ID は無い(goal. は分解でしか作らない)。
            put("timeline.skill_added", newSkill(TimelineGraph.Node(id: id, name: title.isEmpty ? subunit.outcome : title, kind: "combination", unitId: subunit.id),
                                                 source: "build", expansion: "pending"))
            added.append(id)
        }
        return added
    }

    /// まだ前提を調べていない、今の単元の中身の点(次の段で分解する)。
    var pendingSkills: [TimelineSkillRecord] {
        activeSkills.filter { $0.expansion == "pending" }
    }

    nonisolated struct StepResult: Equatable, Sendable {
        var added: [String]
        var edges: Int
        var droppedCycles: [String]
        var removedRedundant: [String]
    }

    /// 分解の答えを点検してから入れる。循環を作る線だけを捨てて記録し、他の点を経由して届く直接の線は消す。
    @discardableResult
    mutating func applyDecomposition(_ output: TimelineGraph.Decomposition, requested: [String: String?], descend: Bool) -> StepResult {
        let plan = TimelineGraph.plan(decomposition: output, requested: requested, descend: descend, existing: skills, existingEdges: Array(edges.values))
        for node in plan.addNodes {
            put("timeline.skill_added", newSkill(node, source: descend ? "descend" : "build", expansion: plan.expansion[node.id] ?? "unexplored"))
        }
        for id in plan.dugNodes {
            guard var row = skills[id], row.expansion != "done" else { continue }
            row.expansion = "done"
            row.updatedAt = now()
            put("timeline.skill_dug", row)
        }
        for edge in plan.addEdges {
            addEdge(skillID: edge.to, requires: edge.from, relation: "prerequisite", source: descend ? "descend" : "build", note: "")
        }
        let removed = removeRedundantEdges()
        let dropped = plan.droppedCycles.map { "\($0.from) -> \($0.to)" }
        recordChange(kind: descend ? "descend" : "decompose", detail: .object([
            "nodes": .array(plan.dugNodes.map(LedgerJSON.string)), "added": .array(plan.addNodes.map { .string($0.id) }),
            "dropped_cycle_edges": .array(dropped.map(LedgerJSON.string)), "removed_redundant_edges": .array(removed.map(LedgerJSON.string)),
            "problems": .object(plan.problems.mapValues(LedgerJSON.string)),
        ]), attemptIDs: [], source: "build", reviewed: true)
        return StepResult(added: plan.addNodes.map(\.id), edges: plan.addEdges.count, droppedCycles: dropped, removedRedundant: removed)
    }

    /// 他の点を経由して届く直接の前提の線を消す(直前の前提だけを残す)。消した線を「元 -> 先」で返す。
    mutating func removeRedundantEdges() -> [String] {
        let prerequisites = edges.values.filter { $0.relation == "prerequisite" && $0.requiresSkillId != $0.skillId }
        let redundant = TimelineGraph.redundantEdges(prerequisites.sorted { $0.id < $1.id }.map { (from: $0.requiresSkillId, to: $0.skillId) })
        var removed: [String] = []
        for edge in redundant {
            for row in edges.values where row.relation == "prerequisite" && row.requiresSkillId == edge.from && row.skillId == edge.to {
                events.append(.delete("timeline.edge_removed", entity: .timelineSkillEdges, entityID: row.id))
                edges[row.id] = nil
            }
            removed.append("\(edge.from) -> \(edge.to)")
        }
        return removed
    }

    /// よくある勘違いを付ける(形が決まった後の別の依頼)。同じ中身は重ねない。
    mutating func applyMisconceptions(_ output: TimelineGraph.Misconceptions) -> Int {
        var count = 0
        for item in output.items {
            let id = TimelineGraph.normalizedID(item.nodeId)
            guard skills[id]?.isActive == true else { continue }
            for note in item.misconceptions.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !note.isEmpty {
                guard !edges.values.contains(where: { $0.skillId == id && $0.relation == "misconception" && $0.note == note }) else { continue }
                addEdge(skillID: id, requires: id, relation: "misconception", source: "build", note: note)
                count += 1
            }
        }
        return count
    }

    /// 前の版で作った点に「まだ掘っていない」印を付ける(作り直さない)。前提の線が出ていない一番下の点が unexplored、
    /// 前提の線がある点は done。
    mutating func markLegacyExpansion() {
        for var skill in skills.values where skill.expansion == nil && skill.isActive {
            skill.expansion = directPrerequisites(of: skill.id).isEmpty ? "unexplored" : "done"
            skill.updatedAt = now()
            put("timeline.skill_expansion_marked", skill)
        }
    }

    /// 上位モデルの見直しが要るか: 前回の見直しから、アプリが足した行・変えた行が3つ溜まった、または2日続けて同じ所で止まった。
    var needsReview: Bool {
        let pending = changes.values.filter { !$0.reviewed && $0.source == "app" }
        if pending.count >= TimelineRules.reviewAfterChanges { return true }
        return !TimelineRules.stuckTwoDays(results: skillResults, today: today).isEmpty && !pending.isEmpty
    }

    mutating func markReviewed() {
        for var change in changes.values where !change.reviewed {
            change.reviewed = true
            put("timeline.map_reviewed", change)
        }
    }

    // MARK: - 見直し(2026-10-25)

    /// 見直しが入れるカードの位置: 生徒が次に解く位置(今解いている問題の次)。
    private var frontPosition: Int { (queue.first?.position ?? nextPosition) - 1 }

    /// 確かめの 1 問を、生徒が次に解く位置に入れる。
    @discardableResult
    mutating func addReviewCard(prompt: String, math: String, question: String, answerKey: String, skillIDs: [String], level: Int, note: String) -> String {
        let known = Set(activeSkills.map(\.id))
        let card = TimelineCardRecord(
            id: newID(), batchId: nil, position: frontPosition, kind: TimelineCards.Kind.solve.rawValue, level: min(4, max(1, level)),
            skills: skillIDs.map(TimelineGraph.normalizedID).filter { known.isEmpty || known.contains($0) }, typeName: "確かめ", prompt: prompt, math: math,
            question: question, answerKey: answerKey, answerExpr: "", checkpoints: [], commonMistakes: [], estimatedSeconds: 60, chain: nil, easierOf: nil,
            subunitId: nil, unitId: nil, payload: .object(["note": .string(note)]), origin: "review", status: "unused", createdAt: now(), updatedAt: now()
        )
        put("timeline.card_review_added", card)
        return card.id
    }

    /// 生徒に選ばせる問いを、次に出す位置に入れる(選んだものは今日の記録に載る)。
    @discardableResult
    mutating func addAsk(question: String, options: [String], aboutAttemptID: String?) -> String {
        let card = TimelineCardRecord(
            id: newID(), batchId: nil, position: frontPosition, kind: TimelineCards.Kind.ask.rawValue, level: 1, skills: [], typeName: "", prompt: question,
            math: "", question: "", answerKey: "", answerExpr: "", checkpoints: [], commonMistakes: [], estimatedSeconds: 20, chain: nil, easierOf: nil,
            subunitId: nil, unitId: nil, payload: .object(["options": .array(options.map(LedgerJSON.string)), "about_attempt_id": aboutAttemptID.map(LedgerJSON.string) ?? .null]),
            origin: "review", status: "unused", createdAt: now(), updatedAt: now()
        )
        put("timeline.card_ask_added", card)
        return card.id
    }

    /// 判定を直したことなどを生徒に伝えるカードを、次に出す位置に入れる。
    @discardableResult
    mutating func addNotice(text: String, aboutAttemptID: String?) -> String {
        let card = TimelineCardRecord(
            id: newID(), batchId: nil, position: frontPosition, kind: TimelineCards.Kind.notice.rawValue, level: 1, skills: [], typeName: "", prompt: text,
            math: "", question: "", answerKey: "", answerExpr: "", checkpoints: [], commonMistakes: [], estimatedSeconds: 10, chain: nil, easierOf: nil,
            subunitId: nil, unitId: nil, payload: .object(["about_attempt_id": aboutAttemptID.map(LedgerJSON.string) ?? .null]),
            origin: "review", status: "unused", createdAt: now(), updatedAt: now()
        )
        put("timeline.card_notice_added", card)
        return card.id
    }

    /// 問い・お知らせのカードに答えた(正誤は無い)。
    @discardableResult
    mutating func recordResponse(cardID: String, choice: Int?, seconds: Double) -> String {
        let id = newID()
        put("timeline.attempt_answered", TimelineAttemptRecord(
            id: id, cardId: cardID, capturePath: nil, verdict: "answered", checkpointResults: .array(choice.map { [.number(Double($0))] } ?? []), errors: .emptyArray,
            learnerAnswer: "", cause: "unknown", seconds: seconds, firstTry: true, assisted: false, skipReason: nil, keySuspect: false,
            countsForAccuracy: false, feedback: "", createdAt: now(), gradedAt: now()
        ))
        markAnswered(cardID)
        logAttempt(id)
        return id
    }

    /// 前の判定を取り消して直す。正誤を直し、スキルの印を付け直す(直した印の分だけ、その点に ○× を記録し直す)。
    /// 問題が無ければ nil、あれば理由を返す。
    mutating func revise(attemptID: String, grade: String, marks: [String: String]?, note: String) -> String? {
        guard var row = attempts[attemptID], let card = cards[row.cardId] else { return "attempt not found: \(attemptID)" }
        guard ["correct", "partial", "wrong"].contains(grade) else { return "grade must be correct, partial or wrong" }
        let known = Set(activeSkills.map(\.id))
        let before = row.skillMarks ?? [:]
        var after = before
        if let marks {
            for (id, mark) in marks {
                let id = TimelineGraph.normalizedID(id)
                guard known.isEmpty || known.contains(id) else { return "unknown skill: \(id)" }
                guard mark == "correct" || mark == "wrong" else { return "skill result must be correct or wrong" }
                after[id] = mark
            }
        } else if row.skillsPending != true {
            // 印を指定しなかった: 付いていた印を、直した正誤に合わせる。
            for id in after.keys { after[id] = grade == "correct" ? "correct" : "wrong" }
        }
        let previous = row.grade ?? row.verdict
        row.grade = grade
        row.verdict = grade == "correct" ? "correct" : "wrong"
        row.skillMarks = after.isEmpty ? row.skillMarks : after
        if marks != nil, Set(after.keys).isSuperset(of: Set(row.skillIds ?? [])) { row.skillsPending = false }
        row.reviewNotes = [row.reviewNotes, "判定を直した(\(previous) → \(grade)): " + note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        row.reviewedAt = now()
        put("timeline.attempt_revised", row)
        let withinTime = row.seconds <= Double(card.estimatedSeconds)
        for (id, mark) in after.sorted(by: { $0.key < $1.key }) where before[id] != mark {
            applySkill(id: id, card: card, correct: mark == "correct", assisted: row.assisted, withinTime: withinTime, firstTry: row.firstTry, attemptID: attemptID)
        }
        recordChange(kind: "revise_grade", detail: .object(["attempt_id": .string(attemptID), "from": .string(previous), "to": .string(grade), "note": .string(note)]),
                     attemptIDs: [attemptID], source: "review", reviewed: true)
        appendLog(kind: "revise", attemptID: attemptID, text: TimelineLogText.revise(row, from: previous, note: note, machine: self))
        return nil
    }

    nonisolated struct Review: Codable, Sendable {
        nonisolated struct SkillResult: Codable, Sendable {
            var attemptID: String
            var skillID: String
            var result: String
            enum CodingKeys: String, CodingKey {
                case result
                case attemptID = "attempt_id"
                case skillID = "skill_id"
            }
        }
        var skillResults: [SkillResult]
        var notes: String
        enum CodingKeys: String, CodingKey {
            case notes
            case skillResults = "skill_results"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            skillResults = try c.decodeIfPresent([SkillResult].self, forKey: .skillResults) ?? []
            notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        }
        static func parse(_ text: String) throws -> Review { try TimelineReply.decode(Review.self, from: text) }
    }

    /// 見直しの結果を綴じる: 決めずに置いたスキルの ○×、見直しのメモ。見直した答案(対象と、それより前に採点した未見直しの答案)に印を付ける。
    mutating func applyReview(targetID: String, review: Review) {
        let known = Set(activeSkills.map(\.id))
        var decided: [String: [String: String]] = [:]
        for item in review.skillResults where item.result == "correct" || item.result == "wrong" {
            let id = TimelineGraph.normalizedID(item.skillID)
            guard known.isEmpty || known.contains(id), attempts[item.attemptID] != nil else { continue }
            decided[item.attemptID, default: [:]][id] = item.result
        }
        for (attemptID, marks) in decided.sorted(by: { $0.key < $1.key }) {
            guard var row = attempts[attemptID], let card = cards[row.cardId] else { continue }
            let before = row.skillMarks ?? [:]
            var after = before
            for (id, mark) in marks { after[id] = mark }
            row.skillMarks = after
            if Set(after.keys).isSuperset(of: Set(row.skillIds ?? [])) { row.skillsPending = false }
            put("timeline.attempt_skills_decided", row)
            let withinTime = row.seconds <= Double(card.estimatedSeconds)
            for (id, mark) in after.sorted(by: { $0.key < $1.key }) where before[id] != mark {
                applySkill(id: id, card: card, correct: mark == "correct", assisted: row.assisted, withinTime: withinTime, firstTry: row.firstTry, attemptID: attemptID)
            }
        }
        let cutoff = attempts[targetID]?.gradedAt ?? attempts[targetID]?.createdAt ?? now()
        for var row in orderedAttempts where row.reviewedAt == nil && (row.id == targetID || (row.grade != nil && (row.gradedAt ?? row.createdAt) <= cutoff)) {
            if row.id == targetID, !review.notes.isEmpty {
                row.reviewNotes = [row.reviewNotes, review.notes].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            }
            row.reviewedAt = now()
            put("timeline.attempt_reviewed", row)
        }
        if let text = TimelineLogText.review(targetID: targetID, notes: review.notes, decided: decided, machine: self) {
            appendLog(kind: "review", attemptID: targetID, text: text)
        }
    }

    /// 生徒が判定に納得できないと伝えた(結果の画面の「質問」から)。見直しに回す。
    mutating func recordDispute(attemptID: String, text: String) {
        guard var row = attempts[attemptID] else { return }
        row.dispute = text.isEmpty ? "判定に納得できない" : text
        row.reviewedAt = nil
        row.disputedAt = now()
        put("timeline.attempt_disputed", row)
        appendLog(kind: "dispute", attemptID: attemptID, text: TimelineLogText.dispute(row))
    }

    // MARK: - 今日の記録

    /// 今日の記録(保存した順)。
    var todayLog: [TimelineLogRecord] {
        let today = today
        return log.values.filter { $0.day == today }.sorted { ($0.seq, $0.createdAt, $0.id) < ($1.seq, $1.createdAt, $1.id) }
    }

    /// 1 件足す(書いた時点の文のまま残す)。`first` はその日の先頭に入れる(その日最初の「今の単元とスキルの一覧」。
    /// その日まだ依頼を送っていない時だけ使う)。
    @discardableResult
    mutating func appendLog(kind: String, attemptID: String? = nil, unitID: String? = nil, skillIDs: [String] = [], text: String, first: Bool = false) -> String {
        let entries = todayLog
        let seq = first ? (entries.first?.seq ?? 1) - 1 : (entries.last?.seq ?? 0) + 1
        let id = newID()
        put("timeline.log_appended", TimelineLogRecord(id: id, day: today, seq: seq, kind: kind, attemptId: attemptID, unitId: unitID,
                                                       skillIds: skillIDs, text: text, createdAt: now()))
        return id
    }

    /// 答案の結果が出た(採点・端末の中の採点・飛ばした・答えた・読めなかった・採点できなかった)時の 1 件。
    private mutating func logAttempt(_ attemptID: String) {
        guard let attempt = attempts[attemptID], let card = cards[attempt.cardId] else { return }
        appendLog(kind: "attempt", attemptID: attemptID, text: TimelineLogText.attempt(attempt, card: card, machine: self))
    }

    /// 今日の記録にまだ無い、結果の出た今日の答案(この版より前に解いた答案など)。
    var unloggedAttemptsToday: [TimelineAttemptRecord] {
        let today = today
        let logged = Set(log.values.filter { $0.day == today && $0.kind == "attempt" }.compactMap(\.attemptId))
        return orderedAttempts.filter { TimelineRules.day($0.createdAt, calendar: calendar) == today && $0.verdict != "grading" && !logged.contains($0.id) }
    }

    mutating func logMissedAttempts() {
        for attempt in unloggedAttemptsToday { logAttempt(attempt.id) }
    }

    // MARK: - 2択カード

    mutating func recordDip(trigger: TimelineRules.DipTrigger) -> String {
        let id = newID()
        put("timeline.dip_shown", TimelineDipRecord(id: id, trigger: trigger.rawValue, chosen: nil, cardsAfter: 0, createdAt: now(), updatedAt: now()))
        return id
    }

    mutating func chooseDip(id: String, chosen: String) {
        guard var row = dips[id] else { return }
        row.chosen = chosen
        row.updatedAt = now()
        put("timeline.dip_chosen", row)
    }

    /// 2択カードの後に解いた枚数を数える。
    mutating func countAfterDip() {
        guard var last = dips.values.max(by: { $0.createdAt < $1.createdAt }) else { return }
        last.cardsAfter = attempts.values.filter { $0.createdAt > last.createdAt && $0.verdict != "skipped" }.count
        last.updatedAt = now()
        put("timeline.dip_counted", last)
    }

    /// 速攻の自己ベスト(○ だった速攻の秒数の最小)。
    var rapidBest: Double? {
        attempts.values.filter { $0.verdict == "correct" && cards[$0.cardId]?.origin == "rapid" }.map(\.seconds).min()
    }
}
