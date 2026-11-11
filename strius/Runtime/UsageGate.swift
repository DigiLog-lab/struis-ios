import Foundation
import OSLog

nonisolated private let usageLog = Logger(subsystem: "com.digiloglab.strius", category: "usage")

/// 料金プラン(#62、2026-10-30 決定)。プラン間で機能の差はつけず、1 週間に使える Claude 代だけが違う。
/// 上限は内部的に 7 日ごとのドルで持つ(Claude 代は手取りの 50% 以内、1 ドル 160 円)。7 日は課金した時刻から数える。問題数は 1 問 ¥10 で割って切り下げた目安。
nonisolated enum UsagePlan: String, CaseIterable, Codable, Sendable {
    case light, standard, generous

    /// App Store Connect の商品 ID(1 つのサブスクリプショングループに 3 つ)。
    var productID: String { "com.digiloglab.strius.plan.\(rawValue)" }

    init?(productID: String) {
        guard let plan = Self.allCases.first(where: { $0.productID == productID }) else { return nil }
        self = plan
    }

    var displayName: String {
        switch self {
        case .light: "ライト"
        case .standard: "スタンダード"
        case .generous: "たっぷり"
        }
    }

    /// 月額(税込)。App Store の商品が読めない時の表示にも使う。
    var yen: Int {
        switch self {
        case .light: 1_480
        case .standard: 3_980
        case .generous: 9_800
        }
    }

    var priceText: String { "¥" + yen.formatted(.number.grouping(.automatic)) }

    /// 週の上限(内部、USD)。
    var weeklyLimitUSD: Double {
        switch self {
        case .light: 0.80
        case .standard: 2.00
        case .generous: 4.80
        }
    }

    /// 週の目安の問題数。
    var weeklyProblems: Int {
        switch self {
        case .light: 12
        case .standard: 30
        case .generous: 75
        }
    }

    /// ライトと比べた利用枠(購入画面の補足)。
    var ratioText: String? {
        switch self {
        case .light: nil
        case .standard: "ライトの2.5倍"
        case .generous: "ライトの6倍"
        }
    }

    /// サブスクリプショングループの中の順位(1 が一番上)。
    var groupLevel: Int {
        switch self {
        case .light: 3
        case .standard: 2
        case .generous: 1
        }
    }

    /// 1 つ上のプラン(使い切った時の案内)。一番上なら nil。
    var upgrade: UsagePlan? {
        switch self {
        case .light: .standard
        case .standard: .generous
        case .generous: nil
        }
    }

    /// 有効な契約のうち、`groupLevel` が一番小さいもの(一番上のプラン)。
    static func best(of plans: some Sequence<UsagePlan>) -> UsagePlan? {
        plans.min { $0.groupLevel < $1.groupLevel }
    }
}

/// 利用枠に数えない「初回の準備」の種類。始めたばかりの人の枠を、解く前の準備(上位モデル)だけで使い切らないために分ける。
/// 費用は台帳にそのまま残す。数えないターンの数は `UsageRules.freeSetupTurns`。
nonisolated enum UsageSetup: String, Codable, Sendable, CaseIterable {
    /// オンボーディングの計画づくり。
    case plan
    /// 単元づくり。
    case unit
    /// 知識グラフの初めての構築・新しい単元の分の追加・つまずきの洗い出し(学習中の見直しと 1 段下りる依頼は含めない)。
    case graph
}

