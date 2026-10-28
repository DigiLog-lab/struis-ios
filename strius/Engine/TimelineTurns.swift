import Foundation
import GRDB
import OSLog

private let timelineTurnLog = Logger(subsystem: "com.digiloglab.strius", category: "timeline-turns")

/// 学習タイムラインの AI のターン(Issue #46「5枚をまとめて作る呼び出し」「採点」「知識グラフ」)。今の構造化ターン
/// (`TurnPlan` → 端末の Codex → OpenAI / `ClaudeResponsesProxy`)に種類を足して回す。
///
/// 採点・出題・見直しは、キャッシュに乗せるため同じ順に並べる(2026-10-27):
/// 1. 基本指示(`prompt:base`・理想の動き・起こり得ること・道具の説明)= Claude の system の 1 つ目。3 つで 1 バイトも違わない
/// 2. 今日の記録(その日最初の単元とスキルの一覧、採点・見直し・申し出・足されたスキル)= system の 2 つ目以降、1 件 1 ブロック。
///    出来事ごとに書いた時点の文を台帳に保存し、後ろに足すだけ(`TimelineLogRecord`)
/// 3. 出力の形(JSON Schema の文)= 記録の後ろ
/// 4. 今回の仕事(1〜2 行)と、今回の材料 = 会話の最初の発話
/// 1 と 2 の最後に 1 時間のキャッシュの印を置く(`ClaudeRequestTranslator` の版 4)。作業フォルダの場所(処理ごとに違う)は
/// 先頭に入れない: 前の版は Skill を作業フォルダに置いていて、その場所が Codex の Skill の一覧として system に入り、毎回外れていた。
nonisolated enum TimelineTurns {
    static let batchFailure = "次の問題を作れませんでした。"
    static let gradingFailure = "採点できませんでした。もう一度撮ってください。"

    /// 採点・出題・見直しの考える深さ(3 つで揃える。深さが違うとキャッシュが分かれることがある。2026-10-27)。
    static let tutorEffort = "medium"

    // MARK: - 先頭(採点・出題・見直しで共通)

    /// 今の単元(直近のカードの単元、なければ単元ホームの最初の単元)。
    static func currentUnit(workbook: WorkbookMachine, timeline: TimelineMachine) -> WorkbookUnitRecord? {
        let recentUnit = timeline.orderedAttempts.reversed().lazy.compactMap { timeline.cards[$0.cardId] }.compactMap { card -> String? in
            card.unitId ?? card.subunitId.flatMap { workbook.subunits[$0]?.unitId }
        }.first
        return recentUnit.flatMap { workbook.units[$0] } ?? workbook.orderedUnits().first
    }

    /// 今の単元と小単元、その単元の「できること」(スキル)の名前と ID(依存関係は含めない)。今日の記録の最初の 1 件に入れる。
    static func sharedContext(workbook: WorkbookMachine, timeline: TimelineMachine) -> String {
        guard let unit = currentUnit(workbook: workbook, timeline: timeline) else { return "" }
        let skills = unitSkills(unit.id, workbook: workbook, timeline: timeline)
        return TimelineLogText.context(unit: unit, subunits: workbook.orderedSubunits(unitID: unit.id), skills: skills, changed: false)
    }

    static func unitSkills(_ unitID: String, workbook: WorkbookMachine, timeline: TimelineMachine) -> [TimelineSkillRecord] {
        timeline.activeSkills.filter { skill in skill.unitId == nil || TimelineGraphSchedule.unitID(of: skill, workbook: workbook) == unitID }
    }

    /// 依頼を組む前に、今日の記録に足りない分を足す(台帳に書く同じ書き込みの中で)。
    /// - その日最初の依頼: 今の単元とスキルの一覧(その日の先頭に入れる)
    /// - 単元が変わった: 新しい単元とスキルの一覧
    /// - 今の単元にスキルが足された: 足された分だけ
    /// - まだ記録に無い、結果の出た今日の答案(この版より前に解いた答案)
    static func syncLog(workbook: WorkbookMachine, timeline: inout TimelineMachine) {
        timeline.logMissedAttempts()
        guard let unit = currentUnit(workbook: workbook, timeline: timeline) else { return }
        let entries = timeline.todayLog
        let skills = unitSkills(unit.id, workbook: workbook, timeline: timeline)
        let lastUnit = entries.last { $0.kind == "context" || $0.kind == "unit" }?.unitId
        if !entries.contains(where: { $0.kind == "context" }) {
            timeline.appendLog(kind: "context", unitID: unit.id, skillIDs: skills.map(\.id),
                               text: TimelineLogText.context(unit: unit, subunits: workbook.orderedSubunits(unitID: unit.id), skills: skills, changed: false), first: true)
        } else if lastUnit != unit.id {
            timeline.appendLog(kind: "unit", unitID: unit.id, skillIDs: skills.map(\.id),
                               text: TimelineLogText.context(unit: unit, subunits: workbook.orderedSubunits(unitID: unit.id), skills: skills, changed: true))
        } else {
            let listed = Set(entries.flatMap(\.skillIds))
            let added = skills.filter { !listed.contains($0.id) }
            if !added.isEmpty {
                timeline.appendLog(kind: "skills", unitID: unit.id, skillIDs: added.map(\.id), text: TimelineLogText.skillsAdded(added))
            }
        }
    }

    /// 今日の記録(採点・出題・見直しのどの依頼にも付ける)。保存済みの文を保存した順に並べるだけで、答案の今の状態から
    /// 作り直さない(前に送った分が 1 バイトも変わらず先頭に残る)。1 件ごとに `ClaudeTranslation.blockSeparator` で区切り、
    /// 終わりに `ClaudeTranslation.logEnd` を置く。Claude への変換(版 4)で 1 件 1 ブロックにする。
    static func answerLog(timeline: TimelineMachine) -> String {
        let entries = timeline.todayLog
        let parts = ["# 今日の記録"] + (entries.isEmpty ? ["まだありません。"] : entries.map(\.text))
        return parts.joined(separator: ClaudeTranslation.blockSeparator) + ClaudeTranslation.logEnd
    }

    /// 採点・出題・見直しのスレッド。基本指示(system の 1 つ目: `prompt:base`・`timeline_shared`・道具の説明)は 3 つで
    /// 1 バイトも違わない。今日の記録は Codex の developer 指示に入れる(system の 2 つ目以降、1 件 1 ブロック)。
    static func tutorThread(composer: TurnComposer, planID: String, workbook: WorkbookMachine, timeline: TimelineMachine) async throws -> TurnPlan.ThreadSpec {
        let model = await composer.assets.model(TimelineModels.role)
        let effort = tutorEffort
        let shared = try await composer.assets.text("prompt:timeline_shared")
        // 道具の説明は今日の記録の前に置く(`CodexTurnRunner.configureThread` は採点・出題・見直しでは developer 指示に足さない)。
        let base = try await composer.assets.ref("prompt:base", append: shared + "\n\n" + NativeToolRouter.instructions)
        return TurnPlan.ThreadSpec(
            codexThreadID: nil, mode: .start, cwd: TurnPlan.guestWorkspace(id: planID), model: model.model, effort: effort,
            ephemeral: true, baseInstructions: base, developerInstructions: nil,
            developerText: answerLog(timeline: timeline), injectDeveloperOnResume: false, config: TurnComposer.structuredConfig(effort: effort), lastTurnID: nil,
            provider: model.provider
        )
    }

    /// 知識グラフの依頼のスレッド(上位モデル。採点・出題とは先頭を共有しない)。
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

    /// 作業フォルダには何も置かない(Skill の本文は先頭の「道具」に書き、tool は直接呼ぶ)。
    static let workspace = TurnPlan.WorkspaceSpec(files: [], dirs: [])

    /// 会話の最初の発話: 今回の仕事と、今回の材料。`repair` は前の返事が決まった形に合わなかった理由(1 回だけ頼み直す時)。
    static func turnText(task: String, materials: LedgerJSON, repair: String? = nil) -> String {
        var text = task.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n# 今回の材料\n\n" + TurnComposer.dump(materials)
        if let repair, !repair.isEmpty {
            text += "\n\n# 前の返事について\n\n同じ仕事の前の返事は、決まった形として読めませんでした(\(repair))。同じ仕事を、決まった形の JSON 1 つだけでもう一度答えてください。"
        }
        return text
    }

    /// 返事が決まった形として読めなかった理由(頼み直す時に添える)。
    static func parseProblem(_ error: Error, text: String) -> String {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "返事が空でした" }
        switch error {
        case DecodingError.dataCorrupted(let context):
            return "JSON として読めません: " + context.debugDescription
        case DecodingError.keyNotFound(let key, let context):
            return "項目 " + (context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".") + " がありません"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "項目 " + context.codingPath.map(\.stringValue).joined(separator: ".") + " の型が違います: " + context.debugDescription
        default:
            return String(String(describing: error).prefix(300))
        }
    }

    // MARK: - 5枚

    /// 5枚を頼む時に渡す材料。直近の結果は今日の記録にあるので、ここには入れない。
    static func batchRequest(workbook: WorkbookMachine, timeline: TimelineMachine, batch: TimelineBatchRecord) -> LedgerJSON {
        let attempts = timeline.orderedAttempts
        let usedSkills = Set(attempts.suffix(10).compactMap { timeline.cards[$0.cardId] }.flatMap(\.skills))
        let unit = currentUnit(workbook: workbook, timeline: timeline)
        let skillRows = timeline.activeSkills.filter { usedSkills.contains($0.id) || (unit != nil && TimelineGraphSchedule.unitID(of: $0, workbook: workbook) == unit?.id) }.prefix(30).map { skill -> LedgerJSON in
            .object([
                "id": .string(skill.id), "status": .string(TimelineGraph.statusLabels[skill.status] ?? skill.status),
                "attempts": .number(Double(skill.attempts)), "correct_days": .number(Double(skill.correctDays)),
            ])
        }
        var flow: [String: LedgerJSON] = [:]
        if let lastCard = attempts.last.flatMap({ timeline.cards[$0.cardId] }), let chain = TimelineRules.chainPosition(lastCard) {
            flow["chain"] = .object(["position": .number(Double(chain.position)), "total": .number(Double(chain.total)), "card_id": .string(lastCard.id)])
        }
        if let resume = TimelineRules.resumeCard(cards: Array(timeline.cards.values), attempts: attempts, today: timeline.today) {
            flow["resume_from_yesterday"] = .string(resume.prompt)
        }
        let suppressed = TimelineRules.suppressedToday(results: timeline.skillResults, today: timeline.today)
        let splits = timeline.changes.values.filter { $0.kind == "split_requested" && !$0.reviewed }.map(\.detail)
        let placement = timeline.changes.values.filter { $0.kind == "build" }.max { $0.createdAt < $1.createdAt }?.detail["start_node_id"]
        var request: [String: LedgerJSON] = [
            "count": .number(Double(TimelineRules.batchSize)),
            "accuracy_last_10": batch.accuracy.map { .number(($0 * 100).rounded() / 100) } ?? .null,
            "level_cap": batch.levelCap.map { .number(Double($0)) } ?? .null,
            "skills": .array(Array(skillRows)),
            "allowed_skill_ids": .array(timeline.activeSkills.map { .string($0.id) }),
            "flow": .object(flow),
            "review_due": .array(TimelineRules.reviewDue(timeline.activeSkills, today: timeline.today).map { .string($0.id) }),
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

    static func batch(composer: TurnComposer, planID: String, batchID: String, workbook: WorkbookMachine, timeline: TimelineMachine, repair: String? = nil) async throws -> TurnPlan {
        guard let batch = timeline.batches[batchID] else { throw LedgerError.notFound("timeline batch") }
        let request = batchRequest(workbook: workbook, timeline: timeline, batch: batch)
        return TurnPlan(
            id: planID, kind: .timelineBatch, round: repair == nil ? 1 : 2,
            thread: try await tutorThread(composer: composer, planID: planID, workbook: workbook, timeline: timeline),
            turn: TurnPlan.TurnSpec(text: turnText(task: try await composer.assets.text("prompt:timeline_instructions"), materials: request, repair: repair), images: [],
                                    outputSchema: try await composer.assets.json("schema:timeline_batch"), sandboxPolicy: "dangerFullAccess"),
            workspace: workspace, delegation: nil, collect: [], limits: .structured, items: nil
        )
    }

    // MARK: - 採点

    /// 採点の材料: 答案の画像のほかに、問題・正しい答え・出題時の解き方の手順(参考として)。
    static func gradingRequest(attempt: TimelineAttemptRecord, card: TimelineCardRecord) -> LedgerJSON {
        var request: [String: LedgerJSON] = [
            "attempt_id": .string(attempt.id), "card_id": .string(card.id), "kind": .string(card.kind),
            "problem": .string(card.payload["problem"]?.stringValue ?? card.prompt), "math": .string(card.math), "question": .string(card.question),
            "answer_key": .string(card.answerKey),
            "steps_for_reference": card.payload["steps"] ?? .emptyArray,
        ]
        switch TimelineCards.Kind(rawValue: card.kind) {
        case .fillLine:
            request["lines"] = card.payload["lines"] ?? .emptyArray
            request["hidden_line_index"] = card.payload["hidden"] ?? .null
            request["note"] = .string("生徒が書いたのは、隠した 1 行だけです。")
        case .inverse:
            request["target_vertex"] = card.payload["vertex"] ?? .null
            request["note"] = .string("正しい答えは 1 つではありません。")
        default: break
        }
        return .object(request)
    }

    static func grading(composer: TurnComposer, planID: String, attemptID: String, workbook: WorkbookMachine, timeline: TimelineMachine, repair: String? = nil) async throws -> TurnPlan {
        guard let attempt = timeline.attempts[attemptID], let card = timeline.cards[attempt.cardId], let path = attempt.capturePath else {
            throw LedgerError.notFound("timeline attempt")
        }
        let ext = (path as NSString).pathExtension.isEmpty ? "jpg" : (path as NSString).pathExtension
        let image = TurnPlan.ImageRef(path: "tutor_desk/inbox/timeline/\(attemptID).\(ext)", hostPath: StruisPaths.captures.appendingPathComponent(path).path,
                                      maxDimension: TimelineCaptureImage.requestMaxDimension)
        return TurnPlan(
            id: planID, kind: .timelineGrading, round: repair == nil ? 1 : 2,
            thread: try await tutorThread(composer: composer, planID: planID, workbook: workbook, timeline: timeline),
            turn: TurnPlan.TurnSpec(text: turnText(task: try await composer.assets.text("prompt:timeline_grading_instructions"), materials: gradingRequest(attempt: attempt, card: card), repair: repair),
                                    images: [image], outputSchema: try await composer.assets.json("schema:timeline_grading"), sandboxPolicy: "dangerFullAccess"),
            workspace: workspace, delegation: nil, collect: [], limits: .structured, items: nil
        )
    }

    // MARK: - 見直し

    /// 見直しの材料: 直近の答案、スキルを決めずに置いた答案、生徒が納得していない答案。
    static func reviewRequest(targetID: String, timeline: TimelineMachine) -> LedgerJSON {
        let today = timeline.today
        let todays = timeline.orderedAttempts.filter { TimelineRules.day($0.createdAt, calendar: timeline.calendar) == today }
        let recent = todays.filter { $0.reviewedAt == nil && ($0.grade != nil || $0.id == targetID) }.suffix(5).map(\.id)
        let pending = timeline.orderedAttempts.filter { $0.skillsPending == true }.suffix(10).map { attempt -> LedgerJSON in
            .object(["attempt_id": .string(attempt.id), "skill_ids": .array((attempt.skillIds ?? []).map(LedgerJSON.string))])
        }
        let disputes = todays.filter { ($0.dispute ?? "").isEmpty == false && $0.reviewedAt == nil }.map { LedgerJSON.string($0.id) }
        return .object([
            "target_attempt_id": .string(targetID),
            "recent_attempt_ids": .array(recent.map(LedgerJSON.string)),
            "pending": .array(pending),
            "disputed_attempt_ids": .array(disputes),
        ])
    }

    static func review(composer: TurnComposer, planID: String, attemptID: String, workbook: WorkbookMachine, timeline: TimelineMachine, repair: String? = nil) async throws -> TurnPlan {
        guard timeline.attempts[attemptID] != nil else { throw LedgerError.notFound("timeline attempt") }
        var images: [TurnPlan.ImageRef] = []
        if let attempt = timeline.attempts[attemptID], let path = attempt.capturePath {
            let ext = (path as NSString).pathExtension.isEmpty ? "jpg" : (path as NSString).pathExtension
            images.append(TurnPlan.ImageRef(path: "tutor_desk/inbox/timeline/\(attemptID).\(ext)", hostPath: StruisPaths.captures.appendingPathComponent(path).path,
                                            maxDimension: TimelineCaptureImage.requestMaxDimension))
        }
        return TurnPlan(
            id: planID, kind: .timelineReview, round: repair == nil ? 1 : 2,
            thread: try await tutorThread(composer: composer, planID: planID, workbook: workbook, timeline: timeline),
            turn: TurnPlan.TurnSpec(text: turnText(task: try await composer.assets.text("prompt:timeline_review_instructions"), materials: reviewRequest(targetID: attemptID, timeline: timeline), repair: repair),
                                    images: images, outputSchema: try await composer.assets.json("schema:timeline_review"), sandboxPolicy: "dangerFullAccess"),
            workspace: workspace, delegation: nil, collect: [], limits: .structured, items: nil
        )
    }

    // MARK: - 知識グラフ

    /// 1回の分解で渡す点の数と、1つの構築で続ける段の数(費用の歯止め)。
    static let graphStepSize = 8
    static let graphStepLimit = 6
    static let misconceptionNodeLimit = 40

    /// 丸ごと見直す依頼(上位モデル)。
    static func reviewRequest(changeIDs: [String], timeline: TimelineMachine) -> LedgerJSON {
        var request: [String: LedgerJSON] = ["task": .string("review")]
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
        return .object(request)
    }

    /// 1段分の分解の依頼。渡すのはまだ前提を調べていない点だけで、モデルには 3 つだけを答えさせる(典型的な問題を
    /// 1問手順に分けて書く / 各手順で使う、より小さい「できること」を挙げる / 既にある点から選べるものはその ID を使う)。
    static func decomposeRequest(mode: String, nodes: [TimelineSkillRecord], units: [String], depth: Int, workbook: WorkbookMachine,
                                 timeline: TimelineMachine, profile: OnboardingProfile?) -> LedgerJSON {
        let nodeJSON: [LedgerJSON] = nodes.map { node in
            let unitID = TimelineGraphSchedule.unitID(of: node, workbook: workbook)
            var object: [String: LedgerJSON] = [
                "id": .string(node.id), "name": .string(node.name), "kind": .string(node.kind),
                "unit_id": unitID.map(LedgerJSON.string) ?? .null, "unit_title": .string(unitID.flatMap { workbook.units[$0]?.title } ?? ""),
            ]
            // 一番上の点(小単元の到達目標)は、小単元の到達目標の文も渡す。
            if let subunit = node.unitId.flatMap({ workbook.subunits[$0] }) { object["goal"] = .string(subunit.outcome.isEmpty ? subunit.title : subunit.outcome) }
            return .object(object)
        }
        let contextUnits = Set(units + nodes.compactMap { TimelineGraphSchedule.unitID(of: $0, workbook: workbook) })
        var request: [String: LedgerJSON] = [
            "task": .string("decompose"), "mode": .string(mode), "depth": .number(Double(depth)),
            "units": .array(units.map(LedgerJSON.string)),
            "unit_context": .array(workbook.orderedUnits().filter { contextUnits.contains($0.id) }.map { unit in
                .object(["id": .string(unit.id), "title": .string(unit.title), "outcome": .string(unit.outcome),
                         "subunits": .array(workbook.orderedSubunits(unitID: unit.id).map { .string($0.title) })])
            }),
            "nodes": .array(nodeJSON),
            "existing_nodes": .array(timeline.activeSkills.prefix(300).map { .object(["id": .string($0.id), "name": .string($0.name), "kind": .string($0.kind)]) }),
            "only_direct_prerequisites": .bool(mode == "descend"),
        ]
        if let profile {
            request["grade"] = profile.grade.map(LedgerJSON.string) ?? .null
            request["subject"] = profile.subject.map(LedgerJSON.string) ?? .null
        }
        return .object(request)
    }

    /// よくある勘違いを付ける依頼(形が決まった後に 1 回)。
    static func misconceptionRequest(units: [String], workbook: WorkbookMachine, timeline: TimelineMachine) -> LedgerJSON? {
        let unitSet = Set(units)
        let nodes = timeline.activeSkills.filter { skill in
            skill.expansion == "done" && TimelineGraphSchedule.unitID(of: skill, workbook: workbook).map(unitSet.contains) == true
        }.prefix(misconceptionNodeLimit)
        guard !nodes.isEmpty else { return nil }
        return .object([
            "task": .string("misconceptions"), "units": .array(units.map(LedgerJSON.string)),
            "nodes": .array(nodes.map { .object(["id": .string($0.id), "name": .string($0.name), "kind": .string($0.kind)]) }),
        ])
    }

    /// 依頼の行を書く(グラフを頼むかの判定の後、同じ書き込みの中で)。もう頼んでいたら・頼むものが無ければ nil。
    static func insertGraphRequest(_ request: TimelineGraphSchedule.Request, timeline: inout TimelineMachine, workbook: WorkbookMachine, profile: OnboardingProfile?) -> String? {
        guard !TimelineGraphSchedule.isBlocked(request, timeline: timeline) else { return nil }
        switch request {
        case .build, .extend:
            let units: [String]
            if case .extend(let unitID) = request { units = [unitID] } else { units = workbook.orderedUnits().map(\.id) }
            timeline.addGoalNodes(units.flatMap { workbook.orderedSubunits(unitID: $0) })
            let unitSet = Set(units)
            let nodes = timeline.pendingSkills.filter { TimelineGraphSchedule.unitID(of: $0, workbook: workbook).map(unitSet.contains) == true }.prefix(graphStepSize)
            guard !nodes.isEmpty else { return nil }
            let mode = request == .build ? "build" : "extend"
            let body = decomposeRequest(mode: mode, nodes: Array(nodes), units: units, depth: 1, workbook: workbook, timeline: timeline, profile: profile)
            return timeline.insertBatchRequest(purpose: request == .build ? "graph_build" : "graph_extend", request: body, accuracy: nil, levelCap: nil)
        case .review(let changeIDs):
            return timeline.insertBatchRequest(purpose: "graph_review", request: reviewRequest(changeIDs: changeIDs, timeline: timeline), accuracy: nil, levelCap: nil)
        }
    }

    /// 1段下りる依頼(対象の 1 点の直前の前提だけを聞く。モデルは上位モデル)。見直しなどのモデルが
    /// `struis.timeline_descend` で出す。いつ下りるかはモデルに任せ、アプリは条件を決めない。
    static func insertDescend(skillID: String, timeline: inout TimelineMachine, workbook: WorkbookMachine, note: String = "") -> String? {
        guard let skill = timeline.skills[skillID], !TimelineGraphSchedule.descendRequested(timeline, skillID: skillID) else { return nil }
        var body = decomposeRequest(mode: "descend", nodes: [skill], units: [], depth: 1, workbook: workbook, timeline: timeline, profile: OnboardingProfile.load())
        if case .object(var object) = body {
            object["skill_id"] = .string(skillID)
            if !note.isEmpty { object["reason"] = .string(note) }
            body = .object(object)
        }
        return timeline.insertBatchRequest(purpose: "graph_descend", request: body, accuracy: nil, levelCap: nil)
    }

    /// 1段を受け取った後: 今の単元の中身にまだ調べていない点が残っていれば次の段を、無ければよくある勘違いを頼む。
    static func continueGraph(after batch: TimelineBatchRecord, timeline: inout TimelineMachine, workbook: WorkbookMachine) -> String? {
        let units = (batch.request["units"]?.arrayValue ?? []).compactMap(\.stringValue)
        let unitSet = Set(units)
        let depth = batch.request["depth"]?.intValue ?? 1
        let pending = timeline.pendingSkills.filter { skill in
            unitSet.isEmpty || TimelineGraphSchedule.unitID(of: skill, workbook: workbook).map(unitSet.contains) == true
        }
        if !pending.isEmpty, depth < graphStepLimit {
            let nodes = Array(pending.prefix(graphStepSize))
            let ids = nodes.map(\.id).sorted()
            let asked = timeline.batches.values.contains { row in
                row.purpose.hasPrefix("graph") && (row.request["nodes"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }.sorted() == ids
            }
            if !asked {
                let body = decomposeRequest(mode: "step", nodes: nodes, units: units, depth: depth + 1, workbook: workbook, timeline: timeline, profile: OnboardingProfile.load())
                return timeline.insertBatchRequest(purpose: "graph_step", request: body, accuracy: nil, levelCap: nil)
            }
        }
        guard !units.isEmpty,
              !timeline.batches.values.contains(where: { $0.purpose == "graph_misconceptions" && TimelineGraphSchedule.unitIDs(in: $0.request) == unitSet }),
              let body = misconceptionRequest(units: units, workbook: workbook, timeline: timeline) else { return nil }
        return timeline.insertBatchRequest(purpose: "graph_misconceptions", request: body, accuracy: nil, levelCap: nil)
    }

    static func graph(composer: TurnComposer, planID: String, batchID: String, workbook: WorkbookMachine, timeline: TimelineMachine) async throws -> TurnPlan {
        guard let batch = timeline.batches[batchID] else { throw LedgerError.notFound("timeline graph request") }
        var request = batch.request.objectValue ?? [:]
        if !batch.rejected.isEmpty { request["rejected_last_time"] = .array(batch.rejected.map(LedgerJSON.string)) }
        let (instructions, schema) = switch request["task"]?.stringValue {
        case "decompose": ("prompt:timeline_decompose_instructions", "schema:timeline_decompose")
        case "misconceptions": ("prompt:timeline_misconceptions_instructions", "schema:timeline_misconceptions")
        default: ("prompt:timeline_graph_instructions", "schema:timeline_graph")
        }
        return TurnPlan(
            id: planID, kind: .timelineGraph, round: 1,
            thread: try await thread(composer: composer, planID: planID, instructions: instructions, role: TimelineModels.graphRole, workbook: workbook, timeline: timeline),
            turn: TurnPlan.TurnSpec(text: TurnComposer.dump(.object(request)), images: [], outputSchema: try await composer.assets.json(schema), sandboxPolicy: "dangerFullAccess"),
            workspace: workspace, delegation: nil, collect: [], limits: .structured, items: nil
        )
    }

    // MARK: - 反映

    nonisolated struct FollowUp: Sendable, Equatable {
        /// 同じ対象でターンを組み直す(受け取りを断って作り直させる)。
        var retry = false
        /// 返事が決まった形に合わなかった理由。あれば同じ中身に理由を添えて 1 回だけ頼み直す(`retry` と一緒に立つ)。
        var repair: String?
        /// 続けて頼むグラフの依頼(次の段・よくある勘違い・1段下りる)。
        var nextGraph: String?
        /// 結果を出した後に、生徒が次の問題を解いている間に見直す答案。
        var review: String?
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
                // 形に合わなかった: 理由を添えて 1 回だけ頼み直す(頼み直した返事も読めなければ失敗)。
                if outcome.round <= 1 {
                    followUp.retry = true
                    followUp.repair = parseProblem(error, text: outcome.finalText)
                } else {
                    timeline.failBatch(id: targetID, error: "unreadable batch")
                }
            }
        case .timelineGrading:
            guard let attempt = timeline.attempts[targetID], attempt.verdict == "grading" else { return ([], followUp) }
            guard outcome.status == .completed else {
                timelineTurnLog.error("timeline grading failed: \(outcome.error ?? "-", privacy: .public)")
                timeline.failGrading(attemptID: targetID)
                break
            }
            let grading: TimelineMachine.Grading
            do {
                grading = try TimelineMachine.Grading.parse(outcome.finalText)
            } catch {
                timelineTurnLog.error("timeline grading unreadable: \(String(describing: error), privacy: .public)")
                // 形に合わなかった: 答案は採点中のまま、理由を添えて 1 回だけ頼み直す。
                if outcome.round <= 1 {
                    followUp.retry = true
                    followUp.repair = parseProblem(error, text: outcome.finalText)
                } else {
                    timeline.failGrading(attemptID: targetID)
                }
                break
            }
            let result = timeline.applyGrading(attemptID: targetID, grading: grading)
            if result.verdict == "correct" || result.verdict == "wrong" { followUp.review = targetID }
            if result.countsForUnitHome, let card = timeline.cards[attempt.cardId], let subunitID = card.subunitId {
                var workbook = try WorkbookMachine(loading: db)
                workbook.recordTimelineAttempt(subunitID: subunitID, prompt: [card.prompt, card.math].filter { !$0.isEmpty }.joined(separator: " "),
                                               answerKey: card.answerKey, checkpoints: card.checkpoints, verdict: result.verdict, attemptID: targetID)
                extra = workbook.events
            }
        case .timelineReview:
            guard timeline.attempts[targetID] != nil else { return ([], followUp) }
            guard outcome.status == .completed else {
                // 見直しに失敗しても、生徒の流れは止めない(次の見直しで、まだ見ていない答案を一緒に見る)。
                timelineTurnLog.error("timeline review failed: \(outcome.error ?? "-", privacy: .public)")
                break
            }
            let review: TimelineMachine.Review
            do {
                review = try TimelineMachine.Review.parse(outcome.finalText)
            } catch {
                timelineTurnLog.error("timeline review unreadable: \(String(describing: error), privacy: .public)")
                if outcome.round <= 1 {
                    followUp.retry = true
                    followUp.repair = parseProblem(error, text: outcome.finalText)
                }
                break
            }
            timeline.applyReview(targetID: targetID, review: review)
        case .timelineGraph:
            guard let batch = timeline.batches[targetID], batch.status == "requested" else { return ([], followUp) }
            timeline.noteUsage(batchID: targetID, model: model, executions: outcome.executions)
            guard outcome.status == .completed else {
                timeline.failBatch(id: targetID, error: outcome.error ?? outcome.status.rawValue)
                break
            }
            switch batch.request["task"]?.stringValue {
            case "decompose":
                followUp = try applyDecomposition(batchID: targetID, text: outcome.finalText, timeline: &timeline, db: db)
            case "misconceptions":
                guard let output = try? JSONDecoder().decode(TimelineGraph.Misconceptions.self, from: Data(outcome.finalText.utf8)) else {
                    timeline.failBatch(id: targetID, error: "unreadable misconceptions")
                    break
                }
                let count = timeline.applyMisconceptions(output)
                markGraphReady(targetID, reason: "\(count) misconceptions. " + output.notes, timeline: &timeline)
            default:
                followUp = applyLegacyGraph(batchID: targetID, text: outcome.finalText, error: outcome.error, timeline: &timeline)
            }
        default:
            break
        }
        // このターンの中でモデルが `struis.timeline_descend` で出した依頼: ターンが終わった後に続けて頼む。
        if followUp.nextGraph == nil { followUp.nextGraph = try unstartedDescend(timeline: timeline, excluding: targetID, db: db) }
        return (timeline.events + extra, followUp)
    }

    /// 1段下りる依頼のうち、まだターンを始めていないもの(古い順の最初)。
    static func unstartedDescend(timeline: TimelineMachine, excluding targetID: String, db: Database) throws -> String? {
        let waiting = timeline.batches.values.filter { $0.purpose == "graph_descend" && $0.status == "requested" && $0.id != targetID }.sorted { $0.createdAt < $1.createdAt }
        for batch in waiting where try TurnRecord.filter(Column("target_id") == batch.id).fetchCount(db) == 0 {
            return batch.id
        }
        return nil
    }

    private static func markGraphReady(_ id: String, reason: String, timeline: inout TimelineMachine) {
        guard var batch = timeline.batches[id] else { return }
        batch.status = "ready"
        batch.reason = String(reason.prefix(500))
        batch.updatedAt = timeline.now()
        timeline.put("timeline.graph_ready", batch)
    }

    /// 受け取りを断って 1 回だけ作り直させる。2 回目は失敗にする(起動し直しても自動では頼み直さない)。
    private static func rejectGraph(_ id: String, problems: [String], timeline: inout TimelineMachine) -> FollowUp {
        guard var batch = timeline.batches[id] else { return FollowUp() }
        guard batch.retries < 1 else {
            timeline.failBatch(id: id, error: problems.joined(separator: "; "))
            return FollowUp()
        }
        batch.retries += 1
        batch.rejected = problems
        batch.updatedAt = timeline.now()
        timeline.put("timeline.graph_rejected", batch)
        return FollowUp(retry: true)
    }

    /// 1段分の分解を受け取る。循環の線だけを捨てて残りは受け取り、次の段(またはよくある勘違い)を続けて頼む。
    private static func applyDecomposition(batchID: String, text: String, timeline: inout TimelineMachine, db: Database) throws -> FollowUp {
        guard let batch = timeline.batches[batchID] else { return FollowUp() }
        guard let output = try? TimelineGraph.Decomposition.parse(text) else { return rejectGraph(batchID, problems: ["unreadable decomposition"], timeline: &timeline) }
        let requested: [String: String?] = Dictionary((batch.request["nodes"]?.arrayValue ?? []).compactMap { node -> (String, String?)? in
            guard let id = node["id"]?.stringValue else { return nil }
            return (id, node["unit_id"]?.stringValue)
        }, uniquingKeysWith: { first, _ in first })
        let descend = batch.request["mode"]?.stringValue == "descend"
        let result = timeline.applyDecomposition(output, requested: requested, descend: descend)
        let dug = requested.keys.filter { timeline.skills[$0]?.isDug == true }
        guard !dug.isEmpty else { return rejectGraph(batchID, problems: ["no requested node was decomposed: " + requested.keys.sorted().joined(separator: ", ")], timeline: &timeline) }
        var reason = "added \(result.added.count) nodes, \(result.edges) edges"
        if !result.droppedCycles.isEmpty { reason += "; dropped cycle edges " + result.droppedCycles.joined(separator: ", ") }
        if !result.removedRedundant.isEmpty { reason += "; removed redundant edges " + result.removedRedundant.joined(separator: ", ") }
        markGraphReady(batchID, reason: reason + (output.notes.isEmpty ? "" : ". " + output.notes), timeline: &timeline)
        guard !descend, let current = timeline.batches[batchID] else { return FollowUp() }
        return FollowUp(nextGraph: continueGraph(after: current, timeline: &timeline, workbook: try WorkbookMachine(loading: db)))
    }

    /// 前の版の依頼(点と線の JSON・見直しの操作の列)。
    private static func applyLegacyGraph(batchID: String, text: String, error: String?, timeline: inout TimelineMachine) -> FollowUp {
        guard let batch = timeline.batches[batchID] else { return FollowUp() }
        guard let output = try? JSONDecoder().decode(TimelineGraph.Output.self, from: Data(text.utf8)) else {
            timeline.failBatch(id: batchID, error: error ?? "unreadable graph")
            return FollowUp()
        }
        let problems: [TimelineGraph.Problem]
        if batch.purpose == "graph_review" {
            problems = timeline.applyGraphOps(output.ops, source: "review")
            if problems.isEmpty { timeline.markReviewed() }
        } else {
            problems = timeline.applyGraph(output, source: "initial", unitID: batch.request["unit"]?["id"]?.stringValue)
        }
        guard problems.isEmpty else { return rejectGraph(batchID, problems: problems.map(\.description), timeline: &timeline) }
        markGraphReady(batchID, reason: output.notes, timeline: &timeline)
        return FollowUp()
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
        kind == .timelineBatch || kind == .timelineGrading || kind == .timelineGraph || kind == .timelineReview
    }
}

