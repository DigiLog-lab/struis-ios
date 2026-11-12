import XCTest
@testable import strius

/// 利用枠(#62・#78): 期間の区切り(課金した時刻から 7 日ごと、課金したことが無ければ月曜 0:00)・保存先の大きい方・プランごとの上限と
/// ソフトリミット(途中の答案の採点だけが余裕分を使う)・プランもお試しも無い時の停止・料金が分からない要求の見積もり・
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

    /// お試しの残りと規約の同意を差し替えた判定(端末の Keychain を読まない)。
    private func gate(_ meter: UsageMeter, trialRemaining: Int = 3, consented: Bool = true) -> DeviceUsageGate {
        DeviceUsageGate(meter: meter, trialRemaining: { trialRemaining }, consented: { consented })
    }

    private let grading = UsageRequest(kind: .timelineGrading, finishing: true)

    // MARK: - 初回の準備は枠に数えない

    private func billed(_ usd: Double) -> [String: Any] { ["estimated_cost_usd": usd, "cost_status": "estimated"] }

    /// ライトを買った直後の計画づくりと知識グラフの構築(上位モデル)は、枠を減らさない。出題と採点は減らす。
    func testTheFirstPlanAndGraphBuildAreNotCountedButTheProblemsAre() {
        let meter: UsageMeter = meter(plan: .light)
        let gate: DeviceUsageGate = gate(meter)
        gate.record(billed(0.23), requestBytes: 10, setup: .plan, turnID: "plan-1")
        gate.record(billed(0.24), requestBytes: 10, setup: .graph, turnID: "graph-build")
        gate.record(billed(0.28), requestBytes: 10, setup: .graph, turnID: "graph-extend")
        XCTAssertEqual(meter.snapshot().spentUSD, 0, accuracy: 1e-9)
        XCTAssertNil(gate.denial(for: .newWork))
        gate.record(billed(0.11), requestBytes: 10, setup: nil, turnID: "batch-1")
        gate.record(billed(0.01), requestBytes: 10, setup: nil, turnID: "answer-1")
        XCTAssertEqual(meter.snapshot().spentUSD, 0.12, accuracy: 1e-9)
        XCTAssertNil(gate.denial(for: .newWork))
    }

    /// 同じターンの送り直し・続きの要求は、数えないターンの数を増やさない。
    func testASecondRequestOfTheSameSetupTurnDoesNotUseAnotherFreeTurn() {
        let meter: UsageMeter = meter(plan: .light)
        let gate: DeviceUsageGate = gate(meter)
        gate.record(billed(0.2), requestBytes: 10, setup: .unit, turnID: "unit-1")
        gate.record(billed(0.2), requestBytes: 10, setup: .unit, turnID: "unit-1")
        XCTAssertEqual(meter.freeSetupCount(.unit), 1)
        XCTAssertEqual(meter.snapshot().spentUSD, 0, accuracy: 1e-9)
    }

    /// 単元づくりは 3 回まで数えず、4 回目からは枠に数える。課金されなかった要求は回数を使わない。
    func testTheFourthUnitIsCounted() {
        let meter: UsageMeter = meter(plan: .standard)
        let gate: DeviceUsageGate = gate(meter)
        gate.record(["estimated_cost_usd": NSNull(), "cost_status": "not_billed"], requestBytes: 10, setup: .unit, turnID: "unit-0")
        XCTAssertEqual(meter.freeSetupCount(.unit), 0)
        for index in 1...UsageRules.freeSetupTurns(.unit) {
            gate.record(billed(0.2), requestBytes: 10, setup: .unit, turnID: "unit-\(index)")
        }
        XCTAssertEqual(meter.snapshot().spentUSD, 0, accuracy: 1e-9)
        gate.record(billed(0.2), requestBytes: 10, setup: .unit, turnID: "unit-4")
        XCTAssertEqual(meter.snapshot().spentUSD, 0.2, accuracy: 1e-9)
        // 種類ごとに数える: 単元づくりを使い切っても、知識グラフの分は残っている。
        gate.record(billed(0.3), requestBytes: 10, setup: .graph, turnID: "graph-1")
        XCTAssertEqual(meter.snapshot().spentUSD, 0.2, accuracy: 1e-9)
    }

    /// 数えなかったターンの記録は、入れ直しても(Keychain)、別の端末でも(iCloud)残る。
    func testFreeSetupTurnsSurviveAReinstallAndAreSharedAcrossDevices() {
        let local = MemoryValueStore()
        let cloud = MemoryValueStore()
        let first: UsageMeter = meter(plan: .light, local: local, cloud: cloud)
        for index in 1...UsageRules.freeSetupTurns(.plan) {
            XCTAssertTrue(first.takesFree(.plan, turnID: "plan-\(index)"))
        }
        let other: UsageMeter = meter(plan: .light, local: MemoryValueStore(), cloud: cloud)
        XCTAssertFalse(other.takesFree(.plan, turnID: "plan-new"))
        let reinstalled: UsageMeter = meter(plan: .light, local: local, cloud: MemoryValueStore())
        XCTAssertFalse(reinstalled.takesFree(.plan, turnID: "plan-new"))
        XCTAssertTrue(reinstalled.takesFree(.plan, turnID: "plan-1"))
    }

    /// iPhone と iPad が同期の前にそれぞれ 1 回ずつ使っても、同期の後は両方の分が数えられる(端末ごとの鍵に書くので、
    /// 後から届いた方が相手の分を消さない)。
    func testFreeSetupTurnsFromTwoDevicesBeforeSyncAreBothCounted() {
        let phoneCloud = MemoryValueStore()
        let padCloud = MemoryValueStore()
        let phone: UsageMeter = meter(plan: .light, local: MemoryValueStore(), cloud: phoneCloud)
        let pad: UsageMeter = meter(plan: .light, local: MemoryValueStore(), cloud: padCloud)
        XCTAssertTrue(phone.takesFree(.plan, turnID: "phone-1"))
        XCTAssertTrue(pad.takesFree(.plan, turnID: "pad-1"))
        // 同期: 両方の端末が書いた鍵が、iCloud に集まる。
        let synced = MemoryValueStore()
        for cloud in [phoneCloud, padCloud] {
            for key in cloud.keys(withPrefix: "usage.free-setup.") { synced.set(cloud.string(key), key) }
        }
        let third: UsageMeter = meter(plan: .light, local: MemoryValueStore(), cloud: synced)
        XCTAssertEqual(third.freeSetupCount(.plan), 2)
        XCTAssertTrue(third.takesFree(.plan, turnID: "third-1"))
        XCTAssertFalse(third.takesFree(.plan, turnID: "third-2"))
        XCTAssertTrue(third.takesFree(.plan, turnID: "phone-1"))
    }

    /// 学習中に起きる知識グラフの見直し・1 段下りる依頼は「初回の準備」に入れない。最初の構築の続きの段は入れる。
    func testOnlyTheFirstGraphWorkIsSetup() {
        XCTAssertEqual(TimelineTurns.setupPurposes, ["graph_build", "graph_extend", "graph_step", "graph_misconceptions"])
        XCTAssertFalse(TimelineTurns.setupPurposes.contains("graph_review"))
        XCTAssertFalse(TimelineTurns.setupPurposes.contains("graph_descend"))
        // 学習中の見直し・1 段下りる依頼は「手入れ」: 何回でも数えない(回数は頼む側が 7 日に 1 回までに抑える)。
        XCTAssertEqual(TimelineTurns.upkeepPurposes, ["graph_review", "graph_descend"])
        let meter: UsageMeter = meter(plan: .light)
        let gate: DeviceUsageGate = gate(meter)
        for index in 0..<40 { gate.record(billed(0.23), requestBytes: 10, setup: .graphUpkeep, turnID: "review-\(index)") }
        XCTAssertEqual(meter.freeSetupCount(.graphUpkeep), 0, "数えないターンの ID は残さない")
        XCTAssertEqual(meter.snapshot().spentUSD, 0, accuracy: 1e-6)
        // 単元 4 つ分の最初の構築(構築 1 + 続きの段 + つまずきの洗い出し 1)が、数えないターンの数に収まる。
        XCTAssertGreaterThanOrEqual(UsageRules.freeSetupTurns(.graph), 4 * (TimelineTurns.graphStepLimit + 1))
    }

    /// 実測(2026-11-11、高2・三角関数): 構築 1・続きの段 3・つまずきの洗い出し 1 で 1.05 ドル。これを数えると、ライト(週 0.80 ドル)は
    /// 4 問で止まった。数えなければ、同じ 4 問で使うのは出題と採点の 0.21 ドル。
    func testTheMeasuredFirstSessionLeavesMostOfTheLightAllowance() {
        let meter: UsageMeter = meter(plan: .light)
        let gate: DeviceUsageGate = gate(meter)
        for (index, usd) in [0.2294, 0.2447, 0.2048, 0.1811, 0.1873].enumerated() {
            gate.record(billed(usd), requestBytes: 10, setup: .graph, turnID: "graph-\(index)")
        }
        for (index, usd) in [0.1115, 0.0104, 0.0019, 0.0023, 0.0157, 0.011, 0.0573, 0.0021].enumerated() {
            gate.record(billed(usd), requestBytes: 10, setup: nil, turnID: "work-\(index)")
        }
        XCTAssertEqual(meter.snapshot().spentUSD, 0.2122, accuracy: 1e-6)
        XCTAssertNil(gate.denial(for: .newWork))
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
        XCTAssertEqual(gate(reinstalled).denial(for: grading), .limitReached, "お試しの枠($0.25 + カード 1 枚分)を超えたまま")
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
        XCTAssertEqual(gate(meter).denial(for: .newWork), .limitReached)
        meter.setPlan(.light, chargeID: 5, chargedAt: now, renewsAt: now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(meter.snapshot().spentUSD, 0)
        XCTAssertNil(gate(meter).denial(for: .newWork))
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

    func testNewWorkStopsAtTheLimitAndOnlyTheGradingOfTheAnswerInProgressUsesTheGrace() {
        let meter = meter(plan: .light)
        let gate = gate(meter)
        meter.add(0.79)
        XCTAssertNil(gate.denial(for: .newWork))
        meter.add(0.02)
        XCTAssertTrue(meter.snapshot().isExhausted, "100% に達した")
        for kind in [TurnPlan.Kind.timelineBatch, .timelineReview, .timelineGraph, .workbookSet, .workbookUnit, .onboardingPlan] {
            XCTAssertEqual(gate.denial(for: UsageRequest.of(kind: kind, turnAdmitted: true)), .limitReached, "\(kind.rawValue) は新しい作業: 上限で止める")
        }
        XCTAssertEqual(gate.denial(for: UsageRequest.of(kind: .chat, turnAdmitted: false)), .limitReached, "新しい質問は上限で止める")
        XCTAssertNil(gate.denial(for: UsageRequest.of(kind: .chat, turnAdmitted: true)), "通った質問は、その返事までは返す")
        for kind in UsageRequest.gradingKinds {
            XCTAssertNil(gate.denial(for: UsageRequest.of(kind: kind, turnAdmitted: false)), "ソフトリミット: 解いている途中の答案(\(kind.rawValue))は採点まで通す")
        }
        meter.add(UsageRules.graceUSD)
        XCTAssertEqual(gate.denial(for: grading), .limitReached, "カード 1 枚分を超えたら通さない")
    }

    /// #62 の穴: 裏の出題は上限の手前までしか使えないので、上限の後の余裕分は途中の答案の採点に残る。
    func testBackgroundCardsCannotSpendTheGraceBeforeTheAnswerInProgressIsGraded() {
        let meter = meter(plan: .light)
        let gate = gate(meter)
        meter.add(0.799)
        let batch = UsageRequest.of(kind: .timelineBatch, turnAdmitted: false)
        XCTAssertNil(gate.denial(for: batch), "上限の手前なら出題を頼める")
        meter.add(0.05) // その出題で上限を越えた
        XCTAssertEqual(gate.denial(for: UsageRequest.of(kind: .timelineBatch, turnAdmitted: true)), .limitReached, "出題の続きの要求も上限で止める")
        XCTAssertNil(gate.denial(for: grading), "途中の答案の採点は通る")
    }

    func testWithoutAPlanOnlyTheTrialAllowanceIsAvailable() {
        let meter = meter(plan: nil)
        XCTAssertEqual(meter.snapshot().limitUSD, UsageRules.trialLimitUSD)
        meter.add(UsageRules.trialLimitUSD + UsageRules.graceUSD)
        XCTAssertEqual(gate(meter).denial(for: grading), .limitReached)
        meter.setPlan(.standard)
        XCTAssertNil(gate(meter).denial(for: .newWork), "購入すると、すぐに続けられる")
    }

    /// #78 の 6: プランが無く、お試しを使い切った(契約が切れた後を含む)なら、使用額が 0 でも送らない。送ったお試しの採点だけは通す。
    func testWithoutAPlanAndNoTrialLeftNothingIsSentExceptTheTrialGradingInProgress() {
        let meter = meter(plan: nil)
        XCTAssertNil(gate(meter, trialRemaining: 1).denial(for: .newWork), "お試しが残っていれば、お試しの枠の中で使える")
        let used = gate(meter, trialRemaining: 0)
        XCTAssertEqual(meter.snapshot().spentUSD, 0)
        for kind in [TurnPlan.Kind.chat, .timelineBatch, .timelineGrading, .workbookGrading, .workbookUnit, .onboardingPlan] {
            XCTAssertEqual(used.denial(for: UsageRequest.of(kind: kind, turnAdmitted: false)), .noPlan, "\(kind.rawValue) を送らない")
            XCTAssertEqual(used.denial(for: UsageRequest.of(kind: kind, turnAdmitted: true)), kind == .onboardingGrading ? nil : .noPlan)
        }
        XCTAssertNil(used.denial(for: UsageRequest.of(kind: .onboardingGrading, turnAdmitted: false)), "3 問目の採点の途中は通す")
        meter.setPlan(.light)
        XCTAssertNil(used.denial(for: .newWork), "購入すると、すぐに続けられる")
        meter.setPlan(nil)
        XCTAssertEqual(used.denial(for: .newWork), .noPlan, "契約が切れたら止める")
    }

    func testNothingIsSentUntilTheCurrentTermsAreAccepted() {
        let meter = meter(plan: .generous)
        XCTAssertEqual(gate(meter, consented: false).denial(for: grading), .consentRequired)
        XCTAssertNil(gate(meter, consented: false).usageDenial(), "画面の枠の判定は同意を見ない(同意は取り直しの画面が受け持つ)")
    }

    func testDenialIsReadBackFromTheFailedTurn() {
        XCTAssertEqual(UsageLimitResponse.denial(in: TurnRuntimeError.turnFailed(UsageDenial.limitReached.message).detail), .limitReached)
        XCTAssertEqual(UsageLimitResponse.denial(in: TurnRuntimeError.turnFailed(UsageDenial.noPlan.message).detail), .noPlan)
        XCTAssertEqual(UsageLimitResponse.denial(in: TurnRuntimeError.turnFailed(UsageDenial.consentRequired.message).detail), .consentRequired)
        XCTAssertNil(UsageLimitResponse.denial(in: "turn failed: Claude stream error: overloaded_error"))
        XCTAssertEqual(TurnRuntimeError.turnFailed(UsageDenial.noPlan.message).errorDescription, "お試しの3問を使い切りました。続けるには、設定の「利用枠」でプランを選んでください。")
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
        let gate: ClosedGate = ClosedGate()
        let upstream: ClaudeUpstream = ClaudeUpstream(baseURL: URL(string: "https://stub.invalid")!, apiKey: { "sk-test" },
                                                      session: URLSession(configuration: configuration), gate: gate)
        let hit: XCTestExpectation = expectation(forNotification: .usageLimitReached, object: nil) { notification in
            (notification.object as? UsageLimitHit)?.kind == .workbookSet
        }
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
        XCTAssertEqual(gate.requests, [UsageRequest(kind: .workbookSet, finishing: false)], "単元の問題づくりは新しい作業として確かめる")
        await fulfillment(of: [hit], timeout: 2)
    }
}

/// 送らせない判定(ランナーのテスト)。確かめた要求を残す。
nonisolated private final class ClosedGate: UsageGate, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [UsageRequest] = []
    var requests: [UsageRequest] { lock.withLock { seen } }
    func denial(for request: UsageRequest) -> UsageDenial? {
        lock.withLock { seen.append(request) }
        return .limitReached
    }
    func record(_ attempt: [String: Any], requestBytes: Int) {}
}
