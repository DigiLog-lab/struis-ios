import Foundation
import OSLog
import StoreKit
import SwiftUI

private let storeLog = Logger(subsystem: "com.digiloglab.strius", category: "subscription")

/// 購読(StoreKit 2、#40・#62)。サブスクリプショングループ 1 つに 3 商品(`groupLevel`: たっぷり 1・スタンダード 2・ライト 3)。
/// 今の契約は `.subscriptionStatusTask` で受け取り、有効なもののうち `groupLevel` が一番小さいものをプランとする。
/// App Store の無料トライアルは付けない(お試しはアプリの 3 問)。
@Observable
@MainActor
final class SubscriptionStore {
    /// App Store Connect のサブスクリプショングループ「Struis」の ID。
    /// Simulator・UI テスト・単体テストは `Config/Struis.storekit` のテスト用の ID(21579510)で動く。
    static let groupID = "22531808"

    enum LoadState: Equatable {
        case idle, loading, loaded, failed
    }

    private(set) var products: [UsagePlan: Product] = [:]
    private(set) var loadState: LoadState = .idle
    private(set) var plan: UsagePlan?
    private(set) var purchasing: UsagePlan?
    /// 今の契約を受け取るグループ。商品を読んだら、その商品のグループにする
    /// (Xcode の StoreKit の設定ファイルで動かした時は、設定ファイルのテスト用の ID になる)。
    private(set) var activeGroupID = SubscriptionStore.groupID
    var errorMessage: String?
    private let meter: UsageMeter
    private var updates: Task<Void, Never>?

    init(meter: UsageMeter = .shared) {
        self.meter = meter
        plan = meter.plan
    }

    /// 起動した時: 終わっていない取引を終わらせる(更新・家族の購入・別の端末での購入)。
    func start() {
        guard updates == nil else { return }
        updates = Task.detached {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
            }
        }
    }

    func price(of plan: UsagePlan) -> String { products[plan]?.displayPrice ?? plan.priceText }

    func loadProducts() async {
        guard loadState != .loading, products.count < UsagePlan.allCases.count else { return }
        loadState = .loading
        do {
            let loaded = try await Product.products(for: UsagePlan.allCases.map(\.productID))
            products = Dictionary(uniqueKeysWithValues: loaded.compactMap { product in UsagePlan(productID: product.id).map { ($0, product) } })
            if let group = products.values.first?.subscription?.subscriptionGroupID { activeGroupID = group }
            loadState = products.isEmpty ? .failed : .loaded
        } catch {
            storeLog.error("products failed: \(String(describing: error), privacy: .public)")
            loadState = .failed
        }
    }

    /// 購入する。買えたら true(プランは `subscriptionStatusTask` でも届く)。
    func purchase(_ plan: UsagePlan) async -> Bool {
        errorMessage = nil
        if products[plan] == nil { await loadProducts() }
        guard let product = products[plan] else {
            errorMessage = "App Store に接続できませんでした。少し待ってから、もう一度押してください。"
            return false
        }
        purchasing = plan
        defer { purchasing = nil }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    errorMessage = "購入を確かめられませんでした。もう一度試してください。"
                    return false
                }
                await transaction.finish()
                apply(plans: [plan])
                return true
            case .pending:
                errorMessage = "購入の承認を待っています。承認されると使えるようになります。"
                return false
            case .userCancelled:
                return false
            @unknown default:
                return false
            }
        } catch {
            storeLog.error("purchase failed: \(String(describing: error), privacy: .public)")
            errorMessage = "購入できませんでした。もう一度試してください。"
            return false
        }
    }

    /// 購入を復元(App Store と同期して、今の契約を読み直す)。
    func restore() async {
        errorMessage = nil
        do {
            try await AppStore.sync()
        } catch {
            storeLog.error("restore failed: \(String(describing: error), privacy: .public)")
        }
        var plans: [UsagePlan] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.revocationDate == nil, let plan = UsagePlan(productID: transaction.productID) { plans.append(plan) }
        }
        apply(plans: plans)
        if plans.isEmpty { errorMessage = "復元できる購入が見つかりませんでした。" }
    }

    /// `.subscriptionStatusTask` から: 有効な契約(購読中・猶予期間)のうち、一番上のプラン。
    func update(statuses: [Product.SubscriptionInfo.Status]) {
        let plans = statuses.compactMap { status -> UsagePlan? in
            guard status.state == .subscribed || status.state == .inGracePeriod, case .verified(let transaction) = status.transaction else { return nil }
            return UsagePlan(productID: transaction.productID)
        }
        apply(plans: plans, replacing: true)
    }

    private func apply(plans: [UsagePlan], replacing: Bool = false) {
        let best = UsagePlan.best(of: plans)
        guard replacing || best != nil else { return }
        meter.setPlan(best)
        plan = meter.plan
    }

    /// 端末の控え(DEBUG の差し替えを含む)を読み直す。
    func refreshFromMeter() { plan = meter.plan }
}

extension View {
    /// 今の契約を受け取り続ける(アプリの一番外側に付ける)。
    func struisSubscriptionStatus(_ store: SubscriptionStore) -> some View {
        subscriptionStatusTask(for: store.activeGroupID) { state in
            if let statuses = state.value { store.update(statuses: statuses) }
        }
        .task {
            store.start()
            await store.loadProducts()
        }
    }
}
