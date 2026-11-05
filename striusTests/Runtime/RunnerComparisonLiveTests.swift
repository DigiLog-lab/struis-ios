import CryptoKit
import GRDB
import UIKit
import XCTest
@testable import strius

/// Claude 直結版(`ClaudeTurnRunner`)に決まった依頼を流し、模擬の Anthropic に届いた要求・結果・時間・メモリを記録する。
/// 手で流す測定で、CI の門には入れない。
///
/// 端末内の Codex(`CodexTurnRunner`)は 2026-11-03 に外したので、Codex 版はもう動かせない。移行の時に同じ依頼で録った
/// Codex 版の結果は `artifacts/compare-final` にあり、`scripts/e2e/compare_runners.py` はそれと今回の直結版(版の名前は
/// `direct` のまま)を比べる。
///
///     python3 scripts/e2e/fake_anthropic.py --port 8787 --log-dir <dir>/server [--upstream-key-file <key>]
///     TEST_RUNNER_STRUIS_RUNNER_COMPARE_OUT=<dir>/outcomes [TEST_RUNNER_STRUIS_RUNNER_COMPARE_RUNNER=direct]
///     TEST_RUNNER_STRUIS_RUNNER_COMPARE_SETS=record,normal,replay,faults,structured,chat(既定 normal,faults)
///     TEST_RUNNER_STRUIS_ANTHROPIC_BASE_URL=http://127.0.0.1:8787 TEST_RUNNER_STRUIS_DEBUG_ANTHROPIC_KEY_FILE=<偽のキー>
///     TEST_RUNNER_STRUIS_DEVICE_RUNTIME=0 TEST_RUNNER_STRUIS_PLAN=generous TEST_RUNNER_STRUIS_USAGE_PERCENT=0
///
/// `STRUIS_PLAN`・`STRUIS_USAGE_PERCENT` は端末の利用枠をメモリの中だけの枠に替える。付けないと Keychain に週ごとに溜まる
/// お試しの枠($0.25)を数回で使い切り、以降の依頼が全部「利用枠を使い切りました」で止まる。
///
/// 組(`STRUIS_RUNNER_COMPARE_SETS`):
/// - `record`・`normal`・`replay`・`faults`: タイムラインの判定・見直し・5枚の依頼(`faults` は故障ごとに 1 回と、待っている間の停止)。
/// - `structured`: 構造化ターンの各種を 1 回ずつ(`timeline_graph`・`workbook_grading`・`workbook_set`・`workbook_unit`・
///   `onboarding_grading`・`onboarding_plan`)。場面は `<版>/structured/<種類>`。
/// - `chat`: 本物の `TurnCoordinator` で会話を回す。1 つの会話で `reply`(ふつうの質問)→ `photo`(写真つき)→ `tool`(道具を使う)
///   → `continue`(「続けて」で続きのラウンド)→ `delegate`(「調べて」で資料探しを任せる)→ `restart`(アプリを開き直したことにして、
///   前の話を覚えているか)→ `interrupt`(返事を待っている間に止める)→ `interrupt-next`(止めた後の質問)→ `drop`(返事の途中で
///   接続が切れる)。最後に別の会話で `fork`(小単元の要点の起動と、`thread_fork` の上で先回りする例題)。場面は `<版>/chat/<場面>`。
///
/// `replay` は Codex 版が録った録画(`codex-real`)を再生する。比べるのは `scripts/e2e/compare_runners.py`。
final class RunnerComparisonLiveTests: XCTestCase {
    typealias F = TimelineFixture

    private static let steps: [(name: String, kind: TurnPlan.Kind)] = [("grading-1", .timelineGrading), ("grading-2", .timelineGrading), ("review", .timelineReview), ("batch", .timelineBatch)]
    /// 止まった答えの判定を試す長さ(本番は 120 秒)。
    private static let stall: Duration = .seconds(3)

    private struct Fault {
        let name: String
        let faults: [[String: Any]]
    }

    private static let faults: [Fault] = [
        Fault(name: "http-500-once", faults: [["kind": "http", "status": 500]]),
        Fault(name: "http-529-once", faults: [["kind": "http", "status": 529]]),
        Fault(name: "http-429", faults: [["kind": "http", "status": 429, "retry_after": 1]]),
        Fault(name: "http-500-many", faults: Array(repeating: ["kind": "http", "status": 500] as [String: Any], count: 20)),
        Fault(name: "drop-mid-text", faults: [["kind": "drop", "after": "text_delta"]]),
        Fault(name: "sse-overloaded", faults: [["kind": "sse_error", "after": "text_delta", "type": "overloaded_error"]]),
        Fault(name: "sse-api-error", faults: [["kind": "sse_error", "after": "text_delta", "type": "api_error"]]),
        Fault(name: "stall-mid-text", faults: [["kind": "stall", "after": "text_delta", "seconds": 8]]),
        Fault(name: "thinking-rejected", faults: [["kind": "none"], ["kind": "http", "status": 400, "message": "messages.1.content.0: Invalid `signature` in `thinking` block"]]),
    ]