/// 利用枠の決まり(#62)。
nonisolated enum UsageRules {
    /// 1 問の目安(¥10)を USD にしたもの(1 ドル 160 円)。
    static let problemUSD = 10.0 / 160.0
    /// ソフトリミット: 上限に達しても、解いている途中のカード 1 枚分は採点まで通す。
    static let graceUSD = 0.07
    /// 購入する前(プランなし)の枠。お試しの 3 問の採点だけを通す(何問解いたかはアプリが Keychain で数える)。
    static let trialLimitUSD = 0.25

    static func limitUSD(plan: UsagePlan?) -> Double { plan?.weeklyLimitUSD ?? trialLimitUSD }

    /// 「初回の準備」のうち、利用枠に数えないターンの数(種類ごと)。これを超えた分は普通に数える。
    static func freeSetupTurns(_ setup: UsageSetup) -> Int {
        switch setup {
        case .plan: 3
        case .unit: 3
        // 単元 4 つ分(オンボーディングの 1 つ + 単元づくりの 3 つ)。1 つの単元の最初の構築は、構築(追加)1 回 +
        // 続きの段 5 回まで(`TimelineTurns.graphStepLimit`)+ つまずきの洗い出し 1 回で、多くて 7 回。
        case .graph: 28
        }
    }

    /// 1 期間の長さ(7 日)。課金した時刻から数えるので、暦や時間帯によらず秒で持つ。
    static let periodSeconds: TimeInterval = 7 * 86_400

    /// 週の始まり(端末の時刻で月曜 0:00)。課金したことが無い時(お試しだけ)の区切り。
    static func weekStart(for date: Date, calendar: Calendar = .current) -> Date {
        var calendar = calendar
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// 次に枠が戻る日時(次の月曜 0:00)。課金したことが無い時の区切り。
    static func resetDate(after date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 7, to: weekStart(for: date, calendar: calendar)) ?? date
    }

    /// 保存の鍵(週の始まりの日付)。課金したことが無い時の区切り。
    static func weekKey(for date: Date, calendar: Calendar = .current) -> String {
        let start = weekStart(for: date, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        return String(format: "usage.week.%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// `date` を含む期間の始まり。`chargedAt`(最後に課金された時刻: 購入・上げた時・更新)があれば、そこから 7 日ごとに
    /// 区切る(課金すると使用額が 0 から始まる)。無ければ月曜 0:00 区切り。
    static func periodStart(for date: Date, chargedAt: Date?, calendar: Calendar = .current) -> Date {
        guard let chargedAt else { return weekStart(for: date, calendar: calendar) }
        let elapsed: TimeInterval = date.timeIntervalSince(chargedAt)
        let count: Double = (elapsed / periodSeconds).rounded(.down)
        return chargedAt.addingTimeInterval(count * periodSeconds)
    }

    /// 期間の終わり(次に枠が戻る日時)。
    static func periodEnd(for date: Date, chargedAt: Date?, calendar: Calendar = .current) -> Date {
        guard chargedAt != nil else { return resetDate(after: date, calendar: calendar) }
        return periodStart(for: date, chargedAt: chargedAt, calendar: calendar).addingTimeInterval(periodSeconds)
    }

    /// 期間の使用額を保存する鍵。課金したことが無ければ `weekKey`、あれば課金の取引 ID と期間の始まりの UNIX 秒
    /// (取引 ID も入れるのは、同じ秒に 2 回課金されても別の期間にするため)。
    static func periodKey(for date: Date, chargedAt: Date?, chargeID: UInt64? = nil, calendar: Calendar = .current) -> String {
        guard chargedAt != nil else { return weekKey(for: date, calendar: calendar) }
        let start: Date = periodStart(for: date, chargedAt: chargedAt, calendar: calendar)
        let id: String = chargeID.map { "\($0)." } ?? ""
        return "usage.period.\(id)\(Int64(start.timeIntervalSince1970.rounded(.down)))"
    }

    /// 料金が分からない要求(`usage_unavailable`・`unknown_model`)の見積もり。少なく数えない側に倒す:
    /// 要求本文 3 バイトを 1 トークン(和文は 1 字 3 バイト、欧文と画像の base64 はこれより多く数える)、出力 4,096 トークン、
    /// 料金表で一番高い単価で数える。
    static func conservativeUSD(requestBytes: Int) -> Double {
        let rates = ClaudePricing.tables.values.flatMap { [$0.base] + ($0.longContext.map { [$0.rates] } ?? []) }
        let input = rates.map(\.input).max() ?? 0
        let output = rates.map(\.output).max() ?? 0
        return (Double(requestBytes) / 3 * input + 4_096 * output) / 1_000_000
    }

    /// 1 回の要求の記録(`Attempt.finish`)から、使った金額を決める。課金されなかった要求は 0。
    static func charge(record: [String: Any], requestBytes: Int) -> Double {
        if let usd = record["estimated_cost_usd"] as? Double { return usd }
        switch record["cost_status"] as? String {
        case "not_billed": return 0
        default: return conservativeUSD(requestBytes: requestBytes)
        }
    }
}

/// 端末に残す小さな値の保存先。Keychain(入れ直しても戻らない)と、本人の iCloud の Key-Value ストア(同じ Apple ID の
/// iPhone と iPad で共有)の両方に書き、読む時は両方を見る。
nonisolated protocol DeviceValueStore: Sendable {
    func string(_ key: String) -> String?
    func set(_ value: String?, _ key: String)
    /// `prefix` で始まる鍵の一覧。iCloud(全端末の値が集まる)でだけ使う。
    func keys(withPrefix prefix: String) -> [String]
}

nonisolated struct KeychainValueStore: DeviceValueStore {
    var keychain = KeychainStore(service: "com.digiloglab.strius.device-record")
    /// バックアップから別の端末へ移さない鍵。端末の ID が 2 台で同じになると、2 台の使用額が同じ鍵で上書きし合い、合計されない。
    var deviceOnlyKeys: Set<String> = [UsageMeter.deviceKey]
    func string(_ key: String) -> String? { keychain.get(key) }
    func set(_ value: String?, _ key: String) {
        if let value { keychain.set(value, for: key, thisDeviceOnly: deviceOnlyKeys.contains(key)) } else { keychain.delete(key) }
    }
    /// Keychain にはこの端末の値しか無いので、一覧は使わない。
    func keys(withPrefix prefix: String) -> [String] { [] }
}

nonisolated struct CloudValueStore: DeviceValueStore {
    func string(_ key: String) -> String? { NSUbiquitousKeyValueStore.default.string(forKey: key) }
    func keys(withPrefix prefix: String) -> [String] {
        NSUbiquitousKeyValueStore.default.dictionaryRepresentation.keys.filter { $0.hasPrefix(prefix) }
    }
    func set(_ value: String?, _ key: String) {
        if let value { NSUbiquitousKeyValueStore.default.set(value, forKey: key) } else { NSUbiquitousKeyValueStore.default.removeObject(forKey: key) }
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}

/// テストと DEBUG の差し替え用(メモリの中だけ)。
nonisolated final class MemoryValueStore: DeviceValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    init(_ values: [String: String] = [:]) { self.values = values }
    func string(_ key: String) -> String? { lock.withLock { values[key] } }
    func set(_ value: String?, _ key: String) { lock.withLock { values[key] = value } }
    func keys(withPrefix prefix: String) -> [String] { lock.withLock { values.keys.filter { $0.hasPrefix(prefix) } } }
}

#if DEBUG
/// UI テスト用(`STRUIS_USAGE_SEED_PREFIX`・`STRUIS_USAGE_SEED_USD`): `prefix` で始まる期間の鍵がまだ書かれていなければ、
/// その期間に `usd` を使った状態として読ませる(端末ごとの鍵は除く)。課金で期間が替わった時に 0 に戻るかを画面で確かめる。
nonisolated final class SeededValueStore: DeviceValueStore, @unchecked Sendable {
    private let base: MemoryValueStore = MemoryValueStore()
    private let prefix: String
    private let usd: Double

    init(prefix: String, usd: Double) {
        self.prefix = prefix
        self.usd = usd
    }

    func string(_ key: String) -> String? {
        if let value = base.string(key) { return value }
        guard key.hasPrefix(prefix), !key.contains(UsageMeter.deviceMarker) else { return nil }
        return String(usd)
    }

    func set(_ value: String?, _ key: String) { base.set(value, key) }
    func keys(withPrefix prefix: String) -> [String] { base.keys(withPrefix: prefix) }
}
#endif

/// Keychain と iCloud の Key-Value ストアの組。
nonisolated struct MirroredValues: Sendable {
    let local: any DeviceValueStore
    let cloud: any DeviceValueStore

    static let device = MirroredValues(local: KeychainValueStore(), cloud: CloudValueStore())

    /// 数は大きい方を採る(お試しの数・使用額を、入れ直しで戻さない)。
    func number(_ key: String) -> Double {
        max(local.string(key).flatMap(Double.init) ?? 0, cloud.string(key).flatMap(Double.init) ?? 0)
    }

    func setNumber(_ value: Double, _ key: String) {
        let text = String(value)
        local.set(text, key)
        cloud.set(text, key)
    }

    /// 文字の値は端末の方を先に見る(無ければ iCloud)。
    func string(_ key: String) -> String? { local.string(key) ?? cloud.string(key) }

    func set(_ value: String?, _ key: String) {
        local.set(value, key)
        cloud.set(value, key)
    }
}

/// 今週の利用の見え方(設定の「利用枠」・使い切った時のシート)。
nonisolated struct UsageSnapshot: Equatable, Sendable, Identifiable {
    var id: Date { resetsAt }
    var plan: UsagePlan?
    var spentUSD: Double
    var limitUSD: Double
    var resetsAt: Date

    /// 使用率(0〜1)。
    var fraction: Double { limitUSD > 0 ? min(1, max(0, spentUSD / limitUSD)) : 1 }
    var percent: Int { Int((fraction * 100).rounded(.down)) }
    var isExhausted: Bool { spentUSD >= limitUSD }
    /// 残りの目安の問題数(1 問 ¥10 で割って切り下げ)。購入画面の「週 約○問」を超えて見せない。
    var remainingProblems: Int {
        let remaining: Int = max(0, Int(((limitUSD - spentUSD) / UsageRules.problemUSD).rounded(.down)))
        guard let plan else { return remaining }
        return min(remaining, plan.weeklyProblems)
    }
}

extension Notification.Name {
    /// 使用額かプランが変わった(画面の表示を読み直す)。
    nonisolated static let usageMeterChanged = Notification.Name("struis.usageMeterChanged")
}

/// 期間ごとの使用額と今のプラン。中継(主スレッドの外)と画面の両方から使うので、鍵で守る。
///
/// 使用額は端末ごとに分けて書く(期間の鍵 + `.device.` + 端末の ID)。各端末は自分の値だけを足し、読む時は iCloud に
/// 集まった全端末の値を合計する。iPhone と iPad で同期の前に同時に使っても、どちらかの分が消えない(大きい方だけを採ると、
/// 小さい方の端末で使った分が消える)。期間の鍵そのものに書かれた値(端末ごとに分ける前の記録)も合計に足す。
nonisolated final class UsageMeter: @unchecked Sendable {
    static let shared = UsageMeter.makeShared()

    private let lock = NSLock()
    private let values: MirroredValues
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    /// DEBUG の差し替え(`STRUIS_PLAN`)。nil なら StoreKit から受け取ったプラン。
    private let forcedPlan: UsagePlan??

    static let planKey = "usage.plan.v1"
    /// 最後の課金(購入・上げた時・更新)。値は「`Transaction.purchaseDate` の UNIX 秒|`Transaction.id`」の 1 つの文字列で、
    /// 期間はこの時刻から 7 日ごと。時刻と ID を 1 つの値にして、片方だけ新しい組み合わせで鍵を作らないようにする。
    /// 使用額と同じ Keychain と iCloud に置く(入れ直しても、プランが切れた後のその期間の使用額を引き継ぐため)。
    static let chargeKey = "usage.charge.v1"
    /// 枠に数えなかった「初回の準備」のターンの ID(種類ごと・端末ごとの鍵に、カンマ区切り)。
    static let freeSetupPrefix = "usage.free-setup.v1."
    /// 次の更新の予定日時(自動更新が続いている時の `Transaction.expirationDate`)。更新されるとその時刻から新しい期間になるので、
    /// 戻る日時はこれより後にしない。解約の予約中は更新されず期間も替わらないので、持たない。
    static let renewsAtKey = "usage.renewsAt.v1"
    /// この端末の ID。Keychain だけに置き、バックアップから別の端末へは移さない(入れ直しても同じ ID のまま、自分の値に足し続ける)。
    static let deviceKey = "usage.device.v1"
    /// 端末ごとの使用額の鍵の印(期間の鍵 + この印 + 端末の ID)。
    static let deviceMarker = ".device."

    private let cloudObserver: NSObjectProtocol?

    /// `observesCloud`: 別の端末の使用額が iCloud から届いたら、画面に読み直させる(本番の共有の計器だけ)。
    init(values: MirroredValues = .device, defaults: UserDefaults = .standard, forcedPlan: UsagePlan?? = nil, observesCloud: Bool = false,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.values = values
        self.defaults = defaults
        self.forcedPlan = forcedPlan
        self.now = now
        if observesCloud {
            cloudObserver = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                                   object: NSUbiquitousKeyValueStore.default, queue: nil) { _ in
                Self.notifyChanged()
            }
            NSUbiquitousKeyValueStore.default.synchronize()
        } else {
            cloudObserver = nil
        }
    }

    deinit {
        if let cloudObserver { NotificationCenter.default.removeObserver(cloudObserver) }
    }

    private static func makeShared() -> UsageMeter {
        #if DEBUG
        // 画面の確認用: `STRUIS_PLAN=none|light|standard|generous`・`STRUIS_USAGE_PERCENT=0〜100` で差し替える(端末の記録は触らない)。
        let environment = ProcessInfo.processInfo.environment
        let forced: UsagePlan?? = environment["STRUIS_PLAN"].map { value -> UsagePlan? in value == "none" ? nil : UsagePlan(rawValue: value) }
        // UI テスト用: `STRUIS_USAGE_SEED_PREFIX` で始まる期間を `STRUIS_USAGE_SEED_USD` 使った状態から始める
        // (端末の Keychain と iCloud は触らない。プランは StoreKit の設定ファイルの契約から受け取る)。
        if let prefix = environment["STRUIS_USAGE_SEED_PREFIX"], let usd = environment["STRUIS_USAGE_SEED_USD"].flatMap(Double.init) {
            let seeded = MirroredValues(local: SeededValueStore(prefix: prefix, usd: usd), cloud: MemoryValueStore())
            let suite = "struis.usage.seeded.\(UUID().uuidString)"
            return UsageMeter(values: seeded, defaults: UserDefaults(suiteName: suite) ?? .standard)
        }
        if let percent = environment["STRUIS_USAGE_PERCENT"].flatMap(Double.init) {
            let plan = forced ?? nil
            let memory = MirroredValues(local: MemoryValueStore(), cloud: MemoryValueStore())
            memory.setNumber(UsageRules.limitUSD(plan: plan) * percent / 100, UsageRules.periodKey(for: Date(), chargedAt: nil))
            return UsageMeter(values: memory, defaults: UserDefaults(suiteName: "struis.usage.debug") ?? .standard, forcedPlan: forced)
        }
        if forced != nil { return UsageMeter(forcedPlan: forced, observesCloud: true) }
        #endif
        return UsageMeter(observesCloud: true)
    }

    /// 今のプラン(購入していなければ nil)。StoreKit の契約から `setPlan` で受け取り、起動直後のために端末にも控える。
    var plan: UsagePlan? {
        if let forcedPlan { return forcedPlan }
        return defaults.string(forKey: Self.planKey).flatMap(UsagePlan.init(rawValue:))
    }

    /// 課金の時刻と取引 ID の組。
    private struct Charge {
        var at: Date
        var id: UInt64?

        init(at: Date, id: UInt64?) {
            self.at = at
            self.id = id
        }

        init?(_ text: String?) {
            guard let parts = text?.split(separator: "|", omittingEmptySubsequences: false), let seconds = parts.first.flatMap({ Double($0) }) else { return nil }
            self.init(at: Date(timeIntervalSince1970: seconds), id: parts.count > 1 ? UInt64(parts[1]) : nil)
        }

        var text: String { "\(at.timeIntervalSince1970)|\(id.map(String.init) ?? "")" }

        /// 時刻が新しい方。同じ時刻なら取引 ID の大きい方。
        func isNewer(than other: Charge?) -> Bool {
            guard let other else { return true }
            return at > other.at || (at == other.at && (id ?? 0) > (other.id ?? 0))
        }
    }

    /// 最後の課金。Keychain と iCloud の新しい方(鍵の中で呼ぶ)。
    private func storedCharge() -> Charge? {
        guard forcedPlan == nil else { return nil }
        let local: Charge? = Charge(values.local.string(Self.chargeKey))
        let cloud: Charge? = Charge(values.cloud.string(Self.chargeKey))
        guard let local else { return cloud }
        return cloud.map { $0.isNewer(than: local) ? $0 : local } ?? local
    }

    /// 最後に課金された時刻(課金したことが無ければ nil)。
    var chargedAt: Date? { lock.withLock { storedCharge()?.at } }

    /// 最後に課金された取引の ID(課金したことが無ければ nil)。
    var chargeID: UInt64? { lock.withLock { storedCharge()?.id } }

    /// 次の更新の予定日時(自動更新が続いていなければ nil)。
    var renewsAt: Date? {
        guard forcedPlan == nil, defaults.object(forKey: Self.renewsAtKey) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: Self.renewsAtKey))
    }

    /// 今の契約を受け取る。`chargedAt`・`chargeID` は一番上のプランの最新の取引の `purchaseDate`・`id`(購入・上げた時・
    /// 更新で新しい取引になる)。今の取引より新しい時だけ進める(遅れて届いた古い契約の状態で、前の期間に戻さない)。
    /// 時刻が同じ時は取引 ID の大きい方を新しいとみなす。下げる予約・解約の予約は課金ではないので取引が変わらず、期間もそのまま。
    /// `renewsAt` は自動更新が続いている時だけ渡す(解約の予約中は、期限が来てもプランが終わるだけで使用額は戻らない)。
    func setPlan(_ plan: UsagePlan?, chargeID: UInt64? = nil, chargedAt: Date? = nil, renewsAt: Date? = nil) {
        guard forcedPlan == nil else { return }
        var changed: Bool = false
        if plan != self.plan {
            defaults.set(plan?.rawValue, forKey: Self.planKey)
            usageLog.info("plan is now \(plan?.rawValue ?? "none", privacy: .public)")
            changed = true
        }
        if let chargedAt {
            let charge: Charge = Charge(at: chargedAt, id: chargeID)
            let moved: Bool = lock.withLock {
                guard charge.isNewer(than: storedCharge()) else { return false }
                values.set(charge.text, Self.chargeKey)
                return true
            }
            if moved {
                usageLog.info("charged at \(chargedAt.timeIntervalSince1970, privacy: .public): a new period starts")
                changed = true
            }
        }
        let renews: Date? = plan == nil ? nil : renewsAt
        if renews != self.renewsAt {
            if let renews { defaults.set(renews.timeIntervalSince1970, forKey: Self.renewsAtKey) } else { defaults.removeObject(forKey: Self.renewsAtKey) }
            changed = true
        }
        if changed { Self.notifyChanged() }
    }

    /// この端末の ID(無ければ作って Keychain に置く。ロックの中で呼ぶ)。
    private func deviceID() -> String {
        if let id = values.local.string(Self.deviceKey) { return id }
        let id: String = UUID().uuidString.lowercased()
        values.local.set(id, Self.deviceKey)
        return id
    }

    /// 今の期間の鍵と、この端末の分の鍵(ロックの中で呼ぶ)。
    private func periodKeys(at date: Date) -> (period: String, own: String) {
        let charge: Charge? = storedCharge()
        let period: String = UsageRules.periodKey(for: date, chargedAt: charge?.at, chargeID: charge?.id)
        return (period, period + Self.deviceMarker + deviceID())
    }

    /// 期間の使用額: 端末ごとに分ける前の記録 + 全端末の分の合計(ロックの中で呼ぶ)。
    /// この端末の分は Keychain と iCloud の大きい方(iCloud に届く前の分も数える)。ほかの端末の分は iCloud から読む。
    private func spentUSD(period: String, own: String) -> Double {
        var devices: [String: Double] = [:]
        for key in values.cloud.keys(withPrefix: period + Self.deviceMarker) {
            devices[key] = values.cloud.string(key).flatMap(Double.init) ?? 0
        }
        devices[own] = values.number(own)
        return values.number(period) + devices.values.reduce(0, +)
    }

    func snapshot() -> UsageSnapshot {
        let date: Date = now()
        let (charged, spent): (Date?, Double) = lock.withLock {
            let keys = periodKeys(at: date)
            return (storedCharge()?.at, spentUSD(period: keys.period, own: keys.own))
        }
        let plan: UsagePlan? = plan
        var resetsAt: Date = UsageRules.periodEnd(for: date, chargedAt: charged)
        // 期間の途中で契約が更新されると、更新の時刻から新しい期間になる。
        if plan != nil, let renews = renewsAt, renews > date, renews < resetsAt { resetsAt = renews }
        return UsageSnapshot(plan: plan, spentUSD: spent, limitUSD: UsageRules.limitUSD(plan: plan), resetsAt: resetsAt)
    }

    /// 使った金額を、この端末の分に足す(Keychain と iCloud の大きい方に足して、両方に書く)。
    func add(_ usd: Double) {
        guard usd > 0 else { return }
        let date: Date = now()
        lock.withLock {
            // 保存の鍵を決めるのと足すのを同じロックの中で行い、課金の更新と混ざらないようにする。
            let own: String = periodKeys(at: date).own
            values.setNumber(values.number(own) + usd, own)
        }
        Self.notifyChanged()
    }

    /// 数えなかった「初回の準備」のターンの ID(ロックの中で呼ぶ)。使用額と同じく、端末ごとの鍵(種類の鍵 + `.device.` +
    /// 端末の ID)に自分の分だけを書き、読む時は iCloud に集まった全端末の分を合わせる。1 つの鍵に全部の ID を書くと、
    /// iPhone と iPad が同期の前にそれぞれ書いた時に、後から届いた方が相手の分を消してしまう。
    private func freeSetupIDs(_ setup: UsageSetup) -> (ownKey: String, own: [String], all: Set<String>) {
        func ids(_ text: String?) -> [String] { (text ?? "").split(separator: ",").map(String.init) }
        let prefix: String = Self.freeSetupPrefix + setup.rawValue + Self.deviceMarker
        let ownKey: String = prefix + deviceID()
        var own: [String] = []
        for id in ids(values.local.string(ownKey)) + ids(values.cloud.string(ownKey)) where !own.contains(id) { own.append(id) }
        var all: Set<String> = Set(own)
        for key in values.cloud.keys(withPrefix: prefix) { all.formUnion(ids(values.cloud.string(key))) }
        return (ownKey, own, all)
    }

    /// 「初回の準備」のターンを、利用枠に数えずに通すか。数えないと決めたターンの ID を残し、同じターンの 2 回目以降の
    /// 要求(送り直し・続き)は数を増やさずに通す。種類ごとの数(`UsageRules.freeSetupTurns`、全端末の合計)を超えたら数える。
    func takesFree(_ setup: UsageSetup, turnID: String) -> Bool {
        lock.withLock {
            let stored = freeSetupIDs(setup)
            if stored.all.contains(turnID) { return true }
            guard stored.all.count < UsageRules.freeSetupTurns(setup) else { return false }
            values.set((stored.own + [turnID]).joined(separator: ","), stored.ownKey)
            return true
        }
    }

    /// 数えなかった「初回の準備」のターンの数(全端末の合計)。
    func freeSetupCount(_ setup: UsageSetup) -> Int {
        lock.withLock { freeSetupIDs(setup).all.count }
    }

    private static func notifyChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .usageMeterChanged, object: nil) }
    }
}

