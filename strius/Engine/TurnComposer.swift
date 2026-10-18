import Foundation
import GRDB
import OSLog

private let applierLog = Logger(subsystem: "com.digiloglab.strius", category: "turn-applier")

/// Builds `TurnPlan`s from the ledger (design §6.2 `TurnComposer`). Structured
/// turns (判定・一枚・単元) follow `start_structured_turn` in `codex_app_server.py`
/// and the request shapes in `workbook_turns.py`.
nonisolated struct TurnComposer {
    let assets: AssetCache

    nonisolated static func structuredConfig(effort: String) -> LedgerJSON {
        .object([
            "model_reasoning_effort": .string(effort),
            "features.multi_agent": .bool(false), "features.unified_exec": .bool(false), "features.apps": .bool(false),
            "features.browser_use": .bool(false), "features.computer_use": .bool(false), "web_search": .string("disabled"),
        ])
    }

    nonisolated static func dump(_ value: LedgerJSON) -> String {
        // json.dumps(ensure_ascii=False, default=str): compact, unicode kept.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func structuredThread(planID: String, instructions asset: String, model: DeliveryManifest.Model) async throws -> TurnPlan.ThreadSpec {
        TurnPlan.ThreadSpec(
            codexThreadID: nil, mode: .start, cwd: TurnPlan.guestWorkspace(id: planID), model: model.model, effort: model.effort,
            ephemeral: true, baseInstructions: try await assets.ref(asset), developerInstructions: nil,
            developerText: "Answer only with one JSON object matching the supplied output schema.",
            injectDeveloperOnResume: false, config: Self.structuredConfig(effort: model.effort), lastTurnID: nil,
            provider: model.provider
        )
    }

    // MARK: - 判定 (workbook_turns._grade_capture)

    func grading(planID: String, machine: WorkbookMachine, captureID: String) async throws -> (plan: TurnPlan, context: WorkbookMachine.GradingContext) {
        guard let capture = machine.captures[captureID] else { throw LedgerError.notFound("capture") }
        let context = machine.gradingContext(capture: capture)
        let pages = WorkbookMachine.pagePaths(capture)
        var request: [String: LedgerJSON] = [
            "task": .string("grade_answer_sheet"), "capture_id": .string(captureID), "scope": context.scope, "subunits": .array(context.subunits),
        ]
        if pages.count > 1 {
            // 一括採点: 添えた画像は 1 つの答案の連続したページ(順に)。全ページの問題を 1 つの答案として判定する。
            request["page_count"] = .number(Double(pages.count))
            request["pages_note"] = .string("The attached \(pages.count) images are consecutive pages of one answer sheet, in order. Grade every problem on every page as one answer sheet; a problem may continue onto the next page.")
        }
        let images = pages.enumerated().map { index, relative in
            let ext = (relative as NSString).pathExtension.lowercased()
            return TurnPlan.ImageRef(
                path: "tutor_desk/inbox/captures/\(captureID)/paper\(index == 0 ? "" : "-\(index + 1)").\(ext.isEmpty ? "jpg" : ext)",
                hostPath: StruisPaths.captures.appendingPathComponent(relative).path
            )
        }
        let plan = TurnPlan(
            id: planID, kind: .workbookGrading, round: 1,
            thread: try await structuredThread(planID: planID, instructions: "prompt:grading_instructions", model: await assets.model("astra")),
            turn: TurnPlan.TurnSpec(text: Self.dump(.object(request)), images: images, outputSchema: try await assets.json("schema:workbook_grading"), sandboxPolicy: "dangerFullAccess"),
            workspace: TurnPlan.WorkspaceSpec(files: [], dirs: []), delegation: nil, collect: [], limits: .structured, items: nil
        )
        return (plan, context)
    }

    // MARK: - 一枚 (workbook_turns.generate_set_job)

    /// `avoidExpressions`: その小単元の会話に出た式(D14、`ConversationExpressions.forSubunit`)。問題に使わない。
    func set(planID: String, machine: WorkbookMachine, setID: String, avoidExpressions: [String] = []) async throws -> TurnPlan {
        guard let set = machine.sets[setID] else { throw LedgerError.notFound("set") }
        guard let subunit = machine.subunits[set.subunitId] else { throw LedgerError.notFound("subunit") }
        let total = max(1, set.gate["count"]?.intValue ?? 1)
        // §3.2: n 問の一枚は、まず 1 問だけ組んで出し、残りは次のターンで組む(学習者は 1 問目から解き始められる)。
        let count = Self.setTurnCount(total: total, filled: set.problemIds.count)
        let existing = machine.subunitProblemPrompts(subunitID: subunit.id).suffix(40).map { $0["prompt"] ?? .string("") }
        let inThisSet = set.problemIds.compactMap { machine.problems[$0]?.prompt }.map(LedgerJSON.string)
        let request: LedgerJSON = .object([
            "task": .string("compose_set"), "kind": .string(set.kind), "stage": .number(Double(set.stage)),
            "set_total": .number(Double(total)), "already_in_this_set": .array(inThisSet),
            "stage_label": .string(WorkbookMachine.stageLabels[set.stage] ?? ""), "count": .number(Double(count)),
            "unit_title": .string(machine.units[subunit.unitId]?.title ?? ""),
            "subunit": .object([
                "title": .string(subunit.title), "outcome": .string(subunit.outcome), "scoring_unit": .string(subunit.scoringUnit),
                "n": .number(Double(subunit.n)),
            ]),
            "existing_prompts": .array(Array(existing)),
            "recent_error_tags": .array(machine.recentErrorTags(subunitID: subunit.id).map(LedgerJSON.string)),
            "retry": .bool(set.gate["retry_of"]?.stringValue != nil),
            "target_error_tags": set.gate["target_error_tags"] ?? .emptyArray,
            // D14: 学習者がこの小単元の会話で見た式は、答えを見たことになるので問題に使わない。
            "avoid_expressions_from_conversation": .array(avoidExpressions.map(LedgerJSON.string)),
            // 前の組み立てで会話の式と重なったもの(組み直しの時だけ)。
            "rejected_expressions_reused_from_conversation": set.gate["rejected_expressions"] ?? .emptyArray,
        ])
        var schema = try await assets.json("schema:workbook_set")
        if var root = schema.objectValue, var properties = root["properties"]?.objectValue, var problems = properties["problems"]?.objectValue {
            problems["maxItems"] = .number(Double(count))
            problems["minItems"] = .number(Double(count))
            properties["problems"] = .object(problems)
            root["properties"] = .object(properties)
            schema = .object(root)
        }
        return TurnPlan(
            id: planID, kind: .workbookSet, round: 1,
            thread: try await structuredThread(planID: planID, instructions: "prompt:set_instructions", model: await assets.model("astra")),
            turn: TurnPlan.TurnSpec(text: Self.dump(request), images: [], outputSchema: schema, sandboxPolicy: "dangerFullAccess"),
            workspace: TurnPlan.WorkspaceSpec(files: [], dirs: []), delegation: nil, collect: [], limits: .structured, items: nil
        )
    }

    /// この一枚で次のターンが組む問題の数。まだ 1 問も無い n 問の一枚は 1 問、あとは残り全部。
    static func setTurnCount(total: Int, filled: Int) -> Int {
        let remaining = max(1, total - filled)
        return filled == 0 && total > 1 ? 1 : remaining
    }

    // MARK: - 単元 (workbook_turns.generate_proposal_job)

    func unit(planID: String, machine: WorkbookMachine, proposalID: String) async throws -> TurnPlan {
        guard let proposal = machine.proposals[proposalID] else { throw LedgerError.notFound("proposal") }
        return try await unit(planID: planID, machine: machine, request: proposal.request)
    }

    /// 提案の依頼文から組む(提案の行を書く前に先回りで組む時も同じ入力にする。A12)。
    func unit(planID: String, machine: WorkbookMachine, request proposalRequest: String) async throws -> TurnPlan {
        let request: LedgerJSON = .object([
            "task": .string("plan_unit"), "request": .string(proposalRequest),
            "existing_unit_titles": .array(machine.orderedUnits().map { .string($0.title) }),
        ])
        return TurnPlan(
            id: planID, kind: .workbookUnit, round: 1,
            thread: try await structuredThread(planID: planID, instructions: "prompt:unit_instructions", model: await assets.model("astra")),
            turn: TurnPlan.TurnSpec(text: Self.dump(request), images: [], outputSchema: try await assets.json("schema:workbook_unit"), sandboxPolicy: "dangerFullAccess"),
            workspace: TurnPlan.WorkspaceSpec(files: [], dirs: []), delegation: nil, collect: [], limits: .structured, items: nil
        )
    }
}

