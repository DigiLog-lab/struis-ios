import StoreKit
import StoreKitTest
import XCTest
@testable import strius

/// 購入まわり(#40・#62): `Config/Struis.storekit` を `SKTestSession` で読み、画面を出さずに `SubscriptionStore` と
/// 利用枠(`UsageMeter`・`DeviceUsageGate`)を確かめる。`.subscriptionStatusTask` の代わりに、グループの契約の状態を
/// 読み直して `update(statuses:)` に渡す。
///
/// 週の使用額の決まり: プランが変わっても今週の使用額は引き継ぎ、月曜 0:00 にだけ戻す。上げた直後は新しい上限から
/// 今週の使用額を引いた分が使える。下げた時は次の更新日から切り替わり、切り替え後に上限を超えていれば次の月曜まで
/// 止まる。期限切れのあとは、お試しの枠(週 $0.25)に今週の使用額を引き継ぐ。
@MainActor
final class SubscriptionStoreTests: XCTestCase {
    private var session: SKTestSession!
    private var clock: TestClock!
    /// 入れ直しても残る保存先(Keychain と iCloud)。
    private var local: MemoryValueStore!
    private var cloud: MemoryValueStore!

    override func setUp() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Config/Struis.storekit")
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.failTransactionsEnabled = false
        // 水曜の昼(週の途中)。
        clock = TestClock(UsageRules.weekStart(for: Date()).addingTimeInterval(2 * 86_400 + 12 * 3_600))
        local = MemoryValueStore()
        cloud = MemoryValueStore()
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        session = nil
    }

    /// アプリを入れた直後の状態(UserDefaults は空。Keychain と iCloud は `local`・`cloud` を引き継ぐ)。
    private func install() -> (store: SubscriptionStore, meter: UsageMeter) {
        let defaults = UserDefaults(suiteName: "subscription-tests-\(UUID().uuidString)")!
        let clock = clock!
        let meter = UsageMeter(values: MirroredValues(local: local, cloud: cloud), defaults: defaults, now: { clock.date })
        return (SubscriptionStore(meter: meter), meter)
    }

    /// `.subscriptionStatusTask` が届ける今の契約を読み直す。
    private func deliverStatuses(to store: SubscriptionStore) async throws {
        store.update(statuses: try await Product.SubscriptionInfo.status(for: SubscriptionStore.groupID))
    }

    /// 更新・期限切れ・返金を起こし、契約の状態が変わってから届ける(`SKTestSession` の操作は少し遅れて状態に出る)。
    /// 15 秒たっても変わらなければ、そのままの状態を届ける(続く確かめで落ちる)。
    private func deliverStatuses(to store: SubscriptionStore, after change: () throws -> Void) async throws {
        func signature(_ statuses: [Product.SubscriptionInfo.Status]) -> [String] {
            statuses.map { "\($0.state.rawValue):\((try? $0.transaction.payloadValue.id) ?? 0)" }
        }
        let before = signature(try await Product.SubscriptionInfo.status(for: SubscriptionStore.groupID))
        try change()
        let deadline = Date().addingTimeInterval(15)
        var statuses = try await Product.SubscriptionInfo.status(for: SubscriptionStore.groupID)
        while signature(statuses) == before, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            statuses = try await Product.SubscriptionInfo.status(for: SubscriptionStore.groupID)
        }
        store.update(statuses: statuses)
    }

    private func transaction(for plan: UsagePlan) -> SKTestTransaction? {
        session.allTransactions().last { $0.productIdentifier == plan.productID }
    }

    func testStoreKitConfigurationHasThreePlansInOneGroupByGroupLevel() async throws {
        let (store, _) = install()
        await store.loadProducts()
        XCTAssertEqual(store.loadState, .loaded)
        for plan in UsagePlan.allCases {
            let product = try XCTUnwrap(store.products[plan], plan.displayName)
            XCTAssertEqual(product.subscription?.subscriptionGroupID, SubscriptionStore.groupID)
            XCTAssertNil(product.subscription?.introductoryOffer, "App Store の無料トライアルは付けない")
            XCTAssertEqual(product.displayPrice, plan.priceText, "購入画面に出す価格")
        }
    }

    // MARK: - 上げる・下げる

    func testUpgradeFromStandardToGenerousSwitchesNowAndKeepsThisWeeksSpending() async throws {
        let (store, meter) = install()
        let purchasedStandard = await store.purchase(.standard)
        XCTAssertTrue(purchasedStandard)
        XCTAssertEqual(store.plan, .standard)
        meter.add(1.50)

        let upgraded = await store.purchase(.generous)
        XCTAssertTrue(upgraded)
        XCTAssertEqual(store.plan, .generous)
        try await deliverStatuses(to: store)
        XCTAssertEqual(store.plan, .generous, "有効な契約のうち groupLevel の小さい方(たっぷり 1)")

        let snapshot = meter.snapshot()
        XCTAssertEqual(snapshot.limitUSD, UsagePlan.generous.weeklyLimitUSD)
        XCTAssertEqual(snapshot.spentUSD, 1.50, accuracy: 1e-9, "今週の使用額は引き継ぐ")
        XCTAssertEqual(snapshot.limitUSD - snapshot.spentUSD, 4.80 - 1.50, accuracy: 1e-9, "新しい上限から今週の使用額を引いた分が使える")
        XCTAssertTrue(DeviceUsageGate(meter: meter).admit())
    }

    func testUpgradeRightAfterReachingTheLimitLetsTheLearnerContinue() async throws {
        let (store, meter) = install()
        _ = await store.purchase(.standard)
        meter.add(UsagePlan.standard.weeklyLimitUSD + UsageRules.graceUSD)
        XCTAssertFalse(DeviceUsageGate(meter: meter).admit())

        _ = await store.purchase(.generous)
        try await deliverStatuses(to: store)
        XCTAssertTrue(DeviceUsageGate(meter: meter).admit(), "上げた直後から続けられる")
        XCTAssertEqual(meter.snapshot().spentUSD, 2.07, accuracy: 1e-9)
    }

    func testDowngradeKeepsTheCurrentPlanUntilTheNextRenewal() async throws {
        let (store, meter) = install()
        _ = await store.purchase(.standard)
        meter.add(1.50)

        _ = await store.purchase(.light)
        XCTAssertEqual(store.plan, .standard, "下げた直後は、次の更新日まで今のプランのまま")
        try await deliverStatuses(to: store)
        XCTAssertEqual(store.plan, .standard, "契約の状態でも、更新日まではスタンダード")
        XCTAssertEqual(meter.snapshot().limitUSD, UsagePlan.standard.weeklyLimitUSD)
        XCTAssertTrue(DeviceUsageGate(meter: meter).admit())

        // 次の更新日。
        try await deliverStatuses(to: store) { try session.forceRenewalOfSubscription(productIdentifier: UsagePlan.standard.productID) }
        XCTAssertEqual(store.plan, .light, "更新日からライト")
    }

    func testAfterADowngradeTakesEffectSpendingOverTheNewLimitStopsUntilMonday() async throws {
        let (store, meter) = install()
        _ = await store.purchase(.standard)
        meter.add(1.50)
        _ = await store.purchase(.light)
        try await deliverStatuses(to: store) { try session.forceRenewalOfSubscription(productIdentifier: UsagePlan.standard.productID) }
        XCTAssertEqual(store.plan, .light)

        let snapshot = meter.snapshot()
        XCTAssertEqual(snapshot.spentUSD, 1.50, accuracy: 1e-9, "今週の使用額は引き継ぐ")
        XCTAssertTrue(snapshot.isExhausted)
        XCTAssertEqual(snapshot.remainingProblems, 0)
        XCTAssertFalse(DeviceUsageGate(meter: meter).admit(), "切り替え後に上限を超えていれば止まる")

        clock.date = UsageRules.resetDate(after: clock.date).addingTimeInterval(-60)
        XCTAssertFalse(DeviceUsageGate(meter: meter).admit(), "日曜の 23:59 も止まったまま")
        clock.date = UsageRules.resetDate(after: clock.date)
        XCTAssertEqual(meter.snapshot().spentUSD, 0, "月曜 0:00 に戻る")
        XCTAssertTrue(DeviceUsageGate(meter: meter).admit())
    }

    // MARK: - 期限切れ・返金

    func testAfterExpiryTheTrialAllowanceTakesOverThisWeeksSpending() async throws {
        let (store, meter) = install()
        _ = await store.purchase(.light)
        meter.add(0.20)
        try await deliverStatuses(to: store) { try session.expireSubscription(productIdentifier: UsagePlan.light.productID) }

        XCTAssertNil(store.plan)
        let snapshot = meter.snapshot()
        XCTAssertEqual(snapshot.limitUSD, UsageRules.trialLimitUSD, "お試しの枠(週 $0.25)へ戻る")
        XCTAssertEqual(snapshot.spentUSD, 0.20, accuracy: 1e-9, "今週の使用額は引き継ぐ")
        XCTAssertTrue(DeviceUsageGate(meter: meter).admit())
        meter.add(0.15)
        XCTAssertFalse(DeviceUsageGate(meter: meter).admit(), "お試しの枠を超えたら止まる")
    }

    func testAfterExpiryWithSpendingOverTheTrialAllowanceItStopsUntilMonday() async throws {
        let (store, meter) = install()
        _ = await store.purchase(.standard)
        meter.add(1.00)
        try await deliverStatuses(to: store) { try session.expireSubscription(productIdentifier: UsagePlan.standard.productID) }

        XCTAssertNil(store.plan)
        XCTAssertEqual(meter.snapshot().limitUSD, UsageRules.trialLimitUSD)
        XCTAssertFalse(DeviceUsageGate(meter: meter).admit())
        clock.date = UsageRules.resetDate(after: clock.date)
        XCTAssertTrue(DeviceUsageGate(meter: meter).admit(), "月曜 0:00 からお試しの枠が使える")
    }

    func testAfterARefundTheTrialAllowanceTakesOverThisWeeksSpending() async throws {
        let (store, meter) = install()
        _ = await store.purchase(.standard)
        meter.add(0.20)
        let purchase = try XCTUnwrap(transaction(for: .standard))
        try await deliverStatuses(to: store) { try session.refundTransaction(identifier: purchase.identifier) }

        XCTAssertNil(store.plan)
        XCTAssertEqual(meter.snapshot().limitUSD, UsageRules.trialLimitUSD, "お試しの枠(週 $0.25)へ戻る")
        XCTAssertEqual(meter.snapshot().spentUSD, 0.20, accuracy: 1e-9, "今週の使用額は引き継ぐ")
    }

    func testRestoreDoesNotBringBackARefundedPlan() async throws {
        let (store, _) = install()
        _ = await store.purchase(.standard)
        let purchase = try XCTUnwrap(transaction(for: .standard))
        try await deliverStatuses(to: store) { try session.refundTransaction(identifier: purchase.identifier) }

        let (reinstalled, meter) = install()
        await reinstalled.restore()
        XCTAssertNil(reinstalled.plan)
        XCTAssertNotNil(reinstalled.errorMessage)
        XCTAssertEqual(meter.snapshot().limitUSD, UsageRules.trialLimitUSD)
    }

    // MARK: - 入れ直し

    func testReinstallRestoresThePurchasedPlanAndKeepsThisWeeksSpending() async throws {
        let (store, meter) = install()
        _ = await store.purchase(.standard)
        meter.add(0.50)

        // 入れ直し: UserDefaults の控えは消え、Keychain と iCloud の使用額は残る。
        let (reinstalled, reinstalledMeter) = install()
        XCTAssertNil(reinstalled.plan, "起動直後は端末の控えが無い")
        try await deliverStatuses(to: reinstalled)
        XCTAssertEqual(reinstalled.plan, .standard, "契約の状態から購入済みのプランが戻る")
        XCTAssertEqual(reinstalledMeter.snapshot().limitUSD, UsagePlan.standard.weeklyLimitUSD)
        XCTAssertEqual(reinstalledMeter.snapshot().spentUSD, 0.50, accuracy: 1e-9, "入れ直しても今週の使用額は戻らない")
    }

    func testRestorePurchasesBringsBackTheTopPlanAfterReinstall() async throws {
        let (store, _) = install()
        _ = await store.purchase(.standard)
        _ = await store.purchase(.generous)

        let (reinstalled, meter) = install()
        await reinstalled.restore()
        XCTAssertEqual(reinstalled.plan, .generous)
        XCTAssertNil(reinstalled.errorMessage)
        XCTAssertEqual(meter.snapshot().limitUSD, UsagePlan.generous.weeklyLimitUSD)
    }

    // MARK: - 購入の失敗

    func testFailedPurchaseKeepsNoPlanAndReturnsThePaywallToBeforePurchase() async throws {
        let (store, meter) = install()
        let model = OnboardingModel(profile: OnboardingProfile(), records: OnboardingRecords(values: MirroredValues(local: MemoryValueStore(), cloud: MemoryValueStore())),
                                    hasPlan: { store.plan != nil }, isClaudeAvailable: { true }, start: .paywall)
        XCTAssertEqual(model.step, .paywall)
        await store.loadProducts()
        session.failTransactionsEnabled = true

        // 購入画面のボタンと同じ流れ。
        if await store.purchase(.light) { model.afterPurchase() }

        XCTAssertNil(store.plan, "プランは変わらない")
        XCTAssertNil(meter.plan)
        XCTAssertEqual(meter.snapshot().limitUSD, UsageRules.trialLimitUSD)
        XCTAssertNil(store.purchasing, "ボタンは「購入しています」から戻り、押せる")
        XCTAssertNotNil(store.errorMessage, "購入できなかったことを出す")
        XCTAssertEqual(model.step, .paywall, "購入画面に留まる")
        try await deliverStatuses(to: store)
        XCTAssertNil(store.plan)

        // 失敗が直れば、同じ画面からもう一度買える。
        session.failTransactionsEnabled = false
        if await store.purchase(.light) { model.afterPurchase() }
        XCTAssertEqual(store.plan, .light)
        XCTAssertNil(store.errorMessage)
        XCTAssertNotEqual(model.step, .paywall)
    }

    func testFailedUpgradeKeepsTheCurrentPlan() async throws {
        let (store, meter) = install()
        _ = await store.purchase(.standard)
        session.failTransactionsEnabled = true

        let upgraded = await store.purchase(.generous)
        XCTAssertFalse(upgraded)
        XCTAssertEqual(store.plan, .standard)
        XCTAssertNil(store.purchasing)
        XCTAssertNotNil(store.errorMessage)
        try await deliverStatuses(to: store)
        XCTAssertEqual(store.plan, .standard)
        XCTAssertEqual(meter.snapshot().limitUSD, UsagePlan.standard.weeklyLimitUSD)
    }
}

/// 進められる時計(週の切れ目を確かめる)。
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var date: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
