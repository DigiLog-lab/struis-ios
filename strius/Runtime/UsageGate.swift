import Foundation
import OSLog

nonisolated private let usageLog = Logger(subsystem: "com.digiloglab.strius", category: "usage")

/// 料金プラン(#62、2026-10-30 決定)。プラン間で機能の差はつけず、1 週間に使える Claude 代だけが違う。
/// 上限は内部的に週ごとのドルで持つ(Claude 代は手取りの 50% 以内、1 ドル 160 円)。問題数は 1 問 ¥10 で割って切り下げた目安。
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

/// 利用枠の決まり(#62)。
nonisolated enum UsageRules {
    /// 1 問の目安(¥10)を USD にしたもの(1 ドル 160 円)。
    static let problemUSD = 10.0 / 160.0
    /// ソフトリミット: 上限に達しても、解いている途中のカード 1 枚分は採点まで通す。
    static let graceUSD = 0.07
    /// 購入する前(プランなし)の枠。お試しの 3 問の採点だけを通す(何問解いたかはアプリが Keychain で数える)。
    static let trialLimitUSD = 0.25

    static func limitUSD(plan: UsagePlan?) -> Double { plan?.weeklyLimitUSD ?? trialLimitUSD }

    /// 週の始まり(端末の時刻で月曜 0:00)。購読の開始日を起点にした週は #62 の後続で替える。
    static func weekStart(for date: Date, calendar: Calendar = .current) -> Date {
        var calendar = calendar
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// 次に枠が戻る日時(次の月曜 0:00)。
    static func resetDate(after date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 7, to: weekStart(for: date, calendar: calendar)) ?? date
    }

    /// 保存の鍵(週の始まりの日付)。
    static func weekKey(for date: Date, calendar: Calendar = .current) -> String {
        let start = weekStart(for: date, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        return String(format: "usage.week.%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
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
}

nonisolated struct KeychainValueStore: DeviceValueStore {
    var keychain = KeychainStore(service: "com.digiloglab.strius.device-record")
    func string(_ key: String) -> String? { keychain.get(key) }
    func set(_ value: String?, _ key: String) {
        if let value { keychain.set(value, for: key) } else { keychain.delete(key) }
    }
}

nonisolated struct CloudValueStore: DeviceValueStore {
    func string(_ key: String) -> String? { NSUbiquitousKeyValueStore.default.string(forKey: key) }
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
}

/// Keychain と iCloud の Key-Value ストアの組。
nonisolated struct MirroredValues: Sendable {
    let local: any DeviceValueStore
    let cloud: any DeviceValueStore

    static let device = MirroredValues(local: KeychainValueStore(), cloud: CloudValueStore())

    /// 数は大きい方を採る(使用額・お試しの数を、入れ直しや別の端末で戻さない)。
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
    /// 残りの目安の問題数(1 問 ¥10 で割って切り下げ)。
    var remainingProblems: Int { max(0, Int(((limitUSD - spentUSD) / UsageRules.problemUSD).rounded(.down))) }
}

extension Notification.Name {
    /// 使用額かプランが変わった(画面の表示を読み直す)。
    nonisolated static let usageMeterChanged = Notification.Name("struis.usageMeterChanged")
}

/// 期間ごとの使用額と今のプラン。中継(主スレッドの外)と画面の両方から使うので、鍵で守る。
nonisolated final class UsageMeter: @unchecked Sendable {
    static let shared = UsageMeter.makeShared()

    private let lock = NSLock()
    private let values: MirroredValues
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    /// DEBUG の差し替え(`STRUIS_PLAN`)。nil なら StoreKit から受け取ったプラン。
    private let forcedPlan: UsagePlan??

    static let planKey = "usage.plan.v1"

    init(values: MirroredValues = .device, defaults: UserDefaults = .standard, forcedPlan: UsagePlan?? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.values = values
        self.defaults = defaults
        self.forcedPlan = forcedPlan
        self.now = now
    }

    private static func makeShared() -> UsageMeter {
        #if DEBUG
        // 画面の確認用: `STRUIS_PLAN=none|light|standard|generous`・`STRUIS_USAGE_PERCENT=0〜100` で差し替える(端末の記録は触らない)。
        let environment = ProcessInfo.processInfo.environment
        let forced: UsagePlan?? = environment["STRUIS_PLAN"].map { value -> UsagePlan? in value == "none" ? nil : UsagePlan(rawValue: value) }
        if let percent = environment["STRUIS_USAGE_PERCENT"].flatMap(Double.init) {
            let plan = forced ?? nil
            let memory = MirroredValues(local: MemoryValueStore(), cloud: MemoryValueStore())
            memory.setNumber(UsageRules.limitUSD(plan: plan) * percent / 100, UsageRules.weekKey(for: Date()))
            return UsageMeter(values: memory, defaults: UserDefaults(suiteName: "struis.usage.debug") ?? .standard, forcedPlan: forced)
        }
        if forced != nil { return UsageMeter(forcedPlan: forced) }
        #endif
        return UsageMeter()
    }

    /// 今のプラン(購入していなければ nil)。StoreKit の契約から `setPlan` で受け取り、起動直後のために端末にも控える。
    var plan: UsagePlan? {
        if let forcedPlan { return forcedPlan }
        return defaults.string(forKey: Self.planKey).flatMap(UsagePlan.init(rawValue:))
    }

    func setPlan(_ plan: UsagePlan?) {
        guard forcedPlan == nil, plan != self.plan else { return }
        defaults.set(plan?.rawValue, forKey: Self.planKey)
        usageLog.info("plan is now \(plan?.rawValue ?? "none", privacy: .public)")
        Self.notifyChanged()
    }

    func snapshot() -> UsageSnapshot {
        let date = now()
        let spent = lock.withLock { values.number(UsageRules.weekKey(for: date)) }
        return UsageSnapshot(plan: plan, spentUSD: spent, limitUSD: UsageRules.limitUSD(plan: plan), resetsAt: UsageRules.resetDate(after: date))
    }

    /// 使った金額を足す(Keychain と iCloud の大きい方に足して、両方に書く)。
    func add(_ usd: Double) {
        guard usd > 0 else { return }
        let key = UsageRules.weekKey(for: now())
        lock.withLock {
            values.setNumber(values.number(key) + usd, key)
        }
        Self.notifyChanged()
    }

    private static func notifyChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .usageMeterChanged, object: nil) }
    }
}

