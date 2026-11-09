import GRDB
import UIKit
import XCTest
@testable import strius

/// 書く面の答案の採点(`timeline_grading` に赤ペンの節を足したもの)を、本物の Claude で確かめる。手で流す測定で、CI の門には
/// 入れない(出力先が無ければ飛ばす)。
///
///     TEST_RUNNER_STRUIS_RED_PEN_LIVE_OUT=<結果を書くフォルダー>
///     TEST_RUNNER_STRUIS_DEBUG_ANTHROPIC_KEY_FILE=<キーのファイル>(Dev Box なら "$DEVBOX_ANTHROPIC_KEY_FILE")
///     TEST_RUNNER_STRUIS_PLAN=generous TEST_RUNNER_STRUIS_USAGE_PERCENT=0
///     [TEST_RUNNER_STRUIS_RED_PEN_LIVE_ITERATIONS=2]
///
/// 答えは合うが途中で原始関数の符号を間違えた答案を 1 枚描き、書く面の答案(赤ペンの節あり)と紙を撮った答案(節なし)の名前で
/// 交互に採点する。結果は `<出力>/red-pen-live.json`(判定・赤ペン・答案を取り込んだか・ミリ秒・費用)と、赤ペンの範囲を
/// 答案に描き足した画像 `red-pen-live-<回>.png`。
final class TimelineRedPenLiveTests: XCTestCase {
    typealias F = TimelineFixture

    private static let lines: [String] = [
        "∫(1/2 − 1/2 cos 6x) dx",
        "= [ 1/2 x + 1/12 sin 6x ]  (−π → π)",
        "= 1/2 π − (−1/2 π)",
        "= π",
    ]