    private var out: URL!
    private var runnerName = ""
    private var baseURL = ""
    private var results: [[String: Any]] = []
    private var assets: AssetCache!
    /// 会話の控え。開き直した時の新しいランナーも同じものを使う。
    private var conversations: ClaudeConversationStore?
    /// 道具(コマンド)の実行環境。開き直したランナーも同じものを使う(同じプロセスの中で二重に起こさない)。
    private var boot: HyotanBoot?

    @MainActor
    func testCompareRunners() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = environment["STRUIS_RUNNER_COMPARE_OUT"] ?? ""
        try XCTSkipIf(output.isEmpty, "TEST_RUNNER_STRUIS_RUNNER_COMPARE_OUT が無い(比較は手動)")
        out = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let requested: String = environment["STRUIS_RUNNER_COMPARE_RUNNER"] ?? "direct"
        try XCTSkipIf(requested != "direct", "Codex 版は 2026-11-03 に外した。録った結果は artifacts/compare-final にある")
        runnerName = "direct"
        baseURL = environment["STRUIS_ANTHROPIC_BASE_URL"] ?? "http://127.0.0.1:8787"
        let sets = (environment["STRUIS_RUNNER_COMPARE_SETS"] ?? "normal,faults").split(separator: ",").map(String.init)
        let iterations = Int(environment["STRUIS_RUNNER_COMPARE_ITERATIONS"] ?? "") ?? 5

        let assets: AssetCache = AssetCache()
        self.assets = assets
        let composer = TurnComposer(assets: assets)
        let before = StruisMemorySnapshot()
        let began = Date()
        let runner = try await makeRunner(assets: assets)
        let startupMs = ClaudeTurnClock.elapsed(began)
        let afterStart = StruisMemorySnapshot()

        // 最初の 1 回だけ、起動の分を含む時間として別に残す(`warm`)。
        try await control(["scenario": "\(runnerName)/warm/grading-1", "mode": "script"])
        _ = try await runSteps(set: "warm", only: 1, mode: "script", tapePrefix: nil, runner: runner, composer: composer)

        if sets.contains("record") {
            // 本物の API に 1 回通して録る。`replay` が再生するのは、移行の時に Codex 版が録った録画(`codex-real`)。
            _ = try await runSteps(set: "real", only: nil, mode: "record", tapePrefix: "\(runnerName)-real", runner: runner, composer: composer)
        }
        if sets.contains("normal") {
            for iteration in 1...iterations {
                _ = try await runSteps(set: "normal-\(iteration)", only: nil, mode: "script", tapePrefix: nil, runner: runner, composer: composer)
            }
        }
        if sets.contains("replay") {
            for iteration in 1...iterations {
                _ = try await runSteps(set: "replay-\(iteration)", only: nil, mode: "replay", tapePrefix: "codex-real", runner: runner, composer: composer)
            }
        }
        if sets.contains("faults") {
            for fault in Self.faults {
                _ = try await runSteps(set: "fault-\(fault.name)", only: 1, mode: "script", tapePrefix: nil, faults: fault.faults, runner: runner, composer: composer)
            }
            try await interruptDuringWait(runner: runner, composer: composer)
        }
        if sets.contains("structured") {
            try await runStructured(runner: runner, composer: composer)
        }
        if sets.contains("chat") {
            // 開き直し(`restart`)で版を作り直すので最後に回す。
            try await runChat(runner: runner)
        }