/// 上限の判定(#62)。中継が送る前に `admit`、応答の料金が分かったら `record`。Enclave に移る時は、この実装と
/// `ClaudeUpstream` の送り先だけを差し替える。
nonisolated protocol UsageGate: Sendable {
    /// この要求を送ってよいか。
    func admit() -> Bool
    /// 使った金額を記録する(`Attempt.finish` の記録と、送った本文の大きさ)。
    func record(_ attempt: [String: Any], requestBytes: Int)
}

/// 端末内で数える判定。ソフトリミットとして、上限を超えてもカード 1 枚分(`graceUSD`)までは通す。
nonisolated struct DeviceUsageGate: UsageGate {
    var meter: UsageMeter = .shared

    func admit() -> Bool {
        let snapshot = meter.snapshot()
        return snapshot.spentUSD < snapshot.limitUSD + UsageRules.graceUSD
    }

    func record(_ attempt: [String: Any], requestBytes: Int) {
        meter.add(UsageRules.charge(record: attempt, requestBytes: requestBytes))
    }
}

/// 数えない判定(中継のテスト)。
nonisolated struct UnlimitedUsageGate: UsageGate {
    func admit() -> Bool { true }
    func record(_ attempt: [String: Any], requestBytes: Int) {}
}

/// 上限に達した時の返し方。Codex は 429・5xx を再試行するので、再試行されない 400 に `usage_limit_reached` を付ける。
nonisolated enum UsageLimitResponse {
    static let code = "usage_limit_reached"
    static let message = "usage_limit_reached: 今週の利用枠を使い切りました。設定の「利用枠」で、戻る日時とプランを確かめてください。"
}
