import UIKit
import XCTest
@testable import strius

/// 答えの読み取り(Issue #101、`timeline_answer`)と、いつもの採点(`timeline_grading`)の待ち時間と費用を、本物の Claude で
/// 比べる。手で流す測定で、CI の門には入れない(キーが無ければ飛ばす)。
///
///     TEST_RUNNER_STRUIS_ANSWER_LIVE_OUT=<結果を書くフォルダー>
///     TEST_RUNNER_STRUIS_DEBUG_ANTHROPIC_KEY_FILE=<キーのファイル>(Dev Box なら "$DEVBOX_ANTHROPIC_KEY_FILE")
///     TEST_RUNNER_STRUIS_PLAN=generous TEST_RUNNER_STRUIS_USAGE_PERCENT=0
///     [TEST_RUNNER_STRUIS_ANSWER_LIVE_ITERATIONS=3]
///
/// 正しい答案と、答えが違う答案(符号の誤り)を 1 枚ずつ描き、それぞれ読み取りと採点を交互に回す。採点は同じ先頭
/// (基本指示・今日の記録)を使うので、2 回目からはキャッシュの読み込みになる(アプリで続けて解いた時と同じ)。
/// 結果は `<出力>/answer-live.json` に 1 回ずつ(種類・答案・ミリ秒・最初の文字までのミリ秒・費用・トークン・返事)。
final class TimelineAnswerLiveTests: XCTestCase {
    typealias F = TimelineFixture

    private static let captures: [(name: String, lines: [String])] = [
        ("answer-live-correct.jpg", ["y = 2x² - 8x + 3", "= 2(x² - 4x) + 3", "= 2(x - 2)² - 5", "最小値 -5"]),
        ("answer-live-wrong.jpg", ["y = 2x² - 8x + 3", "= 2(x² - 4x) + 3", "= 2(x - 2)² + 5", "最小値 5"]),
    ]

    private static func jpeg(lines: [String]) -> Data {
        let size = CGSize(width: 640, height: 480)
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 40, y: 80 + CGFloat(index) * 70),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 34), .foregroundColor: UIColor.black])
            }
        }
    }

    @MainActor
    func testAnswerReadAgainstTheUsualGrading() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = environment["STRUIS_ANSWER_LIVE_OUT"] ?? ""
        try XCTSkipIf(output.isEmpty, "TEST_RUNNER_STRUIS_ANSWER_LIVE_OUT が無い(本物の Claude での測定は手動)")
        let iterations = Int(environment["STRUIS_ANSWER_LIVE_ITERATIONS"] ?? "") ?? 3
        let out = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        try StruisPaths.prepare()
        for capture in Self.captures {
            try Self.jpeg(lines: capture.lines).write(to: StruisPaths.captures.appendingPathComponent(capture.name), options: .atomic)
        }
        let ledger = try Ledger.inMemory()
        let attemptIDs: [String] = try await ledger.commit { db in
            let unit = WorkbookUnitRecord(id: "u-live", title: "二次関数", outcome: "", status: "active", source: "manual", position: 0,
                                          overview: .emptyObject, createdAt: F.now, updatedAt: F.now, passedAt: nil)
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", F.skill("quadratic.complete_square"))
            var ids: [String] = []
            for (index, capture) in Self.captures.enumerated() {
                var card = F.card("live\(index)", skills: ["quadratic.complete_square"])
                card.prompt = "次の関数の最小値を求めなさい。"
                card.math = "y = 2x^2 - 8x + 3"
                card.answerKey = "-5"
                card.answerExpr = "-5"
                card.payload = .object(["steps": .array(["y = 2x^2 - 8x + 3", "= 2(x - 2)^2 - 5", "最小値 -5"].map(LedgerJSON.string))])
                timeline.put("test", card)
                ids.append(timeline.recordCapture(cardID: card.id, capturePath: capture.name, seconds: 40, assisted: false))
            }
            return ([.upsert("test", unit)] + timeline.events, ids)
        }

        let assets = AssetCache()
        let composer = TurnComposer(assets: assets)
        let boot = HyotanBoot()
        let runner = ClaudeTurnRunner(assets: assets, conversations: try ClaudeConversationStore.temporary()) {
            await boot.start()
            await NativeRuntimeHost.shared.prepareForCommands()
        }
        await runner.warmUp()

        var rows: [[String: Any]] = []
        for iteration in 1...iterations {
            for (index, attemptID) in attemptIDs.enumerated() {
                for kind in [TurnPlan.Kind.timelineAnswer, .timelineGrading] {
                    let (workbook, timeline): (WorkbookMachine, TimelineMachine) = try await ledger.commit { db in
                        let workbook = try WorkbookMachine(loading: db)
                        var timeline = try TimelineMachine(loading: db)
                        TimelineTurns.syncLog(workbook: workbook, timeline: &timeline)
                        return (timeline.events, (workbook, timeline))
                    }
                    let planID = "live-\(kind.rawValue)-\(iteration)-\(index)"
                    let plan: TurnPlan = kind == .timelineAnswer
                        ? try await TimelineTurns.answer(composer: composer, planID: planID, attemptID: attemptID, timeline: timeline)
                        : try await TimelineTurns.grading(composer: composer, planID: planID, attemptID: attemptID, workbook: workbook, timeline: timeline)
                    let outcome = try await runner.run(plan) { _ in }
                    let execution: LedgerJSON = outcome.executions.last ?? .emptyObject
                    var matched: Any = NSNull()
                    if kind == .timelineAnswer, let read = try? TimelineTurns.AnswerRead.parse(outcome.finalText), let card = timeline.cards[timeline.attempts[attemptID]?.cardId ?? ""] {
                        matched = TimelineTurns.answerMatches(read, card: card)
                    }
                    let row: [String: Any] = [
                        "iteration": iteration, "capture": Self.captures[index].name, "kind": kind.rawValue, "status": outcome.status.rawValue,
                        "model": plan.thread.model, "effort": plan.thread.effort,
                        "elapsed_ms": outcome.elapsedMs, "first_text_ms": execution["first_text_ms"]?.intValue as Any? ?? NSNull(),
                        "estimated_cost_usd": execution["estimated_cost_usd"]?.doubleValue as Any? ?? NSNull(),
                        "turn_tokens": execution["turn_tokens"]?.any ?? NSNull(),
                        "matched": matched, "final_text": outcome.finalText, "error": outcome.error ?? NSNull(),
                    ]
                    rows.append(row)
                    print("answer-live \(kind.rawValue) \(Self.captures[index].name) #\(iteration): \(outcome.status.rawValue) \(outcome.elapsedMs) ms, $\(execution["estimated_cost_usd"]?.doubleValue ?? -1), matched=\(matched)")
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("answer-live.json"))
        XCTAssertFalse(rows.isEmpty)
    }
}
