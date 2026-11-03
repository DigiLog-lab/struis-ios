import GRDB
import UIKit
import XCTest
@testable import strius

/// Codex 版(`CodexTurnRunner`)と Claude 直結版(`DirectClaudeTurnRunner`)に同じタイムラインの依頼を流し、模擬の
/// Anthropic に届いた要求・結果・時間・メモリを記録する。手で流す測定で、CI の門には入れない(移行が終わったら消す)。
///
/// プロセスを分けて 1 回に 1 つの版だけ動かす(Codex はアプリのプロセスの中で動くので、同じプロセスだとメモリを比べられない)。
///
///     python3 scripts/e2e/fake_anthropic.py --port 8787 --log-dir <dir>/server [--upstream-key-file <key>]
///     TEST_RUNNER_STRUIS_RUNNER_COMPARE_OUT=<dir>/outcomes TEST_RUNNER_STRUIS_RUNNER_COMPARE_RUNNER=codex|direct
///     TEST_RUNNER_STRUIS_RUNNER_COMPARE_SETS=record,normal,replay,faults(既定 normal,faults)
///     TEST_RUNNER_STRUIS_ANTHROPIC_BASE_URL=http://127.0.0.1:8787 TEST_RUNNER_STRUIS_DEBUG_ANTHROPIC_KEY_FILE=<偽のキー>
///     TEST_RUNNER_STRUIS_DEVICE_RUNTIME=0 TEST_RUNNER_STRUIS_PLAN=generous TEST_RUNNER_STRUIS_USAGE_PERCENT=0
///
/// `STRUIS_PLAN`・`STRUIS_USAGE_PERCENT` は端末の利用枠をメモリの中だけの枠に替える。付けないと Keychain に週ごとに溜まる
/// お試しの枠($0.25)を数回で使い切り、以降の依頼が全部「利用枠を使い切りました」で止まる。
///
/// 比べるのは `scripts/e2e/compare_runners.py`。
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

    @MainActor
    func testCompareRunners() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = environment["STRUIS_RUNNER_COMPARE_OUT"] ?? ""
        try XCTSkipIf(output.isEmpty, "TEST_RUNNER_STRUIS_RUNNER_COMPARE_OUT が無い(比較は手動)")
        out = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        runnerName = environment["STRUIS_RUNNER_COMPARE_RUNNER"] ?? "codex"
        baseURL = environment["STRUIS_ANTHROPIC_BASE_URL"] ?? "http://127.0.0.1:8787"
        let sets = (environment["STRUIS_RUNNER_COMPARE_SETS"] ?? "normal,faults").split(separator: ",").map(String.init)
        let iterations = Int(environment["STRUIS_RUNNER_COMPARE_ITERATIONS"] ?? "") ?? 5
        setenv("STRUIS_MODEL_PROVIDER", "anthropic", 1)

        let assets = AssetCache(root: FileManager.default.temporaryDirectory.appendingPathComponent("compare-\(UUID().uuidString)"), lenient: true)
        let composer = TurnComposer(assets: assets)
        let before = StruisMemorySnapshot()
        let began = Date()
        let runner = try await makeRunner(assets: assets)
        let startupMs = CodexTurnRunner.elapsed(began)
        let afterStart = StruisMemorySnapshot()

        // 最初の 1 回だけ、起動の分を含む時間として別に残す(`warm`)。
        try await control(["scenario": "\(runnerName)/warm/grading-1", "mode": "script"])
        _ = try await runSteps(set: "warm", only: 1, mode: "script", tapePrefix: nil, runner: runner, composer: composer)

        if sets.contains("record") {
            // 本物の API に 1 回通して録る。録画は Codex 版だけが作り、両方が同じ録画を再生する。
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
        switch runnerName {
        case "direct":
            let boot = HyotanBoot()
            let runner = DirectClaudeTurnRunner(assets: assets, timeouts: DirectClaudeTurnRunner.Timeouts(messageStall: Self.stall)) {
                await boot.start()
                await NativeRuntimeHost.shared.prepareForCommandsOnly()
            }
            await runner.warmUp()
            return runner
        default:
            let runtime = DeviceRuntime()
            await runtime.start()
            try await runtime.ensureRunning()
            return CodexTurnRunner(session: runtime.session, assets: assets, timeouts: CodexTurnRunner.Timeouts(messageStall: Self.stall)) {
                try await runtime.ensureRunning()
            }
        }
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

    private func plan(step: (name: String, kind: TurnPlan.Kind), target: String, ledger: Ledger, composer: TurnComposer) async throws -> TurnPlan {
        let (workbook, timeline): (WorkbookMachine, TimelineMachine) = try await ledger.commit { db in
            let workbook = try WorkbookMachine(loading: db)
            var timeline = try TimelineMachine(loading: db)
            TimelineTurns.syncLog(workbook: workbook, timeline: &timeline)
            return (timeline.events, (workbook, timeline))
        }
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
        try WorkspaceStager.prepare(plan: plan, assets: AssetCache(lenient: true))
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
        try WorkspaceStager.prepare(plan: plan, assets: AssetCache(lenient: true))
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