    private static func jpeg() -> Data {
        let size = CGSize(width: 720, height: 420)
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.85) { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 40, y: 50 + CGFloat(index) * 85),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 36), .foregroundColor: UIColor.black])
            }
        }
    }

    private static func marked(_ data: Data, marks: [TimelineMachine.RedPenMark]) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return UIGraphicsImageRenderer(size: image.size).pngData { context in
            image.draw(at: .zero)
            UIColor.red.setStroke()
            for mark in marks {
                let path = UIBezierPath(rect: mark.region)
                path.lineWidth = 3
                path.stroke()
            }
        }
    }

    @MainActor
    func testInkAnswerGradingReturnsTheRedPenInTheSameTurn() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = environment["STRUIS_RED_PEN_LIVE_OUT"] ?? ""
        try XCTSkipIf(output.isEmpty, "TEST_RUNNER_STRUIS_RED_PEN_LIVE_OUT が無い(本物の Claude での測定は手動)")
        let iterations = Int(environment["STRUIS_RED_PEN_LIVE_ITERATIONS"] ?? "") ?? 2
        let out = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        try StruisPaths.prepare()
        let image = Self.jpeg()
        let names = [TimelineTurns.inkCapturePrefix + "red-pen-live.jpg", "timeline-red-pen-live.jpg"]
        for name in names { try image.write(to: StruisPaths.captures.appendingPathComponent(name), options: .atomic) }

        var rows: [[String: Any]] = []
        let assets = AssetCache()
        let composer = TurnComposer(assets: assets)
        let boot = HyotanBoot()
        let runner = ClaudeTurnRunner(assets: assets, conversations: try ClaudeConversationStore.temporary()) {
            await boot.start()
            await NativeRuntimeHost.shared.prepareForCommands()
        }
        await runner.warmUp()

        for iteration in 1...iterations {
            for name in names {
                let ledger = try Ledger.inMemory()
                let attemptID: String = try await ledger.commit { db in
                    let unit = WorkbookUnitRecord(id: "u-live", title: "積分", outcome: "", status: "active", source: "manual", position: 0,
                                                  overview: .emptyObject, createdAt: F.now, updatedAt: F.now, passedAt: nil)
                    var timeline = try TimelineMachine(loading: db)
                    timeline.put("test", F.skill("integral.trig_square"))
                    var card = F.card("live", skills: ["integral.trig_square"])
                    card.prompt = "次の定積分の値を求めなさい。必要なら $\\sin^2\\theta = \\frac{1 - \\cos 2\\theta}{2}$ を使いなさい。"
                    card.math = "\\int_{-\\pi}^{\\pi} \\sin^2 3x \\, dx"
                    card.answerKey = "\\pi"
                    card.answerExpr = "\\pi"
                    card.payload = .object(["steps": .array([
                        "\\sin^2 3x = \\frac{1}{2} - \\frac{1}{2}\\cos 6x",
                        "\\int (\\frac{1}{2} - \\frac{1}{2}\\cos 6x) dx = \\frac{1}{2}x - \\frac{1}{12}\\sin 6x",
                        "= \\pi",
                    ].map(LedgerJSON.string))])
                    timeline.put("test", card)
                    let id = timeline.recordCapture(cardID: card.id, capturePath: name, seconds: 120, assisted: false)
                    return ([.upsert("test", unit)] + timeline.events, id)
                }
                // 答案を拡大する道具(`timeline_view_capture`)は、アプリと同じく台帳から答案の画像を引く。
                TimelineQueryHost.install(ledger)
                let (workbook, timeline): (WorkbookMachine, TimelineMachine) = try await ledger.commit { db in
                    let workbook = try WorkbookMachine(loading: db)
                    var timeline = try TimelineMachine(loading: db)
                    TimelineTurns.syncLog(workbook: workbook, timeline: &timeline)
                    return (timeline.events, (workbook, timeline))
                }
                let plan = try await TimelineTurns.grading(composer: composer, planID: "live-red-pen-\(iteration)-\(TimelineTurns.isInkCapture(name) ? "ink" : "photo")", attemptID: attemptID,
                                                           workbook: workbook, timeline: timeline)
                let outcome = try await runner.run(plan) { _ in }
                let viewed = TimelineTurns.viewedCapture(outcome.executions, attemptID: attemptID)
                try await ledger.commit { db in
                    let result = try TimelineTurns.apply(kind: .timelineGrading, targetID: attemptID, outcome: outcome, model: plan.thread.model, db: db)
                    return (result.events, ())
                }
                let attempt: TimelineAttemptRecord? = try await ledger.read { db in try TimelineAttemptRecord.fetchOne(db, key: attemptID) }
                let stored = attempt.map(TimelineMachine.redPenMarks) ?? []
                let returned = (try? TimelineMachine.Grading.parse(outcome.finalText))?.marks ?? []
                let ink = TimelineTurns.isInkCapture(name)
                if ink, let png = Self.marked(image, marks: returned) {
                    try png.write(to: out.appendingPathComponent("red-pen-live-\(iteration).png"))
                }
                let execution: LedgerJSON = outcome.executions.last ?? .emptyObject
                let row: [String: Any] = [
                    "iteration": iteration, "ink": ink, "status": outcome.status.rawValue, "model": plan.thread.model, "effort": plan.thread.effort,
                    "grade": attempt?.grade ?? NSNull(), "viewed_capture": viewed,
                    "returned_marks": returned.map { ["x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height, "correction": $0.correction] },
                    "stored_marks": stored.count, "elapsed_ms": outcome.elapsedMs,
                    "estimated_cost_usd": execution["estimated_cost_usd"]?.doubleValue as Any? ?? NSNull(),
                    "final_text": outcome.finalText, "error": outcome.error ?? NSNull(),
                ]
                rows.append(row)
                if outcome.status != .completed { print("red-pen-live error: \(outcome.error ?? "-") executions=\(outcome.executions) images=\(plan.turn?.images.map(\.hostPath) ?? [])") }
                print("red-pen-live #\(iteration) ink=\(ink): \(outcome.status.rawValue) \(outcome.elapsedMs) ms grade=\(attempt?.grade ?? "-") viewed=\(viewed) marks=\(returned.count)/\(stored.count) $\(execution["estimated_cost_usd"]?.doubleValue ?? -1)")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("red-pen-live.json"))
        XCTAssertFalse(rows.isEmpty)
    }
}