        let end = StruisMemorySnapshot()
        let summary: [String: Any] = [
            "runner": runnerName, "startup_ms": startupMs,
            "memory": ["before": Self.memory(before), "after_start": Self.memory(afterStart), "end": Self.memory(end)],
            "results": results,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("\(runnerName).json"))
        try await control(["scenario": NSNull(), "mode": "script"])
    }

    private static func memory(_ snapshot: [String: NSNumber]) -> [String: Any] {
        ["footprint": snapshot["footprint"]?.uint64Value ?? 0, "lifetime_peak": snapshot["lifetimePeak"]?.uint64Value ?? 0]
    }

    @MainActor
    private func makeRunner(assets: AssetCache) async throws -> any TurnRunning {
        let conversations: ClaudeConversationStore = try ClaudeConversationStore.temporary()
        self.conversations = conversations
        return await makeClaudeRunner(assets: assets, conversations: conversations)
    }

    @MainActor
    private func makeClaudeRunner(assets: AssetCache, conversations: ClaudeConversationStore) async -> ClaudeTurnRunner {
        let boot: HyotanBoot = self.boot ?? HyotanBoot()
        self.boot = boot
        let runner: ClaudeTurnRunner = ClaudeTurnRunner(
            assets: assets, conversations: conversations, timeouts: ClaudeTurnRunner.Timeouts(messageStall: Self.stall)
        ) {
            await boot.start()
            await NativeRuntimeHost.shared.prepareForCommands()
        }
        await runner.warmUp()
        return runner
    }

    /// アプリを開き直したことにする。同じ会話の控えで、新しいランナーを作り直す。
    @MainActor
    private func relaunch(_ runner: any TurnRunning) async throws -> any TurnRunning {
        let conversations: ClaudeConversationStore = try XCTUnwrap(self.conversations, "会話の控えが無い")
        return await makeClaudeRunner(assets: assets, conversations: conversations)
    }

    private func control(_ payload: [String: Any]) async throws {
        var request = URLRequest(url: URL(string: baseURL + "/__control")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    // MARK: - 台帳と依頼

    private func makeLedger() async throws -> (ledger: Ledger, ids: [String]) {
        let ledger = try Ledger.inMemory()
        try StruisPaths.prepare()
        for name in ["compare-a.jpg", "compare-b.jpg"] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).jpegData(withCompressionQuality: 0.8) { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
                let text = name.contains("-a") ? "∫ 2 cos 2x dx = sin 2x + C" : "∫ 3 sin 3x dx = -cos 3x + C"
                (text as NSString).draw(at: CGPoint(x: 40, y: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor.black])
            }
            try image.write(to: StruisPaths.captures.appendingPathComponent(name))
        }
        let ids: [String] = try await ledger.commit { db in
            let unit = WorkbookUnitRecord(id: "u-compare", title: "フーリエ級数", outcome: "", status: "active", source: "manual", position: 0,
                                          overview: .emptyObject, createdAt: F.now, updatedAt: F.now, passedAt: nil)
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", F.skill("fourier.antiderivative_trig"))
            timeline.put("test", F.card("c1", skills: ["fourier.antiderivative_trig"]))
            timeline.put("test", F.card("c2", skills: ["fourier.antiderivative_trig"]))
            let first = timeline.recordCapture(cardID: "c1", capturePath: "compare-a.jpg", seconds: 30, assisted: false)
            let second = timeline.recordCapture(cardID: "c2", capturePath: "compare-b.jpg", seconds: 30, assisted: false)
            let batch = timeline.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: 0.8, levelCap: nil)
            return ([.upsert("test", unit)] + timeline.events, [first, second, batch])
        }
        return (ledger, ids)
    }

    private func targets(_ ids: [String]) -> [String: String] {
        ["grading-1": ids[0], "grading-2": ids[1], "review": ids[1], "batch": ids[2]]
    }

    /// 依頼を組む直前の問題集とタイムライン(アプリと同じく、問題集の記録をタイムラインへ写してから)。
    private func machines(_ ledger: Ledger) async throws -> (workbook: WorkbookMachine, timeline: TimelineMachine) {
        try await ledger.commit { db in
            let workbook = try WorkbookMachine(loading: db)
            var timeline = try TimelineMachine(loading: db)
            TimelineTurns.syncLog(workbook: workbook, timeline: &timeline)
            return (timeline.events, (workbook, timeline))
        }
    }

    private func plan(step: (name: String, kind: TurnPlan.Kind), target: String, ledger: Ledger, composer: TurnComposer) async throws -> TurnPlan {
        let (workbook, timeline): (WorkbookMachine, TimelineMachine) = try await machines(ledger)
        let planID = "compare-\(step.name)-\(UUID().uuidString.prefix(8).lowercased())"
        return switch step.kind {
        case .timelineGrading: try await TimelineTurns.grading(composer: composer, planID: planID, attemptID: target, workbook: workbook, timeline: timeline)
        case .timelineReview: try await TimelineTurns.review(composer: composer, planID: planID, attemptID: target, workbook: workbook, timeline: timeline)
        default: try await TimelineTurns.batch(composer: composer, planID: planID, batchID: target, workbook: workbook, timeline: timeline)
        }
    }

    /// 結果を綴じたことにして、今日の記録を後ろに足す(本文の違いが比べる対象に混ざらないよう、毎回同じ結果にする)。
    private func applyFixedResult(step: (name: String, kind: TurnPlan.Kind), target: String, ledger: Ledger) async throws {
        try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            switch step.kind {
            case .timelineGrading:
                _ = timeline.applyGrading(attemptID: target, grading: TimelineMachine.Grading(grade: "partial", learnerAnswer: "0", skillIds: ["fourier.antiderivative_trig"],
                                                                                              transcript: "[-2 sin 2x]", notes: "原始関数の係数が違う"))
            case .timelineReview:
                timeline.applyReview(targetID: target, review: try TimelineMachine.Review.parse(#"{"notes":"同じ所の誤りが 2 回","skill_results":[]}"#))
            default: break
            }
            return (timeline.events, ())
        }
    }

    // MARK: - 実行

    private func runSteps(set: String, only: Int?, mode: String, tapePrefix: String?, faults: [[String: Any]] = [],
                          runner: any TurnRunning, composer: TurnComposer) async throws -> [TurnOutcome] {
        let (ledger, ids) = try await makeLedger()
        let targets = targets(ids)
        var outcomes: [TurnOutcome] = []
        for step in Self.steps.prefix(only ?? Self.steps.count) {
            let target = targets[step.name] ?? ""
            let plan = try await plan(step: step, target: target, ledger: ledger, composer: composer)
            var payload: [String: Any] = ["scenario": "\(runnerName)/\(set)/\(step.name)", "mode": mode, "faults": faults]
            if let tapePrefix { payload["tape"] = "\(tapePrefix)/\(step.name)" }
            try await control(payload)
            let outcome = try await timedRun(plan, set: set, step: step.name, runner: runner)
            outcomes.append(outcome)
            try await applyFixedResult(step: step, target: target, ledger: ledger)
        }
        return outcomes
    }

    private func timedRun(_ plan: TurnPlan, set: String, step: String, runner: any TurnRunning) async throws -> TurnOutcome {
        let recorder = ProgressRecorder()
        try WorkspaceStager.prepare(plan: plan, assets: assets)
        let started = Date()
        let outcome = try await runner.run(plan) { event in recorder.add(event) }
        let ended = Date()
        WorkspaceStager.cleanup(plan: plan)
        record(outcome, set: set, step: step, kind: plan.kind.rawValue, started: started, ended: ended, progress: recorder.labels)
        return outcome
    }

    private func record(_ outcome: TurnOutcome, set: String, step: String, kind: String, started: Date, ended: Date, progress: [String]) {
        let last = outcome.executions.last?.any as? [String: Any] ?? [:]
        results.append([
            "set": set, "step": step, "kind": kind, "status": outcome.status.rawValue, "final_text": outcome.finalText,
            "error": outcome.error ?? NSNull(), "error_detail": outcome.errorDetail ?? NSNull(), "elapsed_ms": outcome.elapsedMs,
            "started_at": started.timeIntervalSince1970, "ended_at": ended.timeIntervalSince1970, "progress": progress,
            "execution_count": outcome.executions.count, "audit_status": last["status"] ?? NSNull(),
            "request_reasons": last["request_reasons"] ?? NSNull(), "turn_tokens": last["turn_tokens"] ?? NSNull(),
            "estimated_cost_usd": last["estimated_cost_usd"] ?? NSNull(), "audit_keys": last.keys.sorted(),
            "cache_states": (last["requests"] as? [[String: Any]] ?? []).map { $0["cache_state"] ?? NSNull() },
            "request_tokens": (last["requests"] as? [[String: Any]] ?? []).map { $0["tokens"] ?? NSNull() },
        ])
    }

    /// 応答を待っている間に止める。止めてから返るまでの時間を見る。
    private func interruptDuringWait(runner: any TurnRunning, composer: TurnComposer) async throws {
        let (ledger, ids) = try await makeLedger()
        let step = Self.steps[0]
        let plan = try await plan(step: step, target: ids[0], ledger: ledger, composer: composer)
        try await control(["scenario": "\(runnerName)/fault-interrupt/\(step.name)", "mode": "script", "faults": [["kind": "first_byte_delay", "seconds": 6]]])
        try WorkspaceStager.prepare(plan: plan, assets: assets)
        let started = Date()
        let task = Task { try await runner.run(plan) { _ in } }
        try await Task.sleep(for: .seconds(2))
        await runner.interrupt(planID: plan.id)
        let outcome = try await task.value
        let ended = Date()
        WorkspaceStager.cleanup(plan: plan)
        record(outcome, set: "fault-interrupt", step: step.name, kind: plan.kind.rawValue, started: started, ended: ended, progress: [])
    }
}

