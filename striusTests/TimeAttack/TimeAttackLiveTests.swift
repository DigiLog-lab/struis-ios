// タイムアタック(#133)は延期中。Config/Build.xcconfig の STRUIS_TIME_ATTACK が YES の時だけ本体に入る(App Clip は常に入れる)。
#if STRUIS_TIME_ATTACK
import UIKit
import XCTest
@testable import strius

/// タイムアタック(#133)の出題と写真の読み取りを、本物の Claude で確かめる。手で流す確認で、CI の門には入れない
/// (出力先が無ければ飛ばす)。
///
///     TEST_RUNNER_STRUIS_TIME_ATTACK_LIVE_OUT=<結果を書くフォルダー>
///     TEST_RUNNER_STRUIS_DEBUG_ANTHROPIC_KEY_FILE=<キーのファイル>(Dev Box なら "$DEVBOX_ANTHROPIC_KEY_FILE")
///     [TEST_RUNNER_STRUIS_TIME_ATTACK_UNIT=三角関数]
///
/// 5問を作らせ、1〜4問目は正答、5問目だけ違う答えを上から順に書いた紙の画像を読ませて、正誤が [○○○○×] になるかを見る。
/// 結果は `<出力>/time-attack-live.json`(作った問題・読み取りの正誤・かかった秒数・費用)。
final class TimeAttackLiveTests: XCTestCase {
    private struct Recorder: TimeAttackTransport {
        let base: AppTimeAttackTransport
        let log: Log
        final class Log: @unchecked Sendable {
            var rows: [[String: Any]] = []
        }

        func send(_ body: [String: Any], purpose: TimeAttackClaude.Purpose) async throws -> [String: Any] {
            let started = Date()
            let json = try await base.send(body, purpose: purpose)
            log.rows.append(["purpose": purpose.rawValue, "seconds": Date().timeIntervalSince(started),
                             "cost": AppTimeAttackTransport.usageRecord(json, status: 200)["estimated_cost_usd"] ?? NSNull(),
                             "reply": ((json["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""])
            return json
        }
    }

    private static func paper(_ lines: [String]) -> Data {
        let size = CGSize(width: 900, height: 1_200)
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.85) { context in
            UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 80, y: 100 + CGFloat(index) * 160),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 56), .foregroundColor: UIColor.black])
            }
        }
    }

    func testGenerateAndReadWithTheRealClaude() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = environment["STRUIS_TIME_ATTACK_LIVE_OUT"] ?? ""
        try XCTSkipIf(output.isEmpty, "TEST_RUNNER_STRUIS_TIME_ATTACK_LIVE_OUT が無い(本物の Claude での確認は手動)")
        let key = try XCTUnwrap(AnthropicCredentials.debugAPIKey, "STRUIS_DEBUG_ANTHROPIC_KEY_FILE が無い")
        let out = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let upstream = ClaudeUpstream(baseURL: ClaudeUpstream.anthropicBaseURL, apiKey: { key }, gate: UnlimitedUsageGate())
        let transport = Recorder(base: AppTimeAttackTransport(upstream: upstream), log: .init())
        let unit = environment["STRUIS_TIME_ATTACK_UNIT"] ?? "三角関数"
        let made: (field: String, problems: [TimeAttack.Problem])
        do {
            made = try await TimeAttackClaude.generate(unitTitle: unit, context: "", transport: transport)
        } catch {
            // 作れなかった時も、返事を残して原因を見られるようにする。
            try JSONSerialization.data(withJSONObject: ["error": "\(error)", "requests": transport.log.rows], options: [.prettyPrinted, .sortedKeys])
                .write(to: out.appendingPathComponent("time-attack-live.json"))
            throw error
        }
        XCTAssertEqual(made.problems.count, TimeAttack.problemCount)

        var lines = made.problems.map { TimeAttackMath.plain($0.answerKey) }
        lines[4] = lines[4] == "7" ? "8" : "7"  // 5問目だけ違う答え
        let photo = Self.paper(lines)
        try photo.write(to: out.appendingPathComponent("time-attack-paper.jpg"))
        let correct = try await TimeAttackClaude.grade(problems: made.problems, photo: photo, transport: transport)

        let report: [String: Any] = [
            "field": made.field,
            "problems": made.problems.map { ["prompt": $0.prompt, "math": $0.math, "answer_key": $0.answerKey, "answer_expr": $0.answerExpr] },
            "written": lines, "correct": correct, "requests": transport.log.rows,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("time-attack-live.json"))
        XCTAssertEqual(correct, [true, true, true, true, false])
    }
}
#endif
