import Foundation
import GRDB
import OSLog

private let timelineTurnLog = Logger(subsystem: "com.digiloglab.strius", category: "timeline-turns")

/// 学習タイムラインの AI のターン(Issue #46「5枚をまとめて作る呼び出し」「採点」「知識グラフ」)。今の構造化ターン
/// (`TurnPlan` → 端末の Codex → OpenAI / `ClaudeResponsesProxy`)に種類を足して回す。
///
/// キャッシュに乗せるため、出題と採点は先頭(system)を 1 文字も違わない形に揃える: 基本指示(`prompt:base`)の後ろに、
/// Skill の名前と1行の説明(`prompt:timeline_shared`)と、今の単元・小単元・その単元の「できること」の名前を足す。
/// 前提の依存関係は入れない(詰まった時だけ `struis.timeline_query` で台帳をたどる)。出題用・採点用の指示はその後ろ
/// (developer)に置く。
nonisolated enum TimelineTurns {
    static let batchFailure = "次の問題を作れませんでした。"
    static let gradingFailure = "採点できませんでした。もう一度撮ってください。"

    // MARK: - 先頭(採点と出題で共通)

    /// 今の単元(直近のカードの単元、なければ単元ホームの最初の単元)。
    static func currentUnit(workbook: WorkbookMachine, timeline: TimelineMachine) -> WorkbookUnitRecord? {
        let recentUnit = timeline.orderedAttempts.reversed().lazy.compactMap { timeline.cards[$0.cardId] }.compactMap { card -> String? in
            card.unitId ?? card.subunitId.flatMap { workbook.subunits[$0]?.unitId }
        }.first
        return recentUnit.flatMap { workbook.units[$0] } ?? workbook.orderedUnits().first
    }

    /// 先頭の 3 番目: 今の単元と小単元、その単元の「できること」の名前(依存関係は含めない)。
    static func sharedContext(workbook: WorkbookMachine, timeline: TimelineMachine) -> String {
        var lines: [String] = []
        if let unit = currentUnit(workbook: workbook, timeline: timeline) {
            lines.append("## 今の単元")
            lines.append("- \(unit.title)(\(unit.id))")
            for subunit in workbook.orderedSubunits(unitID: unit.id) {
                lines.append("  - 小単元: \(subunit.title)(\(subunit.id))")
            }
            let names = timeline.activeSkills.filter { skill in skill.unitId == nil || TimelineGraphSchedule.unitID(of: skill, workbook: workbook) == unit.id }.map { "\($0.name)(\($0.id))" }
            if !names.isEmpty {
                lines.append("## この単元の「できること」")
                lines.append(names.joined(separator: "、"))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func thread(composer: TurnComposer, planID: String, instructions: String, role: String, workbook: WorkbookMachine, timeline: TimelineMachine) async throws -> TurnPlan.ThreadSpec {
        let model = await composer.assets.model(role)
        let shared = try await composer.assets.text("prompt:timeline_shared")
        let base = try await composer.assets.ref("prompt:base", append: shared + "\n\n" + sharedContext(workbook: workbook, timeline: timeline))
        return TurnPlan.ThreadSpec(
            codexThreadID: nil, mode: .start, cwd: TurnPlan.guestWorkspace(id: planID), model: model.model, effort: model.effort,
            ephemeral: true, baseInstructions: base, developerInstructions: try await composer.assets.ref(instructions),
            developerText: nil, injectDeveloperOnResume: false, config: TurnComposer.structuredConfig(effort: model.effort), lastTurnID: nil,
            provider: model.provider
        )
    }

    /// Skill の本文は作業フォルダの `.agents/skills` に置く(普段の文脈に入るのは名前と1行の説明だけ)。
    static let workspace = TurnPlan.WorkspaceSpec(files: [TurnPlan.FileSpec(path: ".agents/skills/timeline-query/SKILL.md", asset: "skill:timeline_query")], dirs: [])

    // MARK: - 5枚

    /// 5枚を頼む時に渡すもの(本文の「渡すもの」4〜8番)。
    static func batchRequest(workbook: WorkbookMachine, timeline: TimelineMachine, batch: TimelineBatchRecord) -> LedgerJSON {
        let attempts = timeline.orderedAttempts
        let recent = attempts.suffix(10).compactMap { attempt -> LedgerJSON? in
            guard let card = timeline.cards[attempt.cardId] else { return nil }
            return .object([
                "prompt": .string([card.prompt, card.math].filter { !$0.isEmpty }.joined(separator: " ")), "level": .number(Double(card.level)),
                "kind": .string(card.kind), "result": .string(attempt.verdict), "seconds": .number(attempt.seconds.rounded()),
                "skip_reason": attempt.skipReason.map(LedgerJSON.string) ?? .null, "type_name": .string(card.typeName),
                "counted": .bool(attempt.countsForAccuracy),
            ])
        }
        let usedSkills = Set(attempts.suffix(10).compactMap { timeline.cards[$0.cardId] }.flatMap(\.skills))
        let unit = currentUnit(workbook: workbook, timeline: timeline)
        let skillRows = timeline.activeSkills.filter { usedSkills.contains($0.id) || (unit != nil && TimelineGraphSchedule.unitID(of: $0, workbook: workbook) == unit?.id) }.prefix(30).map { skill -> LedgerJSON in
            .object([
                "id": .string(skill.id), "name": .string(skill.name), "kind": .string(skill.kind),
                "status": .string(TimelineGraph.statusLabels[skill.status] ?? skill.status), "attempts": .number(Double(skill.attempts)),
                "correct_days": .number(Double(skill.correctDays)), "solved_today": .number(Double(timeline.solvedToday(skill: skill.id))),
            ])
        }
        let lastCard = attempts.last.flatMap { timeline.cards[$0.cardId] }
        var flow: [String: LedgerJSON] = [:]
        if let lastCard, let chain = TimelineRules.chainPosition(lastCard) {
            flow["chain"] = .object(["position": .number(Double(chain.position)), "total": .number(Double(chain.total)),
                                     "last_prompt": .string([lastCard.prompt, lastCard.math].joined(separator: " ")),
                                     "last_result": .string(attempts.last?.verdict ?? "")])
        }
        if let resume = TimelineRules.resumeCard(cards: Array(timeline.cards.values), attempts: attempts, today: timeline.today) {
            flow["resume_from_yesterday"] = .string(resume.prompt)
        }
        if let notes = batch.request["notes"]?.arrayValue, !notes.isEmpty { flow["notes"] = .array(notes) }
        let results = timeline.skillResults
        let suppressed = TimelineRules.suppressedToday(results: results, today: timeline.today)
        let skips = attempts.suffix(20).compactMap(\.skipReason)
        let splits = timeline.changes.values.filter { $0.kind == "split_requested" && !$0.reviewed }.map(\.detail)
        let placement = timeline.changes.values.filter { $0.kind == "build" }.max { $0.createdAt < $1.createdAt }?.detail["start_node_id"]
        var request: [String: LedgerJSON] = [
            "task": .string("compose_timeline_cards"),
            "count": .number(Double(TimelineRules.batchSize)),
            "accuracy": batch.accuracy.map { .number(($0 * 100).rounded() / 100) } ?? .null,
            "target_accuracy": .number(TimelineRules.targetAccuracy),
            "direction": .string(TimelineRules.levelDirection(accuracy: batch.accuracy)),
            "level_cap": batch.levelCap.map { .number(Double($0)) } ?? .null,
            "current_level": .number(Double(timeline.currentLevel)),
            "skills": .array(Array(skillRows)),
            "allowed_skill_ids": .array(timeline.activeSkills.map { .string($0.id) }),
            "recent": .array(recent),
            "flow": .object(flow),
            "stuck": stuckLine(timeline: timeline).map(LedgerJSON.string) ?? .null,
            "review_due": .array(TimelineRules.reviewDue(timeline.activeSkills, today: timeline.today).map { .object(["id": .string($0.id), "name": .string($0.name)]) }),
            "skip_feedback": .object(["too_hard": .number(Double(skips.filter { $0 == "too_hard" }.count)), "too_easy": .number(Double(skips.filter { $0 == "too_easy" }.count))]),
            "suppressed_today": .array(suppressed.sorted().map(LedgerJSON.string)),
            "split_requests": .array(splits),
            "subunits": .array(workbook.orderedSubunits(status: "active").map { .object(["id": .string($0.id), "title": .string($0.title), "unit": .string(workbook.units[$0.unitId]?.title ?? "")]) }),
        ]
        if attempts.isEmpty, let placement, placement != .null { request["placement_start"] = placement }
        if !batch.rejected.isEmpty { request["rejected_last_time"] = .array(batch.rejected.map(LedgerJSON.string)) }
        return .object(request)
    }

    /// 詰まりの兆し(1行)。同じ点で × が2回続いた時の、その点と誤答の種類。
    static func stuckLine(timeline: TimelineMachine) -> String? {
        let graded = timeline.orderedAttempts.filter { $0.verdict == "correct" || $0.verdict == "wrong" }.suffix(2)
        guard graded.count == 2, graded.allSatisfy({ $0.verdict == "wrong" }) else { return nil }
        let cards = graded.compactMap { timeline.cards[$0.cardId] }
        let shared = Set(cards.first?.skills ?? []).intersection(cards.last?.skills ?? [])
        guard let skillID = shared.sorted().first else { return "× が2回続いた" }
        let name = timeline.skills[skillID]?.name ?? skillID
        let kinds = graded.last?.errors.arrayValue?.compactMap { $0["kind"]?.stringValue } ?? []
        return "\(name)(\(skillID))で × が2回続いた。" + (kinds.isEmpty ? "" : "誤答の種類は " + kinds.joined(separator: "・"))
    }

    static func batch(composer: TurnComposer, planID: String, batchID: String, workbook: WorkbookMachine, timeline: TimelineMachine) async throws -> TurnPlan {
        guard let batch = timeline.batches[batchID] else { throw LedgerError.notFound("timeline batch") }
        let request = batchRequest(workbook: workbook, timeline: timeline, batch: batch)
        return TurnPlan(
            id: planID, kind: .timelineBatch, round: 1,
            thread: try await thread(composer: composer, planID: planID, instructions: "prompt:timeline_instructions", role: TimelineModels.role, workbook: workbook, timeline: timeline),
            turn: TurnPlan.TurnSpec(text: TurnComposer.dump(request), images: [], outputSchema: try await composer.assets.json("schema:timeline_batch"), sandboxPolicy: "dangerFullAccess"),
            workspace: workspace, delegation: nil, collect: [], limits: .structured, items: nil
        )
    }

    // MARK: - 採点

    static func grading(composer: TurnComposer, planID: String, attemptID: String, workbook: WorkbookMachine, timeline: TimelineMachine) async throws -> TurnPlan {
        guard let attempt = timeline.attempts[attemptID], let card = timeline.cards[attempt.cardId], let path = attempt.capturePath else {
            throw LedgerError.notFound("timeline attempt")
        }
        var request: [String: LedgerJSON] = [
            "task": .string("grade_timeline_card"), "kind": .string(card.kind),
            "prompt": .string(card.payload["problem"]?.stringValue ?? card.prompt), "math": .string(card.math), "question": .string(card.question),
            "answer_key": .string(card.answerKey), "checkpoints": .array(card.checkpoints.map(LedgerJSON.string)),
            "common_mistakes": .array(card.commonMistakes.map(LedgerJSON.string)),
        ]
        switch TimelineCards.Kind(rawValue: card.kind) {
        case .fillLine:
            request["lines"] = card.payload["lines"] ?? .emptyArray
            request["hidden_line_index"] = card.payload["hidden"] ?? .null
            request["note"] = .string("The learner wrote only the hidden line. Put that line in learner_expr.")
        case .inverse:
            request["target_vertex"] = card.payload["vertex"] ?? .null
            request["note"] = .string("Many answers are correct. Put the learner's function in learner_expr.")
        default: break
        }
        let ext = (path as NSString).pathExtension.isEmpty ? "jpg" : (path as NSString).pathExtension
        let image = TurnPlan.ImageRef(path: "tutor_desk/inbox/timeline/\(attemptID).\(ext)", hostPath: StruisPaths.captures.appendingPathComponent(path).path)
        return TurnPlan(
            id: planID, kind: .timelineGrading, round: 1,
            thread: try await thread(composer: composer, planID: planID, instructions: "prompt:timeline_grading_instructions", role: TimelineModels.role, workbook: workbook, timeline: timeline),
            turn: TurnPlan.TurnSpec(text: TurnComposer.dump(.object(request)), images: [image], outputSchema: try await composer.assets.json("schema:timeline_grading"), sandboxPolicy: "dangerFullAccess"),
            workspace: workspace, delegation: nil, collect: [], limits: .structured, items: nil
        )
    }

    // MARK: - 知識グラフ

    static let gradeOrder = ["小1", "小2", "小3", "小4", "小5", "小6", "中1", "中2", "中3", "高1", "高2", "高3"]

    static func graphRequest(purpose: String, unitID: String?, changeIDs: [String] = [], workbook: WorkbookMachine, timeline: TimelineMachine, profile: OnboardingProfile?) -> LedgerJSON {
        var request: [String: LedgerJSON] = [:]
        func unitJSON(_ unit: WorkbookUnitRecord) -> LedgerJSON {
            .object([
                "id": .string(unit.id), "title": .string(unit.title), "outcome": .string(unit.outcome),
                "subunits": .array(workbook.orderedSubunits(unitID: unit.id).map { subunit in
                    let attempts = workbook.attemptsOf(subunitID: subunit.id)
                    return .object([
                        "id": .string(subunit.id), "title": .string(subunit.title), "outcome": .string(subunit.outcome), "status": .string(subunit.status),
                        "correct": .number(Double(attempts.filter { $0.verdict == "correct" }.count)),
                        "wrong": .number(Double(attempts.filter { $0.verdict == "wrong" }.count)),
                        "error_tags": .array(Array(Set(attempts.map(\.errorTag).filter { !$0.isEmpty })).sorted().prefix(8).map(LedgerJSON.string)),
                    ])
                }),
            ])
        }
        switch purpose {
        case "graph_extend":
            request["task"] = .string("extend_unit")
            if let unitID, let unit = workbook.units[unitID] { request["unit"] = unitJSON(unit) }
            request["existing_nodes"] = .array(timeline.activeSkills.map { .object(["id": .string($0.id), "name": .string($0.name), "kind": .string($0.kind)]) })
        case "graph_review":
            request["task"] = .string("review")
            // 同じ一覧の見直しを二度頼まないための印(`TimelineGraphSchedule`)。
            request["change_ids"] = .array(changeIDs.map(LedgerJSON.string))
            request["nodes"] = .array(timeline.activeSkills.map { .object(["id": .string($0.id), "name": .string($0.name), "kind": .string($0.kind),
                                                                         "status": .string($0.status), "correct_days": .number(Double($0.correctDays))]) })
            request["edges"] = .array(timeline.edges.values.sorted { $0.id < $1.id }.map { .object(["from": .string($0.requiresSkillId), "to": .string($0.skillId), "relation": .string($0.relation), "note": .string($0.note)]) })
            let pending = timeline.changes.values.filter { !$0.reviewed }.sorted { $0.createdAt < $1.createdAt }
            request["app_changes"] = .array(pending.map { change in
                .object(["kind": .string(change.kind), "detail": change.detail, "evidence": .array(change.attemptIds.compactMap { id in
                    guard let attempt = timeline.attempts[id], let card = timeline.cards[attempt.cardId] else { return nil }
                    return .object(["attempt_id": .string(id), "prompt": .string(card.prompt + " " + card.math), "verdict": .string(attempt.verdict), "errors": attempt.errors])
                })])
            })
        default:
            request["task"] = .string("build")
            request["units"] = .array(workbook.orderedUnits().map(unitJSON))
            if let profile {
                request["grade"] = profile.grade.map(LedgerJSON.string) ?? .null
                request["subject"] = profile.subject.map(LedgerJSON.string) ?? .null
                if let grade = profile.grade, let index = gradeOrder.firstIndex(where: { grade.contains($0) }) {
                    // その学年と1つ下の学年の単元と小単元(下りていける先を最初から用意する)。
                    let grades = Set(gradeOrder[max(0, index - 1)...index])
                    request["catalog"] = .array(UnitCatalog.units.filter { !grades.isDisjoint(with: $0.grades) }.map { unit in
                        .object(["subject": .string(unit.subject), "name": .string(unit.name), "subunits": .array(unit.subunits.map(LedgerJSON.string))])
                    })
                }
            }
        }
        return .object(request)
    }

    static func graph(composer: TurnComposer, planID: String, batchID: String, workbook: WorkbookMachine, timeline: TimelineMachine) async throws -> TurnPlan {
        guard let batch = timeline.batches[batchID] else { throw LedgerError.notFound("timeline graph request") }
        var request = batch.request.objectValue ?? [:]
        if !batch.rejected.isEmpty { request["rejected_last_time"] = .array(batch.rejected.map(LedgerJSON.string)) }
        return TurnPlan(
            id: planID, kind: .timelineGraph, round: 1,
            thread: try await thread(composer: composer, planID: planID, instructions: "prompt:timeline_graph_instructions", role: TimelineModels.graphRole, workbook: workbook, timeline: timeline),
            turn: TurnPlan.TurnSpec(text: TurnComposer.dump(.object(request)), images: [], outputSchema: try await composer.assets.json("schema:timeline_graph"), sandboxPolicy: "dangerFullAccess"),
            workspace: workspace, delegation: nil, collect: [], limits: .structured, items: nil
        )
    }

    // MARK: - 反映

    nonisolated struct FollowUp: Sendable, Equatable {
        /// 同じ対象でターンを組み直す(受け取りを断って作り直させる)。
        var retry = false
    }

    static func apply(kind: TurnPlan.Kind, targetID: String, outcome: TurnOutcome, model: String, db: Database) throws -> (events: [LedgerEvent], followUp: FollowUp) {
        var timeline = try TimelineMachine(loading: db)
        var followUp = FollowUp()
        var extra: [LedgerEvent] = []
        switch kind {
        case .timelineBatch:
            guard timeline.batches[targetID]?.status == "requested" else { return ([], followUp) }
            timeline.noteUsage(batchID: targetID, model: model, executions: outcome.executions)
            guard outcome.status == .completed else {
                timelineTurnLog.error("timeline batch failed: \(outcome.error ?? "-", privacy: .public)")
                timeline.failBatch(id: targetID, error: outcome.error ?? outcome.status.rawValue)
                break
            }
            do {
                let parsed = try TimelineCards.Batch.parse(outcome.finalText)
                if timeline.applyBatch(id: targetID, batch: parsed) == .retry { followUp.retry = true }
            } catch {
                timelineTurnLog.error("timeline batch unreadable: \(String(describing: error), privacy: .public)")
                timeline.failBatch(id: targetID, error: "unreadable batch")
            }
        case .timelineGrading:
            guard let attempt = timeline.attempts[targetID], attempt.verdict == "grading" else { return ([], followUp) }
            guard outcome.status == .completed, let grading = try? TimelineMachine.Grading.parse(outcome.finalText) else {
                timelineTurnLog.error("timeline grading failed: \(outcome.error ?? "unreadable", privacy: .public)")
                timeline.failGrading(attemptID: targetID)
                break
            }
            let result = timeline.applyGrading(attemptID: targetID, grading: grading)
            if result.countsForUnitHome, let card = timeline.cards[attempt.cardId], let subunitID = card.subunitId {
                var workbook = try WorkbookMachine(loading: db)
                workbook.recordTimelineAttempt(subunitID: subunitID, prompt: [card.prompt, card.math].filter { !$0.isEmpty }.joined(separator: " "),
                                               answerKey: card.answerKey, checkpoints: card.checkpoints, verdict: result.verdict, attemptID: targetID)
                extra = workbook.events
            }
        case .timelineGraph:
            guard var batch = timeline.batches[targetID], batch.status == "requested" else { return ([], followUp) }
            timeline.noteUsage(batchID: targetID, model: model, executions: outcome.executions)
            guard outcome.status == .completed, let output = try? JSONDecoder().decode(TimelineGraph.Output.self, from: Data(outcome.finalText.utf8)) else {
                timeline.failBatch(id: targetID, error: outcome.error ?? "unreadable graph")
                break
            }
            let problems: [TimelineGraph.Problem]
            if batch.purpose == "graph_review" {
                problems = timeline.applyGraphOps(output.ops, source: "review")
                if problems.isEmpty { timeline.markReviewed() }
            } else {
                problems = timeline.applyGraph(output, source: "initial", unitID: batch.request["unit"]?["id"]?.stringValue)
            }
            batch = timeline.batches[targetID] ?? batch
            if problems.isEmpty {
                batch.status = "ready"
                batch.reason = output.notes
                batch.updatedAt = timeline.now()
                timeline.put("timeline.graph_ready", batch)
            } else if batch.retries < 1 {
                batch.retries += 1
                batch.rejected = problems.map(\.description)
                batch.updatedAt = timeline.now()
                timeline.put("timeline.graph_rejected", batch)
                followUp.retry = true
            } else {
                timeline.failBatch(id: targetID, error: problems.map(\.description).joined(separator: "; "))
            }
        default:
            break
        }
        return (timeline.events + extra, followUp)
    }

    /// 組めなかった・走らせる前に止めた時の後始末。
    static func fail(kind: TurnPlan.Kind, targetID: String, error: String, db: Database) throws -> [LedgerEvent] {
        var timeline = try TimelineMachine(loading: db)
        switch kind {
        case .timelineBatch, .timelineGraph: timeline.failBatch(id: targetID, error: error)
        case .timelineGrading: timeline.failGrading(attemptID: targetID)
        default: break
        }
        return timeline.events
    }

    static func isTimeline(_ kind: TurnPlan.Kind) -> Bool {
        kind == .timelineBatch || kind == .timelineGrading || kind == .timelineGraph
    }
}