// MARK: - 構造化ターンの各種(`structured`)

extension RunnerComparisonLiveTests {
    /// 構造化の依頼の的(問題集の答案・組んでいる一枚・グラフの依頼)。
    fileprivate struct StructuredTargets: Sendable {
        let captureID: String
        let setID: String
        let graphID: String
    }

    fileprivate static let structuredKinds: [String] = ["timeline_graph", "workbook_grading", "workbook_set", "workbook_unit", "onboarding_grading", "onboarding_plan"]

    /// 決まった文を書いた紙の写真(両方の版で同じ画像になるよう、毎回同じに描く)。
    fileprivate static func jpeg(lines: [String]) -> Data {
        let size: CGSize = CGSize(width: 640, height: 480)
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 40, y: 80 + CGFloat(index) * 60),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor.black])
            }
        }
    }

    @discardableResult
    fileprivate static func writeCapture(_ name: String, lines: [String]) throws -> Data {
        let data: Data = jpeg(lines: lines)
        try data.write(to: StruisPaths.captures.appendingPathComponent(name), options: .atomic)
        return data
    }

    fileprivate static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func orNull(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }

    /// タイムラインの台帳(`makeLedger`)に、問題集の単元(撮った答案のある一枚と、組んでいる一枚)とグラフの依頼を足す。
    fileprivate func makeStructuredLedger() async throws -> (ledger: Ledger, targets: StructuredTargets) {
        let (ledger, _): (Ledger, [String]) = try await makeLedger()
        let sheet: Data = try Self.writeCapture("compare-sheet.jpg", lines: ["問1 (1, -1)", "問2 (2, -4)", "問3 (3, -9)"])
        try Self.writeCapture("compare-trial.jpg", lines: ["x^2 - 5x + 6 = 0", "(x - 2)(x - 3) = 0", "x = 2, 3"])
        try Self.writeCapture("compare-material.jpg", lines: ["期末テストの範囲", "二次関数 p.40-62", "平方完成・最大と最小"])
        let sheetSHA: String = Self.sha256(sheet)
        let sheetBytes: Int = sheet.count
        let targets: StructuredTargets = try await ledger.commit { db in
            var workbook: WorkbookMachine = try WorkbookMachine(loading: db)
            var counter: Int = 0
            workbook.newID = { counter += 1; return "compare-wb-\(counter)" }
            workbook.now = { TimelineFixture.now }
            let unitID: String = workbook.createUnit(
                title: "二次関数", outcome: "二次関数の基本問題が自力で解ける", source: "consult",
                subunits: [WorkbookMachine.SubunitSpec(title: "頂点の座標が求められる", outcome: "平方完成で頂点を求める", n: 3, scoringUnit: "1問ごとに正誤")],
                overview: .object(["unit_title": .string("二次関数"), "outcome": .string("二次関数の基本問題が自力で解ける")]), firstStage: 4
            )
            let subunitID: String = workbook.orderedSubunits(unitID: unitID)[0].id
            // 撮った答案のある一枚(判定の依頼)。
            let openSpec: WorkbookMachine.SetSpec = try workbook.nextSetSpec(subunitID: subunitID)
            let openSet: String = workbook.insertGeneratingSet(subunitID: subunitID, spec: openSpec)
            let problems: [WorkbookMachine.ProblemSpec] = (1...3).map { index in
                WorkbookMachine.ProblemSpec(prompt: "演習 \(index): y = x^2 - \(2 * index)x の頂点の座標を求めよ")
            }
            let problemIDs: [String] = workbook.addProblems(subunitID: subunitID, problems: problems, source: "generated")
            workbook.fillSet(setID: openSet, problemIDs: problemIDs)
            let captureID: String = "compare-wb-capture"
            _ = try workbook.createCapture(id: captureID, imagePath: "compare-sheet.jpg", contentType: "image/jpeg", sha256: sheetSHA,
                                           byteCount: sheetBytes, subunitID: nil, setID: openSet)
            // 組んでいる一枚(一枚の依頼)。
            let nextSpec: WorkbookMachine.SetSpec = try workbook.nextSetSpec(subunitID: subunitID)
            let generating: String = workbook.insertGeneratingSet(subunitID: subunitID, spec: nextSpec)
            // グラフの依頼(初めて開いた時の 1 段目の分解)。
            var timeline: TimelineMachine = try TimelineMachine(loading: db)
            var graphID: String = ""
            if let skill: TimelineSkillRecord = timeline.skills["fourier.antiderivative_trig"] {
                let request: LedgerJSON = TimelineTurns.decomposeRequest(mode: "build", nodes: [skill], units: ["u-compare"], depth: 1,
                                                                         workbook: workbook, timeline: timeline, profile: nil)
                graphID = timeline.insertBatchRequest(purpose: "graph_build", request: request, accuracy: nil, levelCap: nil)
            }
            return (workbook.events + timeline.events, StructuredTargets(captureID: captureID, setID: generating, graphID: graphID))
        }
        return (ledger, targets)
    }

    /// 構造化ターンの各種を 1 回ずつ流す。場面は `<版>/structured/<種類>`。
    fileprivate func runStructured(runner: any TurnRunning, composer: TurnComposer) async throws {
        let (ledger, targets): (Ledger, StructuredTargets) = try await makeStructuredLedger()
        let problem: TrialProblem = TrialProblem(
            id: "compare-trial", grade: "中3", unit: "二次方程式", prompt: "次の二次方程式を解きなさい。", math: "x^2 - 5x + 6 = 0",
            answer: "x = 2, 3", rubric: ["因数分解できている", "解を 2 つとも書いている"]
        )
        let planRequest: LedgerJSON = .object([
            "task": .string("onboarding_plan"), "route": .string("range"), "grade": .string("中3"), "unit": .string("二次関数"),
            "until_test": .string("2週間"),
            "trial": .array([.object(["problem": .string(problem.label), "correct": .bool(true), "learner_answer": .string("x = 2, 3"),
                                      "comment": .string("因数分解で解けている")])]),
            "material_count": .number(1),
        ])
        for kind in Self.structuredKinds {
            let (workbook, timeline): (WorkbookMachine, TimelineMachine) = try await machines(ledger)
            let planID: String = "compare-\(kind.replacingOccurrences(of: "_", with: "-"))-\(UUID().uuidString.prefix(8).lowercased())"
            let plan: TurnPlan
            switch kind {
            case "timeline_graph":
                plan = try await TimelineTurns.graph(composer: composer, planID: planID, batchID: targets.graphID, workbook: workbook, timeline: timeline)
            case "workbook_grading":
                plan = try await composer.grading(planID: planID, machine: workbook, captureID: targets.captureID).plan
            case "workbook_set":
                plan = try await composer.set(planID: planID, machine: workbook, setID: targets.setID)
            case "workbook_unit":
                plan = try await composer.unit(planID: planID, machine: workbook, request: "一次方程式の文章題(中学1年)")
            case "onboarding_grading":
                plan = try await OnboardingTurns.gradingPlan(assets: assets, planID: planID, problem: problem, imagePath: "compare-trial.jpg")
            default:
                plan = try await OnboardingTurns.planPlan(assets: assets, planID: planID, request: planRequest, imagePaths: ["compare-material.jpg"])
            }
            try await control(["scenario": "\(runnerName)/structured/\(kind)", "mode": "script", "faults": [[String: Any]]()])
            _ = try await timedRun(plan, set: "structured", step: kind, runner: runner)
        }
    }
}

