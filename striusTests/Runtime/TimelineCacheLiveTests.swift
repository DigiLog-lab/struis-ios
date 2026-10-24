import GRDB
import UIKit
import XCTest
@testable import strius

/// 連続する 2 回の採点で Anthropic に送る本文を、実 Codex(端末の app-server)と模擬の Anthropic で記録して比べる
/// (2026-10-25: 採点 25 回の cached_input_tokens が全部 0 だった)。前の版の形(Skill を作業フォルダに置く)と今の形を
/// 同じ条件で流し、Claude の system の先頭が 2 回で同じかを見る。
///
/// 手で流す測定: `scripts/e2e/fake_anthropic.py --port 8787 --log-dir <dir>` を起動し、`TEST_RUNNER_STRUIS_TIMELINE_CACHE_LIVE=<出力先>`・
/// `TEST_RUNNER_STRUIS_ANTHROPIC_BASE_URL=http://127.0.0.1:8787`・`TEST_RUNNER_STRUIS_DEBUG_ANTHROPIC_KEY_FILE=<偽のキー>`・
/// `TEST_RUNNER_STRUIS_DEVICE_RUNTIME=0` を渡す。
final class TimelineCacheLiveTests: XCTestCase {
    typealias F = TimelineFixture

    @MainActor
    func testConsecutiveGradingsSendTheSameSystemPrefix() async throws {
        let output = ProcessInfo.processInfo.environment["STRUIS_TIMELINE_CACHE_LIVE"] ?? ""
        try XCTSkipIf(output.isEmpty, "TEST_RUNNER_STRUIS_TIMELINE_CACHE_LIVE が無い (模擬の Anthropic での測定は手動)")
        let out = URL(fileURLWithPath: output, isDirectory: true)
        let dump = out.appendingPathComponent("proxy-dump", isDirectory: true)
        try? FileManager.default.removeItem(at: dump)
        try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
        setenv("STRUIS_CLAUDE_PROXY_DUMP_DIR", dump.path, 1)
        setenv("STRUIS_MODEL_PROVIDER", "anthropic", 1)

        let runtime = DeviceRuntime()
        await runtime.start()
        do { try await runtime.ensureRunning() } catch {
            XCTFail("app-server が起動しない: boot=\(runtime.boot.state) server=\(runtime.appServerState) error=\(error)")
            return
        }
        XCTAssertTrue(runtime.isRunning, "app-server が起動しない: \(runtime.appServerState)")
        let assets = AssetCache(root: FileManager.default.temporaryDirectory.appendingPathComponent("cache-live-\(UUID().uuidString)"), lenient: true)
        let runner = CodexTurnRunner(runtime: runtime, assets: assets)
        let composer = TurnComposer(assets: assets)

        // 台帳: 2 枚のカードと、それぞれの答案(画像)。
        let ledger = try Ledger.inMemory()
        try StruisPaths.prepare()
        for name in ["live-a.jpg", "live-b.jpg"] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).jpegData(withCompressionQuality: 0.8) { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            }
            try image.write(to: StruisPaths.captures.appendingPathComponent(name))
        }
        let ids: [String] = try await ledger.commit { db in
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", F.skill("fourier.antiderivative_trig"))
            timeline.put("test", F.card("c1", skills: ["fourier.antiderivative_trig"]))
            timeline.put("test", F.card("c2", skills: ["fourier.antiderivative_trig"]))
            let first = timeline.recordCapture(cardID: "c1", capturePath: "live-a.jpg", seconds: 30, assisted: false)
            _ = timeline.applyGrading(attemptID: first, grading: TimelineMachine.Grading(grade: "partial", learnerAnswer: "0", skillIds: ["fourier.antiderivative_trig"],
                                                                                       transcript: "[-2 sin 2x]", notes: "原始関数の係数が違う"))
            let second = timeline.recordCapture(cardID: "c2", capturePath: "live-b.jpg", seconds: 30, assisted: false)
            return (timeline.events, [first, second])
        }
        let (workbook, timeline) = try await ledger.read { db in (try WorkbookMachine(loading: db), try TimelineMachine(loading: db)) }

        var summary: [String: Any] = [:]
        for layout in ["before", "after"] {
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: dump.path)) ?? [])
            for (index, attemptID) in ids.enumerated() {
                var plan = try await TimelineTurns.grading(composer: composer, planID: "live-\(layout)-\(index)-\(UUID().uuidString.prefix(8).lowercased())",
                                                           attemptID: attemptID, workbook: workbook, timeline: timeline)
                if layout == "before" {
                    // 前の版: Skill の本文を処理ごとの作業フォルダの `.agents/skills` に置いていた。
                    plan.workspace = TurnPlan.WorkspaceSpec(files: [TurnPlan.FileSpec(path: ".agents/skills/timeline-query/SKILL.md", asset: "skill:timeline_query")], dirs: [])
                }
                try WorkspaceStager.prepare(plan: plan, assets: assets)
                defer { WorkspaceStager.cleanup(plan: plan) }
                let outcome = try await runner.run(plan) { _ in }
                XCTAssertEqual(outcome.status, .completed, "\(layout) \(index): \(outcome.error ?? "")")
            }
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dump.path)) ?? []).filter { !before.contains($0) && $0.hasSuffix("-messages.json") }.sorted()
            let bodies = try files.map { try JSONSerialization.jsonObject(with: Data(contentsOf: dump.appendingPathComponent($0))) as? [String: Any] ?? [:] }
            XCTAssertGreaterThanOrEqual(bodies.count, 2, layout)
            guard bodies.count >= 2 else { continue }
            let a = bodies[bodies.count - 2], b = bodies[bodies.count - 1]
            func blocks(_ body: [String: Any]) -> [String] {
                if let text = body["system"] as? String { return [text] }
                return (body["system"] as? [[String: Any]] ?? []).map { $0["text"] as? String ?? "" }
            }
            let systemA = blocks(a), systemB = blocks(b)
            let joinedA = Array(systemA.joined(separator: "\u{1}").utf8), joinedB = Array(systemB.joined(separator: "\u{1}").utf8)
            let firstDiff = zip(joinedA, joinedB).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            summary[layout] = [
                "files": Array(files.suffix(2)), "system_blocks": systemA.count, "system_identical": systemA == systemB,
                "first_block_equal": systemA.first == systemB.first, "first_difference_utf8_offset": firstDiff ?? NSNull(),
                "tools_equal": (try? JSONSerialization.data(withJSONObject: a["tools"] ?? [], options: [.sortedKeys])) == (try? JSONSerialization.data(withJSONObject: b["tools"] ?? [], options: [.sortedKeys])),
            ]
            if layout == "after" {
                XCTAssertEqual(systemA.first, systemB.first, "今の形でも 1 つ目の先頭が 2 回で違う")
                XCTAssertEqual(systemA.count, 2)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("summary.json"))
        print("TIMELINE_CACHE_LIVE " + String(decoding: data, as: UTF8.self))
    }
}
