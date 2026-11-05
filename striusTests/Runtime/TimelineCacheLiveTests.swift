import GRDB
import UIKit
import XCTest
@testable import strius

/// 続けて頼む採点・見直し・出題で Anthropic に送る本文を、`ClaudeTurnRunner` と模擬の Anthropic(`StubAnthropic`)で記録して比べる。
/// 2026-10-25: 採点 25 回の cached_input_tokens が全部 0 だった(Skill を作業フォルダに置いていた)。
/// 2026-10-27: 今日の答案の一覧が 1 つのブロックのまま伸び、出力の形の差し込みで依頼の種類ごとに先頭が変わっていた。
/// 採点→採点、採点→見直し、見直し→出題の順に流し、前の依頼の印(基本指示の最後・今日の記録の最後)までが次の依頼の
/// 先頭と 1 バイトも違わないかを見る。
///
/// 手で流す測定: `TEST_RUNNER_STRUIS_TIMELINE_CACHE_LIVE=<出力先>` を渡すと、比べた結果を `<出力先>/summary.json` に、
/// 送った本文を `<出力先>/requests/` に残す。模擬の Anthropic は端末の中で答えるので、外のサーバーやキーは要らない。
final class TimelineCacheLiveTests: XCTestCase {
    typealias F = TimelineFixture

    @MainActor
    func testGradingReviewAndBatchKeepThePrefixUpToThePreviousMark() async throws {
        let output = ProcessInfo.processInfo.environment["STRUIS_TIMELINE_CACHE_LIVE"] ?? ""
        try XCTSkipIf(output.isEmpty, "TEST_RUNNER_STRUIS_TIMELINE_CACHE_LIVE が無い (模擬の Anthropic での測定は手動)")
        let out = URL(fileURLWithPath: output, isDirectory: true)
        let dump = out.appendingPathComponent("requests", isDirectory: true)
        try? FileManager.default.removeItem(at: dump)
        try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)

