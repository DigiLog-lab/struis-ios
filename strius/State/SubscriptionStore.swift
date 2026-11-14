import Foundation
import OSLog
import StoreKit
import SwiftUI

private let storeLog = Logger(subsystem: "com.digiloglab.strius", category: "subscription")

/// 購読(StoreKit 2、#40・#62)。サブスクリプショングループ 1 つに 3 商品(`groupLevel`: たっぷり 1・スタンダード 2・ライト 3)。
/// 今の契約は `.subscriptionStatusTask` で受け取り、有効なもののうち `groupLevel` が一番小さいものをプランとする。
/// App Store の無料体験(無料の導入オファー・1 週間)はライトだけに付ける。導入オファーはグループで 1 回だけで、以前に
/// 無料体験を使った人と、今どれかのプランを契約している人は対象外。対象外の人には無料体験の文言を出さない
/// (購入する前のお試しはアプリの 3 問のまま)。
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
    /// 商品から読んだ無料体験(無料の導入オファー)。`Config/Struis.storekit` と App Store Connect ではライトだけに付いている。
    private(set) var freeTrialOffers: [UsagePlan: FreeTrialOffer] = [:]
    /// 無料体験の対象か(App Store の `isEligibleForIntroOffer`。以前に無料体験を使った人・今契約している人は対象外)。
    /// App Store に確かめられるまでは false にして、対象外の人に無料の文言を出さない。
    private(set) var isEligibleForFreeTrial: Bool = false
    /// 今どれかのプランを契約しているか(上げる・下げる・乗り換えは導入オファーの対象外)。
    private(set) var isSubscribedInGroup: Bool = false
    /// このグループで無料体験(導入オファー)を使った取引を見たか。一度見たら、このアプリの間は戻さない。
    private(set) var hasUsedFreeTrial: Bool = false
    /// App Store の答えを待たずに、無料体験を出さないと分かっているか(今の契約か、無料体験を使った取引がある)。
    /// App Store の「対象か」は、購入の後や入れ直した直後に前のまま(対象)で返ることがあるため、アプリの側でも外す
    /// (StoreKit の設定ファイルのシミュレータで、購入の後も対象のまま返った。iPad の Dev Box と、マージキューの検証で。
    /// 2026-11-14)。プランが切れた人がもう一度対象になるか(導入オファーを使っていない人は対象)は App Store の答えに任せる。
    var isFreeTrialRuledOut: Bool { isSubscribedInGroup || hasUsedFreeTrial }
    /// 今のプランが無料体験中なら、無料の期間が終わる日時(その時刻に最初の請求がある)。無料体験中でなければ nil。
    private(set) var freeTrialEndsAt: Date?
    /// 今の契約を受け取るグループ。商品を読んだら、その商品のグループにする
    /// (Xcode の StoreKit の設定ファイルで動かした時は、設定ファイルのテスト用の ID になる)。
    private(set) var activeGroupID = SubscriptionStore.groupID
    var errorMessage: String?
    /// 商品を買う 1 か所。本番は `product.purchase(options:)`。単体テストは `SKTestSession.buyProduct` に差し替える。
    typealias Purchase = @MainActor (Product, Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult
    /// 無料体験の対象かを App Store に聞く 1 か所。本番は `isEligibleForIntroOffer`。単体テストは答えを差し替え、
    /// App Store が古い答え(対象)を返し続ける場合でも、アプリの側で外せることを確かめる。
    typealias IntroEligibility = @MainActor (Product.SubscriptionInfo) async -> Bool
    private let meter: UsageMeter
    private let purchaseProduct: Purchase
    private let introEligibility: IntroEligibility
    /// 購入に付ける項目(16 歳未満は保護者の同意番号を `appAccountToken` にする。#76)。
    private let purchaseOptions: () -> Set<Product.PurchaseOption>
    private var updates: Task<Void, Never>?

    init(meter: UsageMeter = .shared, purchaseOptions: @escaping () -> Set<Product.PurchaseOption> = { OnboardingRecords.shared.purchaseOptions },
         purchase: @escaping Purchase = { try await $0.purchase(options: $1) },
         introEligibility: @escaping IntroEligibility = { await $0.isEligibleForIntroOffer }) {
        self.meter = meter
        self.purchaseOptions = purchaseOptions
        purchaseProduct = purchase
        self.introEligibility = introEligibility
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

    /// 購入の画面に出す無料体験。対象外の人と、無料体験の無いプランは nil(文言を一切出さない)。
    func freeTrial(for plan: UsagePlan) -> FreeTrialOffer? {
        guard isEligibleForFreeTrial, !isFreeTrialRuledOut else { return nil }
        return freeTrialOffers[plan]
    }

    /// 無料体験の対象かを App Store に聞き直す(商品を読んだ時・購入の後・購入の画面を開いた時)。
    /// あわせて端末の取引の記録を見て、無料体験を使った取引があれば、App Store の答えを待たずに外す
    /// (入れ直した直後は、契約の状態が届く前に購入の画面が開くことがある)。
    func refreshFreeTrialEligibility() async {
        for await result in Transaction.all {
            if case .verified(let transaction) = result, UsagePlan(productID: transaction.productID) != nil,
               transaction.offer?.type == .introductory {
                hasUsedFreeTrial = true
                break
            }
        }
        var eligible: Bool = false
        for plan in UsagePlan.allCases where freeTrialOffers[plan] != nil {
            guard let subscription: Product.SubscriptionInfo = products[plan]?.subscription else { continue }
            let planEligible: Bool = await introEligibility(subscription)
            if planEligible { eligible = true }
        }
        isEligibleForFreeTrial = eligible
    }

    /// 取引が無料体験(無料の導入オファー)の期間なら、その終わる日時。
    nonisolated static func freeTrialEnd(of transaction: StoreKit.Transaction) -> Date? {
        guard let offer: StoreKit.Transaction.Offer = transaction.offer, offer.type == .introductory,
              offer.paymentMode == .freeTrial else { return nil }
        return transaction.expirationDate
    }

    func loadProducts() async {
        guard loadState != .loading, products.count < UsagePlan.allCases.count else { return }
        loadState = .loading
        do {
            let loaded = try await Product.products(for: UsagePlan.allCases.map(\.productID))
            products = Dictionary(uniqueKeysWithValues: loaded.compactMap { product in UsagePlan(productID: product.id).map { ($0, product) } })
            if let group = products.values.first?.subscription?.subscriptionGroupID { activeGroupID = group }
            var offers: [UsagePlan: FreeTrialOffer] = [:]
            for (plan, product) in products {
                if let offer: FreeTrialOffer = FreeTrialOffer(product: product) { offers[plan] = offer }
            }
            freeTrialOffers = offers
            await refreshFreeTrialEligibility()
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
            switch try await purchaseProduct(product, purchaseOptions()) {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    errorMessage = "購入を確かめられませんでした。もう一度試してください。"
                    return false
                }
                await transaction.finish()
                // 契約している間は、グループのどのプランでも無料体験の対象外。
                isSubscribedInGroup = true
                if transaction.offer?.type == .introductory { hasUsedFreeTrial = true }
                await refreshFreeTrialEligibility()
                // 押されたプランをそのまま使わず、契約の状態を読み直す(下げた時は次の更新日まで今のプランのまま)。
                if let statuses = try? await product.subscription?.status, !statuses.isEmpty {
                    update(statuses: statuses)
                } else {
                    let bought: [UsagePlan] = UsagePlan(productID: transaction.productID).map { [$0] } ?? []
                    // 買った直後は自動更新が続く。
                    apply(plans: bought, charges: Dictionary(uniqueKeysWithValues: bought.map { ($0, Charge(transaction, renews: true)) }))
                    cancelsAt = nil
                    if !bought.isEmpty { freeTrialEndsAt = Self.freeTrialEnd(of: transaction) }
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
        var trialEnds: [UsagePlan: Date] = [:]
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.revocationDate == nil, !transaction.isUpgraded,
               let plan = UsagePlan(productID: transaction.productID) {
                plans.append(plan)
                // 自動更新が続いているかは、その取引の契約の状態から読む(読めなければ、続いていない側に倒す)。
                let status: Product.SubscriptionInfo.Status? = await transaction.subscriptionStatus
                var renews: Bool = false
                if let status, case .verified(let renewal) = status.renewalInfo { renews = renewal.willAutoRenew }
                charges[plan] = Charge(transaction, renews: renews)
                if let ends: Date = Self.freeTrialEnd(of: transaction) { trialEnds[plan] = ends }
                if transaction.offer?.type == .introductory { hasUsedFreeTrial = true }
            }
        }
        apply(plans: plans, charges: charges)
        if let best: UsagePlan = UsagePlan.best(of: plans) { freeTrialEndsAt = trialEnds[best] }
        if !plans.isEmpty { isSubscribedInGroup = true }
        await refreshFreeTrialEligibility()
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

    /// `.subscriptionStatusTask` から: 有効な契約(購読中・猶予期間)のうち、一番上のプランと、その解約の予約・無料体験の終わり。
    func update(statuses: [Product.SubscriptionInfo.Status]) {
        var plans: [UsagePlan] = []
        var endDates: [UsagePlan: Date] = [:]
        var charges: [UsagePlan: Charge] = [:]
        var trialEnds: [UsagePlan: Date] = [:]
        // 期限切れの契約も届く。その取引が導入オファーなら、もう無料体験の対象ではない。
        var usedIntroOffer: Bool = false
        for status in statuses {
            if case .verified(let latest) = status.transaction, latest.offer?.type == .introductory { usedIntroOffer = true }
        }
        for status in statuses {
            guard status.state == .subscribed || status.state == .inGracePeriod,
                  case .verified(let transaction) = status.transaction,
                  let plan = UsagePlan(productID: transaction.productID) else { continue }
            plans.append(plan)
            var renews: Bool = true
            if case .verified(let renewal) = status.renewalInfo, !renewal.willAutoRenew {
                endDates[plan] = transaction.expirationDate
                renews = false
            }
            charges[plan] = Charge(transaction, renews: renews)
            if let ends: Date = Self.freeTrialEnd(of: transaction) { trialEnds[plan] = ends }
        }
        apply(plans: plans, charges: charges, replacing: true)
        let best: UsagePlan? = UsagePlan.best(of: plans)
        cancelsAt = best.flatMap { endDates[$0] }
        freeTrialEndsAt = best.flatMap { trialEnds[$0] }
        isSubscribedInGroup = best != nil
        if usedIntroOffer { hasUsedFreeTrial = true }
    }

    /// 取引から読む、課金の時刻と次の更新の予定日時。利用枠の 7 日はこの課金の時刻から数える(購入・上げた時・更新で 0 から始まる)。
    struct Charge: Equatable {
        var id: UInt64
        var chargedAt: Date
        /// 自動更新が続いている時の期限(その時刻に更新され、新しい期間になる)。解約の予約中・分からない時は nil。
        var renewsAt: Date?

        init(id: UInt64, chargedAt: Date, renewsAt: Date?) {
            self.id = id
            self.chargedAt = chargedAt
            self.renewsAt = renewsAt
        }

        init(_ transaction: StoreKit.Transaction, renews: Bool) {
            self.init(id: transaction.id, chargedAt: transaction.purchaseDate, renewsAt: renews ? transaction.expirationDate : nil)
        }
    }

    private func apply(plans: [UsagePlan], charges: [UsagePlan: Charge], replacing: Bool = false) {
        let best: UsagePlan? = UsagePlan.best(of: plans)
        guard replacing || best != nil else { return }
        let charge: Charge? = best.flatMap { charges[$0] }
        meter.setPlan(best, chargeID: charge?.id, chargedAt: charge?.chargedAt, renewsAt: charge?.renewsAt)
        plan = meter.plan
    }

    /// 端末の控え(DEBUG の差し替えを含む)を読み直す。
    func refreshFromMeter() { plan = meter.plan }
}

/// 無料体験(App Store の導入オファーのうち無料のもの)。期間と値段は App Store の商品から読み、文言はここで組む。
/// 購入の画面では、無料を値段より目立たせない(値段はカードの大きい字のまま、無料はその下に小さく。App Review 3.1.2(c))。
nonisolated struct FreeTrialOffer: Equatable, Sendable {
    /// 期間の長さ(「1週間」「1か月」)。
    nonisolated struct Length: Equatable, Sendable {
        nonisolated enum Unit: Equatable, Sendable {
            case day, week, month, year
        }

        let value: Int
        let unit: Unit

        /// 7 日の倍数の日数は週にそろえる(App Store が 1 週間を 7 日で返すことがあるため)。
        init(value: Int, unit: Unit) {
            if unit == .day, value > 0, value % 7 == 0 {
                self.value = value / 7
                self.unit = .week
            } else {
                self.value = value
                self.unit = unit
            }
        }

        init(_ period: Product.SubscriptionPeriod) {
            let unit: Unit
            switch period.unit {
            case .day: unit = .day
            case .week: unit = .week
            case .month: unit = .month
            case .year: unit = .year
            @unknown default: unit = .day
            }
            self.init(value: period.value, unit: unit)
        }

        /// 「3日間」「1週間」「1か月」「1年間」。
        var text: String {
            switch unit {
            case .day: return "\(value)日間"
            case .week: return "\(value)週間"
            case .month: return "\(value)か月"
            case .year: return "\(value)年間"
            }
        }
    }

    /// 無料の期間。
    let trial: Length
    /// 無料の期間の後の、自動更新の期間(ひと月)。
    let renewal: Length
    /// 値段の通貨(「JPY」)。
    let currencyCode: String
    /// App Store の表示の値段(「¥1,480」、税込)。カードに出す値段と同じ文字から金額を組む。
    /// `Product.price` は使わない(StoreKit の設定ファイルで動かした iPad のシミュレータで、表示が ¥1,480 なのに
    /// `price` が 1 になり、説明が「月額1円」になった。2026-11-14)。
    let displayPrice: String

    init(trial: Length, renewal: Length, currencyCode: String, displayPrice: String) {
        self.trial = trial
        self.renewal = renewal
        self.currencyCode = currencyCode
        self.displayPrice = displayPrice
    }

    /// 商品に無料の導入オファーがあれば作る(割引の導入オファーは無料体験ではないので nil)。
    init?(product: Product) {
        guard let subscription: Product.SubscriptionInfo = product.subscription,
              let offer: Product.SubscriptionOffer = subscription.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        self.init(trial: Length(offer.period), renewal: Length(subscription.subscriptionPeriod),
                  currencyCode: product.priceFormatStyle.currencyCode, displayPrice: product.displayPrice)
    }

    /// プランのカードの値段の下に小さく出す一文(「最初の1週間は無料」)。
    var badgeText: String { "最初の\(trial.text)は無料" }

    /// 購入ボタンの下に出す一文。無料の期間・その後に自動更新される値段・無料の間に解約すれば請求が無いこと。
    var noticeText: String {
        "\(trial.text)無料、その後は\(renewalPriceText)で自動更新されます。無料期間中に解約すれば請求はありません。"
    }

    /// 「月額1,480円」。円は表示の値段(「¥1,480」)の数字と区切りだけを取って「1,480円」と書き、
    /// それ以外の通貨(数字が取れない時も)は App Store の表示の値段のまま。
    var renewalPriceText: String {
        let digits: String = String(displayPrice.filter { (character: Character) -> Bool in character.isASCII && (character.isNumber || character == ",") })
        let amount: String = currencyCode == "JPY" && !digits.isEmpty ? "\(digits)円" : displayPrice
        switch (renewal.value, renewal.unit) {
        case (1, .month): return "月額\(amount)"
        case (1, .year): return "年額\(amount)"
        default: return "\(renewal.text)ごとに\(amount)"
        }
    }
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