// MARK: - 会話(`chat`)

extension RunnerComparisonLiveTests {
    fileprivate struct Reply: Sendable {
        var message: MessageRecord?
        var turn: TurnRecord?
        var timedOut: Bool
    }

    fileprivate static let chatThreadID: String = "30000000-0000-0000-0000-000000000001"
    /// 1 つの返事を待つ長さ。
    fileprivate static let replyTimeout: TimeInterval = 120

    /// 本物の `TurnCoordinator` で 1 つの会話を進める(場面の順番は両方の版で同じ)。
    @MainActor
    fileprivate func runChat(runner initial: any TurnRunning) async throws {
        // 記憶の机は端末に 1 つで、前の回(もう一方の版)の記憶が残っている。空から始める。
        try? FileManager.default.removeItem(at: ChatTurns.desk)
        try StruisPaths.prepare()
        let ledger: Ledger = try Ledger.inMemory()
        let threadID: String = Self.chatThreadID
        try await ledger.commit { db in
            let created: LedgerEvent = ChatRepository.createThread(id: threadID, title: "比較の会話").1
            return ([created], ())
        }
        var runner: any TurnRunning = initial
        var turns: TurnCoordinator = TurnCoordinator(ledger: ledger, assets: assets, runner: runner)
        try await chatTurn(turns, ledger: ledger, threadID: threadID, step: "reply", text: "二次関数の頂点の求め方を教えて")
        try await chatTurn(turns, ledger: ledger, threadID: threadID, step: "photo", text: "写真の式の頂点を求めたいです。どこから始めればいいですか",
                           attachments: [try Self.chatAttachment()])
        try await chatTurn(turns, ledger: ledger, threadID: threadID, step: "tool", text: "作業フォルダの資料も確かめて、y = x^2 - 4x + 3 の頂点を説明して")
        try await chatTurn(turns, ledger: ledger, threadID: threadID, step: "continue", text: "続けて、平方完成の手順をもう一度まとめてください")
        try await chatTurn(turns, ledger: ledger, threadID: threadID, step: "delegate", text: "前の会話の記録を調べて、私が最初に何を聞いたか確認して")
        // アプリを開き直したことにする(同じ台帳・同じ会話のまま、版と調整役を作り直す)。
        runner = try await relaunch(runner)
        turns = TurnCoordinator(ledger: ledger, assets: assets, runner: runner)
        try await chatTurn(turns, ledger: ledger, threadID: threadID, step: "restart", text: "前に何を聞いたか覚えていますか")
        // 最初の応答が 6 秒届かない間に、2 秒で止める。
        try await chatTurn(turns, ledger: ledger, threadID: threadID, step: "interrupt", text: "y = 2x^2 + 8x + 5 の頂点を求める手順を教えて",
                           faults: [["kind": "first_byte_delay", "seconds": 6]]) { turns in
            try await Task.sleep(for: .seconds(2))
            await turns.interruptChat(threadID: threadID)
        }
        try await chatTurn(turns, ledger: ledger, threadID: threadID, step: "interrupt-next", text: "止めた質問に、もう一度短く答えてください")
        try await chatTurn(turns, ledger: ledger, threadID: threadID, step: "drop", text: "グラフの軸の方程式はどう求めますか",
                           faults: [["kind": "drop", "after": "text_delta"]])
        try await runFork(runner: runner)
    }

