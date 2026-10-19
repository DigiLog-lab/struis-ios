import Foundation
import GRDB

/// 問題集の「機械」(design §3.3 / §6.2 `WorkbookRules`): `backend/src/struis/services/workbook.py`
/// と `workbook_turns.apply_grading_result` の移植。合否・段階遷移・進行の判断はここ (コード) が
/// 行い、モデルの自己申告は使わない。
///
/// A `WorkbookMachine` is loaded from the ledger projections inside one write
/// transaction, mutated by the rule functions, and the events it recorded are
/// appended by `Ledger.commit`. Every mutation goes through `put`, so the
/// projections are never written directly.
nonisolated struct WorkbookMachine {
    static let stageLabels: [Int: String] = [1: "要点", 2: "例題", 3: "類題", 4: "演習"]
    static let modelStages: Set<Int> = [1, 2]
    static let learnerStages: Set<Int> = [3, 4]
    static let defaultThreshold = 0.8
    /// 窓に数える一枚の種類。過去の `remedial`(補習、2026-09-24 廃止)は演習として扱う。
    static let practiceKinds: Set<String> = ["practice", "remedial"]
    static let recentCapturesLimit = 20
    static let maxCandidateProblems = 80
    static let verdictScore: [String: Double] = ["correct": 1.0, "wrong": 0.0, "unknown": 0.0]

    var units: [String: WorkbookUnitRecord] = [:]
    var subunits: [String: WorkbookSubunitRecord] = [:]
    var problems: [String: WorkbookProblemRecord] = [:]
    var sets: [String: WorkbookSetRecord] = [:]
    var captures: [String: WorkbookCaptureRecord] = [:]
    var attempts: [String: WorkbookAttemptRecord] = [:]
    var proposals: [String: WorkbookProposalRecord] = [:]
    private(set) var events: [LedgerEvent] = []

    /// Injectable clock / id source for tests and vectors.
    var now: () -> String = { LedgerClock.now() }
    var newID: () -> String = { LedgerID.make() }

    init() {}

    init(loading db: Database) throws {
        units = Dictionary(uniqueKeysWithValues: try WorkbookUnitRecord.fetchAll(db).map { ($0.id, $0) })
        subunits = Dictionary(uniqueKeysWithValues: try WorkbookSubunitRecord.fetchAll(db).map { ($0.id, $0) })
        problems = Dictionary(uniqueKeysWithValues: try WorkbookProblemRecord.fetchAll(db).map { ($0.id, $0) })
        sets = Dictionary(uniqueKeysWithValues: try WorkbookSetRecord.fetchAll(db).map { ($0.id, $0) })
        captures = Dictionary(uniqueKeysWithValues: try WorkbookCaptureRecord.fetchAll(db).map { ($0.id, $0) })
        attempts = Dictionary(uniqueKeysWithValues: try WorkbookAttemptRecord.fetchAll(db).map { ($0.id, $0) })
        proposals = Dictionary(uniqueKeysWithValues: try WorkbookProposalRecord.fetchAll(db).map { ($0.id, $0) })
    }

    // MARK: - Mutation (event recording)

    mutating func put(_ kind: String, _ row: WorkbookUnitRecord) { units[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: WorkbookSubunitRecord) { subunits[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: WorkbookProblemRecord) { problems[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: WorkbookSetRecord) { sets[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: WorkbookCaptureRecord) { captures[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: WorkbookAttemptRecord) { attempts[row.id] = row; events.append(.upsert(kind, row)) }
    mutating func put(_ kind: String, _ row: WorkbookProposalRecord) { proposals[row.id] = row; events.append(.upsert(kind, row)) }

    static func error(_ code: String, _ message: String) -> LedgerError {
        .rejected(code: code, message: message)
    }

    // MARK: - Ordering helpers

    func orderedUnits(includeArchived: Bool = false) -> [WorkbookUnitRecord] {
        units.values.filter { includeArchived || $0.status != "archived" }
            .sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) }
    }

    /// `_subunit_rows`: ordered by unit position/created, then subunit position/created.
    func orderedSubunits(unitID: String? = nil, status: String? = nil) -> [WorkbookSubunitRecord] {
        let unitOrder = Dictionary(uniqueKeysWithValues: orderedUnits(includeArchived: true).enumerated().map { ($1.id, $0) })
        return subunits.values
            .filter { unitID == nil || $0.unitId == unitID }
            .filter { status == nil || $0.status == status }
            .sorted { lhs, rhs in
                let l = (unitOrder[lhs.unitId] ?? Int.max, lhs.position, lhs.createdAt)
                let r = (unitOrder[rhs.unitId] ?? Int.max, rhs.position, rhs.createdAt)
                return l < r
            }
    }

    func problemsOf(subunitID: String) -> [WorkbookProblemRecord] {
        problems.values.filter { $0.subunitId == subunitID }.sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) }
    }

    func attemptsOf(subunitID: String) -> [WorkbookAttemptRecord] {
        attempts.values.filter { $0.subunitId == subunitID }.sorted { $0.sequence < $1.sequence }
    }

    func attemptsOf(problemID: String) -> [WorkbookAttemptRecord] {
        attempts.values.filter { $0.problemId == problemID }.sorted { $0.sequence < $1.sequence }
    }

    /// 小単元の今の段の一枚(組んでいる・開いている)。先回りで組んでいる次の段の一枚(§3.1)は、その段に来るまで出さない。
    func openSet(subunitID: String) -> WorkbookSetRecord? {
        let stage = subunits[subunitID]?.stage
        return sets.values.filter { $0.subunitId == subunitID && ($0.status == "generating" || $0.status == "open") && (stage == nil || $0.stage == stage) }
            .max { $0.createdAt < $1.createdAt }
    }

    /// 段を問わず、組んでいる・開いている一枚(先回りの一枚を含む)。
    func pendingSet(subunitID: String, stage: Int) -> WorkbookSetRecord? {
        sets.values.filter { $0.subunitId == subunitID && ($0.status == "generating" || $0.status == "open") && $0.stage == stage }
            .max { $0.createdAt < $1.createdAt }
    }

    func lastResult(subunitID: String) -> LedgerJSON? {
        sets.values.filter { $0.subunitId == subunitID && $0.status == "graded" }
            .max { ($0.gradedAt ?? "") < ($1.gradedAt ?? "") }?.result
    }

    // MARK: - Score window

    nonisolated struct Window: Hashable, Sendable {
        let n: Int
        let threshold: Double
        let count: Int
        let correct: Int
        let score: Double?
        let passed: Bool
        let requiredCorrect: Int

        var json: LedgerJSON {
            .object([
                "n": .number(Double(n)), "threshold": .number(threshold), "count": .number(Double(count)),
                "correct": .number(Double(correct)), "score": score.map { .number($0) } ?? .null,
                "passed": .bool(passed), "required_correct": .number(Double(requiredCorrect)),
            ])
        }

        var dto: WorkbookWindowDTO {
            WorkbookWindowDTO(n: n, threshold: threshold, count: count, correct: correct, score: score, passed: passed, requiredCorrect: requiredCorrect)
        }
    }

    /// 類題の一枚に載った問題。
    private var exampleSetProblemIDs: Set<String> {
        Set(sets.values.filter { $0.kind == "example" }.flatMap(\.problemIds))
    }

    /// 合格の窓に入る試行か。段階 4 の演習の一枚の試行だけを数え、類題の試行は入れない。
    /// 一枚を経ずに綴じた答案は、綴じた時の段(答案の `summary.counts_toward_window`)で決める。
    /// `current` は今まさに集計している答案と、その答案が数に入るか。
    func countsTowardWindow(_ attempt: WorkbookAttemptRecord, current: (captureID: String, counts: Bool)? = nil, exampleProblems: Set<String>? = nil) -> Bool {
        // 過去の補習(remedial)は段階 3 でも作られていた。窓に入れるのは段階 4 の一枚だけ。
        if let setID = attempt.setId, let set = sets[setID] { return Self.practiceKinds.contains(set.kind) && set.stage == 4 }
        if let current, attempt.captureId == current.captureID { return current.counts }
        if let flag = captures[attempt.captureId]?.summary["counts_toward_window"]?.boolValue { return flag }
        // 旗の無い旧い答案: 類題の一枚の問題でなければ数える。
        return !(exampleProblems ?? exampleSetProblemIDs).contains(attempt.problemId)
    }

    /// 窓の計算に使う、演習の試行(古い順)。
    func practiceAttemptsOf(subunitID: String, current: (captureID: String, counts: Bool)? = nil) -> [WorkbookAttemptRecord] {
        let examples = exampleSetProblemIDs
        return attemptsOf(subunitID: subunitID).filter { countsTowardWindow($0, current: current, exampleProblems: examples) }
    }

    func passWindow(subunitID: String, current: (captureID: String, counts: Bool)? = nil) -> Window {
        guard let row = subunits[subunitID] else { return Self.scoreWindow([], n: 1) }
        return Self.scoreWindow(practiceAttemptsOf(subunitID: subunitID, current: current), n: row.n, threshold: row.threshold)
    }

    /// 窓に入った試行そのもの(古い順、最大 n)。マスの表示はこれを使う。
    func windowAttempts(subunitID: String, current: (captureID: String, counts: Bool)? = nil) -> [WorkbookAttemptRecord] {
        guard let row = subunits[subunitID] else { return [] }
        return Self.eligible(practiceAttemptsOf(subunitID: subunitID, current: current)).suffix(row.n).map { $0 }
    }

    static func eligible(_ attempts: [WorkbookAttemptRecord]) -> [WorkbookAttemptRecord] {
        var seen = Set<String>()
        var eligible: [WorkbookAttemptRecord] = []
        for attempt in attempts.sorted(by: { $0.sequence < $1.sequence }) {
            let first = !seen.contains(attempt.problemId)
            seen.insert(attempt.problemId)
            if first, !attempt.assisted { eligible.append(attempt) }
        }
        return eligible
    }

    /// 直近 n 問の 8 割。各問の最初の解答だけ、ヒントなしだけを数える。
    static func scoreWindow(_ attempts: [WorkbookAttemptRecord], n: Int, threshold: Double = defaultThreshold) -> Window {
        let window = Array(eligible(attempts).suffix(n))
        let correct = window.filter { $0.verdict == "correct" }.count
        let score: Double? = window.isEmpty ? nil : window.map(\.score).reduce(0, +) / Double(window.count)
        let passed = window.count == n && score != nil && score! >= threshold - 1e-9
        return Window(n: n, threshold: threshold, count: window.count, correct: correct, score: score, passed: passed, requiredCorrect: requiredCorrect(n: n, threshold: threshold))
    }

    static func requiredCorrect(n: Int, threshold: Double) -> Int {
        Int((Double(n) * threshold - 1e-9).rounded(.up))
    }

    // MARK: - Views (DTOs the screens already use)

    func tile(_ problem: WorkbookProblemRecord) -> WorkbookProblemTileDTO {
        let history = attemptsOf(problemID: problem.id)
        let last = history.last
        let state: WorkbookProblemTileDTO.State = last.flatMap { WorkbookProblemTileDTO.State(rawValue: $0.verdict) } ?? .notStarted
        return WorkbookProblemTileDTO(
            id: problem.id, position: problem.position, prompt: problem.prompt, source: problem.source, state: state,
            attemptCount: history.count, assisted: last?.assisted ?? false, errorTag: last?.errorTag ?? "",
            hintGiven: problem.hintGivenAt != nil, lastAttemptAt: last?.createdAt
        )
    }

    static func setResult(_ value: LedgerJSON?) -> WorkbookSetResultDTO? {
        guard let object = value?.objectValue, !object.isEmpty else { return nil }
        return WorkbookSetResultDTO(
            correct: object["correct"]?.intValue ?? 0, total: object["total"]?.intValue ?? 0,
            score: object["score"]?.doubleValue ?? 0, passed: object["passed"]?.boolValue ?? false,
            note: object["note"]?.stringValue ?? ""
        )
    }

    func windowTile(_ attempt: WorkbookAttemptRecord) -> WorkbookProblemTileDTO {
        let problem = problems[attempt.problemId]
        return WorkbookProblemTileDTO(
            id: attempt.problemId, position: problem?.position ?? 0, prompt: problem?.prompt ?? "", source: problem?.source ?? "",
            state: WorkbookProblemTileDTO.State(rawValue: attempt.verdict) ?? .unknown, attemptCount: 1, assisted: attempt.assisted,
            errorTag: attempt.errorTag, hintGiven: problem?.hintGivenAt != nil, lastAttemptAt: attempt.createdAt
        )
    }

    func subunitSummary(_ row: WorkbookSubunitRecord) -> WorkbookSubunitDTO {
        let unit = units[row.unitId]
        let window = passWindow(subunitID: row.id)
        let metadata = row.metadata.objectValue ?? [:]
        let example = metadata["example_problem"]?.objectValue
        let exampleRound = metadata["example_round"]?.intValue ?? 0
        let examplePrompt = (example?["round"]?.intValue ?? 0) == exampleRound ? example?["prompt"]?.stringValue : nil
        return WorkbookSubunitDTO(
            id: row.id, unitId: row.unitId, unitTitle: unit?.title ?? "", title: row.title, outcome: Self.cleanOutcome(row.outcome, n: row.n, threshold: row.threshold),
            position: row.position, stage: row.stage, stageLabel: Self.stageLabels[row.stage] ?? "", status: WorkbookSubunitDTO.Status(rawValue: row.status) ?? .pending,
            n: row.n, threshold: row.threshold, scoringUnit: row.scoringUnit, window: window.dto,
            tiles: problemsOf(subunitID: row.id).map(tile), openSetId: openSet(subunitID: row.id)?.id,
            lastResult: Self.setResult(lastResult(subunitID: row.id)),
            canAdvance: Self.modelStages.contains(row.stage) && row.status == "active", updatedAt: row.updatedAt,
            windowTiles: windowAttempts(subunitID: row.id).map(windowTile),
            exampleProblem: row.stage == 2 ? examplePrompt : nil,
            exampleReady: row.stage == 2 ? Self.isExampleReady(row) : nil,
            returnStage: metadata["return_stage"]?.intValue,
            threadId: metadata["thread_id"]?.stringValue,
            kickoffKey: Self.kickoffKey(row),
            kickoffMessageId: Self.kickoffKey(row).flatMap { metadata["kickoffs"]?[$0]?.stringValue }
        )
    }

    /// 段階 1・2 でモデルのターンを起こす単位。「例題に戻る」ごとに新しい例題を起こす。
    static func kickoffKey(_ row: WorkbookSubunitRecord) -> String? {
        guard row.status == "active", modelStages.contains(row.stage) else { return nil }
        let round = row.stage == 2 ? (row.metadata["example_round"]?.intValue ?? 0) : 0
        return "\(row.stage):\(round)"
    }

    func subunitSummary(id: String) throws -> WorkbookSubunitDTO {
        guard let row = subunits[id] else { throw LedgerError.notFound("subunit") }
        return subunitSummary(row)
    }

    func unitSummary(_ unit: WorkbookUnitRecord) -> WorkbookUnitDTO {
        let children = orderedSubunits(unitID: unit.id).map(subunitSummary)
        return WorkbookUnitDTO(
            id: unit.id, title: unit.title, outcome: unit.outcome, status: WorkbookUnitDTO.Status(rawValue: unit.status) ?? .active,
            source: unit.source, subunitCount: children.count, passedCount: children.filter { $0.status == .passed }.count,
            subunits: children, createdAt: unit.createdAt
        )
    }

    func unitSummary(id: String) throws -> WorkbookUnitDTO {
        guard let unit = units[id], unit.status != "archived" else { throw LedgerError.notFound("unit") }
        return unitSummary(unit)
    }

    func loadUnits() -> [WorkbookUnitDTO] {
        orderedUnits().map(unitSummary)
    }

    func captureView(_ row: WorkbookCaptureRecord) -> WorkbookCaptureDTO {
        let subunit = row.subunitId.flatMap { subunits[$0] }
        let unit = subunit.flatMap { units[$0.unitId] }
        let summary = row.summary.objectValue ?? [:]
        let verdicts: [WorkbookCaptureVerdictDTO] = (row.verdicts.arrayValue ?? []).compactMap { item in
            guard let object = item.objectValue else { return nil }
            return WorkbookCaptureVerdictDTO(
                problemId: object["problem_id"]?.stringValue,
                label: object["label"]?.stringValue ?? "", promptText: object["prompt_text"]?.stringValue ?? "",
                verdict: WorkbookProblemTileDTO.State(rawValue: object["verdict"]?.stringValue ?? "") ?? .unknown,
                errorTag: object["error_tag"]?.stringValue ?? "", note: object["note"]?.stringValue ?? ""
            )
        }
        let candidates: [WorkbookCaptureCandidateDTO] = (row.candidates.arrayValue ?? []).compactMap { item in
            guard let object = item.objectValue, let problemID = object["problem_id"]?.stringValue,
                  !Self.reasonSaysMismatch(object["reason"]?.stringValue ?? "") else { return nil }
            return WorkbookCaptureCandidateDTO(
                problemId: problemID, subunitId: object["subunit_id"]?.stringValue ?? "",
                subunitTitle: object["subunit_title"]?.stringValue ?? "", prompt: object["prompt"]?.stringValue ?? "",
                reason: object["reason"]?.stringValue ?? ""
            )
        }
        let progress = row.setId.flatMap { setProgress(setID: $0, captureID: row.id) }
        var result = Self.resultView(summary)
        if summary["outcome"]?.stringValue == "partial", progress?.isOpen != true {
            // 一枚がもう締まった後に開いた途中の答案: 撮り足す・締めるは出さない(R6)。
            result?.actions = [.ask]
        }
        return WorkbookCaptureDTO(
            id: row.id, status: WorkbookCaptureDTO.Status(rawValue: row.status) ?? .failed, createdAt: row.createdAt, gradedAt: row.gradedAt,
            subunitId: row.subunitId, subunitTitle: subunit?.title, unitId: unit?.id, unitTitle: unit?.title, setId: row.setId,
            verdicts: verdicts, summary: Self.setResult(summary["result"]), candidates: candidates,
            nextSetId: summary["next_set_id"]?.stringValue, outcome: summary["outcome"]?.stringValue, error: row.error,
            imagePath: row.imagePath, result: result, setProgress: progress, pagePaths: Self.pagePaths(row)
        )
    }

    /// 答案の全ページの写真(順に)。1 枚の答案は `image_path` だけ。
    nonisolated static func pagePaths(_ row: WorkbookCaptureRecord) -> [String] {
        let pages = (row.context["page_paths"]?.arrayValue ?? []).compactMap(\.stringValue)
        return pages.isEmpty ? [row.imagePath] : pages
    }

    /// リザルト画面の値。旧い答案(補習・自動降格の時代)も読めるようにする。
    static func resultView(_ summary: [String: LedgerJSON]) -> WorkbookResultDTO? {
        guard let stage = summary["stage_before"]?.intValue ?? summary["stage_after"]?.intValue else { return nil }
        let window = summary["window"]?.objectValue
        let windowDTO = window.flatMap { object -> WorkbookWindowDTO? in
            guard let n = object["n"]?.intValue else { return nil }
            return WorkbookWindowDTO(
                n: n, threshold: object["threshold"]?.doubleValue ?? defaultThreshold, count: object["count"]?.intValue ?? 0,
                correct: object["correct"]?.intValue ?? 0, score: object["score"]?.doubleValue, passed: object["passed"]?.boolValue ?? false,
                requiredCorrect: object["required_correct"]?.intValue ?? requiredCorrect(n: n, threshold: defaultThreshold)
            )
        }
        let tiles: [WorkbookResultTileDTO] = (summary["window_tiles"]?.arrayValue ?? []).compactMap { item in
            guard let object = item.objectValue else { return nil }
            return WorkbookResultTileDTO(
                problemId: object["problem_id"]?.stringValue ?? "",
                state: WorkbookProblemTileDTO.State(rawValue: object["verdict"]?.stringValue ?? "") ?? .unknown,
                isCurrent: object["current"]?.boolValue ?? false
            )
        }
        var actions = (summary["next_actions"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(WorkbookResultDTO.Action.init(rawValue:)) }
        let outcome = summary["outcome"]?.stringValue
        let unitPassed = summary["unit_passed"]?.boolValue ?? (outcome == "unit_passed")
        let subunitPassed = summary["subunit_passed"]?.boolValue ?? (outcome == "subunit_passed" || outcome == "unit_passed")
        let nextSubunitID = summary["next_subunit_id"]?.stringValue
        let stageAfter = summary["stage_after"]?.intValue ?? stage
        if summary["next_actions"] == nil {
            // 旧い答案(next_actions が無い)は、結果から次の行動を組み立てる。補習・降格の時代の不合格は「質問する」だけ。
            if unitPassed || (subunitPassed && nextSubunitID == nil) {
                actions = [.finishUnit, .ask]
            } else if subunitPassed {
                actions = [.nextSubunit, .ask]
            } else if outcome == "stage_advanced" || (stage == 3 && stageAfter == 4) {
                actions = [.practice, .ask]
            }
        }
        return WorkbookResultDTO(
            stageBefore: stage, stageAfter: stageAfter, window: windowDTO, windowTiles: tiles,
            subunitPassed: subunitPassed,
            unitPassed: unitPassed,
            nextSubunitId: nextSubunitID,
            actions: actions.isEmpty ? [.ask] : actions
        )
    }

    func captureView(id: String) throws -> WorkbookCaptureDTO {
        guard let row = captures[id] else { throw LedgerError.notFound("capture") }
        return captureView(row)
    }

    func recentCaptures(limit: Int = recentCapturesLimit) -> [WorkbookCaptureDTO] {
        captures.values.sorted { $0.createdAt > $1.createdAt }.prefix(limit).map(captureView)
    }

    func triageCaptures(limit: Int = recentCapturesLimit) -> [WorkbookCaptureDTO] {
        captures.values.filter { $0.status == "triage" }.sorted { $0.createdAt > $1.createdAt }.prefix(limit).map(captureView)
    }

    func home() -> WorkbookHomeDTO {
        let units = loadUnits()
        return WorkbookHomeDTO(
            now: units.flatMap { $0.subunits.filter { $0.status == .active } },
            recent: recentCaptures(), units: units,
            triageCount: captures.values.filter { $0.status == "triage" }.count
        )
    }

    func setView(_ row: WorkbookSetRecord) -> WorkbookSetDTO {
        let tiles = row.problemIds.compactMap { problems[$0] }.map(tile)
        return WorkbookSetDTO(
            id: row.id, subunitId: row.subunitId, stage: row.stage, stageLabel: Self.stageLabels[row.stage] ?? "",
            kind: WorkbookSetDTO.Kind(rawValue: row.kind) ?? .practice, status: WorkbookSetDTO.Status(rawValue: row.status) ?? .failed,
            problems: tiles, result: Self.setResult(row.result), error: row.error, createdAt: row.createdAt,
            count: row.gate["count"]?.intValue
        )
    }

    func setView(id: String) throws -> WorkbookSetDTO {
        guard let row = sets[id] else { throw LedgerError.notFound("set") }
        return setView(row)
    }

    func problemDetail(id: String) throws -> WorkbookProblemDetailDTO {
        guard let problem = problems[id], let subunit = subunits[problem.subunitId] else { throw LedgerError.notFound("problem") }
        let history = attemptsOf(problemID: id).reversed().map { attempt in
            WorkbookProblemAttemptDTO(
                captureId: attempt.captureId, verdict: WorkbookProblemTileDTO.State(rawValue: attempt.verdict) ?? .unknown,
                assisted: attempt.assisted, errorTag: attempt.errorTag, note: attempt.note, createdAt: attempt.createdAt
            )
        }
        return WorkbookProblemDetailDTO(
            tile: tile(problem), subunitId: subunit.id, subunitTitle: subunit.title, unitTitle: units[subunit.unitId]?.title ?? "", attempts: history
        )
    }

    func proposalView(_ row: WorkbookProposalRecord) -> WorkbookProposalDTO {
        var overview: WorkbookProposalOverviewDTO?
        if let object = row.overview.objectValue, let title = object["unit_title"]?.stringValue, !title.isEmpty {
            overview = WorkbookProposalOverviewDTO(
                unitTitle: title, outcome: Self.cleanOutcome(object["outcome"]?.stringValue ?? ""),
                subunits: (object["subunits"]?.arrayValue ?? []).compactMap { item in
                    guard let spec = item.objectValue, let subtitle = spec["title"]?.stringValue, !subtitle.isEmpty else { return nil }
                    return WorkbookProposalSubunitDTO(
                        title: subtitle, outcome: Self.cleanOutcome(spec["outcome"]?.stringValue ?? "", n: spec["n"]?.intValue), n: spec["n"]?.intValue ?? 5,
                        scoringUnit: spec["scoring_unit"]?.stringValue ?? ""
                    )
                }
            )
        }
        return WorkbookProposalDTO(
            id: row.id, status: WorkbookProposalDTO.Status(rawValue: row.status) ?? .failed, request: row.request, overview: overview,
            unitId: row.unitId, threadId: row.threadId, messageId: row.messageId, error: row.error, createdAt: row.createdAt
        )
    }

    func proposalView(id: String) throws -> WorkbookProposalDTO {
        guard let row = proposals[id] else { throw LedgerError.notFound("proposal") }
        return proposalView(row)
    }

    // MARK: - Writes: units / subunits / problems

    nonisolated struct SubunitSpec: Sendable {
        var title: String
        var outcome: String = ""
        var n: Int = 5
        var scoringUnit: String = ""

        init(title: String, outcome: String = "", n: Int = 5, scoringUnit: String = "") {
            self.title = title
            self.outcome = outcome
            self.n = n
            self.scoringUnit = scoringUnit
        }

        init?(json: LedgerJSON) {
            guard let object = json.objectValue, let title = object["title"]?.stringValue, !title.isEmpty else { return nil }
            self.init(title: title, outcome: object["outcome"]?.stringValue ?? "", n: object["n"]?.intValue ?? 5, scoringUnit: object["scoring_unit"]?.stringValue ?? "")
        }
    }

    @discardableResult
    mutating func createUnit(title: String, outcome: String, source: String, subunits specs: [SubunitSpec], overview: LedgerJSON = .emptyObject, firstStage: Int = 1) -> String {
        let id = newID()
        let timestamp = now()
        let position = (units.values.map(\.position).max() ?? -1) + 1
        put("unit.created", WorkbookUnitRecord(
            id: id, title: String(title.prefix(300)), outcome: String(outcome.prefix(2000)), status: "active", source: source,
            position: position, overview: overview, createdAt: timestamp, updatedAt: timestamp, passedAt: nil
        ))
        for (index, spec) in specs.enumerated() {
            createSubunit(unitID: id, spec: spec, position: index, stage: index == 0 ? firstStage : 1, status: index == 0 ? "active" : "pending")
        }
        return id
    }

    @discardableResult
    mutating func createSubunit(unitID: String, spec: SubunitSpec, position: Int? = nil, stage: Int = 1, status: String = "pending") -> String {
        let id = newID()
        let timestamp = now()
        let resolvedPosition = position ?? (subunits.values.filter { $0.unitId == unitID }.map(\.position).max() ?? -1) + 1
        put("subunit.created", WorkbookSubunitRecord(
            id: id, unitId: unitID, title: String(spec.title.prefix(300)), outcome: String(spec.outcome.prefix(2000)),
            position: resolvedPosition, stage: max(1, min(4, stage)), status: status, n: max(1, min(100, spec.n)),
            threshold: Self.defaultThreshold, assistance: "independent_first", scoringUnit: String(spec.scoringUnit.prefix(300)),
            metadata: .emptyObject, createdAt: timestamp, updatedAt: timestamp, passedAt: nil
        ))
        return id
    }

    nonisolated struct ProblemSpec: Sendable {
        var prompt: String
        var answerKey: String = ""
        var checkpoints: [String] = []
    }

    @discardableResult
    mutating func addProblems(subunitID: String, problems specs: [ProblemSpec], source: String) -> [String] {
        let start = (problems.values.filter { $0.subunitId == subunitID }.map(\.position).max() ?? -1) + 1
        var ids: [String] = []
        for (offset, spec) in specs.enumerated() {
            let id = newID()
            put("problem.added", WorkbookProblemRecord(
                id: id, subunitId: subunitID, position: start + offset, prompt: String(spec.prompt.prefix(4000)),
                answerKey: String(spec.answerKey.prefix(4000)), checkpoints: spec.checkpoints.prefix(10).map { String($0.prefix(400)) },
                source: source, hintGivenAt: nil, createdAt: now()
            ))
            ids.append(id)
        }
        return ids
    }

    @discardableResult
    mutating func markHints(problemIDs: [String]) -> Int {
        var count = 0
        for id in problemIDs {
            guard var problem = problems[id] else { continue }
            if problem.hintGivenAt == nil { problem.hintGivenAt = now() }
            put("problem.hint_marked", problem)
            count += 1
        }
        return count
    }

    // MARK: - Stage machine

    /// 「先に進む」: 段階 1・2 だけ。学習者ゴール (3・4) には効かない。
    mutating func advance(subunitID: String) throws -> WorkbookSubunitDTO {
        guard var row = subunits[subunitID] else { throw LedgerError.notFound("subunit") }
        guard row.status == "active" else { throw Self.error("subunit_not_active", "only the active subunit can advance") }
        guard Self.modelStages.contains(row.stage) else {
            throw Self.error("learner_stage_requires_evidence", "stages 3 and 4 only move on graded learner work")
        }
        let stage = row.stage
        if stage == 2, !Self.isExampleReady(row) {
            throw Self.error("example_not_ready", "stage 2 advances only after the model marks the current example ready")
        }
        var patch: [String: LedgerJSON] = ["advanced_stage_\(stage)_at": .string(now())]
        if stage == 2, let back = row.metadata["return_stage"]?.intValue, Self.learnerStages.contains(back) {
            // 「例題に戻る」から来た: 戻る前の段(類題 / 演習)へ直接戻す。
            row.stage = back
            patch["return_stage"] = .null
        } else {
            row.stage = stage + 1
        }
        row.updatedAt = now()
        row.metadata = Self.merge(row.metadata, patch)
        put("subunit.advanced", row)
        return subunitSummary(row)
    }

    /// 「例題に戻る」: 学習者の操作でだけ起きる。戻る前の段を残し、新しい例題の回を始める。
    /// マスの記録は消さない。開いている一枚は閉じる。
    mutating func returnToExample(subunitID: String) throws -> WorkbookSubunitDTO {
        guard var row = subunits[subunitID] else { throw LedgerError.notFound("subunit") }
        guard row.status == "active" else { throw Self.error("subunit_not_active", "only the active subunit can return to the example") }
        guard Self.learnerStages.contains(row.stage) else {
            throw Self.error("return_requires_learner_stage", "only stages 3 and 4 return to the example")
        }
        let from = row.stage
        let round = (row.metadata["example_round"]?.intValue ?? 0) + 1
        row.stage = 2
        row.updatedAt = now()
        row.metadata = Self.merge(row.metadata, [
            "return_stage": .number(Double(from)), "example_round": .number(Double(round)),
            "returned_to_example_at": .string(now()),
            "return_error_tags": .array(recentErrorTags(subunitID: subunitID, limit: 6).map(LedgerJSON.string)),
        ])
        put("subunit.returned_to_example", row)
        supersedeOpenSets(subunitID: subunitID)
        return subunitSummary(row)
    }

    // MARK: - 小単元の会話 (段階 1・2)

    /// 小単元ごとの会話 thread。無ければ作る(台帳のイベント)。
    mutating func ensureThread(subunitID: String) throws -> (threadID: String, events: [LedgerEvent]) {
        guard var row = subunits[subunitID] else { throw LedgerError.notFound("subunit") }
        if let existing = row.metadata["thread_id"]?.stringValue { return (existing, []) }
        let threadID = LedgerID.make()
        let (_, event) = ChatRepository.createThread(id: threadID, title: row.title, source: "subunit")
        row.metadata = Self.merge(row.metadata, ["thread_id": .string(threadID)])
        row.updatedAt = now()
        put("subunit.thread_created", row)
        return (threadID, [event])
    }

    /// その段のモデルのターンを起こしたと記録する。既に記録があれば false(重複させない)。
    mutating func recordKickoff(subunitID: String, key: String, messageID: String) -> Bool {
        guard var row = subunits[subunitID] else { return false }
        var kickoffs = row.metadata["kickoffs"]?.objectValue ?? [:]
        guard kickoffs[key] == nil else { return false }
        kickoffs[key] = .string(messageID)
        row.metadata = Self.merge(row.metadata, ["kickoffs": .object(kickoffs)])
        row.updatedAt = now()
        put("subunit.kickoff_recorded", row)
        return true
    }

    /// 起こした返事が止まった / 失敗した時、学習者がもう一度起こせるようにキーを外す。
    mutating func clearKickoff(subunitID: String, key: String) {
        guard var row = subunits[subunitID] else { return }
        var kickoffs = row.metadata["kickoffs"]?.objectValue ?? [:]
        guard kickoffs[key] != nil else { return }
        kickoffs[key] = nil
        row.metadata = Self.merge(row.metadata, ["kickoffs": .object(kickoffs)])
        row.updatedAt = now()
        put("subunit.kickoff_cleared", row)
    }

    /// 段階 2 の例題(モデルが `<struis_workbook_example>` で出したもの)を固定表示のために持つ。
    mutating func setExampleProblem(subunitID: String, prompt: String, messageID: String) {
        guard var row = subunits[subunitID], row.stage == 2 else { return }
        let round = row.metadata["example_round"]?.intValue ?? 0
        row.metadata = Self.merge(row.metadata, ["example_problem": .object([
            "prompt": .string(String(prompt.prefix(4000))), "round": .number(Double(round)), "message_id": .string(messageID),
        ])])
        row.updatedAt = now()
        put("subunit.example_set", row)
    }

    /// 段階 2 の準備OK(モデルが `<struis_workbook_example_ready/>` で出したもの)を、今の例題の回に記録する(§13.13 の 5)。
    mutating func setExampleReady(subunitID: String, messageID: String) {
        guard var row = subunits[subunitID], row.stage == 2, row.status == "active" else { return }
        let round = row.metadata["example_round"]?.intValue ?? 0
        guard !Self.isExampleReady(row) else { return }
        row.metadata = Self.merge(row.metadata, ["example_ready": .object([
            "round": .number(Double(round)), "message_id": .string(messageID), "at": .string(now()),
        ])])
        row.updatedAt = now()
        put("subunit.example_ready", row)
    }

    /// 今の例題の回に準備OKが出ているか。「例題に戻る」で回が進むと false に戻る。
    static func isExampleReady(_ row: WorkbookSubunitRecord) -> Bool {
        guard let ready = row.metadata["example_ready"]?.objectValue, let round = ready["round"]?.intValue else { return false }
        return round == (row.metadata["example_round"]?.intValue ?? 0)
    }

    /// 小単元の会話 thread(`metadata.thread_id`)から小単元を引く。
    func subunitID(threadID: String) -> String? {
        subunits.values.first { $0.metadata["thread_id"]?.stringValue == threadID }?.id
    }

    /// マス数 n は増やす方向だけ。既存の試行は残し、直近 n の n だけ更新する。
    mutating func changeCount(subunitID: String, n: Int, reason: String) throws -> WorkbookSubunitDTO {
        guard var row = subunits[subunitID] else { throw LedgerError.notFound("subunit") }
        let current = row.n
        if n < current { throw Self.error("count_cannot_decrease", "n must be at least the current value \(current)") }
        if n > 100 { throw Self.error("count_too_large", "n must be at most 100") }
        if n == current { return subunitSummary(row) }
        var changes = row.metadata["count_changes"]?.arrayValue ?? []
        let trimmedReason = String(reason.prefix(500))
        changes.append(.object([
            "from": .number(Double(current)), "to": .number(Double(n)),
            "reason": .string(trimmedReason.isEmpty ? "learner_increase" : trimmedReason), "at": .string(now()),
        ]))
        row.n = n
        row.metadata = Self.merge(row.metadata, ["count_changes": .array(changes)])
        row.updatedAt = now()
        put("subunit.count_changed", row)
        return subunitSummary(row)
    }

    private mutating func setStage(subunitID: String, stage: Int, metadataPatch: [String: LedgerJSON]) {
        guard var row = subunits[subunitID] else { return }
        row.stage = stage
        row.updatedAt = now()
        row.metadata = Self.merge(row.metadata, metadataPatch)
        put("subunit.stage_set", row)
        supersedeOpenSets(subunitID: subunitID)
    }

    private mutating func supersedeOpenSets(subunitID: String) {
        for var set in sets.values where set.subunitId == subunitID && (set.status == "open" || set.status == "generating") {
            set.status = "superseded"
            set.updatedAt = now()
            put("set.superseded", set)
        }
    }

    nonisolated struct PassOutcome: Sendable {
        var passed = true
        var nextSubunitID: String?
        var unitPassed = false
    }

    private mutating func passSubunit(_ subunit: WorkbookSubunitRecord) -> PassOutcome {
        var row = subunit
        row.status = "passed"
        row.passedAt = now()
        row.updatedAt = now()
        put("subunit.passed", row)
        supersedeOpenSets(subunitID: row.id)
        var outcome = PassOutcome()
        if var next = orderedSubunits(unitID: row.unitId, status: "pending").first {
            next.status = "active"
            next.stage = 1
            next.updatedAt = now()
            put("subunit.activated", next)
            outcome.nextSubunitID = next.id
        } else {
            let remaining = subunits.values.filter { $0.unitId == row.unitId && $0.status != "passed" }.count
            if remaining == 0, var unit = units[row.unitId] {
                unit.status = "passed"
                unit.passedAt = now()
                unit.updatedAt = now()
                put("unit.passed", unit)
                outcome.unitPassed = true
            }
        }
        return outcome
    }

    nonisolated struct Verdict: Sendable {
        var problemID: String
        var verdict: String
        var errorTag: String
        var note: String
    }

    nonisolated struct Recorded: Sendable {
        var problemID: String
        var verdict: String
        var assisted: Bool
        var errorTag: String
        var note: String
    }

    /// verdicts を workbook_attempts に綴じる。
    mutating func recordAttempts(captureID: String, subunitID: String, setID: String?, verdicts: [Verdict], capturedAt: String) -> [Recorded] {
        var recorded: [Recorded] = []
        let capturedDate = LedgerClock.parse(capturedAt) ?? .distantFuture
        for item in verdicts {
            guard let problem = problems[item.problemID], problem.subunitId == subunitID else { continue }
            let assisted: Bool
            if let hint = problem.hintGivenAt, let hintDate = LedgerClock.parse(hint) {
                assisted = hintDate <= capturedDate
            } else {
                assisted = false
            }
            let sequence = (attemptsOf(subunitID: subunitID).map(\.sequence).max() ?? 0) + 1
            let verdict = Self.verdictScore[item.verdict] == nil ? "unknown" : item.verdict
            let exists = attempts.values.contains { $0.captureId == captureID && $0.problemId == problem.id }
            if !exists {
                put("attempt.recorded", WorkbookAttemptRecord(
                    id: newID(), subunitId: subunitID, problemId: problem.id, captureId: captureID, setId: setID,
                    sequence: sequence, verdict: verdict, score: Self.verdictScore[verdict] ?? 0, assisted: assisted,
                    errorTag: String(item.errorTag.prefix(100)), note: String(item.note.prefix(400)), createdAt: now()
                ))
            }
            recorded.append(Recorded(problemID: problem.id, verdict: verdict, assisted: assisted, errorTag: item.errorTag, note: item.note))
        }
        return recorded
    }

    nonisolated struct GradingOutcome: Sendable {
        var stageBefore: Int
        var stageAfter: Int
        var kind: String
        var passed = false
        var nextSubunitID: String?
        var unitPassed = false
        var result: LedgerJSON = .emptyObject
        var window: LedgerJSON = .emptyObject
        /// 窓のマス(古い順)。今回の答案で埋まったものに `current`。
        var windowTiles: [LedgerJSON] = []
        /// リザルト画面で選べる次の行動。
        var nextActions: [String] = ["ask"]
    }

    /// 一枚の結果を集計し、段階を動かす。間違えても段は下げない(2026-09-24 決定)。
    /// 類題 ○ → 演習、演習は直近 n 問の 8 割で合格。× / 不合格は同じ段のまま、次の行動は学習者が選ぶ。
    // MARK: - 一枚を何枚の写真に分けて撮る(配信Skillの説明)

    /// 何枚の写真に分けて撮ってよい一枚か。演習の一枚(2 問以上)。類題の一枚は 1 枚の答案で締める。
    func splitsAcrossCaptures(_ set: WorkbookSetRecord) -> Bool {
        Self.practiceKinds.contains(set.kind) && setTotal(set) > 1
    }

    /// 一枚の問題数。組んでいる途中なら、組み終わる数。
    func setTotal(_ set: WorkbookSetRecord) -> Int {
        max(set.problemIds.count, set.gate["count"]?.intValue ?? 0)
    }

    /// 答案に見せる一枚の問題数。組み立てに失敗した一枚は作れた問題だけ(作れなかった分は「見つからなかった」問題ではない)。
    func shownTotal(_ set: WorkbookSetRecord) -> Int {
        set.status == "failed" ? set.problemIds.count : setTotal(set)
    }

    /// まだ締めていない、今の段の一枚か。今の段のものでない一枚(例題に戻った・段が進んだ)は 1 枚の答案で締める(R5)。
    func isOpenForCapture(_ set: WorkbookSetRecord) -> Bool {
        guard set.status == "open" || set.status == "generating", let subunit = subunits[set.subunitId] else { return false }
        return subunit.status == "active" && subunit.stage == set.stage
    }

    /// 一枚の各問の、一枚の中での初回の判定。
    func firstSetAttempts(setID: String) -> [String: WorkbookAttemptRecord] {
        var first: [String: WorkbookAttemptRecord] = [:]
        for attempt in attempts.values where attempt.setId == setID {
            if let seen = first[attempt.problemId], seen.sequence <= attempt.sequence { continue }
            first[attempt.problemId] = attempt
        }
        return first
    }

    /// まだ判定の無い問題の、一枚の中の番号(1 始まり)。組んでいる途中でまだ届いていない問題も含む。
    func missingPositions(setID: String) -> [Int] {
        guard let set = sets[setID] else { return [] }
        let first = firstSetAttempts(setID: setID)
        return (0..<shownTotal(set)).filter { index in
            index >= set.problemIds.count || first[set.problemIds[index]] == nil
        }.map { $0 + 1 }
    }

    /// 一枚に綴じた全答案の判定(各問の初回、一枚の順)。
    func setRecorded(setID: String) -> [Recorded] {
        guard let set = sets[setID] else { return [] }
        let first = firstSetAttempts(setID: setID)
        return set.problemIds.compactMap { first[$0] }.map {
            Recorded(problemID: $0.problemId, verdict: $0.verdict, assisted: $0.assisted, errorTag: $0.errorTag, note: $0.note)
        }
    }

    /// 一枚の今の様子(リザルトのマスと、足りない問題)。演習の一枚(2 問以上)だけ。
    func setProgress(setID: String, captureID: String) -> WorkbookSetProgressDTO? {
        guard let set = sets[setID], splitsAcrossCaptures(set) else { return nil }
        let first = firstSetAttempts(setID: setID)
        var states: [WorkbookProblemTileDTO.State] = []
        var here: [Bool] = []
        for index in 0..<shownTotal(set) {
            let attempt = index < set.problemIds.count ? first[set.problemIds[index]] : nil
            states.append(attempt.flatMap { WorkbookProblemTileDTO.State(rawValue: $0.verdict) } ?? .notStarted)
            here.append(attempt?.captureId == captureID)
        }
        return WorkbookSetProgressDTO(
            states: states, capturedHere: here, missingPositions: missingPositions(setID: setID), isOpen: isOpenForCapture(set),
            isFailed: set.status == "failed"
        )
    }

    /// 途中のリザルトの「見つかった k 問で結果を出す」: 判定の無い問題を残したまま一枚を締め、一枚の集計を出す(R3)。
    @discardableResult
    mutating func closeSet(captureID: String) throws -> WorkbookCaptureDTO {
        guard let capture = captures[captureID], let setID = capture.setId, let subunitID = capture.subunitId,
              capture.summary["outcome"]?.stringValue == "partial", let set = sets[setID]
        else { throw Self.error("capture_not_partial", "only a partial capture can close its set") }
        guard set.status == "open" || set.status == "generating" else { throw Self.error("set_already_closed", "the set is already closed") }
        let outcome = try applySetGrading(subunitID: subunitID, setID: setID, recorded: setRecorded(setID: setID), captureID: captureID)
        var summary = Self.outcomeSummary(outcome).objectValue ?? [:]
        summary["missing_positions"] = .array(missingPositions(setID: setID).map { .number(Double($0)) })
        summary["closed_by_learner"] = .bool(true)
        patchCaptureSummary(id: captureID, summary)
        return try captureView(id: captureID)
    }

    /// `countsFailure`: 不合格を不合格の回数に数えるか。締めた後に残りを撮った答案は数えない(R4)。
    mutating func applySetGrading(subunitID: String, setID: String?, recorded: [Recorded], captureID: String? = nil, countsFailure: Bool = true) throws -> GradingOutcome {
        guard let subunit = subunits[subunitID] else { throw LedgerError.notFound("subunit") }
        let metadata = subunit.metadata.objectValue ?? [:]
        let setRow = setID.flatMap { sets[$0] }
        let stage = subunit.stage
        // 答案の段: 一枚があればその段、無ければ撮った時の段(記録が無い旧い答案は今の段)。
        let captureStage = captureID.flatMap { captures[$0]?.context["stage"]?.intValue ?? captures[$0]?.context["stages"]?[subunitID]?.intValue }
        let answerStage = setRow?.stage ?? captureStage ?? stage
        let kind = setRow?.kind ?? (answerStage == 3 ? "example" : "practice")
        let isExample = kind == "example" || (setRow == nil && answerStage == 3)
        let total = recorded.count
        let correct = recorded.filter { $0.verdict == "correct" }.count
        let score = total > 0 ? Double(correct) / Double(total) : 0.0
        var outcome = GradingOutcome(stageBefore: stage, stageAfter: stage, kind: Self.practiceKinds.contains(kind) ? "practice" : kind)
        let current = captureID.map { (captureID: $0, counts: !isExample) }
        let window = passWindow(subunitID: subunitID, current: current)
        let windowTiles: [LedgerJSON] = windowAttempts(subunitID: subunitID, current: current).map { attempt in
            .object([
                "problem_id": .string(attempt.problemId), "verdict": .string(attempt.verdict),
                // 今回の答案で埋まったマス。一枚に分けて撮った答案は、その一枚で埋まったマス全部。
                "current": .bool((captureID != nil && attempt.captureId == captureID) || (setID != nil && attempt.setId == setID)),
            ])
        }
        // 段が先へ進んだ後(別の答案で合格した・段が変わった)に判定し直した古い答案は、記録と集計だけにして段を動かさない。
        // 学習者の段(3・4)にいない時(例題に戻った等)も、段を動かさない。
        let isCurrent = subunit.status == "active" && (3...4).contains(stage) && answerStage == stage
        var result: [String: LedgerJSON]
        if !isCurrent {
            let setPassed = isExample ? total > 0 && correct == total : window.passed
            result = ["correct": .number(Double(correct)), "total": .number(Double(total)), "score": .number(score), "passed": .bool(setPassed)]
            if !isExample {
                result["window"] = window.json
                outcome.windowTiles = windowTiles
            }
            outcome.nextActions = ["ask"]
        } else if isExample {
            let setPassed = total > 0 && correct == total
            result = ["correct": .number(Double(correct)), "total": .number(Double(total)), "score": .number(score), "passed": .bool(setPassed)]
            if setPassed {
                setStage(subunitID: subunitID, stage: 4, metadataPatch: ["example_failures": .number(0)])
                outcome.stageAfter = 4
                outcome.nextActions = ["practice", "ask"]
            } else {
                // 類題のまま。数は記録だけ(段は動かさない)。
                let failures = (metadata["example_failures"]?.intValue ?? 0) + 1
                patchMetadata(subunitID: subunitID, ["example_failures": .number(Double(failures))], kind: "subunit.example_failed")
                outcome.nextActions = ["retry", "return_to_example", "ask"]
            }
        } else {
            let setPassed = window.passed
            result = ["correct": .number(Double(correct)), "total": .number(Double(total)), "score": .number(score), "passed": .bool(setPassed), "window": window.json]
            outcome.windowTiles = windowTiles
            if setPassed {
                let passed = passSubunit(subunit)
                outcome.passed = true
                outcome.nextSubunitID = passed.nextSubunitID
                outcome.unitPassed = passed.unitPassed
                outcome.nextActions = passed.unitPassed || passed.nextSubunitID == nil ? ["finish_unit", "ask"] : ["next_subunit", "ask"]
            } else {
                // 演習のまま。数は記録だけ(段は動かさない)。
                if countsFailure {
                    let failedSets = (metadata["practice_failed_sets"]?.intValue ?? 0) + 1
                    patchMetadata(subunitID: subunitID, ["practice_failed_sets": .number(Double(failedSets))], kind: "subunit.practice_failed")
                }
                outcome.nextActions = ["retry", "return_to_example", "ask"]
            }
        }
        outcome.result = .object(result)
        outcome.window = window.json
        if var setRow {
            setRow.status = "graded"
            setRow.result = .object(result)
            setRow.gradedAt = now()
            setRow.updatedAt = now()
            put("set.graded", setRow)
        }
        return outcome
    }

    private mutating func patchMetadata(subunitID: String, _ patch: [String: LedgerJSON], kind: String) {
        guard var row = subunits[subunitID] else { return }
        row.metadata = Self.merge(row.metadata, patch)
        row.updatedAt = now()
        put(kind, row)
    }

    nonisolated struct SetSpec: Sendable {
        var stage: Int
        var kind: String
        var count: Int
        var n: Int
        var threshold: Double
        /// やり直しの一枚: 直前の一枚の誤答の種類を狙う。
        var retryOf: String? = nil
        var targetErrorTags: [String] = []
    }

    /// 現在段階に沿った一枚の仕様。段階 1・2 は一枚を作らない。類題は 1 問、演習は n 問。
    /// 直前の同じ段の一枚が不合格なら、やり直しとしてその誤答の種類を持たせる。
    /// 撮った時の段。小単元・一枚から撮った答案は `stage`、ホームから撮った答案は `stages[小単元]`。
    static func captureStage(_ capture: WorkbookCaptureRecord, subunitID: String) -> Int? {
        capture.context["stage"]?.intValue ?? capture.context["stages"]?[subunitID]?.intValue
    }

    /// `retryOfCapture`: リザルトの「やり直す」で押した答案。あればその答案(と一枚)の誤りを元にする
    /// (古いリザルトから押しても、より新しい結果の誤りを使わない)。
    func nextSetSpec(subunitID: String, retryOfCapture: String? = nil) throws -> SetSpec {
        guard let row = subunits[subunitID] else { throw LedgerError.notFound("subunit") }
        guard Self.learnerStages.contains(row.stage) else {
            throw Self.error("set_requires_learner_stage", "stages 1 and 2 use the question screen; no set is made")
        }
        guard row.status == "active" else { throw Self.error("subunit_not_active", "only the active subunit gets a set") }
        var spec = row.stage == 3
            ? SetSpec(stage: row.stage, kind: "example", count: 1, n: row.n, threshold: row.threshold)
            : SetSpec(stage: row.stage, kind: "practice", count: row.n, n: row.n, threshold: row.threshold)
        if let captureID = retryOfCapture, let capture = captures[captureID], capture.subunitId == subunitID {
            if let setID = capture.setId, let set = sets[setID], set.stage == row.stage {
                spec.retryOf = set.id
                let problemIDs = Set(set.problemIds)
                spec.targetErrorTags = Array(Set(attemptsOf(subunitID: subunitID).filter {
                    problemIDs.contains($0.problemId) && $0.verdict != "correct" && !$0.errorTag.isEmpty
                }.map(\.errorTag))).sorted()
                return spec
            }
            if capture.setId == nil, Self.captureStage(capture, subunitID: subunitID) == row.stage {
                spec.retryOf = capture.id
                spec.targetErrorTags = Array(Set(attemptsOf(subunitID: subunitID).filter {
                    $0.captureId == capture.id && $0.verdict != "correct" && !$0.errorTag.isEmpty
                }.map(\.errorTag))).sorted()
                return spec
            }
        }
        let previous = sets.values.filter { $0.subunitId == subunitID && $0.status == "graded" && $0.stage == row.stage }
            .max { ($0.gradedAt ?? "") < ($1.gradedAt ?? "") }
        // 一枚を経ずに小単元から撮った答案(同じ段)も、やり直しの元になる。一番新しい結果を元にする。
        let previousCapture = captures.values.filter {
            $0.subunitId == subunitID && $0.setId == nil && $0.status == "graded" && Self.captureStage($0, subunitID: subunitID) == row.stage
        }.max { ($0.gradedAt ?? "") < ($1.gradedAt ?? "") }
        if let capture = previousCapture, (capture.gradedAt ?? "") > (previous?.gradedAt ?? "") {
            let offersRetry = capture.summary["next_actions"]?.arrayValue?.contains(.string("retry")) ?? false
            if offersRetry {
                spec.retryOf = capture.id
                spec.targetErrorTags = Array(Set(attemptsOf(subunitID: subunitID).filter {
                    $0.captureId == capture.id && $0.verdict != "correct" && !$0.errorTag.isEmpty
                }.map(\.errorTag))).sorted()
            }
        } else if let previous, previous.result?["passed"]?.boolValue != true {
            spec.retryOf = previous.id
            let problemIDs = Set(previous.problemIds)
            spec.targetErrorTags = Array(Set(attemptsOf(subunitID: subunitID).filter { problemIDs.contains($0.problemId) && $0.verdict != "correct" && !$0.errorTag.isEmpty }.map(\.errorTag))).sorted()
        }
        return spec
    }

    @discardableResult
    mutating func insertGeneratingSet(subunitID: String, spec: SetSpec) -> String {
        let id = newID()
        var gate: [String: LedgerJSON] = ["count": .number(Double(spec.count)), "n": .number(Double(spec.n)), "threshold": .number(spec.threshold), "kind": .string(spec.kind)]
        if let retryOf = spec.retryOf {
            gate["retry_of"] = .string(retryOf)
            gate["target_error_tags"] = .array(spec.targetErrorTags.map(LedgerJSON.string))
        }
        put("set.created", WorkbookSetRecord(
            id: id, subunitId: subunitID, stage: spec.stage, kind: spec.kind, status: "generating", problemIds: [],
            gate: .object(gate), result: nil, error: nil, createdAt: now(), updatedAt: now(), gradedAt: nil
        ))
        return id
    }

    mutating func fillSet(setID: String, problemIDs: [String]) {
        guard var row = sets[setID], row.status == "generating" else { return }
        row.status = "open"
        row.problemIds = problemIDs
        row.updatedAt = now()
        put("set.filled", row)
    }

    /// 組んでいる一枚に問題を足す(§3.2: 1 問できたら出し、残りは解いている間に届く)。問題数に届いたら開く。
    /// 届いていなければ組んでいるまま(true を返し、残りを組むターンを続ける)。
    @discardableResult
    mutating func appendSetProblems(setID: String, problemIDs: [String]) -> Bool {
        guard var row = sets[setID], row.status == "generating" else { return false }
        let count = max(1, row.gate["count"]?.intValue ?? 1)
        let all = row.problemIds + problemIDs
        if all.count >= count {
            fillSet(setID: setID, problemIDs: Array(all.prefix(count)))
            return false
        }
        row.problemIds = all
        row.updatedAt = now()
        put("set.partial", row)
        return true
    }

    /// 次に要る一枚を先回りで組む(§3.1)。`stage` の一枚の仕様で、組んでいる行を書く。もう組んでいる・開いている
    /// 一枚があれば何もしない(nil)。印 `prefetched` は記録だけで、その段に来れば普通の一枚と同じに扱う。
    mutating func insertPrefetchedSet(subunitID: String, stage: Int) -> String? {
        guard let row = subunits[subunitID], row.status == "active", Self.learnerStages.contains(stage),
              pendingSet(subunitID: subunitID, stage: stage) == nil
        else { return nil }
        var ahead = self
        ahead.subunits[subunitID]?.stage = stage
        guard let spec = try? ahead.nextSetSpec(subunitID: subunitID) else { return nil }
        let id = insertGeneratingSet(subunitID: subunitID, spec: spec)
        if var set = sets[id] {
            set.gate = Self.merge(set.gate, ["prefetched": .bool(true)])
            put("set.prefetched", set)
        }
        return id
    }

    /// 組んだ問題が会話に出た式と同じだった(D14): 重なった式を一枚に残し、組み直させる(1 回だけ)。
    /// 組み直したかどうかは `gate.expression_retries`、重なった式は `gate.rejected_expressions`。
    @discardableResult
    mutating func noteRejectedExpressions(setID: String, expressions: [String]) -> Bool {
        guard var row = sets[setID], row.status == "generating", !expressions.isEmpty else { return false }
        var gate = row.gate.objectValue ?? [:]
        let retries = gate["expression_retries"]?.intValue ?? 0
        guard retries < Self.expressionRetryLimit else { return false }
        gate["expression_retries"] = .number(Double(retries + 1))
        gate["rejected_expressions"] = .array(expressions.prefix(20).map(LedgerJSON.string))
        row.gate = .object(gate)
        row.updatedAt = now()
        put("set.expressions_rejected", row)
        return true
    }

    /// 会話に出た式と重なった時に組み直す回数の上限(D14)。
    static let expressionRetryLimit = 1

    /// 組んだ問題の欠け(勉強を止めない仕組み 3.2): 空の問題文・空の答え・同じ問題文の重なり(一枚の中、または
    /// その小単元に既にある問題と)。空の問題は解けず、判定もできないので、一枚に入れない。
    /// 重なりの比較は空白を全部取り除いて行う(`x+1` と `x + 1`、改行の違いは同じ問題)。
    /// 戻り値は欠けの説明(人が読む・組み直しの依頼に添える)。空なら受け入れてよい。
    nonisolated static func problemDefects(prompts: [String], answerKeys: [String], existingPrompts: [String]) -> [String] {
        func key(_ text: String) -> String {
            String(text.unicodeScalars.filter { !$0.properties.isWhitespace })
        }
        var defects: [String] = []
        var seen = Set(existingPrompts.map(key).filter { !$0.isEmpty })
        for (index, prompt) in prompts.enumerated() {
            let normalized = key(prompt)
            let answer = index < answerKeys.count ? key(answerKeys[index]) : ""
            if normalized.isEmpty {
                defects.append("問題 \(index + 1): 問題文が空")
            } else if seen.contains(normalized) {
                let shown = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                defects.append("問題 \(index + 1): 問題文が重複(\(String(shown.prefix(60))))")
            } else {
                seen.insert(normalized)
            }
            if answer.isEmpty {
                defects.append("問題 \(index + 1): 答えが空")
            }
        }
        return defects
    }

    /// 欠けのある問題で組み直す回数の上限。
    static let defectRetryLimit = 1

    /// 組んだ問題に欠けがあった(3.2): 欠けを一枚に残し、組み直させる(1 回だけ)。
    /// 組み直したかどうかは `gate.defect_retries`、欠けは `gate.rejected_problems`。
    @discardableResult
    mutating func noteDefectiveProblems(setID: String, defects: [String]) -> Bool {
        guard var row = sets[setID], row.status == "generating", !defects.isEmpty else { return false }
        var gate = row.gate.objectValue ?? [:]
        let retries = gate["defect_retries"]?.intValue ?? 0
        guard retries < Self.defectRetryLimit else { return false }
        gate["defect_retries"] = .number(Double(retries + 1))
        gate["rejected_problems"] = .array(defects.prefix(20).map(LedgerJSON.string))
        row.gate = .object(gate)
        row.updatedAt = now()
        put("set.problems_rejected", row)
        return true
    }

    mutating func failSet(setID: String, error: String) {
        guard var row = sets[setID], row.status == "generating" else { return }
        // 組んでいる途中で足した問題(§3.2 の 1 問ずつ)は、一枚が失敗しても消さず、失敗した一枚に結び付けたまま残す。
        // 学習者はその問題をもう開いたり撮ったりしているかもしれず(カメラを開いている間・判定中・判定に失敗して
        // 判定し直す前・整理中の候補)、消すとその答案の行き先が無くなる。小単元に見えたまま解ける問題として残り、
        // 「作り直す」の一枚は重複の検査でこれらと同じ問題を入れない。
        row.status = "failed"
        row.error = String(error.prefix(2000))
        row.updatedAt = now()
        put("set.failed", row)
    }

    // MARK: - Context for turns

    func subunitProblemPrompts(subunitID: String) -> [LedgerJSON] {
        problemsOf(subunitID: subunitID).map { problem in
            .object([
                "id": .string(problem.id), "position": .number(Double(problem.position)), "prompt": .string(problem.prompt),
                "answer_key": .string(problem.answerKey), "checkpoints": .array(problem.checkpoints.map(LedgerJSON.string)),
            ])
        }
    }

    func recentErrorTags(subunitID: String, limit: Int = 10) -> [String] {
        attemptsOf(subunitID: subunitID).reversed().filter { !$0.errorTag.isEmpty }.prefix(limit).map(\.errorTag)
    }

    nonisolated struct GradingContext: Sendable {
        var scope: LedgerJSON
        var subunits: [LedgerJSON]

        var json: LedgerJSON { .object(["scope": scope, "subunits": .array(subunits)]) }

        /// problem id → subunit id for every problem passed to the model.
        var known: [String: String] {
            var result: [String: String] = [:]
            for subunit in subunits {
                guard let sid = subunit["subunit_id"]?.stringValue else { continue }
                for problem in subunit["problems"]?.arrayValue ?? [] {
                    if let pid = problem["id"]?.stringValue { result[pid] = sid }
                }
            }
            return result
        }
    }

    /// 判定ターンへ渡す文脈。撮った小単元・一枚があれば絞り、無ければ学習中の候補を渡す。
    func gradingContext(capture: WorkbookCaptureRecord) -> GradingContext {
        let context = capture.context.objectValue ?? [:]
        var scope: LedgerJSON = .object(["mode": .string("all_active")])
        var subunitIDs: [String] = []
        var setProblemIDs: [String] = []
        if let setID = context["set_id"]?.stringValue, let set = sets[setID] {
            subunitIDs = [set.subunitId]
            setProblemIDs = set.problemIds
            scope = .object(["mode": .string("set"), "set_id": .string(set.id), "kind": .string(set.kind), "stage": .number(Double(set.stage))])
        }
        if subunitIDs.isEmpty, let subunitID = context["subunit_id"]?.stringValue {
            subunitIDs = [subunitID]
            scope = .object(["mode": .string("subunit"), "subunit_id": .string(subunitID)])
        }
        if subunitIDs.isEmpty {
            let rows = orderedSubunits()
            subunitIDs = rows.filter { $0.status == "active" }.map(\.id) + rows.filter { $0.status != "active" }.map(\.id)
        }
        let freeScope = scope["mode"]?.stringValue == "all_active"
        var result: [LedgerJSON] = []
        var budget = Self.maxCandidateProblems
        for sid in subunitIDs {
            guard let row = subunits[sid] else { continue }
            var candidates = problemsOf(subunitID: sid)
            if !setProblemIDs.isEmpty { candidates = candidates.filter { setProblemIDs.contains($0.id) } }
            let chosen = Array(candidates.prefix(max(0, budget)))
            budget -= chosen.count
            var problems: [LedgerJSON] = chosen.map { problem in
                .object([
                    "id": .string(problem.id), "position": .number(Double(problem.position)), "prompt": .string(problem.prompt),
                    "answer_key": .string(problem.answerKey), "checkpoints": .array(problem.checkpoints.map(LedgerJSON.string)),
                ])
            }
            // どの小単元でもない所から撮った紙は、小単元そのものにも照合させる(D12)。問題がまだ無い小単元や、
            // 並んだどの問題とも違う問題でも、到達目標に合えばその小単元の新しい問題として綴じる。
            if freeScope {
                problems.append(.object([
                    "id": .string(Self.subunitMatchID(sid)), "position": .number(0),
                    "prompt": .string("（この小単元の新しい問題: 到達目標「\(row.outcome.isEmpty ? row.title : row.outcome)」に合い、上に並んだどの問題とも違う問題は、この id に照合する）"),
                    "answer_key": .string(""), "checkpoints": .emptyArray,
                ]))
            }
            result.append(.object([
                "subunit_id": .string(sid), "unit_title": .string(units[row.unitId]?.title ?? ""), "title": .string(row.title),
                "outcome": .string(row.outcome), "stage": .number(Double(row.stage)), "stage_label": .string(Self.stageLabels[row.stage] ?? ""),
                "problems": .array(problems),
            ]))
        }
        return GradingContext(scope: scope, subunits: result)
    }

    /// 小単元そのものへの照合に使う id(問題の id の代わりに `matched_problem_id` に入る)。D12。
    static let subunitMatchPrefix = "subunit:"

    static func subunitMatchID(_ subunitID: String) -> String { subunitMatchPrefix + subunitID }

    static func subunitID(fromMatch id: String) -> String? {
        id.hasPrefix(subunitMatchPrefix) ? String(id.dropFirst(subunitMatchPrefix.count)) : nil
    }

    /// 質問画面が今見ている小単元・一枚・直近の答案と判定 (`<struis_current_view>` の中身)。
    func currentViewContext(subunitID: String?, setID: String?, captureID: String? = nil) -> LedgerJSON? {
        guard subunitID != nil || setID != nil || captureID != nil else { return nil }
        var result: [String: LedgerJSON] = [:]
        var resolvedSubunit = subunitID
        if let captureID, let capture = captures[captureID] {
            resolvedSubunit = resolvedSubunit ?? capture.subunitId
            result["current_capture"] = .object([
                "capture_id": .string(capture.id), "status": .string(capture.status), "created_at": .string(capture.createdAt),
                "verdicts": capture.verdicts, "summary": capture.summary["result"] ?? .null,
            ])
        }
        if let setID, let set = sets[setID] {
            resolvedSubunit = set.subunitId
            let wanted = Set(set.problemIds)
            result["current_set"] = .object([
                "set_id": .string(set.id), "kind": .string(set.kind), "stage": .number(Double(set.stage)), "status": .string(set.status),
                "problems": .array(subunitProblemPrompts(subunitID: set.subunitId).filter { wanted.contains($0["id"]?.stringValue ?? "") }),
            ])
        }
        guard let sid = resolvedSubunit, let row = subunits[sid] else { return result.isEmpty ? nil : .object(result) }
        let summary = subunitSummary(row)
        let subunitMetadata = row.metadata.objectValue ?? [:]
        var extra: [String: LedgerJSON] = [:]
        // 今の回の例題だけを渡す(「例題に戻る」で回が進んだ後は、前の回の例題を渡さない)。
        let exampleRound = subunitMetadata["example_round"]?.intValue ?? 0
        if let example = subunitMetadata["example_problem"], (example["round"]?.intValue ?? 0) == exampleRound,
           let prompt = example["prompt"], row.stage == 2 { extra["example_problem"] = prompt }
        if let back = subunitMetadata["return_stage"], row.stage == 2 { extra["returned_from_stage"] = back }
        if row.stage == 2, let tags = subunitMetadata["return_error_tags"] { extra["recent_error_tags"] = tags }
        result["subunit"] = .object(extra.merging([
            "subunit_id": .string(summary.id), "unit_title": .string(summary.unitTitle), "title": .string(summary.title),
            "outcome": .string(summary.outcome), "stage": .number(Double(summary.stage)), "stage_label": .string(summary.stageLabel),
            "status": .string(summary.status.rawValue), "n": .number(Double(summary.n)), "threshold": .number(summary.threshold),
            "window": passWindow(subunitID: sid).json,
            "problems": .array(summary.tiles.map { tile in
                .object([
                    "id": .string(tile.id), "position": .number(Double(tile.position)), "prompt": .string(tile.prompt),
                    "state": .string(tile.state.rawValue), "assisted": .bool(tile.assisted), "error_tag": .string(tile.errorTag),
                ])
            }),
        ]) { current, _ in current })
        let recent = captures.values.filter { $0.subunitId == sid }.sorted { $0.createdAt > $1.createdAt }.prefix(3)
        result["recent_captures"] = .array(recent.map { capture in
            .object([
                "capture_id": .string(capture.id), "status": .string(capture.status), "created_at": .string(capture.createdAt),
                "verdicts": capture.verdicts, "summary": capture.summary["result"] ?? .null,
            ])
        })
        return .object(result)
    }

    // MARK: - Captures and grading (workbook_turns.apply_grading_result)

    /// The model's `schema:workbook_grading` reply (Codable mirror of `WorkbookGradingResult`).
    nonisolated struct GradingResult: Codable, Sendable, Equatable {
        nonisolated struct Item: Codable, Sendable, Equatable {
            var label: String
            var promptText: String
            var matchedProblemId: String?
            var verdict: String
            var errorTag: String
            var note: String

            enum CodingKeys: String, CodingKey {
                case label, verdict, note
                case promptText = "prompt_text"
                case matchedProblemId = "matched_problem_id"
                case errorTag = "error_tag"
            }

            var json: LedgerJSON {
                .object([
                    "label": .string(label), "prompt_text": .string(promptText), "matched_problem_id": matchedProblemId.map(LedgerJSON.string) ?? .null,
                    "verdict": .string(verdict), "error_tag": .string(errorTag), "note": .string(note),
                ])
            }
        }

        nonisolated struct Candidate: Codable, Sendable, Equatable {
            var problemId: String
            var reason: String
            enum CodingKeys: String, CodingKey { case problemId = "problem_id", reason }
        }

        nonisolated struct NewSubunit: Codable, Sendable, Equatable {
            var unitTitle: String
            var subunitTitle: String
            var outcome: String
            var n: Int
            var scoringUnit: String
            enum CodingKeys: String, CodingKey {
                case n, outcome
                case unitTitle = "unit_title"
                case subunitTitle = "subunit_title"
                case scoringUnit = "scoring_unit"
            }
        }

        var readable: Bool
        var items: [Item]
        var candidates: [Candidate]
        var newSubunit: NewSubunit?
        var note: String

        enum CodingKeys: String, CodingKey {
            case readable, items, candidates, note
            case newSubunit = "new_subunit"
        }

        static func parse(_ text: String) throws -> GradingResult {
            guard let data = text.data(using: .utf8) else { throw LedgerError.invalid("grading result is not UTF-8") }
            var result = try JSONDecoder().decode(GradingResult.self, from: data)
            result.items = result.items.map { item in
                var copy = item
                if !["correct", "wrong", "unknown"].contains(copy.verdict) { copy.verdict = "unknown" }
                return copy
            }
            return result
        }
    }

    nonisolated struct CaptureOutcome: Sendable {
        var status: String
        var subunitID: String?
        var summary: LedgerJSON = .emptyObject
    }

    /// 撮った紙を `identifying` で登録する (`POST /v1/captures` の移植)。
    @discardableResult
    /// `pagePaths`: 何枚かをまとめて撮った答案の、全ページの写真(順に。1 枚目は `imagePath`)。1 枚なら空。
    mutating func createCapture(id: String, imagePath: String, contentType: String, sha256: String, byteCount: Int, subunitID: String?, setID: String?, pagePaths: [String] = []) throws -> WorkbookCaptureDTO {
        var context: [String: LedgerJSON] = [:]
        var resolvedSubunit: String?
        var resolvedSet: String?
        if let setID {
            guard let set = sets[setID] else { throw Self.error("set_not_found", "set not found") }
            context = ["set_id": .string(setID), "subunit_id": .string(set.subunitId), "stage": .number(Double(set.stage))]
            resolvedSubunit = set.subunitId
            resolvedSet = setID
        } else if let subunitID {
            guard let subunit = subunits[subunitID] else { throw Self.error("subunit_not_found", "subunit not found") }
            // 撮った時の段。一枚の無い答案を後から判定し直す時に、類題か演習かと、段が進んだかを決める。
            context = ["subunit_id": .string(subunitID), "stage": .number(Double(subunit.stage))]
            resolvedSubunit = subunitID
        } else {
            // どの小単元でもない所(ホーム)から撮った答案: 撮った時の、進めている小単元ごとの段を残す
            // (判定が遅れて、その間に「例題に戻る」「先に進む」があっても、撮った時の段で演習かどうかを決める)。
            let stages = subunits.values.filter { $0.status == "active" }.map { ($0.id, LedgerJSON.number(Double($0.stage))) }
            context = ["stages": .object(Dictionary(stages, uniquingKeysWith: { first, _ in first }))]
        }
        if pagePaths.count > 1 { context["page_paths"] = .array(pagePaths.map(LedgerJSON.string)) }
        let row = WorkbookCaptureRecord(
            id: id, status: "identifying", imagePath: imagePath, contentType: contentType, sha256: sha256, byteCount: byteCount,
            context: .object(context), subunitId: resolvedSubunit, setId: resolvedSet, verdicts: .emptyArray, summary: .emptyObject,
            candidates: .emptyArray, error: nil, createdAt: now(), updatedAt: now(), gradedAt: nil
        )
        put("capture.created", row)
        return captureView(row)
    }

    mutating func failCapture(id: String, error: String) {
        guard var row = captures[id], row.status == "identifying" else { return }
        row.status = "failed"
        row.error = String(error.prefix(2000))
        row.updatedAt = now()
        put("capture.failed", row)
    }

    private mutating func finishCapture(_ capture: WorkbookCaptureRecord, status: String, subunitID: String?, setID: String?, summary: LedgerJSON, candidates: [LedgerJSON], verdicts: [LedgerJSON], error: String? = nil) -> CaptureOutcome {
        var row = capture
        row.status = status
        row.subunitId = subunitID
        row.setId = setID
        row.verdicts = .array(verdicts)
        row.summary = summary
        row.candidates = .array(candidates)
        row.error = error
        if status == "graded" { row.gradedAt = now() }
        row.updatedAt = now()
        put("capture.\(status)", row)
        return CaptureOutcome(status: status, subunitID: subunitID, summary: summary)
    }

    private mutating func patchCaptureSummary(id: String, _ patch: [String: LedgerJSON]) {
        guard var row = captures[id] else { return }
        row.summary = Self.merge(row.summary, patch)
        row.updatedAt = now()
        put("capture.summary_patched", row)
    }

    /// 判定結果をマスに反映する。文脈 (一枚 / 小単元 / なし) ごとに綴じ方が違う。
    mutating func applyGradingResult(captureID: String, graded input: GradingResult, context: GradingContext) throws -> CaptureOutcome {
        guard let capture = captures[captureID] else { return CaptureOutcome(status: "missing") }
        guard capture.status == "identifying" else { return CaptureOutcome(status: capture.status) }
        var graded = input
        let scope = context.scope.objectValue ?? [:]
        var known = context.known
        let capturedAt = capture.createdAt

        if !graded.readable || graded.items.isEmpty {
            return finishCapture(capture, status: "triage", subunitID: nil, setID: nil, summary: .object(["outcome": .string("unreadable")]), candidates: [], verdicts: graded.items.map(\.json), error: graded.note.isEmpty ? "答案を読み取れませんでした" : graded.note)
        }

        // 小単元そのものに照合した問題(D12): その小単元の新しい問題(紙のマス)として足し、以後は問題に照合したものと同じに扱う。
        for index in graded.items.indices {
            guard let match = graded.items[index].matchedProblemId, let sid = Self.subunitID(fromMatch: match),
                  known[match] == sid, subunits[sid] != nil else { continue }
            let prompt = graded.items[index].promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = addProblems(subunitID: sid, problems: [ProblemSpec(prompt: prompt.isEmpty ? "撮った紙の問題" : prompt)], source: "capture")[0]
            graded.items[index].matchedProblemId = id
            known[id] = sid
        }
        let verdictRows = graded.items.map(\.json)
        let matched = graded.items.filter { $0.matchedProblemId != nil && known[$0.matchedProblemId!] != nil }
        let unmatched = graded.items.filter { !($0.matchedProblemId != nil && known[$0.matchedProblemId!] != nil) }

        // 1) 一枚から撮った: 写っている問題だけを、その一枚のマスに綴じる。組み立てに失敗した一枚は一枚として集計も
        //    締めもせず(残りの問題が無い)、小単元から撮った答案と同じに綴じる(2)。
        if scope["mode"]?.stringValue == "set", !matched.isEmpty, let setID = scope["set_id"]?.stringValue, sets[setID]?.status != "failed" {
            let subunitID = known[matched[0].matchedProblemId!]!
            let recorded = recordAttempts(captureID: captureID, subunitID: subunitID, setID: setID, verdicts: matched.map { Verdict(problemID: $0.matchedProblemId!, verdict: $0.verdict, errorTag: $0.errorTag, note: $0.note) }, capturedAt: capturedAt)
            if let setRow = sets[setID], splitsAcrossCaptures(setRow) {
                // 演習の一枚は何枚の写真に分けて撮ってもよい(分割採点 R2〜R4)。
                let missing = missingPositions(setID: setID)
                if isOpenForCapture(setRow), !missing.isEmpty {
                    // まだ判定の無い問題が残る: 一枚は締めず、段・合格・不合格の回数も動かさない。
                    let stage = setRow.stage
                    let summary: LedgerJSON = .object([
                        "result": Self.plainResult(recorded), "outcome": .string("partial"), "kind": .string("practice"),
                        "stage_before": .number(Double(stage)), "stage_after": .number(Double(stage)), "counts_toward_window": .bool(stage == 4),
                        "missing_positions": .array(missing.map { .number(Double($0)) }),
                        "next_actions": .array([.string("capture_more"), .string("close_set"), .string("ask")]),
                    ])
                    return finishCapture(capture, status: "graded", subunitID: subunitID, setID: setID, summary: summary, candidates: [], verdicts: Self.withIDs(verdictRows, recorded: recorded))
                }
                // 全問そろった(または締めた後に残りを撮った): 一枚に綴じた全答案の判定を合わせて集計する。
                let setOutcome = try applySetGrading(
                    subunitID: subunitID, setID: setID, recorded: setRecorded(setID: setID), captureID: captureID,
                    countsFailure: setRow.status != "graded"
                )
                var summary = Self.outcomeSummary(setOutcome).objectValue ?? [:]
                summary["missing_positions"] = .array(missing.map { .number(Double($0)) })
                return finishCapture(capture, status: "graded", subunitID: subunitID, setID: setID, summary: .object(summary), candidates: [], verdicts: Self.withIDs(verdictRows, recorded: recorded))
            }
            let setOutcome = try applySetGrading(subunitID: subunitID, setID: setID, recorded: recorded, captureID: captureID)
            let summary = Self.outcomeSummary(setOutcome)
            return finishCapture(capture, status: "graded", subunitID: subunitID, setID: setID, summary: summary, candidates: [], verdicts: Self.withIDs(verdictRows, recorded: recorded))
        }

        // 2) 小単元から撮った: 既存のマスに綴じ、無いものは新しいマスとして足す
        if let mode = scope["mode"]?.stringValue, mode == "subunit" || mode == "set" {
            let subunitID = scope["subunit_id"]?.stringValue ?? context.subunits.first?["subunit_id"]?.stringValue ?? ""
            var verdicts = matched.filter { known[$0.matchedProblemId!] == subunitID }.map { Verdict(problemID: $0.matchedProblemId!, verdict: $0.verdict, errorTag: $0.errorTag, note: $0.note) }
            let newItems = unmatched.enumerated().filter { !$0.element.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !newItems.isEmpty {
                let ids = addProblems(subunitID: subunitID, problems: newItems.map { ProblemSpec(prompt: $0.element.promptText) }, source: "capture")
                for ((index, item), id) in zip(newItems, ids) {
                    verdicts.append(Verdict(problemID: id, verdict: item.verdict, errorTag: item.errorTag, note: item.note))
                    graded.items[graded.items.firstIndex(where: { $0 == item })!].matchedProblemId = id
                    _ = index
                }
            }
            if verdicts.isEmpty {
                return finishCapture(capture, status: "triage", subunitID: subunitID, setID: nil, summary: .object(["outcome": .string("unmatched")]), candidates: candidateRows(context: context, candidates: graded.candidates, fallback: true), verdicts: verdictRows)
            }
            let recorded = recordAttempts(captureID: captureID, subunitID: subunitID, setID: nil, verdicts: verdicts, capturedAt: capturedAt)
            // 演習の答えかどうかは撮った時の段で決める(判定中に「例題に戻る」を押されても、演習の答えは演習として残す)。
            // 段を動かすかどうかは `applySetGrading` が今の段で決める。
            let stage = capture.context["stage"]?.intValue ?? subunits[subunitID]?.stage ?? 0
            var boundSummary: [String: LedgerJSON] = [
                "result": Self.plainResult(recorded), "outcome": .string("bound"), "counts_toward_window": .bool(stage == 4),
                "stage_before": .number(Double(stage)), "stage_after": .number(Double(stage)), "next_actions": .array([.string("ask")]),
            ]
            var done = finishCapture(capture, status: "graded", subunitID: subunitID, setID: nil, summary: .object(boundSummary), candidates: [], verdicts: Self.withIDs(graded.items.map(\.json), recorded: recorded))
            if stage == 4 {
                let boundOutcome = try applySetGrading(subunitID: subunitID, setID: nil, recorded: recorded, captureID: captureID)
                for (key, value) in Self.outcomeSummary(boundOutcome).objectValue ?? [:] { boundSummary[key] = value }
                patchCaptureSummary(id: captureID, boundSummary)
                done.summary = .object(boundSummary)
            }
            return done
        }

        // 3) 文脈なし: 判定でマスが特定できればそこへ、全部が同じ小単元なら段階も動かす
        if !matched.isEmpty {
            var bySubunit: [String: [GradingResult.Item]] = [:]
            var order: [String] = []
            for item in matched {
                let sid = known[item.matchedProblemId!]!
                if bySubunit[sid] == nil { order.append(sid) }
                bySubunit[sid, default: []].append(item)
            }
            var recordedAll: [Recorded] = []
            var firstSubunit: String?
            var freeOutcome: GradingOutcome?
            for sid in order {
                let items = bySubunit[sid]!
                firstSubunit = firstSubunit ?? sid
                let recorded = recordAttempts(captureID: captureID, subunitID: sid, setID: nil, verdicts: items.map { Verdict(problemID: $0.matchedProblemId!, verdict: $0.verdict, errorTag: $0.errorTag, note: $0.note) }, capturedAt: capturedAt)
                recordedAll.append(contentsOf: recorded)
                // 演習の答えかどうかは撮った時の段で決める(記録が無い旧い答案は今の段)。
                if order.count == 1, (capture.context["stages"]?[sid]?.intValue ?? subunits[sid]?.stage) == 4 {
                    freeOutcome = try applySetGrading(subunitID: sid, setID: nil, recorded: recorded, captureID: captureID)
                }
            }
            let stage = firstSubunit.flatMap { capture.context["stages"]?[$0]?.intValue ?? subunits[$0]?.stage } ?? 0
            var freeSummary: [String: LedgerJSON] = [
                "result": Self.plainResult(recordedAll), "outcome": .string("bound"), "counts_toward_window": .bool(freeOutcome != nil),
                "stage_before": .number(Double(stage)), "stage_after": .number(Double(stage)), "next_actions": .array([.string("ask")]),
            ]
            if let freeOutcome {
                for (key, value) in Self.outcomeSummary(freeOutcome).objectValue ?? [:] { freeSummary[key] = value }
            }
            return finishCapture(capture, status: "graded", subunitID: firstSubunit, setID: nil, summary: .object(freeSummary), candidates: [], verdicts: Self.withIDs(verdictRows, recorded: recordedAll))
        }

        // 4) どのマスでもない: 単元が無ければ紙から新設 (入口 B)、あれば整理中へ
        if known.isEmpty, let draft = graded.newSubunit {
            let unitID = createUnit(
                title: draft.unitTitle, outcome: "", source: "capture",
                subunits: [SubunitSpec(title: draft.subunitTitle, outcome: draft.outcome, n: draft.n, scoringUnit: draft.scoringUnit)],
                overview: .object(["subunits": .array([.object(["title": .string(draft.subunitTitle), "outcome": .string(draft.outcome), "n": .number(Double(draft.n))])]), "pending_overview": .bool(true)]),
                firstStage: 4
            )
            let subunitID = orderedSubunits(unitID: unitID).first!.id
            let paperItems = graded.items.enumerated().filter { !$0.element.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let ids = addProblems(subunitID: subunitID, problems: paperItems.map { ProblemSpec(prompt: $0.element.promptText) }, source: "capture")
            var verdicts: [Verdict] = []
            for ((index, item), id) in zip(paperItems, ids) {
                graded.items[index].matchedProblemId = id
                verdicts.append(Verdict(problemID: id, verdict: item.verdict, errorTag: item.errorTag, note: item.note))
            }
            let recorded = recordAttempts(captureID: captureID, subunitID: subunitID, setID: nil, verdicts: verdicts, capturedAt: capturedAt)
            let summary: LedgerJSON = .object([
                "result": Self.plainResult(recorded), "outcome": .string("new_unit"), "unit_id": .string(unitID), "counts_toward_window": .bool(true),
            ])
            return finishCapture(capture, status: "graded", subunitID: subunitID, setID: nil, summary: summary, candidates: [], verdicts: Self.withIDs(graded.items.map(\.json), recorded: recorded))
        }

        let candidates = candidateRows(context: context, candidates: graded.candidates, fallback: !known.isEmpty)
        return finishCapture(capture, status: "triage", subunitID: nil, setID: nil, summary: .object(["outcome": .string("unmatched")]), candidates: candidates, verdicts: verdictRows)
    }

    mutating func noteNextSet(captureID: String, setID: String) {
        patchCaptureSummary(id: captureID, ["next_set_id": .string(setID)])
    }

    func candidateRows(context: GradingContext, candidates: [GradingResult.Candidate], fallback: Bool) -> [LedgerJSON] {
        var index: [(problem: LedgerJSON, subunit: LedgerJSON)] = []
        var byID: [String: (problem: LedgerJSON, subunit: LedgerJSON)] = [:]
        for subunit in context.subunits {
            for problem in subunit["problems"]?.arrayValue ?? [] {
                // 小単元そのものへの照合(D12)は、候補の「問題」には出さない。
                guard let pid = problem["id"]?.stringValue, Self.subunitID(fromMatch: pid) == nil else { continue }
                index.append((problem, subunit))
                byID[pid] = (problem, subunit)
            }
        }
        func row(_ problem: LedgerJSON, _ subunit: LedgerJSON, reason: String) -> LedgerJSON {
            .object([
                "problem_id": problem["id"] ?? .null, "subunit_id": subunit["subunit_id"] ?? .null,
                "subunit_title": subunit["title"] ?? .string(""), "prompt": problem["prompt"] ?? .string(""), "reason": .string(reason),
            ])
        }
        var rows: [LedgerJSON] = []
        for candidate in candidates where !Self.reasonSaysMismatch(candidate.reason) {
            guard let found = byID[candidate.problemId] else { continue }
            rows.append(row(found.problem, found.subunit, reason: candidate.reason))
        }
        // 候補が無ければ無理に並べない(画面は「どの問題？」から選ばせる)。
        _ = (index, fallback)
        return Array(rows.prefix(3))
    }

    /// 判定の講評が「一致しない」と言っている候補は、候補として出さない(E2E M7)。
    /// 「表記は異なるが、内容は一致します」のように、違いを述べた上で一致と結論している講評は候補に残す。
    static func reasonSaysMismatch(_ reason: String) -> Bool {
        let negative = reason.range(of: #"一致し(ない|ません)|該当し(ない|ません)|(違|ちが)(う|います)|異な(る|ります)|別の問題|同じ問題では(ない|ありません)|合わない|合いません"#, options: .regularExpression) != nil
        guard negative else { return false }
        let affirmative = reason.range(of: #"一致(する|します|している|しています)|該当(する|します)|同じ問題(?!では)"#, options: .regularExpression) != nil
        let flatlyNegative = reason.range(of: #"一致し(ない|ません)|該当し(ない|ません)|別の問題|同じ問題では(ない|ありません)"#, options: .regularExpression) != nil
        return !(affirmative && !flatlyNegative)
    }

    static func withIDs(_ verdictRows: [LedgerJSON], recorded: [Recorded]) -> [LedgerJSON] {
        let byProblem = Dictionary(recorded.map { ($0.problemID, $0) }, uniquingKeysWith: { _, last in last })
        return verdictRows.map { row in
            let pid = row["matched_problem_id"]?.stringValue
            let rec = pid.flatMap { byProblem[$0] }
            return .object([
                "problem_id": pid.map(LedgerJSON.string) ?? .null,
                "label": row["label"] ?? .string(""),
                "prompt_text": row["prompt_text"] ?? .string(""),
                "verdict": .string(rec?.verdict ?? row["verdict"]?.stringValue ?? "unknown"),
                "error_tag": row["error_tag"] ?? .string(""),
                "note": row["note"] ?? .string(""),
                "assisted": .bool(rec?.assisted ?? false),
            ])
        }
    }

    static func plainResult(_ recorded: [Recorded]) -> LedgerJSON {
        let total = recorded.count
        let correct = recorded.filter { $0.verdict == "correct" }.count
        return .object([
            "correct": .number(Double(correct)), "total": .number(Double(total)),
            "score": .number(total > 0 ? Double(correct) / Double(total) : 0.0), "passed": .bool(total > 0 && correct == total),
        ])
    }

    static func outcomeLabel(_ outcome: GradingOutcome) -> String {
        if outcome.unitPassed { return "unit_passed" }
        if outcome.passed { return "subunit_passed" }
        if outcome.stageAfter > outcome.stageBefore { return "stage_advanced" }
        if outcome.nextActions.contains("retry") { return "not_passed" }
        return "bound"
    }

    static func outcomeSummary(_ outcome: GradingOutcome) -> LedgerJSON {
        .object([
            "result": outcome.result, "outcome": .string(outcomeLabel(outcome)),
            "stage_before": .number(Double(outcome.stageBefore)), "stage_after": .number(Double(outcome.stageAfter)),
            "kind": .string(outcome.kind), "window": outcome.kind == "practice" ? outcome.window : .null,
            "window_tiles": .array(outcome.windowTiles), "subunit_passed": .bool(outcome.passed),
            "next_subunit_id": outcome.nextSubunitID.map(LedgerJSON.string) ?? .null, "unit_passed": .bool(outcome.unitPassed),
            "next_actions": .array(outcome.nextActions.map(LedgerJSON.string)), "counts_toward_window": .bool(outcome.kind == "practice"),
        ])
    }

    // MARK: - Triage assignment (routes/workbook.py assign_capture)

    nonisolated enum Assignment: Sendable {
        case problem(id: String)
        case newProblem(subunitID: String)
        case newSubunit(unitID: String?, unitTitle: String, title: String, n: Int)
    }

    /// 整理中の答案を綴じる。紙に複数の問題があれば、すべてを綴じる(D12):
    /// 既存の問題を選んだ時は 1 問目をその問題に、残りを同じ小単元の新しい問題に。新しい問題・新しい小単元の時は全部を新しい問題に。
    mutating func assign(captureID: String, assignment: Assignment, verdictOverride: String?) throws -> WorkbookCaptureDTO {
        guard let capture = captures[captureID] else { throw Self.error("capture_not_found", "capture not found") }
        guard capture.status == "triage" else { throw Self.error("capture_not_in_triage", "only 整理中 captures can be assigned") }
        let verdicts = capture.verdicts.arrayValue?.compactMap { $0.objectValue } ?? []
        let fallback: [String: LedgerJSON] = ["verdict": .string("unknown"), "error_tag": .string(""), "note": .string(""), "prompt_text": .string("")]
        let items = verdicts.isEmpty ? [fallback] : verdicts
        func spec(_ item: [String: LedgerJSON]) -> ProblemSpec {
            let prompt = item["prompt_text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ProblemSpec(prompt: prompt.isEmpty ? "撮った紙の問題" : prompt)
        }
        let subunitID: String
        let problemIDs: [String]
        switch assignment {
        case .problem(let id):
            guard let problem = problems[id] else { throw Self.error("problem_not_found", "problem not found") }
            subunitID = problem.subunitId
            problemIDs = [id] + addProblems(subunitID: subunitID, problems: items.dropFirst().map(spec), source: "capture")
        case .newProblem(let sid):
            guard subunits[sid] != nil else { throw Self.error("subunit_not_found", "subunit not found") }
            subunitID = sid
            problemIDs = addProblems(subunitID: sid, problems: items.map(spec), source: "capture")
        case .newSubunit(let unitID, let unitTitle, let title, let n):
            if let unitID {
                guard units[unitID] != nil else { throw Self.error("unit_not_found", "unit not found") }
                subunitID = createSubunit(unitID: unitID, spec: SubunitSpec(title: title, n: n), stage: 4, status: "active")
            } else {
                let newUnit = createUnit(title: unitTitle.isEmpty ? title : unitTitle, outcome: "", source: "capture", subunits: [SubunitSpec(title: title, n: n)], firstStage: 4)
                subunitID = orderedSubunits(unitID: newUnit).first!.id
            }
            problemIDs = addProblems(subunitID: subunitID, problems: items.map(spec), source: "capture")
        }
        let itemVerdicts = items.indices.map { index in
            index == 0 ? (verdictOverride ?? items[0]["verdict"]?.stringValue ?? "unknown") : (items[index]["verdict"]?.stringValue ?? "unknown")
        }
        let recorded = recordAttempts(
            captureID: captureID, subunitID: subunitID, setID: nil,
            verdicts: zip(problemIDs, items.indices).map { problemID, index in
                Verdict(problemID: problemID, verdict: itemVerdicts[index], errorTag: items[index]["error_tag"]?.stringValue ?? "", note: items[index]["note"]?.stringValue ?? "")
            },
            capturedAt: capture.createdAt
        )
        // 演習の答えかどうかは、その小単元で撮った答案なら撮った時の段で決める(整理する前に「例題に戻る」を
        // 押されても演習の答えを失わない)。段を動かすかどうかは `applySetGrading` が今の段で決める。
        let capturedStage = capture.context["subunit_id"]?.stringValue == subunitID
            ? capture.context["stage"]?.intValue : capture.context["stages"]?[subunitID]?.intValue
        let stage = capturedStage ?? subunits[subunitID]?.stage ?? 0
        var summary: [String: LedgerJSON] = [
            "result": Self.plainResult(recorded), "outcome": .string("assigned"), "counts_toward_window": .bool(stage == 4),
            "stage_before": .number(Double(stage)), "stage_after": .number(Double(stage)), "next_actions": .array([.string("ask")]),
        ]
        if stage == 4 {
            let outcome = try applySetGrading(subunitID: subunitID, setID: nil, recorded: recorded, captureID: captureID)
            for (key, value) in Self.outcomeSummary(outcome).objectValue ?? [:] where key != "outcome" { summary[key] = value }
        }
        var newVerdicts = items
        for index in newVerdicts.indices {
            newVerdicts[index]["problem_id"] = .string(problemIDs[index])
            newVerdicts[index]["verdict"] = .string(itemVerdicts[index])
        }
        var row = capture
        row.status = "graded"
        row.subunitId = subunitID
        row.verdicts = .array(newVerdicts.map(LedgerJSON.object))
        row.summary = .object(summary)
        row.candidates = .emptyArray
        row.error = nil
        row.gradedAt = now()
        row.updatedAt = now()
        put("capture.assigned", row)
        return captureView(row)
    }

    // MARK: - Proposals (入口 A)

    @discardableResult
    mutating func insertProposal(request: String, threadID: String?, messageID: String?) -> String {
        let id = newID()
        put("proposal.created", WorkbookProposalRecord(
            id: id, threadId: threadID, messageId: messageID, status: "generating", request: String(request.prefix(4000)),
            overview: .emptyObject, unitId: nil, error: nil, createdAt: now(), updatedAt: now()
        ))
        return id
    }

    mutating func completeProposal(id: String, overview: LedgerJSON) {
        guard var row = proposals[id], row.status == "generating" else { return }
        row.status = "ready"
        row.overview = Self.cleanOverview(overview)
        row.updatedAt = now()
        put("proposal.ready", row)
    }

    mutating func failProposal(id: String, error: String) {
        guard var row = proposals[id], row.status == "generating" else { return }
        row.status = "failed"
        row.error = String(error.prefix(2000))
        row.updatedAt = now()
        put("proposal.failed", row)
    }

    /// 「はじめる」: 単元カードを立て、小単元 1 の段階 1 に入る。
    mutating func startProposal(id: String) throws -> WorkbookProposalDTO {
        guard var row = proposals[id] else { throw LedgerError.notFound("proposal") }
        if row.status == "started" { return proposalView(row) }
        guard row.status == "ready" else { throw Self.error("proposal_not_ready", "the overview is not ready") }
        let overview = row.overview.objectValue ?? [:]
        let specs = (overview["subunits"]?.arrayValue ?? []).compactMap(SubunitSpec.init(json:))
        guard !specs.isEmpty else { throw Self.error("proposal_empty", "the overview has no subunits") }
        let title = overview["unit_title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? String(row.request.prefix(80))
        let unitID = createUnit(title: title, outcome: overview["outcome"]?.stringValue ?? "", source: "consult", subunits: specs, overview: row.overview)
        row.status = "started"
        row.unitId = unitID
        row.updatedAt = now()
        put("proposal.started", row)
        return proposalView(row)
    }

    // MARK: - 到達目標・全体像の文面

    /// 全体像カードと到達目標に、未置換の記号(`n` 単独、`{…}`)と計画メモ(「1週目前半に、」)を出さない。
    /// 到達目標は 1 文にする。n が分かれば実際の値に置き換える。
    /// 記号ごとに実際の値を入れる: `{n}` は n、`{required}` などは合格に要る正解数(n と合格ラインから計算、
    /// n が分からなければ「8割」)。ほかに決まった記号の名前(`{window}` など)は消す。
    /// 数式の波かっこ(`x^{2}`、`\frac{1}{2}`、`\text{cm}`、`{1,2,3}`)は残す。
    static func cleanOutcome(_ text: String, n: Int? = nil, threshold: Double = 0.8) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func replace(_ pattern: String, _ template: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            value = regex.stringByReplacingMatches(in: value, range: NSRange(location: 0, length: (value as NSString).length), withTemplate: template)
        }
        // 直前が英数字・`\`・`^`・`_`・`}` なら数式の一部(`\frac{a}{b}`、`a_{m}`、`x^{n}`)。
        let notMath = #"(?<![A-Za-z0-9\\^_}])"#
        let required = notMath + #"\{\s*(?:required(?:_correct|_count)?|m)\s*\}"#
        if let n {
            replace(required, String(requiredCorrect(n: n, threshold: threshold)))
        } else {
            let ratio = "\(Int((threshold * 10).rounded()))割"
            replace(required + #"\s*問"#, ratio)
            replace(required, ratio)
        }
        replace(notMath + #"\{\s*[nN]\s*\}"#, "n")
        // 消すのは、モデルが埋め忘れた記号の名前だけ(集合の `{x}`・`{A}` などは残す)。
        replace(notMath + #"\{\s*(?:window(?:_size)?|count|total|threshold|ratio|percent(?:age)?|pass(?:_count|_line)?|num(?:ber)?(?:_of_[a-z]+)?|problems?|questions?|items?|correct(?:_count)?|target|goal|k|x_percent)\s*\}"#, "")
        // 問題数としての n(「直近n問」「n問中」)だけを置き換える。「n次方程式」などの数式の n は残す。
        if let n {
            replace(#"(?<![A-Za-z0-9])[nN](?=\s*問)"#, String(n))
        } else {
            replace(#"直近\s*[nN]\s*問"#, "直近の演習")
            replace(#"(?<![A-Za-z0-9])[nN]\s*(?=問)"#, "")
        }
        // 計画メモの前置き(「1週目前半に、」「第2週に、」「初日に、」)。読点で区切られている時だけ消す
        // (「第2週に習う二次方程式を解ける」のように目標の言葉が続く時は残す)。
        replace(#"^(?:第?\d+\s*(?:週目?|日目?)|初日|最終日)[^、。,]{0,8}[、,]\s*"#, "")
        // 1 文だけ。
        if let end = value.firstIndex(of: "。"), value.index(after: end) < value.endIndex {
            value = String(value[...end])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 単元生成の応答を台帳に入れる前に整える。
    static func cleanOverview(_ overview: LedgerJSON) -> LedgerJSON {
        guard var object = overview.objectValue else { return overview }
        if let outcome = object["outcome"]?.stringValue { object["outcome"] = .string(cleanOutcome(outcome)) }
        if let subunits = object["subunits"]?.arrayValue {
            object["subunits"] = .array(subunits.map { item in
                guard var spec = item.objectValue else { return item }
                let n = spec["n"]?.intValue
                if let outcome = spec["outcome"]?.stringValue { spec["outcome"] = .string(cleanOutcome(outcome, n: n)) }
                if let title = spec["title"]?.stringValue { spec["title"] = .string(cleanOutcome(title, n: n).replacingOccurrences(of: "。", with: "")) }
                return .object(spec)
            })
        }
        return .object(object)
    }

    // MARK: - JSON helpers

    static func merge(_ base: LedgerJSON, _ patch: [String: LedgerJSON]) -> LedgerJSON {
        var object = base.objectValue ?? [:]
        for (key, value) in patch { object[key] = value }
        return .object(object)
    }
}
