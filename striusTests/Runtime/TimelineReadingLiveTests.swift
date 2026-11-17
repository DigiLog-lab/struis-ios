import XCTest
@testable import strius

/// 手書きの答案の読み取りを、本物の Claude でモデルごとに比べる手動の測定(CI の門には入れない。設定が無ければ飛ばす)。
/// 書き出した台帳(設定の「書き出す」の zip、答案の写真入り)を取り込み、写真のある答案ごとに、アプリと同じ組み立てで
/// 答えの読み取り(`timeline_answer`)と採点(`timeline_grading`)を流す。
///
///     TEST_RUNNER_STRUIS_READING_ARCHIVE=<台帳の zip>
///     TEST_RUNNER_STRUIS_READING_OUT=<結果を書くフォルダー>(学習記録が入るので、公開される場所に置かない)
///     TEST_RUNNER_STRUIS_READING_MODEL=claude-sonnet-5-5 | claude-haiku-5-5
///     TEST_RUNNER_STRUIS_READING_KIND=timeline_answer | timeline_grading | pipeline
///     (pipeline: アプリと同じ順に、読み取り(Sonnet)→ 一致しなければ書き写しを付けて採点(設定のモデル)。答案は採点前の状態に戻して流す)
///     TEST_RUNNER_STRUIS_DEBUG_ANTHROPIC_KEY_FILE=<キーのファイル>
///     TEST_RUNNER_STRUIS_PLAN=generous TEST_RUNNER_STRUIS_USAGE_PERCENT=0
///     [TEST_RUNNER_STRUIS_READING_CONCURRENCY=3] [TEST_RUNNER_STRUIS_READING_LIMIT=<件数>]
///
/// 結果は `<出力>/reading-<kind>-<model>.json`(答案ごとに 1 行)。標準出力には件数と費用の合計だけを出す。
final class TimelineReadingLiveTests: XCTestCase {
    @MainActor
    func testReadingAcrossModels() async throws {
        let environment = ProcessInfo.processInfo.environment
        let archive = environment["STRUIS_READING_ARCHIVE"] ?? ""
        let output = environment["STRUIS_READING_OUT"] ?? ""
        try XCTSkipIf(archive.isEmpty || output.isEmpty, "TEST_RUNNER_STRUIS_READING_ARCHIVE / _OUT が無い(手動の測定)")
        let model = environment["STRUIS_READING_MODEL"] ?? "claude-sonnet-5-5"
        let kindName = environment["STRUIS_READING_KIND"] ?? ""
        let pipeline = kindName == "pipeline"
        let kind = TurnPlan.Kind(rawValue: kindName) ?? (pipeline ? .timelineGrading : .timelineAnswer)
        let concurrency = max(1, Int(environment["STRUIS_READING_CONCURRENCY"] ?? "") ?? 3)
        let limit = Int(environment["STRUIS_READING_LIMIT"] ?? "") ?? Int.max
        let out = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        try StruisPaths.prepare()
        let ledger = try Ledger.inMemory()
        try await LedgerArchive.importArchive(from: URL(fileURLWithPath: archive), into: ledger)
        // 採点の道具(答案の拡大・台帳の問い合わせ)が、取り込んだ台帳を読むようにする(アプリでは LearnerData が入れる)。
        TimelineQueryHost.install(ledger)
        let (workbook, timeline): (WorkbookMachine, TimelineMachine) = try await ledger.commit { db in
            let workbook = try WorkbookMachine(loading: db)
            var timeline = try TimelineMachine(loading: db)
            TimelineTurns.syncLog(workbook: workbook, timeline: &timeline)
            return (timeline.events, (workbook, timeline))
        }
        let attempts = timeline.attempts.values
            .filter { attempt in
                guard let path = attempt.capturePath, timeline.cards[attempt.cardId] != nil else { return false }
                return FileManager.default.fileExists(atPath: StruisPaths.captures.appendingPathComponent(path).path)
            }
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(limit)
        print("reading-live: \(attempts.count) answers with photos, model=\(model), kind=\(kind.rawValue)")

        let assets = AssetCache(timelineClaudeModel: { model })
        let composer = TurnComposer(assets: assets)
        let boot = HyotanBoot()
        let runner = ClaudeTurnRunner(assets: assets, conversations: try ClaudeConversationStore.temporary()) {
            await boot.start()
            await NativeRuntimeHost.shared.prepareForCommands()
        }
        await runner.warmUp()

        let context = Context(composer: composer, runner: runner, workbook: workbook, timeline: timeline, model: model, kind: kind,
                              ledger: ledger, pipeline: pipeline)
        var rows: [[String: Any]] = []
        var pending = Array(attempts)
        await withTaskGroup(of: Data.self) { group in
            for _ in 0..<min(concurrency, pending.count) {
                let next = pending.removeFirst()
                group.addTask { context.pipeline ? await Self.runPipeline(next, context: context) : await Self.run(next, context: context) }
            }
            while let data = await group.next() {
                if let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { rows.append(row) }
                if !pending.isEmpty {
                    let next = pending.removeFirst()
                    group.addTask { context.pipeline ? await Self.runPipeline(next, context: context) : await Self.run(next, context: context) }
                }
            }
        }

        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("reading-\(pipeline ? "pipeline" : kind.rawValue)-\(model).json"))
        let cost = rows.compactMap { $0["estimated_cost_usd"] as? Double }.reduce(0, +) + rows.compactMap { $0["read_cost_usd"] as? Double }.reduce(0, +)
        let completed = rows.filter { ($0["status"] as? String) == "completed" }.count
        print("reading-live: done \(rows.count) rows, completed \(completed), cost $\(String(format: "%.4f", cost))")
        XCTAssertEqual(rows.count, attempts.count)
    }

    /// 並べて流す読み取りに渡すもの(測定だけで使う。中身は読むだけ)。
    nonisolated final class Context: @unchecked Sendable {
        let composer: TurnComposer
        let runner: ClaudeTurnRunner
        let workbook: WorkbookMachine
        let timeline: TimelineMachine
        let model: String
        let kind: TurnPlan.Kind
        let ledger: Ledger
        let pipeline: Bool
        init(composer: TurnComposer, runner: ClaudeTurnRunner, workbook: WorkbookMachine, timeline: TimelineMachine, model: String, kind: TurnPlan.Kind,
             ledger: Ledger, pipeline: Bool) {
            self.ledger = ledger
            self.pipeline = pipeline
            self.composer = composer
            self.runner = runner
            self.workbook = workbook
            self.timeline = timeline
            self.model = model
            self.kind = kind
        }
    }

    /// 1 枚の答案を流し、結果の 1 行を JSON で返す。
    nonisolated static func run(_ attempt: TimelineAttemptRecord, context: Context) async -> Data {
        let kind = context.kind
        var row: [String: Any] = ["attempt_id": attempt.id, "card_id": attempt.cardId, "capture": attempt.capturePath ?? "",
                                  "model": context.model, "kind": kind.rawValue]
        do {
            // 画像だけの採点を測る: 書き出した台帳の答案には前の採点の書き起こしが残っているので、採点前の状態に戻す。
            var timeline = context.timeline
            if var fresh = timeline.attempts[attempt.id] {
                fresh.verdict = "grading"; fresh.transcript = nil; fresh.learnerAnswer = ""
                timeline.put("test.reset", fresh)
            }
            let planID = "reading-\(kind.rawValue)-\(attempt.id)"
            var plan: TurnPlan = kind == .timelineAnswer
                ? try await TimelineTurns.answer(composer: context.composer, planID: planID, attemptID: attempt.id, timeline: timeline)
                : try await TimelineTurns.grading(composer: context.composer, planID: planID, attemptID: attempt.id,
                                                  workbook: context.workbook, timeline: timeline)
            // 読み取りだけを測る時は、指定したモデルで流す(アプリの読み取りは `TimelineModels.readerModel` に固定)。
            if kind == .timelineAnswer { plan.thread.model = context.model }
            let outcome = try await context.runner.run(plan) { _ in }
            let execution: LedgerJSON = outcome.executions.last ?? .emptyObject
            row["status"] = outcome.status.rawValue
            row["elapsed_ms"] = outcome.elapsedMs
            row["estimated_cost_usd"] = execution["estimated_cost_usd"]?.doubleValue as Any? ?? NSNull()
            row["actual_model"] = execution["actual_model"]?.stringValue as Any? ?? NSNull()
            row["turn_tokens"] = execution["turn_tokens"]?.any ?? NSNull()
            row["final_text"] = outcome.finalText
            row["error"] = outcome.error ?? NSNull()
            if kind == .timelineAnswer, let read = try? TimelineTurns.AnswerRead.parse(outcome.finalText),
               let card = context.timeline.cards[attempt.cardId] {
                row["matched_key"] = TimelineTurns.answerMatches(read, card: card)
            }
        } catch {
            row["status"] = "thrown"
            row["error"] = String(describing: error)
        }
        return (try? JSONSerialization.data(withJSONObject: row)) ?? Data("{}".utf8)
    }

    /// アプリと同じ順に流す: 答案を採点前に戻し、読み取り → 反映 → 一致しなければ採点。
    nonisolated static func runPipeline(_ attempt: TimelineAttemptRecord, context: Context) async -> Data {
        var row: [String: Any] = ["attempt_id": attempt.id, "card_id": attempt.cardId, "capture": attempt.capturePath ?? "",
                                  "model": context.model, "kind": "pipeline"]
        do {
            let reset: TimelineMachine = try await context.ledger.commit { db in
                var timeline = try TimelineMachine(loading: db)
                guard var fresh = timeline.attempts[attempt.id] else { return ([], timeline) }
                fresh.verdict = "grading"; fresh.grade = nil; fresh.transcript = nil; fresh.learnerAnswer = ""; fresh.notes = nil
                timeline.put("test.reset", fresh)
                return (timeline.events, timeline)
            }
            let readPlan = try await TimelineTurns.answer(composer: context.composer, planID: "pipe-read-\(attempt.id)", attemptID: attempt.id, timeline: reset)
            let read = try await context.runner.run(readPlan) { _ in }
            let readExecution: LedgerJSON = read.executions.last ?? .emptyObject
            row["read_model"] = readPlan.thread.model
            row["read_text"] = read.finalText
            row["read_cost_usd"] = readExecution["estimated_cost_usd"]?.doubleValue as Any? ?? NSNull()
            row["read_ms"] = read.elapsedMs
            let followUp: TimelineTurns.FollowUp = try await context.ledger.commit { db in
                let applied = try TimelineTurns.apply(kind: .timelineAnswer, targetID: attempt.id, outcome: read, model: readPlan.thread.model, db: db)
                return (applied.events, applied.followUp)
            }
            guard followUp.grading == attempt.id else {
                row["status"] = "matched"
                row["grade"] = "correct"
                return (try? JSONSerialization.data(withJSONObject: row)) ?? Data("{}".utf8)
            }
            let (workbook, timeline): (WorkbookMachine, TimelineMachine) = try await context.ledger.read { db in
                (try WorkbookMachine(loading: db), try TimelineMachine(loading: db))
            }
            row["used_transcript"] = timeline.attempts[attempt.id].map(TimelineTurns.usesReaderTranscript) ?? false
            let plan = try await TimelineTurns.grading(composer: context.composer, planID: "pipe-grade-\(attempt.id)", attemptID: attempt.id,
                                                       workbook: workbook, timeline: timeline)
            row["images"] = plan.turn?.images.count ?? -1
            let outcome = try await context.runner.run(plan) { _ in }
            let execution: LedgerJSON = outcome.executions.last ?? .emptyObject
            row["status"] = outcome.status.rawValue
            row["elapsed_ms"] = outcome.elapsedMs
            row["estimated_cost_usd"] = execution["estimated_cost_usd"]?.doubleValue as Any? ?? NSNull()
            row["actual_model"] = execution["actual_model"]?.stringValue as Any? ?? NSNull()
            row["final_text"] = outcome.finalText
            row["error"] = outcome.error ?? NSNull()
        } catch {
            row["status"] = "thrown"
            row["error"] = String(describing: error)
        }
        return (try? JSONSerialization.data(withJSONObject: row)) ?? Data("{}".utf8)
    }
}