/// 今日の記録の 1 件の文(書いた時点の文のまま保存する。書式はモデルに決めさせないが、ここで並べる項目は固定)。
nonisolated enum TimelineLogText {
    static func clock(_ iso: String) -> String {
        guard let date = LedgerClock.parse(iso) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 今の単元と小単元、その単元のスキル(その日最初の依頼の時点。単元が変わった時はその単元の分)。
    static func context(unit: WorkbookUnitRecord, subunits: [WorkbookSubunitRecord], skills: [TimelineSkillRecord], changed: Bool) -> String {
        var lines = [changed ? "## 単元が変わった" : "## 今の単元", "- \(unit.title)(\(unit.id))"]
        for subunit in subunits { lines.append("  - 小単元: \(subunit.title)(\(subunit.id))") }
        if !skills.isEmpty {
            lines.append("## この単元のスキル")
            lines.append(contentsOf: skills.map { "- \($0.name)(\($0.id))" })
        }
        return lines.joined(separator: "\n")
    }

    static func skillsAdded(_ skills: [TimelineSkillRecord]) -> String {
        (["## スキルが足された"] + skills.map { "- \($0.name)(\($0.id))" }).joined(separator: "\n")
    }

    /// 答案の結果が出た時の 1 件: 問題、正しい答え、正誤、生徒の答え、書き起こし、採点メモ、生徒に見せた言葉、スキル。
    static func attempt(_ attempt: TimelineAttemptRecord, card: TimelineCardRecord, machine: TimelineMachine) -> String {
        var lines = ["## \(clock(attempt.createdAt)) 答案 \(attempt.id)(カード \(card.id))"]
        let problem = [card.payload["problem"]?.stringValue ?? card.prompt, card.math.isEmpty ? "" : "$\(card.math)$", card.question].filter { !$0.isEmpty }.joined(separator: " ")
        lines.append("問題: " + problem + "(\(TimelineCards.Kind(rawValue: card.kind)?.title ?? card.kind)・段 \(card.level)\(originNote(card)))")
        if !card.answerKey.isEmpty { lines.append("正しい答え: " + card.answerKey) }
        lines.append("結果: " + resultLine(attempt) + "・\(Int(attempt.seconds.rounded()))秒")
        if !attempt.learnerAnswer.isEmpty { lines.append("生徒の答え: " + attempt.learnerAnswer) }
        if let choice = attempt.checkpointResults.arrayValue?.first, card.kind == TimelineCards.Kind.ask.rawValue,
           let index = choice.intValue, let options = card.payload["options"]?.arrayValue?.compactMap(\.stringValue), options.indices.contains(index) {
            lines.append("問い: " + card.prompt + " → 生徒が選んだもの: " + options[index])
        }
        let skills = skillLine(attempt: attempt, card: card, machine: machine)
        if !skills.isEmpty { lines.append("スキル: " + skills) }
        if let transcript = attempt.transcript, !transcript.isEmpty { lines.append("書き起こし:\n" + transcript) }
        if let notes = attempt.notes, !notes.isEmpty { lines.append("メモ:\n" + notes) }
        if !attempt.feedback.isEmpty, attempt.grade != nil { lines.append("生徒に見せた言葉: " + attempt.feedback) }
        return lines.joined(separator: "\n")
    }

    static func skipReason(_ attempt: TimelineAttemptRecord) -> String {
        "## 答案 \(attempt.id) を飛ばした理由: " + (attempt.skipReason == "too_hard" ? "難しすぎる" : attempt.skipReason == "too_easy" ? "簡単すぎる" : attempt.skipReason ?? "")
    }

    static func dispute(_ attempt: TimelineAttemptRecord) -> String {
        "## \(clock(attempt.disputedAt ?? attempt.createdAt)) 生徒からの申し出(答案 \(attempt.id)、判定に納得できない)\n" + (attempt.dispute ?? "")
    }

    /// 見直しの結果: 見直しメモと、確定したスキルの ○×。何も決めず、メモも無ければ書かない。
    static func review(targetID: String, notes: String, decided: [String: [String: String]], machine: TimelineMachine) -> String? {
        guard !notes.isEmpty || !decided.isEmpty else { return nil }
        var lines = ["## \(clock(machine.now())) 見直し(答案 \(targetID))"]
        if !notes.isEmpty { lines.append("見直しメモ:\n" + notes) }
        if !decided.isEmpty {
            lines.append("確定したスキル:")
            for (attemptID, marks) in decided.sorted(by: { $0.key < $1.key }) {
                lines.append("- 答案 \(attemptID): " + marks.keys.sorted().map { skillName($0, machine: machine) + (marks[$0] == "correct" ? " ○" : " ×") }.joined(separator: "、"))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 前の判定を取り消して直した時の 1 件(取り消した判定とその理由)。
    static func revise(_ attempt: TimelineAttemptRecord, from previous: String, note: String, machine: TimelineMachine) -> String {
        var lines = ["## \(clock(machine.now())) 判定を直した(答案 \(attempt.id): \(gradeLabel(previous)) → \(gradeLabel(attempt.grade ?? attempt.verdict)))"]
        if !note.isEmpty { lines.append("理由: " + note) }
        if let marks = attempt.skillMarks, !marks.isEmpty {
            lines.append("スキル: " + marks.keys.sorted().map { skillName($0, machine: machine) + (marks[$0] == "correct" ? " ○" : " ×") }.joined(separator: "、"))
        }
        return lines.joined(separator: "\n")
    }

    private static func skillName(_ id: String, machine: TimelineMachine) -> String { "\(machine.skills[id]?.name ?? id)(\(id))" }

    private static func gradeLabel(_ grade: String) -> String {
        switch grade {
        case "correct": "正解"
        case "partial": "答えは合うが途中に誤り"
        case "wrong": "誤答"
        default: grade
        }
    }

    private static func originNote(_ card: TimelineCardRecord) -> String {
        switch card.origin {
        case "variant": "・数値だけ変えた問題"
        case "easier": "・やさしくした問題"
        case "rapid": "・速攻"
        case "review": "・見直しで入れた問題"
        case "history": "・前に解けた問題"
        default: TimelineRules.chainPosition(card).map { "・続きの \($0.position)/\($0.total)" } ?? ""
        }
    }

    private static func resultLine(_ attempt: TimelineAttemptRecord) -> String {
        switch attempt.grade ?? attempt.verdict {
        case "correct": "正解"
        case "partial": "答えは合うが途中に誤り"
        case "wrong": "誤答"
        case "skipped": "飛ばした" + (attempt.skipReason.map { $0 == "too_hard" ? "(難しすぎる)" : $0 == "too_easy" ? "(簡単すぎる)" : "" } ?? "")
        case "grading": "採点中"
        case "unreadable": "字が読めなかった"
        case "failed": "採点できなかった"
        case "answered": "答えた"
        default: attempt.verdict
        }
    }

    private static func skillLine(attempt: TimelineAttemptRecord, card: TimelineCardRecord, machine: TimelineMachine) -> String {
        if let marks = attempt.skillMarks, !marks.isEmpty {
            return marks.keys.sorted().map { skillName($0, machine: machine) + (marks[$0] == "correct" ? " ○" : " ×") }.joined(separator: "、")
        }
        if let ids = attempt.skillIds, !ids.isEmpty {
            return ids.map { skillName($0, machine: machine) }.joined(separator: "、") + (attempt.skillsPending == true ? "(○× は見直しで決める)" : "")
        }
        return card.skills.map { skillName($0, machine: machine) }.joined(separator: "、")
    }
}
