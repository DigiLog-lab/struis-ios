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
    }

    mutating func put(_ kind: String, _ row: TimelineSkillRecord) { skills[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: TimelineSkillEdgeRecord) { edges[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: TimelineMapChangeRecord) { changes[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: TimelineBatchRecord) { batches[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: TimelineCardRecord) { cards[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: TimelineAttemptRecord) { attempts[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: TimelineDipRecord) { dips[row.id] = row; events.append(.upsert(kind, row)) }

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
        cards.values.filter { $0.status == "unused" && ($0.origin == "batch" || $0.origin == "derived") }
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
            guard attempt.verdict == "correct" || attempt.verdict == "wrong", let card = cards[attempt.cardId] else { return [] }
            let day = TimelineRules.day(attempt.createdAt, calendar: calendar) ?? ""
            return card.skills.map { (skill: $0, correct: attempt.verdict == "correct", day: day) }
        }
    }

    /// その手順を今日解いた回数(「○○」)。
    func solvedToday(skill: String) -> Int {
        let today = today
        return orderedAttempts.filter { attempt in
            attempt.verdict == "correct" && TimelineRules.day(attempt.createdAt, calendar: calendar) == today && cards[attempt.cardId]?.skills.contains(skill) == true
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

    /// 間違えた時に出すやさしい版(AI を待たない)。元のカードの `easier` から作る。
    @discardableResult
    mutating func makeEasier(of cardID: String) -> String? {
        guard let base = cards[cardID], let easier = base.payload["easier"]?.objectValue else { return nil }
        if let existing = cards.values.first(where: { $0.easierOf == cardID }) { return existing.id }
        let first = queue.first?.position ?? nextPosition
        let card = TimelineCardRecord(
            id: newID(), batchId: base.batchId, position: first - 1, kind: "solve", level: max(1, easier["level"]?.intValue ?? base.level - 1),
            skills: base.skills, typeName: base.typeName, prompt: easier["prompt"]?.stringValue ?? base.prompt, math: easier["math"]?.stringValue ?? "",
            question: easier["question"]?.stringValue ?? "", answerKey: easier["answer_key"]?.stringValue ?? "",
            answerExpr: easier["answer_expr"]?.stringValue ?? "", checkpoints: easier["checkpoints"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            commonMistakes: base.commonMistakes, estimatedSeconds: max(20, base.estimatedSeconds / 2), chain: base.chain, easierOf: base.id,
            subunitId: nil, unitId: base.unitId, payload: .object(["steps": base.payload["steps"] ?? .emptyArray]), origin: "easier", status: "unused",
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
        return id
    }

    /// 飛ばした理由(難しそう too_hard / 簡単すぎる too_easy)。押さなくてもよい。
    mutating func setSkipReason(attemptID: String, reason: String) {
        guard var row = attempts[attemptID], row.verdict == "skipped" else { return }
        row.skipReason = reason
        put("timeline.skip_reason", row)
    }

    private mutating func markAnswered(_ cardID: String) {
        guard var card = cards[cardID], card.status != "answered", card.status != "broken" else { return }
        card.status = "answered"
        card.updatedAt = now()
        put("timeline.card_answered", card)
    }

    // MARK: - 採点

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
        var solvedAnswer: String
        var learnerAnswer: String
        var learnerExpr: String
        var verdict: String
        var keySuspect: Bool
        var checkpoints: [Checkpoint]
        var errors: [Error]
        var cause: String
        var feedback: String
        enum CodingKeys: String, CodingKey {
            case readable, verdict, checkpoints, errors, cause, feedback
            case solvedAnswer = "solved_answer"
            case learnerAnswer = "learner_answer"
            case learnerExpr = "learner_expr"
            case keySuspect = "key_suspect"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            readable = try c.decodeIfPresent(Bool.self, forKey: .readable) ?? true
            solvedAnswer = try c.decodeIfPresent(String.self, forKey: .solvedAnswer) ?? ""
            learnerAnswer = try c.decodeIfPresent(String.self, forKey: .learnerAnswer) ?? ""
            learnerExpr = try c.decodeIfPresent(String.self, forKey: .learnerExpr) ?? ""
            verdict = try c.decodeIfPresent(String.self, forKey: .verdict) ?? "wrong"
            keySuspect = try c.decodeIfPresent(Bool.self, forKey: .keySuspect) ?? false
            checkpoints = try c.decodeIfPresent([Checkpoint].self, forKey: .checkpoints) ?? []
            errors = try c.decodeIfPresent([Error].self, forKey: .errors) ?? []
            cause = try c.decodeIfPresent(String.self, forKey: .cause) ?? "unknown"
            feedback = try c.decodeIfPresent(String.self, forKey: .feedback) ?? ""
        }
        static func parse(_ text: String) throws -> Grading {
            try JSONDecoder().decode(Grading.self, from: Data(text.utf8))
        }
    }

    nonisolated struct GradingOutcome: Equatable, Sendable {
        var verdict: String
        /// 答えが間違っていた問題(捨てて、以後の復習にも使わない)。
        var broken = false
        /// 単元ホームの合格に数える(段3以上・初回・ヒントなし)。
        var countsForUnitHome = false
    }

    /// 採点の結果を綴じる。answer_key と食い違い、解き直した答えが学習者と一致したら、壊れていたのは問題の方(学習者は ○)。
    mutating func applyGrading(attemptID: String, grading: Grading) -> GradingOutcome {
        guard var row = attempts[attemptID], let card = cards[row.cardId] else { return GradingOutcome(verdict: "failed") }
        row.gradedAt = now()
        guard grading.readable else {
            row.verdict = "unreadable"
            row.countsForAccuracy = false
            row.feedback = "字が読めませんでした。撮り直してください。"
            put("timeline.attempt_unreadable", row)
            reopen(card.id)
            return GradingOutcome(verdict: "unreadable")
        }
        var verdict = grading.verdict == "correct" ? "correct" : "wrong"
        // 04・09 は読み取った式を数式で判定する(何通りもある答えも、頂点を計算すれば判定できる)。
        if let kind = TimelineCards.Kind(rawValue: card.kind), kind == .fillLine || kind == .inverse,
           let written = TimelineCards.gradeWritten(card, learnerExpr: grading.learnerExpr) {
            verdict = written ? "correct" : "wrong"
        }
        var broken = false
        if grading.keySuspect, verdict == "correct", card.kind == "solve" {
            broken = true
            var bad = card
            bad.status = "broken"
            bad.updatedAt = now()
            put("timeline.card_broken", bad)
            recordChange(kind: "broken_problem", detail: .object(["card_id": .string(card.id), "type_name": .string(card.typeName),
                                                                   "answer_key": .string(card.answerKey), "solved_answer": .string(grading.solvedAnswer)]),
                         attemptIDs: [attemptID], source: "app", reviewed: true)
            // 同じ元のやさしい版も使わない。
            discard(ids: cards.values.filter { $0.easierOf == card.id }.map(\.id))
        }
        row.verdict = verdict
        row.learnerAnswer = grading.learnerAnswer
        row.checkpointResults = .array(grading.checkpoints.map { .object(["text": .string($0.text), "result": .string($0.result)]) })
        row.errors = .array(grading.errors.map { LedgerEvent.encode($0) })
        row.cause = ["practice", "connection"].contains(grading.cause) ? grading.cause : "unknown"
        row.keySuspect = grading.keySuspect
        row.feedback = String(grading.feedback.prefix(80))
        if broken { row.countsForAccuracy = false }
        put("timeline.attempt_graded", row)
        let withinTime = row.seconds <= Double(card.estimatedSeconds)
        if !broken || verdict == "correct" {
            applySkills(card: card, correct: verdict == "correct", assisted: row.assisted, withinTime: withinTime, firstTry: row.firstTry, attemptID: attemptID)
        }
        if verdict == "wrong" { applyWrongFixes(card: card, grading: grading, attemptID: attemptID) }
        let counts = verdict == "correct" || verdict == "wrong"
        return GradingOutcome(verdict: verdict, broken: broken,
                              countsForUnitHome: counts && !broken && TimelineRules.countsForUnitHome(card: card, firstTry: row.firstTry, assisted: row.assisted))
    }

    mutating func failGrading(attemptID: String) {
        guard var row = attempts[attemptID] else { return }
        row.verdict = "failed"
        row.countsForAccuracy = false
        row.gradedAt = now()
        row.feedback = "採点できませんでした。もう一度撮ってください。"
        put("timeline.attempt_failed", row)
        reopen(row.cardId)
    }

    /// 撮り直せるように、カードを出した状態に戻す。
    private mutating func reopen(_ cardID: String) {
        guard var card = cards[cardID], card.status == "answered" else { return }
        card.status = "shown"
        card.updatedAt = now()
        put("timeline.card_reopened", card)
    }

    // MARK: - 「できること」と知識グラフ

    /// 解答をそのカードの「できること」に反映する。グラフにない ID(グラフを作る前)は、仮の点として足す。
    private mutating func applySkills(card: TimelineCardRecord, correct: Bool, assisted: Bool, withinTime: Bool, firstTry: Bool, attemptID: String) {
        for id in card.skills where !id.isEmpty {
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
        }
        // 前提が未定着なのに、上の問題が一発で ○: 前提を「できると推定」にする(後日、30秒問題と混ぜて確かめる)。
        if correct, firstTry, !assisted, card.kind == "solve", card.level >= 2 {
            for id in card.skills {
                for prerequisite in allPrerequisites(of: id) {
                    guard let skill = skills[prerequisite], let assumed = TimelineRules.assume(skill, at: now()) else { continue }
                    put("timeline.skill_assumed", assumed)
                    recordChange(kind: "assume", detail: .object(["skill_id": .string(prerequisite), "because": .string(id)]), attemptIDs: [attemptID], source: "app")
                }
            }
        }
        // 同じ点の中で、問題の形によって ○ と × が分かれる: 2つに分けさせる(次の5枚の呼び出しで)。
        for id in card.skills {
            let results = orderedAttempts.compactMap { attempt -> (typeName: String, correct: Bool)? in
                guard attempt.verdict == "correct" || attempt.verdict == "wrong", let c = cards[attempt.cardId], c.skills.contains(id) else { return nil }
                return (c.typeName, attempt.verdict == "correct")
            }
            if let split = TimelineRules.splitCandidate(results: results),
               !changes.values.contains(where: { $0.kind == "split_requested" && $0.detail["skill_id"]?.stringValue == id }) {
                recordChange(kind: "split_requested", detail: .object(["skill_id": .string(id), "good_type": .string(split.good), "bad_type": .string(split.bad)]), attemptIDs: [attemptID], source: "app")
            }
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