    /// 学習者の写真の添付(アプリと同じく `ChatTurns.attachmentsRoot` の下に置く)。
    fileprivate static func chatAttachment() throws -> ChatTurns.Attachment {
        let relative: String = "compare-photo/1-photo.jpg"
        let url: URL = ChatTurns.attachmentsRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data: Data = jpeg(lines: ["y = x^2 - 6x + 5", "頂点は?"])
        try data.write(to: url, options: .atomic)
        return ChatTurns.Attachment(filename: "photo.jpg", contentType: "image/jpeg", bytes: data.count, relativePath: relative,
                                    sha256: sha256(data), kind: "image")
    }

    /// 場面を切り替えてから 1 つ送り、返事が終わるまで待って記録する。`during` は送った直後に行うこと(止めるなど)。
    @discardableResult
    fileprivate func chatTurn(_ turns: TurnCoordinator, ledger: Ledger, threadID: String, step: String, text: String,
                              attachments: [ChatTurns.Attachment] = [], faults: [[String: Any]] = [],
                              during: ((TurnCoordinator) async throws -> Void)? = nil) async throws -> Reply {
        try await control(["scenario": "\(runnerName)/chat/\(step)", "mode": "script", "faults": faults])
        let started: Date = Date()
        let sent: TurnCoordinator.ChatSendResult = try await turns.sendChat(
            TurnCoordinator.ChatSend(threadID: threadID, text: text, attachments: attachments, workbookView: nil)
        )
        if let during { try await during(turns) }
        let reply: Reply = try await waitForReply(turns, ledger: ledger, threadID: threadID, assistantMessageID: sent.assistantMessageID, turnID: sent.turnID)
        recordChat(step: step, reply: reply, started: started, ended: Date())
        XCTAssertFalse(reply.timedOut, "\(step): 返事が \(Int(Self.replyTimeout)) 秒で終わらない")
        return reply
    }

