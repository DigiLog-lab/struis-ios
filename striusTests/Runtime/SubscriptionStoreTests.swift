import StoreKit
import StoreKitTest
import XCTest
@testable import strius

/// 購入まわり(#40・#62): `Config/Struis.storekit` を `SKTestSession` で読み、画面を出さずに `SubscriptionStore` と
/// 利用枠(`UsageMeter`・`DeviceUsageGate`)を確かめる。`.subscriptionStatusTask` の代わりに、グループの契約の状態を
/// 読み直して `update(statuses:)` に渡す。購入は `product.purchase()` の代わりに `SKTestSession.buyProduct` で行う
/// (`product.purchase()` は、StoreKit の設定が入っていない Simulator ではテストのホストのプロセスが終わるまで Sandbox の
/// アカウントの認証を待つ)。`buyProduct` は契約の状態に出るまで待ってから返す。`buyProduct` は `failTransactionsEnabled` を見ないので、その時は StoreKit と同じエラーを投げてまねる。
///
/// 使用額の決まり: 期間は最後に課金された時刻(取引の `purchaseDate`)から 7 日ごと。課金(購入・上げた時・更新)すると
/// 新しい期間になり、使用額は 0 から始まる。下げる予約・解約の予約は課金ではないので、期間も使用額もそのまま(下げたプランは
/// 次の更新日から、その更新で 0 から)。期限切れ・返金のあとは、お試しの枠(週 $0.25)に今の期間の使用額を引き継ぎ、
/// 期間の終わりに戻す。
@MainActor
final class SubscriptionStoreTests: XCTestCase {
    /// `Config/Struis.storekit` のテスト用のグループ ID(本番の `SubscriptionStore.groupID` とは違う)。
    private static let groupID = "21579510"
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
        // 実際の時刻で進む(`SKTestSession` の取引の `purchaseDate` は実際の時刻)。期間の切れ目は `clock.date` を進めて確かめる。
        clock = TestClock()
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
        let session = session!
        let store = SubscriptionStore(meter: meter) { product in
            if session.failTransactionsEnabled { throw StoreKitError.unknown }
            let transaction = try await session.buyProduct(identifier: product.id)
            // `product.purchase()` は契約の状態に出てから返る。`buyProduct` は少し遅れて出るので、出るまで待つ
            // (上げた時は新しい取引、下げた時は次の更新のプラン)。15 秒たっても出なければそのまま返す(続く確かめで落ちる)。
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                let statuses = try await Product.SubscriptionInfo.status(for: Self.groupID)
                if statuses.contains(where: { status in
                    (try? status.transaction.payloadValue.id) == transaction.id
                        || (try? status.renewalInfo.payloadValue.autoRenewPreference) == product.id
                }) { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            return .success(.verified(transaction))
        }
        return (store, meter)
    }

    /// `.subscriptionStatusTask` が届ける今の契約を読み直す。
    private func deliverStatuses(to store: SubscriptionStore) async throws {
        store.update(statuses: try await Product.SubscriptionInfo.status(for: Self.groupID))
    }