/// 送る要求の種類(#62・#78)。上限に達した後も通すのは、途中の作業を終わらせる要求だけ。
nonisolated struct UsageRequest: Sendable, Equatable {
    var kind: TurnPlan.Kind
    /// 途中の作業を終わらせる要求: 解いている途中の答案の採点と、通ったチャットの返事の続き。上限を超えても `graceUSD` まで通す。
    /// それ以外(出題・見直し・知識グラフ・赤ペン・単元づくり・新しい質問)は新しい作業で、上限で止める
    /// (裏の出題が余裕分を先に使って、途中の答案の採点が止まらないように)。
    var finishing: Bool

    /// 解いている途中の答案の採点。
    static let gradingKinds: Set<TurnPlan.Kind> = [.workbookGrading, .timelineGrading, .onboardingGrading]

    /// - Parameter turnAdmitted: このターンの要求が前に通った(チャットの返事の続き・子の調べもの・直させる回・送り直し)。
    static func of(kind: TurnPlan.Kind, turnAdmitted: Bool) -> UsageRequest {
        UsageRequest(kind: kind, finishing: gradingKinds.contains(kind) || (kind == .chat && turnAdmitted))
    }

    /// 新しい作業を始める要求(画面が先に確かめる時の代表)。
    static let newWork = UsageRequest(kind: .timelineBatch, finishing: false)
}