/// Applies `TurnOutcome`s to the ledger (design §3.3 / §6.2 `TurnApplier`).
nonisolated enum TurnApplier {
    /// 学習者に見せる失敗の一言(修正指示書 §1.3)。内部のエラー文は画面に出さず、ログとターンの記録にだけ残す。
    static let gradingFailure = "判定できませんでした。「判定し直す」を押してください。"
    static let setFailure = "一枚を作れませんでした。「作り直す」を押してください。"
    static let unitFailure = "全体像を作れませんでした。もう一度頼んでください。"

    static func logFailure(_ what: String, _ detail: String?) {
        applierLog.error("\(what, privacy: .public) failed: \(detail ?? "-", privacy: .public)")
    }

    /// What the coordinator should start next after a structured turn was applied.
    nonisolated struct FollowUp: Sendable {
        var setIDToGenerate: String?
        /// 学習者が待っていない、次に要る一枚(§3.1)。学習者が待っている処理より後に回す。
        var prefetchSetID: String?
    }

    /// `apply_grading_result`. 次の一枚は学習者がリザルト画面で選ぶ。ただし類題 ○ で演習に進んだ時は、次に要る
    /// 演習の一枚が決まっているので、先回りで組み始める(§3.1。「演習へ」を押した時にできていれば待ちは無い)。
    static func grading(machine: inout WorkbookMachine, captureID: String, outcome: TurnOutcome, context: WorkbookMachine.GradingContext) -> FollowUp {
        guard outcome.status == .completed else {
            logFailure("grading", outcome.error)
            machine.failCapture(id: captureID, error: gradingFailure)
            return FollowUp()
        }
        do {
            let graded = try WorkbookMachine.GradingResult.parse(outcome.finalText)
            let stagesBefore = machine.subunits.mapValues(\.stage)
            _ = try machine.applyGradingResult(captureID: captureID, graded: graded, context: context)
            let promoted = machine.subunits.values.first { stagesBefore[$0.id] == 3 && $0.stage == 4 && $0.status == "active" }
            if let promoted, let setID = machine.insertPrefetchedSet(subunitID: promoted.id, stage: 4) {
                return FollowUp(prefetchSetID: setID)
            }
            return FollowUp()
        } catch {
            logFailure("grading apply", String(describing: error))
            machine.failCapture(id: captureID, error: gradingFailure)
            return FollowUp()
        }
    }

    nonisolated struct SetDraft: Codable {
        nonisolated struct Problem: Codable {
            var prompt: String
            var answerKey: String?
            var checkpoints: [String]?
            enum CodingKeys: String, CodingKey {
                case prompt, checkpoints
                case answerKey = "answer_key"
            }
        }
        var problems: [Problem]
    }

    /// 一枚のターンの結果を足す。まだ問題数に届かなければ、残りを組むターンを続ける(§3.2)。
    /// `avoidExpressions`(D14): 組んだ問題が会話に出た式と同じなら、足さずに 1 回だけ組み直させる。
    static func set(machine: inout WorkbookMachine, setID: String, outcome: TurnOutcome, avoidExpressions: [String] = []) -> FollowUp {
        guard outcome.status == .completed else {
            logFailure("set", outcome.error)
            machine.failSet(setID: setID, error: setFailure)
            return FollowUp()
        }
        do {
            // 組んでいる間に「例題に戻る」などで閉じられた一枚には、問題を足さない(どこにも出ない問題を残さない)。
            guard let set = machine.sets[setID], set.status == "generating" else { return FollowUp() }
            let count = TurnComposer.setTurnCount(total: max(1, set.gate["count"]?.intValue ?? 1), filled: set.problemIds.count)
            let draft = try JSONDecoder().decode(SetDraft.self, from: Data(outcome.finalText.utf8))
            let problems = Array(draft.problems.prefix(count))
            guard problems.count >= count else { throw LedgerError.invalid("expected \(count) problems, got \(problems.count)") }
            let reused = ConversationExpressions.overlaps(prompts: problems.map(\.prompt), avoid: avoidExpressions)
            if !reused.isEmpty, machine.noteRejectedExpressions(setID: setID, expressions: reused) {
                applierLog.info("set \(setID, privacy: .public) reused conversation expressions; composing again")
                return FollowUp(setIDToGenerate: setID)
            }
            let ids = machine.addProblems(
                subunitID: set.subunitId,
                problems: problems.map { WorkbookMachine.ProblemSpec(prompt: $0.prompt, answerKey: $0.answerKey ?? "", checkpoints: $0.checkpoints ?? []) },
                source: "generated"
            )
            let continues = machine.appendSetProblems(setID: setID, problemIDs: ids)
            return continues ? FollowUp(setIDToGenerate: setID) : FollowUp()
        } catch {
            logFailure("set apply", String(describing: error))
            machine.failSet(setID: setID, error: setFailure)
            return FollowUp()
        }
    }

    static func unit(machine: inout WorkbookMachine, proposalID: String, outcome: TurnOutcome) {
        guard outcome.status == .completed else {
            logFailure("unit", outcome.error)
            machine.failProposal(id: proposalID, error: unitFailure)
            return
        }
        guard let overview = LedgerJSON.parse(outcome.finalText), let object = overview.objectValue,
              let title = object["unit_title"]?.stringValue, !title.isEmpty,
              let subunits = object["subunits"]?.arrayValue, !subunits.isEmpty
        else {
            logFailure("unit apply", "unreadable overview")
            machine.failProposal(id: proposalID, error: unitFailure)
            return
        }
        machine.completeProposal(id: proposalID, overview: overview)
    }
}
