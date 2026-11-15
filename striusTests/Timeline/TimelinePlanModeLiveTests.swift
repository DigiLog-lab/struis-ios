import GRDB
import XCTest
@testable import strius

/// 新しい形(`TimelinePlanMode`)の採点を、実際の Anthropic で測る(手動の測定。2026-11-15)。
///
/// `TEST_RUNNER_STRUIS_PLAN_LIVE=<フォルダ>` と `TEST_RUNNER_STRUIS_DEBUG_ANTHROPIC_KEY_FILE` を渡した時だけ動く。
/// フォルダには `items.json`(答案ごとの問題・正しい答え)・`img/<番号>.jpg`(答案の写真)・`skills.json`(単元のスキル)・
/// `opus_log.md`(Opus に読ませる記録)を置く。結果は `<フォルダ>/plan_live_results.json` に書き、標準出力には件数と費用だけを出す
/// (答案の中身は出さない)。`STRUIS_PLAN_LIVE_LIMIT`(ドル)に達したら止める。
final class TimelinePlanModeLiveTests: XCTestCase {
    private struct Item: Decodable {
        var n: String
        var card_kind: String?
        var prompt: String
        var math: String
        var question: String
        var answer_key: String
        var answer_expr: String
        var steps: [String]
        var skills: [String]
    }

    private struct Skill: Decodable {
        var id: String
        var name: String
        var kind: String
        var status: String
    }

    private static let unitID = "u-static"

