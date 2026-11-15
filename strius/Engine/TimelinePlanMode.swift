import Foundation

/// タイムラインの新しい形(2026-11-15 の検討。試作で、既定はオフ):
/// - 文脈(今日の記録)を読むのは上位モデル(Opus)だけ。Opus が学習の計画を YAML で書き、台帳に残す
///   (`timeline_batches` の purpose "plan"。計画は `request["plan"]`)。
/// - 採点は Sonnet の続くスレッドで行う。system には今日の記録の代わりに、計画とスキルの一覧を入れる。
///   最後の採点から 1 時間以内なら同じスレッドを続け、1 時間を過ぎた・長くなりすぎた時は新しいスレッドにする。
/// - 答案ごとの見直しのターンは走らせない。
/// オフの時は、今までの形(採点・出題・見直しが今日の記録を共有する)のまま動く。
nonisolated enum TimelinePlanMode {
    static let defaultsKey = "timeline.planMode"
    /// 続くスレッドの ID と、最後に使った時刻(この端末で 1 本)。
    static let threadKey = "timeline.session.thread"
    static let lastUsedKey = "timeline.session.lastUsedAt"

    /// 採点のモデル。
    static let sessionModel = "claude-sonnet-5-5"
    /// スレッドを続ける間隔(キャッシュの寿命と同じ 1 時間)。
    static let sessionTTL: TimeInterval = 3_600
    /// これを超えたら新しいスレッドにする(前の要求の入力トークン)。
    static let sessionTokenLimit = 80_000
    /// 計画の依頼の purpose。
    static let planPurpose = "plan"

    /// 計画の依頼の返事(`schema:timeline_plan`)。
    nonisolated struct Reply: Decodable, Sendable {
        var plan: String
    }

    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey) || ProcessInfo.processInfo.environment["STRUIS_TIMELINE_PLAN_MODE"] == "1"
    }

    /// 次の採点で使うスレッド: 1 時間以内に使ったスレッドがあれば、その続き。無ければ新しく始める(nil)。
    static func session(now: Date = Date()) -> String? {
        let defaults = UserDefaults.standard
        guard let thread = defaults.string(forKey: threadKey), !thread.isEmpty else { return nil }
        let last = defaults.double(forKey: lastUsedKey)
        guard last > 0, now.timeIntervalSince1970 - last < sessionTTL else { return nil }
        return thread
    }

    /// 採点を終えたスレッドを、次の採点が続けて使えるように控える。
    static func touch(threadID: String?, now: Date = Date()) {
        guard let threadID, !threadID.isEmpty, !threadID.hasPrefix("direct-") else { return }
        UserDefaults.standard.set(threadID, forKey: threadKey)
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastUsedKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: threadKey)
        UserDefaults.standard.removeObject(forKey: lastUsedKey)
    }

    /// いちばん新しい計画(無ければ nil)。
    static func latestPlan(_ timeline: TimelineMachine) -> String? {
        timeline.batches.values
            .filter { $0.purpose == planPurpose && $0.status == "ready" }
            .max { $0.updatedAt < $1.updatedAt }?
            .request["plan"]?.stringValue
    }

    /// 計画の依頼を台帳に入れる(Opus のターンで書かせる)。`log` は Opus に読ませる記録。
    @discardableResult
    static func insertPlanRequest(log: String, timeline: inout TimelineMachine) -> String {
        timeline.insertBatchRequest(purpose: planPurpose, request: .object(["task": .string("plan"), "log": .string(log)]), accuracy: nil, levelCap: nil)
    }
}
