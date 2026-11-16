import Foundation

/// 先へ進む判定・小単元のゴール・不意打ちによる定着・詰まった時・スキルごとの段の上限(Issue #154)。
/// どれも答案の記録から毎回計算する(新しい列は持たない)。決まりそのものは `TimelineRules`。
extension TimelineMachine {
    /// 数える答案(`countsForAccuracy`)についた、スキルごとの ○×(古い順)。
    nonisolated struct CountedMark: Equatable, Sendable {
        var attemptID: String
        var at: String
        var day: String
        var correct: Bool
        var level: Int
    }

    var countedMarks: [String: [CountedMark]] {
        var result: [String: [CountedMark]] = [:]
        for attempt in orderedAttempts where attempt.countsForAccuracy && (attempt.verdict == "correct" || attempt.verdict == "wrong") {
            guard let card = cards[attempt.cardId] else { continue }
            let at = attempt.gradedAt ?? attempt.createdAt
            let day = TimelineRules.day(attempt.createdAt, calendar: calendar) ?? ""
            for mark in skillMarks(attempt) {
                result[mark.skill, default: []].append(CountedMark(attemptID: attempt.id, at: at, day: day, correct: mark.correct, level: card.level))
            }
        }
        return result
    }

    /// 今「先へ進んでよい」スキル(直近5問中4問 ○)。
    var clearedSkills: Set<String> {
        Set(countedMarks.filter { TimelineRules.isCleared($0.value.map(\.correct)) }.keys)
    }

    /// 初めて先へ進んでよいになった答案(無ければ nil)。
    func clearedPoint(_ id: String, marks: [String: [CountedMark]]? = nil) -> CountedMark? {
        let list = (marks ?? countedMarks)[id] ?? []
        return TimelineRules.firstClearedIndex(list.map(\.correct)).map { list[$0] }
    }

    /// スキルごとの段の上限(そのスキルの直近5問で決める)。
    var skillLevelCaps: [String: Int] {
        countedMarks.compactMapValues { marks in TimelineRules.skillLevelCap(marks.map { (correct: $0.correct, level: $0.level) }) }
    }

    /// 小単元のゴール 1 つの状態。
    nonisolated struct GoalState: Equatable, Sendable {
        var goalID: String
        var subunitID: String
        var ready: Bool
        var cleared: Bool
        var needsEvidence: [String]
    }

    /// 小単元のゴール(`goal.` で始まる点)の状態。`subunitIDs` は今の小単元(順に)。
    func goalStates(subunitIDs: [String]) -> [GoalState] {
        let marks = countedMarks.mapValues { $0.map(\.correct) }
        return subunitIDs.compactMap { subunitID in
            guard let goal = activeSkills.first(where: { $0.id.hasPrefix("goal.") && $0.unitId == subunitID }) else { return nil }
            let readiness = TimelineRules.goalReadiness(prerequisites: directPrerequisites(of: goal.id), marks: marks)
            return GoalState(goalID: goal.id, subunitID: subunitID, ready: readiness.ready, cleared: TimelineRules.isCleared(marks[goal.id] ?? []),
                             needsEvidence: readiness.needsEvidence)
        }
    }

    /// その答案がついた、不意打ちのスキル(カードの印)。
    func surpriseSkill(of card: TimelineCardRecord) -> String? {
        card.payload["surprise"]?.stringValue
    }

    /// 今出す不意打ちのスキル。
    var surpriseDueSkills: [String] {
        let today = today
        let marks = countedMarks
        let cleared = Set(marks.filter { TimelineRules.isCleared($0.value.map(\.correct)) }.keys)
        let countedToday = orderedAttempts.filter { $0.countsForAccuracy && TimelineRules.day($0.createdAt, calendar: calendar) == today }
        let countedAttempts = orderedAttempts.filter { $0.countsForAccuracy && ($0.verdict == "correct" || $0.verdict == "wrong") }
        var due: [String] = []
        for skill in activeSkills {
            let surpriseCards = cards.values.filter { surpriseSkill(of: $0) == skill.id }
            // 手元にもう入れてある(まだ出していない)なら頼まない。
            if surpriseCards.contains(where: { $0.status == "unused" }) { continue }
            let shownToday = surpriseCards.contains { $0.status != "unused" && $0.status != "discarded" && TimelineRules.day($0.updatedAt, calendar: calendar) == today }
            let hadSurprise = surpriseCards.contains { card in attempts.values.contains { $0.cardId == card.id && ($0.verdict == "correct" || $0.verdict == "wrong") } }
            let point = clearedPoint(skill.id, marks: marks)
            let othersSince = point.map { point in
                countedAttempts.filter { attempt in
                    (attempt.gradedAt ?? attempt.createdAt) > point.at && !(cards[attempt.cardId]?.skills.contains(skill.id) ?? false)
                }.count
            } ?? 0
            if TimelineRules.surpriseDue(status: skill.status, nextReviewAt: skill.nextReviewAt, clearedDay: point?.day, cleared: cleared.contains(skill.id),
                                         othersSinceCleared: othersSince, hadSurprise: hadSurprise, answeredToday: countedToday.count,
                                         shownToday: shownToday, today: today) {
                due.append(skill.id)
            }
        }
        return due
    }

    /// 詰まっているスキル(同じ点で今日 3 回 ×。途中に誤りは数えない)と、× になったカードの形。
    var stuckSkills: [(skill: String, typeNames: [String])] {
        let today = today
        var results: [(skill: String, correct: Bool, day: String, partial: Bool)] = []
        var types: [String: [String]] = [:]
        for attempt in orderedAttempts {
            let day = TimelineRules.day(attempt.createdAt, calendar: calendar) ?? ""
            for mark in skillMarks(attempt) {
                results.append((mark.skill, mark.correct, day, attempt.grade == "partial"))
                if day == today, !mark.correct, let card = cards[attempt.cardId], !card.typeName.isEmpty, !(types[mark.skill]?.contains(card.typeName) ?? false) {
                    types[mark.skill, default: []].append(card.typeName)
                }
            }
        }
        return TimelineRules.stuckToday(results: results, today: today).sorted().map { (skill: $0, typeNames: types[$0] ?? []) }
    }

    /// 不意打ちの答案を、その点の定着に反映する。`correct` はその点についた ○×(答案全体の正誤ではない)。
    /// 途中に誤りは ○ として扱う(答えまでたどり着けているので)。やり方を見てから解いた答案は、思い出せなかったものとして × に扱う。
    static func surpriseCorrect(markCorrect: Bool, attempt: TimelineAttemptRecord) -> Bool {
        (markCorrect || attempt.grade == "partial") && !attempt.assisted
    }

    mutating func applySurprise(skillID: String, attemptID: String, markCorrect: Bool) {
        guard let skill = skills[skillID], let attempt = attempts[attemptID], attempt.verdict == "correct" || attempt.verdict == "wrong" else { return }
        let correct = Self.surpriseCorrect(markCorrect: markCorrect, attempt: attempt)
        let updated = TimelineRules.recordSurprise(skill, correct: correct, at: attempt.gradedAt ?? attempt.createdAt,
                                                   clearedDay: clearedPoint(skillID)?.day, calendar: calendar)
        put("timeline.skill_surprise", updated)
        if updated.status == "mastered", skill.status != "mastered" {
            recordChange(kind: "mastered", detail: .object(["skill_id": .string(skillID), "by": .string("surprise")]), attemptIDs: [attemptID], source: "app", reviewed: true)
        }
    }
}
