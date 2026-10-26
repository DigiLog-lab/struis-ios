import XCTest
@testable import strius

/// 台帳に書いた plan を起動時に戻せる(2026-10-26: snake_case の `CodingKeys` と `convertFromSnakeCase` が合わず戻せず、
/// `resumeUnfinished` が前のプロセスの採点を黙って飛ばして「採点中」のまま残した)。
final class TurnPlanCodingTests: XCTestCase {
    func testPlanRoundTripsThroughTheLedgerEncoding() throws {
        let plan = TurnPlan(
            id: "plan-1", kind: .timelineGrading, round: 1,
            thread: TurnPlan.ThreadSpec(
                codexThreadID: nil, mode: .start, cwd: "/workspace", model: "claude-sonnet-5-5", effort: "low", ephemeral: true,
                baseInstructions: TurnPlan.AssetRef(asset: "prompt:base", sha256: "abc", append: "共通の指示"), developerInstructions: nil,
                developerText: "今日の答案", injectDeveloperOnResume: false, config: .object(["model_reasoning_effort": .string("low")]),
                lastTurnID: nil, provider: .anthropic
            ),
            turn: TurnPlan.TurnSpec(
                text: "採点", images: [TurnPlan.ImageRef(path: "tutor_desk/inbox/a.jpg", hostPath: "/captures/a.jpg")],
                outputSchema: .object(["type": .string("object")]), sandboxPolicy: "dangerFullAccess"
            ),
            workspace: TurnPlan.WorkspaceSpec(files: [], dirs: []), delegation: nil, collect: [], limits: .structured, items: nil
        )
        // 台帳に入る形(`turn.plan`)は snake_case。
        XCTAssertEqual(plan.json["limits"]?["turn_timeout_s"]?.intValue, 600)
        XCTAssertEqual(try TurnPlan.from(plan.json), plan)
    }
}