/// 要求を送らない理由。
nonisolated enum UsageDenial: String, Sendable, Equatable {
    /// 今の期間の枠を使い切った。
    case limitReached
    /// プランが無く、お試しの 3 問も使い切った(契約が切れた後を含む)。購入の画面へ案内する。
    case noPlan
    /// 今の版の規約に同意していない(#78)。
    case consentRequired

    /// ターンの失敗として記録する文(学習者に見せる文は `TurnRuntimeError.errorDescription`)。
    var message: String {
        switch self {
        case .limitReached: UsageLimitResponse.message
        case .noPlan: UsageLimitResponse.noPlanMessage
        case .consentRequired: UsageLimitResponse.consentMessage
        }
    }
}

extension UsageRules {
    /// 枠の決まりだけで決める(規約の同意は見ない)。
    /// - プランが無く、お試しの残りが 0: 送ったお試しの採点(その答案の続き)だけを通す。
    /// - 新しい作業は上限まで、途中の作業を終わらせる要求は上限 + `graceUSD` まで通す。
    static func denial(for request: UsageRequest, snapshot: UsageSnapshot, trialRemaining: Int) -> UsageDenial? {
        if snapshot.plan == nil, trialRemaining <= 0, !(request.finishing && request.kind == .onboardingGrading) { return .noPlan }
        let allowance: Double = snapshot.limitUSD + (request.finishing ? graceUSD : 0)
        return snapshot.spentUSD < allowance ? nil : .limitReached
    }
}