    /// 更新・期限切れ・返金を起こし、契約の状態が変わってから届ける(`SKTestSession` の操作は少し遅れて状態に出る)。
    /// 15 秒たっても変わらなければ、そのままの状態を届ける(続く確かめで落ちる)。
    private func deliverStatuses(to store: SubscriptionStore, after change: () throws -> Void) async throws {
        func signature(_ statuses: [Product.SubscriptionInfo.Status]) -> [String] {
            statuses.map { "\($0.state.rawValue):\((try? $0.transaction.payloadValue.id) ?? 0)" }
        }
        let before = signature(try await Product.SubscriptionInfo.status(for: Self.groupID))
        try change()
        let deadline = Date().addingTimeInterval(15)
        var statuses = try await Product.SubscriptionInfo.status(for: Self.groupID)
        while signature(statuses) == before, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            statuses = try await Product.SubscriptionInfo.status(for: Self.groupID)
        }
        store.update(statuses: statuses)
    }

    /// 自動更新を切り替え、`cancelsAt` が変わるまで読み直す(`SKTestSession` の操作は少し遅れて状態に出る)。
    /// 15 秒たっても変わらなければ、そのまま返す(続く確かめで落ちる)。
    private func refreshUntilCancelsAtChanges(on store: SubscriptionStore, after change: () throws -> Void) async throws {
        let before: Date? = store.cancelsAt
        try change()
        let deadline = Date().addingTimeInterval(15)
        repeat {
            await store.refreshStatus()
            if store.cancelsAt != before { return }
            try await Task.sleep(for: .milliseconds(200))
        } while Date() < deadline
    }

    private func transaction(for plan: UsagePlan) -> SKTestTransaction? {
        session.allTransactions().last { $0.productIdentifier == plan.productID }
    }

    func testStoreKitConfigurationHasThreePlansInOneGroupByGroupLevel() async throws {
        let (store, _) = install()
        XCTAssertEqual(store.activeGroupID, SubscriptionStore.groupID, "商品を読むまでは本番のグループ")
        await store.loadProducts()
        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertEqual(store.activeGroupID, Self.groupID, "商品を読んだら、設定ファイルのグループで契約を受け取る")
        for plan in UsagePlan.allCases {
            let product = try XCTUnwrap(store.products[plan], plan.displayName)
            XCTAssertEqual(product.subscription?.subscriptionGroupID, Self.groupID)
            XCTAssertNil(product.subscription?.introductoryOffer, "App Store の無料トライアルは付けない")
            XCTAssertEqual(product.displayPrice, plan.priceText, "購入画面に出す価格")
        }
    }

    // MARK: - 上げる・下げる

    func testFirstPurchaseStartsANewPeriodFromZero() async throws {
        let (store, meter) = install()
        meter.add(UsageRules.trialLimitUSD + UsageRules.graceUSD)
        XCTAssertFalse(DeviceUsageGate(meter: meter).admit(), "お試しの枠を使い切った")

        let purchased = await store.purchase(.light)
        XCTAssertTrue(purchased)
        try await deliverStatuses(to: store)
        let snapshot = meter.snapshot()
        XCTAssertEqual(snapshot.spentUSD, 0, "購入したら 0 から")
        XCTAssertEqual(snapshot.limitUSD, UsagePlan.light.weeklyLimitUSD)
        XCTAssertEqual(snapshot.resetsAt.timeIntervalSince(try XCTUnwrap(meter.chargedAt)), UsageRules.periodSeconds, accuracy: 1,
                       "購入した時刻から 7 日後に戻る")
        XCTAssertTrue(DeviceUsageGate(meter: meter).admit())
    }

    func testUpgradeFromStandardToGenerousSwitchesNowAndStartsANewPeriodFromZero() async throws {
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
        XCTAssertEqual(snapshot.spentUSD, 0, "上げた(課金した)ら 0 から")
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
        XCTAssertEqual(meter.snapshot().spentUSD, 0, "上げたら 0 から")
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
        XCTAssertEqual(meter.snapshot().spentUSD, 1.50, accuracy: 1e-9, "下げる予約は課金ではないので、使用額はそのまま")
        XCTAssertTrue(DeviceUsageGate(meter: meter).admit())

        // 次の更新日。
        try await deliverStatuses(to: store) { try session.forceRenewalOfSubscription(productIdentifier: UsagePlan.standard.productID) }
        XCTAssertEqual(store.plan, .light, "更新日からライト")
    }

    func testRenewalStartsANewPeriodFromZeroEvenAfterADowngrade() async throws {
        let (store, meter) = install()
        _ = await store.purchase(.standard)
        meter.add(1.50)
        _ = await store.purchase(.light)
        let before: UInt64 = try XCTUnwrap(meter.chargeID)
        try await deliverStatuses(to: store) { try session.forceRenewalOfSubscription(productIdentifier: UsagePlan.standard.productID) }
        XCTAssertEqual(store.plan, .light)

        let snapshot = meter.snapshot()
        XCTAssertNotEqual(try XCTUnwrap(meter.chargeID), before, "更新の取引から新しい期間")
        XCTAssertEqual(snapshot.spentUSD, 0, "更新(課金)したら 0 から。スタンダードで使った $1.50 でライトの枠が埋まったままにならない")
        XCTAssertEqual(snapshot.limitUSD, UsagePlan.light.weeklyLimitUSD)
        XCTAssertTrue(DeviceUsageGate(meter: meter).admit())
    }

    // MARK: - 解約

    func testCancellingKeepsThePlanUntilTheEndOfThePeriodAndUndoingClearsTheDate() async throws {
        let (store, meter) = install()
        _ = await store.purchase(.standard)
        XCTAssertNil(store.cancelsAt, "自動更新が続いている間は解約の日付を出さない")
        XCTAssertNotNil(meter.renewsAt, "自動更新が続いている間は、更新の予定日時で期間が替わる")
        let purchase = try XCTUnwrap(transaction(for: .standard))

        try await refreshUntilCancelsAtChanges(on: store) { try session.disableAutoRenewForTransaction(identifier: purchase.identifier) }
        let cancelsAt = try XCTUnwrap(store.cancelsAt, "解約したら、使える最後の日時が分かる")
        XCTAssertGreaterThan(cancelsAt, Date())
        XCTAssertEqual(store.plan, .standard, "解約しても期間の終わりまでは今のプラン")
        XCTAssertNil(meter.renewsAt, "解約の予約中は、期限が来ても使用額は戻らないので、戻る日時を期限で縮めない")

        try await refreshUntilCancelsAtChanges(on: store) { try session.enableAutoRenewForTransaction(identifier: purchase.identifier) }
        XCTAssertNil(store.cancelsAt, "解約を取り消したら出さない")
        XCTAssertEqual(store.plan, .standard)
        XCTAssertNotNil(meter.renewsAt, "解約を取り消したら、また更新の予定日時で期間が替わる")
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
        XCTAssertEqual(snapshot.spentUSD, 0.20, accuracy: 1e-9, "今の期間の使用額は引き継ぐ")
        XCTAssertTrue(DeviceUsageGate(meter: meter).admit())
        meter.add(0.15)
        XCTAssertFalse(DeviceUsageGate(meter: meter).admit(), "お試しの枠を超えたら止まる")
    }

    func testAfterExpiryWithSpendingOverTheTrialAllowanceItStopsUntilThePeriodEnds() async throws {
        let (store, meter) = install()
        _ = await store.purchase(.standard)
        meter.add(1.00)
        try await deliverStatuses(to: store) { try session.expireSubscription(productIdentifier: UsagePlan.standard.productID) }

        XCTAssertNil(store.plan)
        XCTAssertEqual(meter.snapshot().limitUSD, UsageRules.trialLimitUSD)
        XCTAssertFalse(DeviceUsageGate(meter: meter).admit())
        let end: Date = UsageRules.periodEnd(for: clock.date, chargedAt: meter.chargedAt)
        clock.date = end.addingTimeInterval(-60)
        XCTAssertFalse(DeviceUsageGate(meter: meter).admit(), "期間の終わりの直前も止まったまま")
        clock.date = end
        XCTAssertTrue(DeviceUsageGate(meter: meter).admit(), "期間の終わり(最後に課金した時刻から 7 日)からお試しの枠が使える")
    }

    func testAfterARefundTheTrialAllowanceTakesOverThisWeeksSpending() async throws {
        let (store, meter) = install()
        _ = await store.purchase(.standard)
        meter.add(0.20)
        let purchase = try XCTUnwrap(transaction(for: .standard))
        try await deliverStatuses(to: store) { try session.refundTransaction(identifier: purchase.identifier) }

        XCTAssertNil(store.plan)
        XCTAssertEqual(meter.snapshot().limitUSD, UsageRules.trialLimitUSD, "お試しの枠(週 $0.25)へ戻る")
        XCTAssertEqual(meter.snapshot().spentUSD, 0.20, accuracy: 1e-9, "今の期間の使用額は引き継ぐ")
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
        XCTAssertEqual(reinstalledMeter.snapshot().spentUSD, 0.50, accuracy: 1e-9, "入れ直しても使用額は戻らない(契約の状態から同じ期間になる)")
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
        XCTAssertNotNil(meter.renewsAt, "復元でも、自動更新が続いていれば更新の予定日時を持つ")
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

/// 実際の時刻で進み、先へ進められる時計(期間の切れ目を確かめる)。
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    var date: Date {
        get { lock.withLock { Date().addingTimeInterval(offset) } }
        set { lock.withLock { offset = newValue.timeIntervalSinceNow } }
    }
}
