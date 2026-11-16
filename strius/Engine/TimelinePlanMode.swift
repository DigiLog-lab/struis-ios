import Foundation

/// タイムラインの新しい形(2026-11-15 の検討。試作で、既定はオフ):
/// - 文脈(答案の記録)を読むのは上位モデル(Opus)だけ。Opus が学習の計画を YAML で書き、台帳に残す
///   (`timeline_batches` の purpose "plan"。計画は `request["plan"]`)。
/// - 採点は Sonnet の続くスレッドで行う。system には答案の記録の代わりに、計画とスキルの一覧を入れる。
///   最後の採点から 1 時間以内で、計画が変わっていなければ同じスレッドを続ける。1 時間を過ぎた・長くなりすぎた・
///   新しい計画が届いた時は新しいスレッドにする。
/// - 答案ごとの見直しのターンは走らせない。
/// - Opus を呼ぶのは 2 つの時(2026-11-16 に決めた):
///   - その日最初にタイムラインを開いた時(`trigger` morning)。裏で呼び、届くまでは前の計画で続ける。
///   - 採点した Sonnet が、計画の `escalate_when` に当たると返した時(`trigger` escalation)。1 日 1 回まで。
///     新しい計画が届いてから 5 問は呼ばない(新しい計画を確かめる答案がまだ無いため)。
/// オフの時は、今までの形(採点・出題・見直しが今日の記録を共有する)のまま動く。
nonisolated enum TimelinePlanMode {
    static let defaultsKey = "timeline.planMode"
    /// 続くスレッドの ID・最後に使った時刻・そのスレッドを始めた時の計画(この端末で 1 本)。
    static let threadKey = "timeline.session.thread"
    static let lastUsedKey = "timeline.session.lastUsedAt"
    static let threadPlanKey = "timeline.session.plan"
    /// 採点のターンごとに、組んだ時の計画を控える(結果を書く時に、そのスレッドの計画として残す)。
    static func turnPlanKey(_ turnID: String) -> String { "timeline.session.turnPlan.\(turnID)" }

    /// 採点のモデル。
    static let sessionModel = "claude-sonnet-5-5"
    /// スレッドを続ける間隔(キャッシュの寿命と同じ 1 時間)。
    static let sessionTTL: TimeInterval = 3_600
    /// これを超えたら新しいスレッドにする(前の要求の入力トークン)。
    static let sessionTokenLimit = ClaudeModelInfo.timelineSessionTokenLimit
    /// 計画の依頼の purpose。
    static let planPurpose = "plan"
    /// 採点の返事から Opus を呼ぶのは 1 日にこの回数まで。
    static let escalationsPerDay = 1
    /// 新しい計画が届いてから、これだけ答案(飛ばしを含む)が溜まるまでは、採点の返事から Opus を呼ばない。
    static let answersAfterPlan = 5

    nonisolated enum Trigger: String, Sendable {
        case morning, escalation
    }

    /// 計画の依頼の返事(`schema:timeline_plan`)。
    nonisolated struct Reply: Decodable, Sendable {
        var plan: String
    }

    /// 採点の返事のうち、Opus を呼ぶ理由の欄(`withEscalation` で足す)。
    nonisolated struct Escalation: Decodable, Sendable {
        var escalate: String?
    }

    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey) || ProcessInfo.processInfo.environment["STRUIS_TIMELINE_PLAN_MODE"] == "1"
    }

    // MARK: - 続くスレッド

    /// 次の採点で使うスレッド: 1 時間以内に使い、今の計画(`planID`)で始めたスレッドがあれば、その続き。
    /// 無ければ新しく始める(nil)。
    static func session(planID: String?, now: Date = Date()) -> String? {
        let defaults = UserDefaults.standard
        guard let thread = defaults.string(forKey: threadKey), !thread.isEmpty else { return nil }
        let last = defaults.double(forKey: lastUsedKey)
        guard last > 0, now.timeIntervalSince1970 - last < sessionTTL else { return nil }
        guard (defaults.string(forKey: threadPlanKey) ?? "") == (planID ?? "") else { return nil }
        return thread
    }

    /// 採点のターンを組んだ時の計画を控える。
    static func remember(turnID: String, planID: String?) {
        UserDefaults.standard.set(planID ?? "", forKey: turnPlanKey(turnID))
    }

    /// 採点を終えたスレッドを、次の採点が続けて使えるように控える(そのターンを組んだ時の計画と一緒に)。
    static func touch(threadID: String?, turnID: String, now: Date = Date()) {
        let defaults = UserDefaults.standard
        let planID = defaults.string(forKey: turnPlanKey(turnID))
        defaults.removeObject(forKey: turnPlanKey(turnID))
        guard let threadID, !threadID.isEmpty, !threadID.hasPrefix("direct-"), let planID else { return }
        defaults.set(threadID, forKey: threadKey)
        defaults.set(now.timeIntervalSince1970, forKey: lastUsedKey)
        defaults.set(planID, forKey: threadPlanKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: threadKey)
        UserDefaults.standard.removeObject(forKey: lastUsedKey)
        UserDefaults.standard.removeObject(forKey: threadPlanKey)
    }

    // MARK: - 計画

    /// いちばん新しい計画の行(無ければ nil)。
    static func latestPlanRow(_ timeline: TimelineMachine) -> TimelineBatchRecord? {
        timeline.batches.values
            .filter { $0.purpose == planPurpose && $0.status == "ready" && $0.request["plan"]?.stringValue != nil }
            .max { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
    }

    /// いちばん新しい計画(無ければ nil)。
    static func latestPlan(_ timeline: TimelineMachine) -> String? {
        latestPlanRow(timeline)?.request["plan"]?.stringValue
    }

    /// 今日頼んだ計画の依頼(状態を問わない)。
    static func requestsToday(_ timeline: TimelineMachine, trigger: Trigger? = nil) -> [TimelineBatchRecord] {
        let today = timeline.today
        return timeline.batches.values.filter { row in
            row.purpose == planPurpose && TimelineRules.day(row.createdAt, calendar: timeline.calendar) == today
                && (trigger == nil || row.request["trigger"]?.stringValue == trigger?.rawValue)
        }
    }

    /// 返事を待っている計画の依頼が、これより古ければ置き去り(依頼を書いた後、ターンを組む前にアプリが終わった等)とみなす。
    /// 計画のターンの上限(3 分。`TurnCoordinator.timeLimits`)より十分長くする。
    static let abandonedAfter: TimeInterval = 15 * 60
    /// 置き去りとして閉じた依頼の理由(その日の 1 回に数えない)。
    static let abandonedError = "abandoned plan request"

    /// 返事を待っている計画の依頼があるか(置き去りの依頼は数えない)。
    static func inFlight(_ timeline: TimelineMachine) -> Bool {
        timeline.batches.values.contains { $0.purpose == planPurpose && $0.status == "requested" && !isAbandoned($0, timeline: timeline) }
    }

    static func isAbandoned(_ row: TimelineBatchRecord, timeline: TimelineMachine) -> Bool {
        guard row.status == "requested", let created = LedgerClock.parse(row.createdAt), let now = LedgerClock.parse(timeline.now()) else { return false }
        return now.timeIntervalSince(created) > abandonedAfter
    }

    /// 置き去りの計画の依頼を失敗として閉じる(閉じないと、次の依頼がいつまでも出せない)。
    static func closeAbandoned(_ timeline: inout TimelineMachine) {
        let stale = timeline.batches.values.filter { $0.purpose == planPurpose && isAbandoned($0, timeline: timeline) }.map(\.id)
        for id in stale { timeline.failBatch(id: id, error: abandonedError) }
    }

    /// その日最初に開いた時に Opus を呼ぶか: 今日まだ計画を頼んでいない(失敗も含めて 1 回だけ。置き去りで閉じた依頼は数えない)。
    static func needsMorningPlan(_ timeline: TimelineMachine) -> Bool {
        isOn && !inFlight(timeline) && requestsToday(timeline).allSatisfy { $0.error == abandonedError }
    }

    /// 採点の返事に理由があった時に Opus を呼ぶか(1 日 1 回まで・新しい計画のあと 5 問は呼ばない)。
    static func allowsEscalation(_ timeline: TimelineMachine) -> Bool {
        guard isOn, !inFlight(timeline), requestsToday(timeline, trigger: .escalation).count < escalationsPerDay else { return false }
        guard let plan = latestPlanRow(timeline) else { return true }
        let answered = timeline.attempts.values.filter { attempt in
            attempt.createdAt > plan.updatedAt && ["correct", "wrong", "skipped"].contains(attempt.verdict)
        }.count
        return answered >= answersAfterPlan
    }

    /// Opus に読ませる記録: 呼んだ理由・今の計画・答案の記録(朝は前に学習した日と今日、見直しは今日)。
    static func planLog(trigger: Trigger, reason: String?, timeline: TimelineMachine) -> String {
        var parts: [String] = []
        switch trigger {
        case .morning:
            parts.append("# 呼んだ理由\n\nその日最初にタイムラインを開きました。")
        case .escalation:
            parts.append("# 呼んだ理由\n\n採点している先生(Sonnet)が、計画の見直しを頼みました: " + (reason ?? ""))
        }
        parts.append("# 今の計画\n\n" + (latestPlan(timeline) ?? "まだありません。"))
        var days: [String] = []
        if trigger == .morning, let last = timeline.lastLogDayBeforeToday { days.append(last) }
        days.append(timeline.today)
        for day in days {
            let entries = timeline.dayLog(day)
            guard !entries.isEmpty || day == timeline.today else { continue }
            let title = day == timeline.today ? "# 今日(\(day))の記録" : "# \(day) の記録"
            parts.append(([title] + (entries.isEmpty ? ["まだありません。"] : entries.map(\.text))).joined(separator: "\n\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// 計画の依頼を台帳に入れる(Opus のターンで書かせる)。`log` は Opus に読ませる記録。
    @discardableResult
    static func insertPlanRequest(log: String, trigger: Trigger = .morning, reason: String? = nil, timeline: inout TimelineMachine) -> String {
        var request: [String: LedgerJSON] = ["task": .string("plan"), "trigger": .string(trigger.rawValue), "log": .string(log)]
        if let reason, !reason.isEmpty { request["reason"] = .string(reason) }
        return timeline.insertBatchRequest(purpose: planPurpose, request: .object(request), accuracy: nil, levelCap: nil)
    }

    /// 決まりに合えば、計画の依頼を入れて ID を返す(入れなければ nil)。
    static func requestPlan(trigger: Trigger, reason: String? = nil, timeline: inout TimelineMachine) -> String? {
        guard isOn else { return nil }
        closeAbandoned(&timeline)
        switch trigger {
        case .morning: guard needsMorningPlan(timeline) else { return nil }
        case .escalation: guard allowsEscalation(timeline) else { return nil }
        }
        let log = planLog(trigger: trigger, reason: reason, timeline: timeline)
        return insertPlanRequest(log: log, trigger: trigger, reason: reason, timeline: &timeline)
    }

    // MARK: - 出題

    /// 出題(5枚)の材料に入れる直近の答案の数。
    static let recentAnswerCount = 10

    /// 直近の答案(今日の記録の答案・飛ばした理由・判定の直し・異議の行を、新しい方から `recentAnswerCount` 件、古い順に)。
    static func recentAnswers(_ timeline: TimelineMachine) -> [String] {
        let kinds: Set<String> = ["attempt", "skip_reason", "revise", "dispute"]
        return Array(timeline.todayLog.filter { kinds.contains($0.kind) }.suffix(recentAnswerCount).map(\.text))
    }

    /// 新しい形の出題に添える一言(今回の仕事の後ろに足す)。
    static let batchNote = """
    ## 新しい形での出題

    今日の記録は渡しません。先頭の計画(`focus`・`steps`・`problem_forms`・`split_if_stuck`・`known_weak_points`)に沿って、今どのスキルをどの形で出すかを決めてください。直近の答案は材料の `recent_answers` にあります。同じ型の間違いが続いている時は、計画の `split_if_stuck` の順に細かく分けた問題を出します。`escalate` の欄は採点の返事だけのもので、出題の返事には入れません。
    """

    // MARK: - 採点の返事の形

    /// 採点の返事に、Opus を呼ぶ理由の欄(`escalate`。当たらなければ空の文字列)を足す。
    static func withEscalation(_ schema: LedgerJSON) -> LedgerJSON {
        guard case .object(var root) = schema, case .object(var properties)? = root["properties"] else { return schema }
        properties["escalate"] = .object(["type": .string("string")])
        root["properties"] = .object(properties)
        root["required"] = .array((root["required"]?.arrayValue ?? []) + [.string("escalate")])
        return .object(root)
    }
}