    @MainActor
    func testPlanThenSessionGrading() async throws {
        let env = ProcessInfo.processInfo.environment
        let folder = env["STRUIS_PLAN_LIVE"] ?? ""
        let keyFile = env["STRUIS_DEBUG_ANTHROPIC_KEY_FILE"] ?? ""
        try XCTSkipIf(folder.isEmpty || keyFile.isEmpty, "手動の測定(TEST_RUNNER_STRUIS_PLAN_LIVE と鍵のファイルが要る)")
        let limit: Double = Double(env["STRUIS_PLAN_LIVE_LIMIT"] ?? "") ?? 3.0
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        let key = try String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: root.appendingPathComponent("items.json")))
        let skills = try JSONDecoder().decode([Skill].self, from: Data(contentsOf: root.appendingPathComponent("skills.json")))
        let opusLog = try String(contentsOf: root.appendingPathComponent("opus_log.md"), encoding: .utf8)

        UserDefaults.standard.set(true, forKey: TimelinePlanMode.defaultsKey)
        TimelinePlanMode.reset()
        defer {
            UserDefaults.standard.removeObject(forKey: TimelinePlanMode.defaultsKey)
            TimelinePlanMode.reset()
        }

        let assets = AssetCache()
        let upstream = ClaudeUpstream(baseURL: URL(string: "https://api.anthropic.com")!, apiKey: { key }, gate: OpenUsageGate())
        let runner = ClaudeTurnRunner(assets: assets, conversations: try ClaudeConversationStore.temporary(), upstream: upstream,
                                      contextStore: ThreadContextStore(url: nil), prepareCommands: {})
        let composer = TurnComposer(assets: assets)

        // 台帳: 単元・スキル・答案ごとのカード。写真は captures に「書く面の答案」の名前で置く(赤ペンの道具も本番と同じに使う)。
        let ledger = try Ledger.inMemory()
        // 答案を拡大して見る道具(`timeline_view_capture`)と台帳の道具が、この台帳を読むようにする(アプリでは起動時に入れている)。
        TimelineQueryHost.install(ledger)
        // `plan.yaml` があれば Opus を呼ばずにその計画を使う(採点だけを測り直す時)。
        let reusedPlan: String? = try? String(contentsOf: root.appendingPathComponent("plan.yaml"), encoding: .utf8)
        try StruisPaths.prepare()
        let now = LedgerClock.now()
        var paths: [String: String] = [:]
        for item in items {
            let name = "\(TimelineTurns.inkCapturePrefix)live-\(item.n).jpg"
            let target = StruisPaths.captures.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: root.appendingPathComponent("img/\(item.n).jpg"), to: target)
            paths[item.n] = name
        }
        try await ledger.commit { db in
            let unit = WorkbookUnitRecord(id: Self.unitID, title: "静電場が解ける", outcome: "", status: "active", source: "manual", position: 0,
                                          overview: .emptyObject, createdAt: now, updatedAt: now, passedAt: nil)
            var timeline = try TimelineMachine(loading: db)
            for skill in skills {
                timeline.put("test", TimelineSkillRecord(id: skill.id, name: skill.name, kind: skill.kind, unitId: Self.unitID, status: skill.status,
                                                         correctDates: [], masteryThreshold: 3, attempts: 0, lastCorrectAt: nil, nextReviewAt: nil,
                                                         reviewCount: 0, replacedBy: [], source: "initial", createdAt: now, updatedAt: now, expansion: "done"))
            }
            for (index, item) in items.enumerated() {
                timeline.put("test", TimelineCardRecord(
                    id: "card-\(item.n)", batchId: nil, position: index, kind: item.card_kind ?? "solve", level: 1, skills: item.skills, typeName: "測定",
                    prompt: item.prompt, math: item.math, question: item.question, answerKey: item.answer_key, answerExpr: "", checkpoints: [],
                    commonMistakes: [], estimatedSeconds: 60, chain: nil, easierOf: nil, subunitId: nil, unitId: Self.unitID,
                    payload: .object(["steps": .array(item.steps.map(LedgerJSON.string))]), origin: "batch", status: "shown", createdAt: now, updatedAt: now))
            }
            let planBatchID = TimelinePlanMode.insertPlanRequest(log: opusLog, timeline: &timeline)
            if let reusedPlan, var row = timeline.batches[planBatchID] {
                row.request = .object(["task": .string("plan"), "plan": .string(reusedPlan)])
                row.status = "ready"
                timeline.put("timeline.plan_ready", row)
            }
            return ([.upsert("test", unit)] + timeline.events, ())
        }

        var spent: Double = 0
        func cost(_ outcome: TurnOutcome) -> Double {
            outcome.executions.compactMap { $0["estimated_cost_usd"]?.doubleValue }.last ?? 0
        }
        func usage(_ outcome: TurnOutcome) -> [LedgerJSON] {
            outcome.executions.last?["requests"]?.arrayValue ?? []
        }
        var report: [String: Any] = [:]

        // 1. Opus の計画(`plan.yaml` を使う時は呼ばない)。
        if reusedPlan == nil {
        let (workbook0, timeline0): (WorkbookMachine, TimelineMachine) = try await ledger.read { db in (try WorkbookMachine(loading: db), try TimelineMachine(loading: db)) }
        let planBatch = try XCTUnwrap(timeline0.batches.values.first { $0.purpose == TimelinePlanMode.planPurpose })
        let planTurn = try await TimelineTurns.graph(composer: composer, planID: "live-plan", batchID: planBatch.id, workbook: workbook0, timeline: timeline0)
        let started = Date()
        let planOutcome = try await runner.run(planTurn) { _ in }
        WorkspaceStager.cleanup(plan: planTurn)
        spent += cost(planOutcome)
        _ = try await ledger.commit { db in
            try TimelineTurns.apply(kind: .timelineGraph, targetID: planBatch.id, outcome: planOutcome, model: planTurn.thread.model, db: db)
        }
        let plan: String? = try await ledger.read { db in TimelinePlanMode.latestPlan(try TimelineMachine(loading: db)) }
        XCTAssertNotNil(plan, "計画を受け取れなかった: \(planOutcome.errorDetail ?? "")")
        report["plan"] = ["status": planOutcome.status.rawValue, "cost": cost(planOutcome), "seconds": Date().timeIntervalSince(started),
                          "text": plan ?? "", "requests": usage(planOutcome).map(\.any)]
        print(String(format: "PLAN_LIVE plan status=%@ cost=$%.3f seconds=%.0f", planOutcome.status.rawValue, cost(planOutcome), Date().timeIntervalSince(started)))
        } else {
            print("PLAN_LIVE plan reused")
        }

        // 2. 答案を順番に採点する(同じスレッドが続く)。
        var gradings: [[String: Any]] = []
        for item in items {
            guard spent < limit else {
                print("PLAN_LIVE stopped at the limit before \(item.n)")
                break
            }
            let attemptID: String = try await ledger.commit { db in
                var timeline = try TimelineMachine(loading: db)
                let id = timeline.recordCapture(cardID: "card-\(item.n)", capturePath: paths[item.n] ?? "", seconds: 60, assisted: false)
                return (timeline.events, id)
            }
            var round = 0
            var repair: String?
            var record: [String: Any] = ["n": item.n]
            while round < 2 {
                round += 1
                let (workbook, timeline): (WorkbookMachine, TimelineMachine) = try await ledger.read { db in (try WorkbookMachine(loading: db), try TimelineMachine(loading: db)) }
                let turn = try await TimelineTurns.grading(composer: composer, planID: "live-\(item.n)-\(round)", attemptID: attemptID, workbook: workbook,
                                                           timeline: timeline, repair: repair)
                let begin = Date()
                let outcome = try await runner.run(turn) { _ in }
                WorkspaceStager.cleanup(plan: turn)
                spent += cost(outcome)
                let followUp: TimelineTurns.FollowUp = try await ledger.commit { db in
                    try TimelineTurns.apply(kind: .timelineGrading, targetID: attemptID, outcome: outcome, model: turn.thread.model, db: db)
                }
                let requests = usage(outcome)
                record["rounds"] = round
                record["cost"] = ((record["cost"] as? Double) ?? 0) + cost(outcome)
                record["seconds"] = ((record["seconds"] as? Double) ?? 0) + Date().timeIntervalSince(begin)
                record["thread"] = outcome.codexThreadID ?? ""
                record["resumed"] = turn.thread.mode == .resume
                record["requests"] = requests.map(\.any)
                record["views"] = ((record["views"] as? Int) ?? 0) + outcome.executions.reduce(0) { $0 + ($1["capture_views"]?.arrayValue?.count ?? 0) }
                record["status"] = outcome.status.rawValue
                record["error"] = outcome.errorDetail ?? ""
                if followUp.retry, round < 2 {
                    repair = followUp.repair
                    continue
                }
                break
            }
            let attempt: TimelineAttemptRecord? = try await ledger.read { db in try TimelineMachine(loading: db).attempts[attemptID] }
            record["verdict"] = attempt?.verdict ?? ""
            record["grade"] = attempt?.grade ?? ""
            record["learner_answer"] = attempt?.learnerAnswer ?? ""
            record["transcript"] = attempt?.transcript ?? ""
            record["notes"] = attempt?.reviewNotes ?? attempt?.notes ?? ""
            record["feedback"] = attempt?.feedback ?? ""
            record["marks"] = ((attempt?.errors.arrayValue ?? []).filter { $0["kind"]?.stringValue == TimelineMachine.RedPenMark.kind }).count
            gradings.append(record)
            print(String(format: "PLAN_LIVE %@ rounds=%d views=%d marks=%d resumed=%@ cost=$%.4f total=$%.3f", item.n, record["rounds"] as? Int ?? 0,
                         record["views"] as? Int ?? 0, record["marks"] as? Int ?? 0, (record["resumed"] as? Bool ?? false) ? "yes" : "no", record["cost"] as? Double ?? 0, spent))
        }
        report["gradings"] = gradings
        report["spent"] = spent
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent("plan_live_results.json"))
        print(String(format: "PLAN_LIVE done graded=%d spent=$%.3f", gradings.count, spent))
    }
}