        let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAnthropic.self]
        let recorder: RequestRecorder = RequestRecorder()
        let reply: String = [
            #"{"type":"message_start","message":{"id":"msg_live","model":"claude-sonnet-5-5","usage":{"input_tokens":10,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"{\"ok\":true}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}"#,
            #"{"type":"message_stop"}"#,
        ].map { "event: x\ndata: \($0)\n\n" }.joined()
        StubAnthropic.handler = { request in
            let data: Data = StubAnthropic.body(of: request)
            let index: Int = recorder.add((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
            try? data.write(to: dump.appendingPathComponent(String(format: "%04d-messages.json", index)))
            return (200, reply)
        }
        defer { StubAnthropic.handler = nil }
        let assets = AssetCache()
        let upstream: ClaudeUpstream = ClaudeUpstream(baseURL: URL(string: "https://stub.invalid")!, apiKey: { "sk-test" },
                                                      session: URLSession(configuration: configuration), gate: OpenUsageGate())
        let runner: ClaudeTurnRunner = ClaudeTurnRunner(assets: assets, conversations: try ClaudeConversationStore.temporary(), upstream: upstream,
                                                        contextStore: ThreadContextStore(url: nil), prepareCommands: {})
        let composer = TurnComposer(assets: assets)

        // 台帳: 単元、2 枚のカードと、それぞれの答案(画像)、次の 5 枚の依頼。
        let ledger = try Ledger.inMemory()
        try StruisPaths.prepare()
        for name in ["live-a.jpg", "live-b.jpg"] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).jpegData(withCompressionQuality: 0.8) { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            }
            try image.write(to: StruisPaths.captures.appendingPathComponent(name))
        }
        let ids: [String] = try await ledger.commit { db in
            let unit = WorkbookUnitRecord(id: "u-live", title: "フーリエ級数", outcome: "", status: "active", source: "manual", position: 0,
                                          overview: .emptyObject, createdAt: F.now, updatedAt: F.now, passedAt: nil)
            var timeline = try TimelineMachine(loading: db)
            timeline.put("test", F.skill("fourier.antiderivative_trig"))
            timeline.put("test", F.card("c1", skills: ["fourier.antiderivative_trig"]))
            timeline.put("test", F.card("c2", skills: ["fourier.antiderivative_trig"]))
            let first = timeline.recordCapture(cardID: "c1", capturePath: "live-a.jpg", seconds: 30, assisted: false)
            let second = timeline.recordCapture(cardID: "c2", capturePath: "live-b.jpg", seconds: 30, assisted: false)
            let batch = timeline.insertBatchRequest(purpose: "cards", request: .emptyObject, accuracy: 0.8, levelCap: nil)
            return ([.upsert("test", unit)] + timeline.events, [first, second, batch])
        }
        let steps: [(name: String, kind: TurnPlan.Kind, target: String)] = [
            ("grading-1", .timelineGrading, ids[0]), ("grading-2", .timelineGrading, ids[1]), ("review", .timelineReview, ids[1]), ("batch", .timelineBatch, ids[2]),
        ]
        var bodies: [[String: Any]] = []
        for step in steps {
            // 組む前に今日の記録の足りない分を書く(`TurnCoordinator.compose` と同じ)。
            let (workbook, timeline): (WorkbookMachine, TimelineMachine) = try await ledger.commit { db in
                let workbook = try WorkbookMachine(loading: db)
                var timeline = try TimelineMachine(loading: db)
                TimelineTurns.syncLog(workbook: workbook, timeline: &timeline)
                return (timeline.events, (workbook, timeline))
            }
            let planID = "live-\(step.name)-\(UUID().uuidString.prefix(8).lowercased())"
            let plan: TurnPlan = switch step.kind {
            case .timelineGrading: try await TimelineTurns.grading(composer: composer, planID: planID, attemptID: step.target, workbook: workbook, timeline: timeline)
            case .timelineReview: try await TimelineTurns.review(composer: composer, planID: planID, attemptID: step.target, workbook: workbook, timeline: timeline)
            default: try await TimelineTurns.batch(composer: composer, planID: planID, batchID: step.target, workbook: workbook, timeline: timeline)
            }
            let before: Int = recorder.bodies.count
            let outcome = try await runner.run(plan) { _ in }
            WorkspaceStager.cleanup(plan: plan)
            XCTAssertEqual(outcome.status, .completed, "\(step.name): \(outcome.errorDetail ?? "")")
            // 依頼の最初の要求(道具を使った後の続きの要求は同じ依頼の中なので比べない)。
            guard recorder.bodies.count > before else { XCTFail("\(step.name): 本文が記録されていない"); return }
            bodies.append(recorder.bodies[before])
            // 結果を綴じたことにして、今日の記録を後ろに足す。
            try await ledger.commit { db in
                var timeline = try TimelineMachine(loading: db)
                switch step.kind {
                case .timelineGrading:
                    _ = timeline.applyGrading(attemptID: step.target, grading: TimelineMachine.Grading(grade: "partial", learnerAnswer: "0", skillIds: ["fourier.antiderivative_trig"],
                                                                                                      transcript: "[-2 sin 2x]", notes: "原始関数の係数が違う"))
                case .timelineReview:
                    timeline.applyReview(targetID: step.target, review: try TimelineMachine.Review.parse(#"{"notes":"同じ所の誤りが 2 回","skill_results":[]}"#))
                default: break
                }
                return (timeline.events, ())
            }
        }

        func blocks(_ body: [String: Any]) -> [[String: Any]] { body["system"] as? [[String: Any]] ?? [] }
        func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data() }
        func marks(_ body: [String: Any]) -> [Int] { blocks(body).enumerated().filter { $0.element["cache_control"] != nil }.map(\.offset) }
        var pairs: [[String: Any]] = []
        for index in 1..<bodies.count {
            let a = bodies[index - 1], b = bodies[index]
            let markA = marks(a), markB = marks(b)
            XCTAssertEqual(markA.count, 2, "\(steps[index - 1].name): 印は基本指示の最後と今日の記録の最後")
            let last = markA.last ?? 0
            let strip = { (body: [String: Any]) in Array(blocks(body).prefix(last + 1)).map { $0.filter { $0.key != "cache_control" } } }
            let sameUpToMark = json(strip(a)) == json(strip(b))
            let sameBase = json(blocks(a).first ?? [:]) == json(blocks(b).first ?? [:])
            let sameTools = json(a["tools"] ?? []) == json(b["tools"] ?? [])
            let sameConfig = json(a["output_config"] ?? [:]) == json(b["output_config"] ?? [:]) && json(a["thinking"] ?? [:]) == json(b["thinking"] ?? [:])
            XCTAssertTrue(sameBase, "\(steps[index].name): 基本指示が前の依頼と違う")
            XCTAssertTrue(sameUpToMark, "\(steps[index].name): 前の依頼の今日の記録の印までが違う")
            XCTAssertTrue(sameTools, "\(steps[index].name): tools が違う")
            XCTAssertTrue(sameConfig, "\(steps[index].name): output_config・thinking が違う")
            XCTAssertNil((b["output_config"] as? [String: Any])?["format"])
            pairs.append([
                "from": steps[index - 1].name, "to": steps[index].name, "marks_from": markA, "marks_to": markB,
                "system_blocks_to": blocks(b).count, "same_base": sameBase, "same_up_to_previous_log_mark": sameUpToMark,
                "same_tools": sameTools, "same_output_config_and_thinking": sameConfig,
                "added_blocks": blocks(b).count - blocks(a).count,
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: ["pairs": pairs], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("summary.json"))
        print("TIMELINE_CACHE_LIVE " + String(decoding: data, as: UTF8.self))
    }
}
