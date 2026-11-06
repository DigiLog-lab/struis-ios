import XCTest
@testable import strius

/// 利用枠(#62): 期間の区切り(課金した時刻から 7 日ごと、課金したことが無ければ月曜 0:00)・保存先の大きい方・プランごとの上限とソフトリミット・料金が分からない要求の見積もり・
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

    func testAfterAChargeThePeriodIsSevenDaysFromTheChargeTime() {
        // 2026-11-06(金)13:31 に課金。期間は金曜 13:31 から 7 日ごと(月曜 0:00 ではない)。
        let charged = date("2026-11-06T13:31:00+09:00")
        XCTAssertEqual(UsageRules.periodStart(for: date("2026-11-06T13:31:00+09:00"), chargedAt: charged, calendar: tokyo), charged)
        XCTAssertEqual(UsageRules.periodStart(for: date("2026-11-13T13:30:00+09:00"), chargedAt: charged, calendar: tokyo), charged)
        XCTAssertEqual(UsageRules.periodEnd(for: date("2026-11-09T00:00:00+09:00"), chargedAt: charged, calendar: tokyo), date("2026-11-13T13:31:00+09:00"),
                       "月曜 0:00 では戻らない")
        XCTAssertEqual(UsageRules.periodStart(for: date("2026-11-20T14:00:00+09:00"), chargedAt: charged, calendar: tokyo), date("2026-11-20T13:31:00+09:00"))
        XCTAssertNotEqual(UsageRules.periodKey(for: date("2026-11-13T13:30:00+09:00"), chargedAt: charged, calendar: tokyo),
                          UsageRules.periodKey(for: date("2026-11-13T13:31:00+09:00"), chargedAt: charged, calendar: tokyo))
        // 課金したことが無ければ、これまでどおり月曜 0:00 区切り(端末に残っている今週の使用額をそのまま読む)。
        XCTAssertEqual(UsageRules.periodKey(for: date("2026-11-06T13:31:00+09:00"), chargedAt: nil, calendar: tokyo), "usage.week.2026-11-02")
    }

    func testAChargeStartsANewPeriodFromZeroButAnOlderChargeDoesNotGoBack() {
        let now = date("2026-11-06T13:31:00+09:00")
        let meter = meter(plan: nil, now: now)
        meter.add(0.30)
        XCTAssertEqual(meter.snapshot().spentUSD, 0.30, accuracy: 1e-9)

        // 購入した: その時刻から新しい期間で、使用額は 0 から。
        meter.setPlan(.light, chargedAt: now.addingTimeInterval(-60), renewsAt: now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(meter.snapshot().spentUSD, 0, "課金したら 0 から")
        XCTAssertEqual(meter.snapshot().resetsAt, now.addingTimeInterval(-60 + 7 * 86_400))
        meter.add(0.50)

        // 遅れて届いた古い契約の状態(前の課金の時刻)では、期間を戻さない。
        meter.setPlan(.light, chargedAt: now.addingTimeInterval(-3_600), renewsAt: now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(meter.snapshot().spentUSD, 0.50, accuracy: 1e-9)

        // 上げた(新しい取引): また 0 から。
        meter.setPlan(.standard, chargedAt: now, renewsAt: now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(meter.snapshot().spentUSD, 0)
        XCTAssertEqual(meter.snapshot().limitUSD, UsagePlan.standard.weeklyLimitUSD)
    }

    func testAChargeInTheSameSecondIsToldApartByTheTransactionID() {
        let now = date("2026-11-06T13:31:00+09:00")
        let meter = meter(plan: nil, now: now)
        meter.setPlan(.standard, chargeID: 10, chargedAt: now, renewsAt: now.addingTimeInterval(30 * 86_400))
        meter.add(1.00)
        // 同じ秒に上げた(取引 ID が大きい): 新しい期間。
        meter.setPlan(.generous, chargeID: 11, chargedAt: now, renewsAt: now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(meter.snapshot().spentUSD, 0, "同じ秒でも、新しい取引なら 0 から")
        meter.add(0.40)
        // 遅れて届いた前の取引(ID が小さい)では戻さない。
        meter.setPlan(.generous, chargeID: 10, chargedAt: now, renewsAt: now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(meter.snapshot().spentUSD, 0.40, accuracy: 1e-9)
    }

    func testTheChargeSurvivesAReinstallAfterThePlanEnds() {
        let now = date("2026-11-06T13:31:00+09:00")
        let local = MemoryValueStore()
        let cloud = MemoryValueStore()
        let first = meter(plan: nil, local: local, cloud: cloud, now: now)
        first.setPlan(.light, chargeID: 7, chargedAt: now.addingTimeInterval(-86_400), renewsAt: now.addingTimeInterval(29 * 86_400))
        first.add(0.40)
        first.setPlan(nil) // 返金・期限切れ

        // 入れ直し: UserDefaults は空になり、StoreKit からは切れた契約の取引が届かない。
        let reinstalled = meter(plan: nil, local: local, cloud: cloud, now: now)
        XCTAssertEqual(reinstalled.chargeID, 7, "課金は Keychain と iCloud に残る")
        XCTAssertEqual(reinstalled.snapshot().spentUSD, 0.40, accuracy: 1e-9, "その期間の使用額を引き継ぐ(お試しの枠が戻らない)")
        XCTAssertFalse(DeviceUsageGate(meter: reinstalled).admit(), "お試しの枠($0.25 + カード 1 枚分)を超えたまま")
    }

    func testTheNewerChargeOfKeychainAndICloudIsUsed() {
        let now = date("2026-11-06T13:31:00+09:00")
        let local = MemoryValueStore()
        let cloud = MemoryValueStore()
        let iphone = meter(plan: nil, local: local, cloud: MemoryValueStore(), now: now)
        iphone.setPlan(.light, chargeID: 7, chargedAt: now.addingTimeInterval(-86_400))
        // 別の端末が、あとの課金(上げた)を iCloud に書いた。
        let ipad = meter(plan: nil, local: MemoryValueStore(), cloud: cloud, now: now)
        ipad.setPlan(.standard, chargeID: 8, chargedAt: now.addingTimeInterval(-60))
        let merged = meter(plan: nil, local: local, cloud: cloud, now: now)
        XCTAssertEqual(merged.chargeID, 8)
        XCTAssertEqual(merged.chargedAt, now.addingTimeInterval(-60))
    }

    func testWhileCancellationIsReservedTheExpiryDoesNotShortenTheReset() {
        let now = date("2026-11-06T13:31:00+09:00")
        let meter = meter(plan: nil, now: now)
        // 解約の予約中(自動更新なし)で、2 日後に期限が来る: 期限が来てもプランが終わるだけで使用額は戻らない。
        meter.setPlan(.light, chargeID: 3, chargedAt: now.addingTimeInterval(-86_400), renewsAt: nil)
        XCTAssertNil(meter.renewsAt)
        XCTAssertEqual(meter.snapshot().resetsAt, now.addingTimeInterval(-86_400 + 7 * 86_400), "戻るのは課金から 7 日後のまま")
    }

    func testResetsAtIsNotAfterTheRenewal() {
        let now = date("2026-11-06T13:31:00+09:00")
        let meter = meter(plan: nil, now: now)
        // 期間の途中(3 日後)で契約が更新される: そこで新しい期間になるので、戻る日時は更新の時刻。
        meter.setPlan(.light, chargedAt: now.addingTimeInterval(-86_400), renewsAt: now.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(meter.snapshot().resetsAt, now.addingTimeInterval(2 * 86_400))
        // プランが切れたら期限で切らない(お試しの枠は課金の時刻から 7 日ごと)。
        meter.setPlan(nil)
        XCTAssertEqual(meter.snapshot().resetsAt, now.addingTimeInterval(-86_400 + 7 * 86_400))
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

    func testRecordsFromBeforeThePerDeviceSplitStillCountAndNewSpendingGoesToThisDevice() throws {
        let now = date("2026-10-31T09:00:00+09:00")
        let key = UsageRules.weekKey(for: now)
        let local = MemoryValueStore([key: "0.10"])
        let cloud = MemoryValueStore([key: "0.30"])
        let meter = meter(plan: .light, local: local, cloud: cloud, now: now)
        XCTAssertEqual(meter.snapshot().spentUSD, 0.30, accuracy: 1e-9, "端末ごとに分ける前の記録は、Keychain と iCloud の大きい方")
        meter.add(0.05)
        XCTAssertEqual(meter.snapshot().spentUSD, 0.35, accuracy: 1e-9)
        XCTAssertEqual(local.string(key), "0.10", "前の記録には書き足さない")
        let device = try XCTUnwrap(local.string(UsageMeter.deviceKey))
        let own = key + UsageMeter.deviceMarker + device
        XCTAssertEqual(Double(local.string(own) ?? ""), 0.05, "この端末の分を Keychain と iCloud の両方に書く")
        XCTAssertEqual(Double(cloud.string(own) ?? ""), 0.05)
    }

    func testReinstallKeepsTheDeviceAndItsSpending() {
        let now = date("2026-10-31T09:00:00+09:00")
        let local = MemoryValueStore()
        let cloud = MemoryValueStore()
        meter(plan: .light, local: local, cloud: cloud, now: now).add(0.20)
        // 入れ直し: Keychain に端末の ID と使用額が残る。iCloud に届いていなくても戻らない。
        let reinstalled = meter(plan: .light, local: local, cloud: MemoryValueStore(), now: now)
        XCTAssertEqual(reinstalled.snapshot().spentUSD, 0.20, accuracy: 1e-9)
    }

    func testTwoDevicesUsedBeforeICloudSyncsAreBothCounted() {
        let now = date("2026-11-06T13:31:00+09:00")
        // 同期の前: iPhone と iPad はそれぞれ自分の iCloud の写しに書く。
        let phoneCloud = MemoryValueStore()
        let padCloud = MemoryValueStore()
        let phone = meter(plan: nil, local: MemoryValueStore(), cloud: phoneCloud, now: now)
        let pad = meter(plan: nil, local: MemoryValueStore(), cloud: padCloud, now: now)
        for device in [phone, pad] {
            device.setPlan(.standard, chargeID: 21, chargedAt: now.addingTimeInterval(-3_600), renewsAt: now.addingTimeInterval(29 * 86_400))
        }
        phone.add(0.20)
        pad.add(0.10)
        XCTAssertEqual(phone.snapshot().spentUSD, 0.20, accuracy: 1e-9)
        XCTAssertEqual(pad.snapshot().spentUSD, 0.10, accuracy: 1e-9)

        // 同期: iCloud の Key-Value ストアは鍵ごとに揃う。端末ごとに鍵が違うので、どちらの分も残る。
        for key in padCloud.keys(withPrefix: "") { phoneCloud.set(padCloud.string(key), key) }
        for key in phoneCloud.keys(withPrefix: "") { padCloud.set(phoneCloud.string(key), key) }
        XCTAssertEqual(phone.snapshot().spentUSD, 0.30, accuracy: 1e-9, "大きい方の 0.20 ではなく、合計の 0.30")
        XCTAssertEqual(pad.snapshot().spentUSD, 0.30, accuracy: 1e-9)

        // 同期の後に足した分も、相手に届けば合計に入る。
        pad.add(0.05)
        for key in padCloud.keys(withPrefix: "") { phoneCloud.set(padCloud.string(key), key) }
        XCTAssertEqual(phone.snapshot().spentUSD, 0.35, accuracy: 1e-9)
    }

    func testSeededStoreStartsTheMatchingPeriodAsSpentAndANewPeriodFromZero() {
        // UI テストの準備(`STRUIS_USAGE_SEED_PREFIX`): お試しの週を使い切った状態から購入すると 0 から。
        let now = date("2026-11-06T13:31:00+09:00")
        let seeded = MirroredValues(local: SeededValueStore(prefix: "usage.week.", usd: 0.40), cloud: MemoryValueStore())
        let meter = UsageMeter(values: seeded, defaults: UserDefaults(suiteName: "usage-tests-\(UUID().uuidString)")!, now: { now })
        XCTAssertEqual(meter.snapshot().spentUSD, 0.40, accuracy: 1e-9)
        XCTAssertFalse(DeviceUsageGate(meter: meter).admit())
        meter.setPlan(.light, chargeID: 5, chargedAt: now, renewsAt: now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(meter.snapshot().spentUSD, 0)
        XCTAssertTrue(DeviceUsageGate(meter: meter).admit())
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