    /// 返事の吹き出しとターンの記録が両方とも終わり、会話が空くまで待つ(空く前に次を送ると「前の返信を待っています」になる)。
    fileprivate func waitForReply(_ turns: TurnCoordinator, ledger: Ledger, threadID: String, assistantMessageID: String, turnID: String?) async throws -> Reply {
        let deadline: Date = Date().addingTimeInterval(Self.replyTimeout)
        var latest: Reply = Reply(message: nil, turn: nil, timedOut: true)
        while Date() < deadline {
            let rows: (message: MessageRecord?, turn: TurnRecord?) = try await ledger.read { db in
                let message: MessageRecord? = try MessageRecord.fetchOne(db, key: assistantMessageID)
                let turn: TurnRecord?
                if let turnID {
                    turn = try TurnRecord.fetchOne(db, key: turnID)
                } else {
                    turn = try TurnRecord.filter(Column("target_id") == assistantMessageID).fetchOne(db)
                }
                return (message: message, turn: turn)
            }
            latest = Reply(message: rows.message, turn: rows.turn, timedOut: true)
            let messageDone: Bool = ["completed", "failed"].contains(rows.message?.status ?? "")
            let turnDone: Bool = ["completed", "failed", "interrupted"].contains(rows.turn?.status ?? "")
            let running: Bool = await turns.isChatRunning(threadID: threadID)
            if messageDone, turnDone, !running {
                latest.timedOut = false
                return latest
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return latest
    }

    /// 会話の 1 場面の結果(`record` と同じ項目に、ターンの記録の実行監査を足す)。
    fileprivate func recordChat(step: String, reply: Reply, started: Date, ended: Date, extra: [String: Any] = [:]) {
        let executions: [[String: Any]] = (reply.turn?.executions.arrayValue ?? []).compactMap { $0.any as? [String: Any] }
        let last: [String: Any] = executions.last ?? [:]
        let requests: [[String: Any]] = last["requests"] as? [[String: Any]] ?? []
        let error: String? = reply.message?.metadata["error"]?.stringValue ?? reply.turn?.error
        let status: String = reply.timedOut ? "timeout" : (reply.message?.status ?? "missing")
        var entry: [String: Any] = [
            "set": "chat", "step": step, "kind": reply.turn?.kind ?? TurnPlan.Kind.chat.rawValue, "status": status,
            "turn_status": reply.turn?.status ?? "missing", "rounds": reply.turn?.round ?? 0,
            "final_text": reply.message?.plainText ?? "", "error": Self.orNull(error),
            "error_detail": Self.orNull(reply.message?.metadata["error_detail"]?.stringValue),
            "elapsed_ms": Int(ended.timeIntervalSince(started) * 1000),
            "started_at": started.timeIntervalSince1970, "ended_at": ended.timeIntervalSince1970, "progress": [String](),
        ]
        let audit: [String: Any] = [
            "execution_count": executions.count, "execution_statuses": executions.map { $0["status"] ?? NSNull() },
            "audit_status": last["status"] ?? NSNull(), "request_reasons": last["request_reasons"] ?? NSNull(),
            "turn_tokens": last["turn_tokens"] ?? NSNull(), "estimated_cost_usd": last["estimated_cost_usd"] ?? NSNull(),
            "audit_keys": last.keys.sorted(),
            "cache_states": requests.map { $0["cache_state"] ?? NSNull() },
            "request_tokens": requests.map { $0["tokens"] ?? NSNull() },
        ]
        entry.merge(audit) { _, new in new }
        entry.merge(extra) { _, new in new }
        results.append(entry)
    }

    /// 段階 1 の小単元を起こし(要点の返事)、返事の後に `thread_fork` の上で先回りする段階 2 の例題ができるまで待つ。
    /// 起動の返事と先回りの要求は、同じ場面 `<版>/chat/fork` に順に記録される。
    @MainActor
    fileprivate func runFork(runner: any TurnRunning) async throws {
        let ledger: Ledger = try Ledger.inMemory()
        let turns: TurnCoordinator = TurnCoordinator(ledger: ledger, assets: assets, runner: runner)
        let subunitID: String = try await ledger.commit { db in
            var machine: WorkbookMachine = try WorkbookMachine(loading: db)
            var counter: Int = 0
            machine.newID = { counter += 1; return "compare-fork-\(counter)" }
            let unitID: String = machine.createUnit(
                title: "二次関数", outcome: "二次関数の基本問題が自力で解ける", source: "consult",
                subunits: [WorkbookMachine.SubunitSpec(title: "頂点の座標が求められる", outcome: "平方完成で頂点を求める", n: 5, scoringUnit: "1問ごとに正誤")],
                firstStage: 1
            )
            return (machine.events, machine.orderedSubunits(unitID: unitID)[0].id)
        }
        try await control(["scenario": "\(runnerName)/chat/fork", "mode": "script", "faults": [[String: Any]]()])
        let started: Date = Date()
        let kickoff: TurnCoordinator.KickoffResult = await turns.kickoffSubunit(subunitID: subunitID)
        let threadID: String = try await turns.subunitThread(subunitID: subunitID)
        let assistantID: String? = try await ledger.read { db in
            try ChatRepository.messages(db, threadID: threadID).last(where: { $0.role == "assistant" })?.id
        }
        guard let assistantID else {
            recordChat(step: "fork", reply: Reply(message: nil, turn: nil, timedOut: false), started: started, ended: Date(),
                       extra: ["kickoff": String(describing: kickoff)])
            XCTFail("fork: 小単元の起動の返事が無い(\(kickoff))")
            return
        }
        let reply: Reply = try await waitForReply(turns, ledger: ledger, threadID: threadID, assistantMessageID: assistantID, turnID: nil)
        let replied: Date = Date()
        var prefetch: ExamplePrefetch?
        let deadline: Date = replied.addingTimeInterval(Self.replyTimeout)
        while Date() < deadline {
            let current: ExamplePrefetch? = await turns.examplePrefetches[subunitID]
            if current?.ready == true {
                prefetch = current
                break
            }
            // 先回りを始めない・捨てた(作っている途中も無い)なら、少し待ってから諦める。
            let task: Task<Void, Never>? = await turns.examplePrefetchTasks[subunitID]
            if current == nil, task == nil, Date().timeIntervalSince(replied) > 5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let ended: Date = Date()
        recordChat(step: "fork", reply: reply, started: started, ended: ended, extra: [
            "kickoff": String(describing: kickoff), "prefetch_ready": prefetch?.ready ?? false,
            "prefetch_example": Self.orNull(prefetch?.state.exampleProblem), "prefetch_text": prefetch?.state.visibleText ?? "",
            "prefetch_execution_count": prefetch?.state.executions.count ?? 0,
            "prefetch_ms": Int(ended.timeIntervalSince(replied) * 1000),
        ])
        XCTAssertTrue(prefetch?.ready == true, "fork: 先回りの例題ができない")
    }
}

/// 待ちの表示の出来事を、届いた順に残す。
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func add(_ event: TurnProgressEvent) {
        let kind: String = switch event.kind {
        case .activity: "activity"
        case .commentary: "commentary"
        case .replyDelta: "replyDelta"
        case .reasoningSummary: "reasoning"
        case .compaction: "compaction"
        case .delegation: "delegation"
        case .waitingForModel: "waiting"
        case .partialResult: "partial"
        }
        lock.withLock { values.append(kind + ":" + event.label) }
    }

    var labels: [String] { lock.withLock { values } }
}