extension Notification.Name {
    /// 利用枠で要求を止めた(`object` は `UsageLimitHit`)。質問・単元づくりの画面が案内のシートを出す。
    nonisolated static let usageLimitReached = Notification.Name("struis.usageLimitReached")
}

/// 止めた要求の種類と理由(`usageLimitReached` の `object`)。
nonisolated struct UsageLimitHit: Sendable {
    var kind: TurnPlan.Kind
    var denial: UsageDenial
}

/// 上限の判定(#62)。送る前に `denial(for:)`、応答の料金が分かったら `record`。Enclave に移る時は、この実装と
/// `ClaudeUpstream` の送り先だけを差し替える。
nonisolated protocol UsageGate: Sendable {
    /// この要求を送らない理由(nil なら送ってよい)。
    func denial(for request: UsageRequest) -> UsageDenial?
    /// 使った金額を記録する(`Attempt.finish` の記録と、送った本文の大きさ)。
    func record(_ attempt: [String: Any], requestBytes: Int)
    /// ターンの種類つきの記録。`setup` が「初回の準備」のターンは、決まった数まで枠に数えない。
    func record(_ attempt: [String: Any], requestBytes: Int, setup: UsageSetup?, turnID: String)
}

extension UsageGate {
    func record(_ attempt: [String: Any], requestBytes: Int, setup: UsageSetup?, turnID: String) {
        record(attempt, requestBytes: requestBytes)
    }
}

