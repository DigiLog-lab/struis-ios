import XCTest
@testable import strius

/// 利用枠(#62): 週の区切り・保存先の大きい方・プランごとの上限とソフトリミット・料金が分からない要求の見積もり・
/// 上限に達した時の止め方(送らずにターンを失敗にする)。
@MainActor
final class UsageGateTests: XCTestCase {
    private var tokyo: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return formatter.date(from: text)!
    }

    private func meter(plan: UsagePlan?, local: MemoryValueStore = MemoryValueStore(), cloud: MemoryValueStore = MemoryValueStore(), now: Date = Date()) -> UsageMeter {
        let defaults = UserDefaults(suiteName: "usage-tests-\(UUID().uuidString)")!
        let meter = UsageMeter(values: MirroredValues(local: local, cloud: cloud), defaults: defaults, now: { now })
        meter.setPlan(plan)
        return meter
    }

    func testWeekStartsOnMondayAtMidnightAndResetsTheNextMonday() {
        // 2026-10-31 は土曜。週の始まりは 10-26(月)0:00、戻るのは 11-02(月)0:00。
        let saturday = date("2026-10-31T09:13:00+09:00")
        XCTAssertEqual(UsageRules.weekStart(for: saturday, calendar: tokyo), date("2026-10-26T00:00:00+09:00"))
        XCTAssertEqual(UsageRules.resetDate(after: saturday, calendar: tokyo), date("2026-11-02T00:00:00+09:00"))
        // 月曜 0:00 ちょうどは新しい週。日曜の夜は前の週。
        XCTAssertEqual(UsageRules.weekStart(for: date("2026-11-02T00:00:00+09:00"), calendar: tokyo), date("2026-11-02T00:00:00+09:00"))
        XCTAssertEqual(UsageRules.weekKey(for: date("2026-11-01T23:59:00+09:00"), calendar: tokyo), "usage.week.2026-10-26")
        XCTAssertEqual(UsageRules.weekKey(for: date("2026-11-02T00:00:00+09:00"), calendar: tokyo), "usage.week.2026-11-02")
    }

    func testPlansFollowTheDecidedTable() {
        XCTAssertEqual(UsagePlan.allCases.map(\.yen), [1_480, 3_980, 9_800])
        XCTAssertEqual(UsagePlan.allCases.map(\.weeklyLimitUSD), [0.80, 2.00, 4.80])
        XCTAssertEqual(UsagePlan.allCases.map(\.weeklyProblems), [12, 30, 75])
        XCTAssertEqual(UsagePlan.allCases.map(\.groupLevel), [3, 2, 1], "たっぷり 1・スタンダード 2・ライト 3")
        XCTAssertEqual(UsagePlan.light.upgrade, .standard)
        XCTAssertEqual(UsagePlan.standard.upgrade, .generous)
        XCTAssertNil(UsagePlan.generous.upgrade)
        // 購入画面の目安(表の値)は、1 問 ¥10 で割った数を超えない。
        for plan in UsagePlan.allCases {
            XCTAssertLessThanOrEqual(Double(plan.weeklyProblems), plan.weeklyLimitUSD / UsageRules.problemUSD, plan.displayName)
        }
        XCTAssertEqual(UsagePlan(productID: "com.digiloglab.strius.plan.standard"), .standard)
        XCTAssertNil(UsagePlan(productID: "com.example.other"))
    }

    func testCurrentPlanIsTheActiveOneWithTheSmallestGroupLevel() {
        XCTAssertEqual(UsagePlan.best(of: [.light, .generous, .standard]), .generous)
        XCTAssertEqual(UsagePlan.best(of: [.light, .standard]), .standard)
        XCTAssertNil(UsagePlan.best(of: []))
    }

    func testSpentIsTheLargerOfKeychainAndICloudAndAddsToBoth() {
        let now = date("2026-10-31T09:00:00+09:00")
        let key = UsageRules.weekKey(for: now)
        let local = MemoryValueStore([key: "0.10"])
        let cloud = MemoryValueStore([key: "0.30"])
        let meter = meter(plan: .light, local: local, cloud: cloud, now: now)
        XCTAssertEqual(meter.snapshot().spentUSD, 0.30, accuracy: 1e-9, "入れ直した端末(Keychain が少ない)でも iCloud の分を数える")
        meter.add(0.05)
        XCTAssertEqual(Double(local.string(key) ?? ""), 0.35)
        XCTAssertEqual(Double(cloud.string(key) ?? ""), 0.35)
    }

    func testSnapshotShowsPercentRemainingProblemsAndResetDate() {
        let now = date("2026-10-31T09:00:00+09:00")
        let meter = meter(plan: .light, now: now)
        meter.add(0.336)
        let snapshot = meter.snapshot()
        XCTAssertEqual(snapshot.percent, 42)
        XCTAssertEqual(snapshot.remainingProblems, 7, "(0.80 - 0.336) ÷ (10/160) = 7.4 → 7")
        XCTAssertFalse(snapshot.isExhausted)
        XCTAssertEqual(UsageStatus.resetText(snapshot.resetsAt), "11月2日（月）0:00")
    }

    func testRemainingProblemsNeverExceedThePlansWeeklyProblems() {
        // スタンダードの上限 $2.00 を 1 問 $0.0625 で割ると 32 問だが、購入画面の「週 約30問」を超えて見せない。
        let meter = meter(plan: .standard, now: date("2026-10-31T09:00:00+09:00"))
        XCTAssertEqual(meter.snapshot().remainingProblems, 30)
    }

    func testGateAllowsOneCardOverTheLimitThenRefuses() {
        let meter = meter(plan: .light)
        let gate = DeviceUsageGate(meter: meter)
        meter.add(0.79)
        XCTAssertTrue(gate.admit())
        meter.add(0.02)
        XCTAssertTrue(meter.snapshot().isExhausted, "100% に達した")
        XCTAssertTrue(gate.admit(), "ソフトリミット: 解いている途中のカードは採点まで通す")
        meter.add(UsageRules.graceUSD)
        XCTAssertFalse(gate.admit(), "カード 1 枚分を超えたら通さない")
    }

    func testWithoutAPlanOnlyTheTrialAllowanceIsAvailable() {
        let meter = meter(plan: nil)
        XCTAssertEqual(meter.snapshot().limitUSD, UsageRules.trialLimitUSD)
        meter.add(UsageRules.trialLimitUSD + UsageRules.graceUSD)
        XCTAssertFalse(DeviceUsageGate(meter: meter).admit())
        meter.setPlan(.standard)
        XCTAssertTrue(DeviceUsageGate(meter: meter).admit(), "購入すると、すぐに続けられる")
    }

    func testChargeUsesTheEstimatedCostAndNeverCountsUnknownAsZero() {
        XCTAssertEqual(UsageRules.charge(record: ["estimated_cost_usd": 0.0123, "cost_status": "estimated"], requestBytes: 10), 0.0123)
        XCTAssertEqual(UsageRules.charge(record: ["estimated_cost_usd": NSNull(), "cost_status": "not_billed"], requestBytes: 50_000), 0)
        let bytes = 30_000
        let unknown = UsageRules.charge(record: ["estimated_cost_usd": NSNull(), "cost_status": "usage_unavailable"], requestBytes: bytes)
        let unknownModel = UsageRules.charge(record: ["estimated_cost_usd": NSNull(), "cost_status": "unknown_model"], requestBytes: bytes)
        XCTAssertEqual(unknown, unknownModel)
        // 一番高いモデル(Opus 5.5)で、出力 4,096 トークンと本文 3 バイトを 1 トークンとした見積もりより少なくしない。
        let opus = ClaudePricing.cost(model: "claude-opus-5-5", tokens: {
            var tokens = ClaudePricing.Tokens()
            tokens.input = bytes / 3
            tokens.output = 4_096
            return tokens
        }())!.usd
        XCTAssertGreaterThanOrEqual(unknown, opus - 1e-6)
    }

    // MARK: - ランナー

    /// 上限に達したら Anthropic に送らず、ターンを失敗にする(学習者には利用枠の一文、記録には理由)。
    func testRunnerRefusesWithoutSendingWhenTheLimitIsReached() async throws {
        let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAnthropic.self]
        let recorder: RequestRecorder = RequestRecorder()
        StubAnthropic.handler = { _ in
            _ = recorder.add([:])
            return (500, "")
        }
        defer { StubAnthropic.handler = nil }
        let upstream: ClaudeUpstream = ClaudeUpstream(baseURL: URL(string: "https://stub.invalid")!, apiKey: { "sk-test" },
                                                      session: URLSession(configuration: configuration), gate: ClosedGate())
        let assets: AssetCache = AssetCache()
        let runner: ClaudeTurnRunner = ClaudeTurnRunner(assets: assets, conversations: try ClaudeConversationStore.temporary(), upstream: upstream,
                                                        contextStore: ThreadContextStore(url: nil), prepareCommands: {})
        let plan: TurnPlan = TurnPlan(
            id: LedgerID.make(), kind: .workbookSet, round: 1,
            thread: TurnPlan.ThreadSpec(codexThreadID: nil, mode: .start, cwd: "/", model: "claude-sonnet-5-5", effort: "medium", ephemeral: true,
                                        baseInstructions: TurnPlan.AssetRef(asset: "prompt:base", sha256: "unavailable"), developerInstructions: nil,
                                        developerText: "Only JSON.", injectDeveloperOnResume: false, config: .object([:]), lastTurnID: nil),
            turn: TurnPlan.TurnSpec(text: "hi", images: [], outputSchema: nil, sandboxPolicy: "dangerFullAccess"),
            workspace: TurnPlan.WorkspaceSpec(files: [], dirs: []), delegation: nil, collect: [], limits: .structured
        )
        defer { WorkspaceStager.cleanup(plan: plan) }
        let outcome: TurnOutcome = try await runner.run(plan) { _ in }
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(recorder.bodies.isEmpty, "上限に達したら Anthropic に送らない")
        XCTAssertEqual(outcome.error, "今週の利用枠を使い切りました。設定の「利用枠」で、戻る日時とプランを確かめてください。")
        XCTAssertEqual(outcome.errorDetail, TurnRuntimeError.turnFailed(UsageLimitResponse.message).detail)
        XCTAssertTrue(outcome.errorDetail?.contains(UsageLimitResponse.code) == true)
        XCTAssertEqual(outcome.executions.last?["status"]?.stringValue, "failed")
    }
}

/// 送らせない判定(ランナーのテスト)。
nonisolated private struct ClosedGate: UsageGate {
    func admit() -> Bool { false }
    func record(_ attempt: [String: Any], requestBytes: Int) {}
}
