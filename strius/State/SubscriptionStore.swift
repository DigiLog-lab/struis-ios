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
    /// 解約の予約中(自動更新が止まっている)なら、今のプランを使える最後の日時。自動更新が続いていれば nil。
    private(set) var cancelsAt: Date?
    /// 今の契約を受け取るグループ。商品を読んだら、その商品のグループにする
    /// (Xcode の StoreKit の設定ファイルで動かした時は、設定ファイルのテスト用の ID になる)。
    private(set) var activeGroupID = SubscriptionStore.groupID
    var errorMessage: String?
    /// 商品を買う 1 か所。本番は `product.purchase()`。単体テストは `SKTestSession.buyProduct` に差し替える。
    typealias Purchase = @MainActor (Product) async throws -> Product.PurchaseResult
    private let meter: UsageMeter
    private let purchaseProduct: Purchase
    private var updates: Task<Void, Never>?

    init(meter: UsageMeter = .shared, purchase: @escaping Purchase = { try await $0.purchase() }) {
        self.meter = meter
        purchaseProduct = purchase
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

    /// 購入する。買えたら true。プランは契約の状態から決める(`subscriptionStatusTask` でも届く)。
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
            switch try await purchaseProduct(product) {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    errorMessage = "購入を確かめられませんでした。もう一度試してください。"
                    return false
                }
                await transaction.finish()
                // 押されたプランをそのまま使わず、契約の状態を読み直す(下げた時は次の更新日まで今のプランのまま)。
                if let statuses = try? await product.subscription?.status, !statuses.isEmpty {
                    update(statuses: statuses)
                } else {
                    let bought: [UsagePlan] = UsagePlan(productID: transaction.productID).map { [$0] } ?? []
                    apply(plans: bought, charges: Dictionary(uniqueKeysWithValues: bought.map { ($0, Charge(transaction)) }))
                    cancelsAt = nil
                }
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
        var charges: [UsagePlan: Charge] = [:]
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.revocationDate == nil, !transaction.isUpgraded,
               let plan = UsagePlan(productID: transaction.productID) {
                plans.append(plan)
                charges[plan] = Charge(transaction)
            }
        }
        apply(plans: plans, charges: charges)
        if plans.isEmpty { errorMessage = "復元できる購入が見つかりませんでした。" }
    }

    /// 契約の状態を読み直す。管理シートでの解約は `.subscriptionStatusTask` に届かないことがあるので、シートを閉じた時に読む。
    func refreshStatus() async {
        do {
            let statuses: [Product.SubscriptionInfo.Status] = try await Product.SubscriptionInfo.status(for: activeGroupID)
            update(statuses: statuses)
        } catch {
            storeLog.error("status failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// `.subscriptionStatusTask` から: 有効な契約(購読中・猶予期間)のうち、一番上のプランと、その解約の予約。
    func update(statuses: [Product.SubscriptionInfo.Status]) {
        var plans: [UsagePlan] = []
        var endDates: [UsagePlan: Date] = [:]
        var charges: [UsagePlan: Charge] = [:]
        for status in statuses {
            guard status.state == .subscribed || status.state == .inGracePeriod,
                  case .verified(let transaction) = status.transaction,
                  let plan = UsagePlan(productID: transaction.productID) else { continue }
            plans.append(plan)
            charges[plan] = Charge(transaction)
            if case .verified(let renewal) = status.renewalInfo, !renewal.willAutoRenew {
                endDates[plan] = transaction.expirationDate
            }
        }
        apply(plans: plans, charges: charges, replacing: true)
        cancelsAt = UsagePlan.best(of: plans).flatMap { endDates[$0] }
    }

    /// 取引から読む、課金の時刻と期限。利用枠の 7 日はこの課金の時刻から数える(購入・上げた時・更新で 0 から始まる)。
    struct Charge: Equatable {
        var chargedAt: Date
        var expiresAt: Date?

        init(chargedAt: Date, expiresAt: Date?) {
            self.chargedAt = chargedAt
            self.expiresAt = expiresAt
        }

        init(_ transaction: StoreKit.Transaction) {
            self.init(chargedAt: transaction.purchaseDate, expiresAt: transaction.expirationDate)
        }
    }

    private func apply(plans: [UsagePlan], charges: [UsagePlan: Charge], replacing: Bool = false) {
        let best: UsagePlan? = UsagePlan.best(of: plans)
        guard replacing || best != nil else { return }
        let charge: Charge? = best.flatMap { charges[$0] }
        meter.setPlan(best, chargedAt: charge?.chargedAt, expiresAt: charge?.expiresAt)
        plan = meter.plan
    }

    /// 端末の控え(DEBUG の差し替えを含む)を読み直す。
    func refreshFromMeter() { plan = meter.plan }
}

extension View {
    /// 今の契約を受け取り続ける(アプリの一番外側に付ける)。
    /// 単体テストのホストとして起動した時は付けない。テストが `SKTestSession` を作る前に storekitd へ繋ぐと、
    /// 起動時の Sandbox の問い合わせにテストの契約・商品の読み込みが合流し、設定ファイルの契約が読めない。
    @ViewBuilder
    func struisSubscriptionStatus(_ store: SubscriptionStore) -> some View {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            self
        } else {
            subscriptionStatusTask(for: store.activeGroupID) { state in
                if let statuses = state.value { store.update(statuses: statuses) }
            }
            .task {
                store.start()
                await store.loadProducts()
            }
        }
    }
}