/// 端末内で数える判定。ソフトリミットとして、途中の作業を終わらせる要求だけは上限を超えてもカード 1 枚分(`graceUSD`)まで通す。
nonisolated struct DeviceUsageGate: UsageGate {
    var meter: UsageMeter = .shared
    /// お試しの残りの数(プランが無い時に見る)。
    var trialRemaining: @Sendable () -> Int = { OnboardingRecords.shared.trialRemaining }
    /// 今の版の規約に同意しているか(#78。同意するまで AI の機能は使えない)。
    var consented: @Sendable () -> Bool = { OnboardingRecords.shared.allowsAI }

    func denial(for request: UsageRequest) -> UsageDenial? {
        guard consented() else { return .consentRequired }
        return usageDenial(for: request)
    }

    /// 枠の決まりだけの判定(画面が新しいカードを出す前に確かめる。同意は取り直しの画面が受け持つ)。
    func usageDenial(for request: UsageRequest = .newWork) -> UsageDenial? {
        UsageRules.denial(for: request, snapshot: meter.snapshot(), trialRemaining: trialRemaining())
    }

    func record(_ attempt: [String: Any], requestBytes: Int) {
        meter.add(UsageRules.charge(record: attempt, requestBytes: requestBytes))
    }

    func record(_ attempt: [String: Any], requestBytes: Int, setup: UsageSetup?, turnID: String) {
        let usd: Double = UsageRules.charge(record: attempt, requestBytes: requestBytes)
        // 課金されなかった要求では、数えないターンの数を使わない。
        guard usd > 0 else { return }
        if let setup, meter.takesFree(setup, turnID: turnID) {
            usageLog.info("setup turn \(turnID, privacy: .public) (\(setup.rawValue, privacy: .public)) is not counted: \(usd, privacy: .public) USD")
            return
        }
        meter.add(usd)
    }
}

/// 数えない判定(中継のテスト)。
nonisolated struct UnlimitedUsageGate: UsageGate {
    func denial(for request: UsageRequest) -> UsageDenial? { nil }
    func record(_ attempt: [String: Any], requestBytes: Int) {}
}

/// 上限に達した時の返し方(学習者向けの文と、記録に残す印 `usage_limit_reached`)。
nonisolated enum UsageLimitResponse {
    static let code = "usage_limit_reached"
    static let message = "usage_limit_reached: 今週の利用枠を使い切りました。設定の「利用枠」で、戻る日時とプランを確かめてください。"
    /// プランが無く、お試しも使い切った時の印(`code` に続けて書く)。
    static let noPlanCode = "no_plan"
    static let noPlanMessage = "usage_limit_reached: no_plan: お試しの3問を使い切りました。続けるにはプランを選んでください。"
    /// 今の版の規約に同意していない時の印。
    static let consentCode = "terms_consent_required"
    static let consentMessage = "terms_consent_required: 今の版の利用規約に同意していません。"

    /// ターンの失敗の記録(`error_detail`)から、止めた理由を読む。
    static func denial(in detail: String?) -> UsageDenial? {
        guard let detail else { return nil }
        if detail.contains(consentCode) { return .consentRequired }
        guard detail.contains(code) else { return nil }
        return detail.contains(noPlanCode) ? .noPlan : .limitReached
    }
}
