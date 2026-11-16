import XCTest
@testable import strius

/// Issue #154: 先へ進む判定(直近5問中4問)・小単元のゴール・不意打ちによる定着・詰まった時・スキルごとの段の上限を、
/// 答案の並びを再生して確かめる(写真・書き起こし・問題文は持たない)。
final class TimelineProgressTests: XCTestCase {
    typealias F = TimelineFixture

    private func answer(_ machine: inout TimelineMachine, _ id: String, skill: String, correct: Bool, at: String, level: Int = 2,
                        grade: String? = nil, typeName: String = "型") {
        var card = F.card("c-\(id)", level: level, status: "answered", skills: [skill], createdAt: at)
        card.typeName = typeName
        machine.put("test", card)
        var attempt = F.attempt(id, card: card.id, verdict: correct ? "correct" : "wrong", createdAt: at)
        attempt.grade = grade
        attempt.skillMarks = [skill: correct ? "correct" : "wrong"]
        machine.put("test", attempt)
    }

    private func edge(_ id: String, from skill: String, requires: String) -> TimelineSkillEdgeRecord {
        TimelineSkillEdgeRecord(id: id, skillId: skill, requiresSkillId: requires, relation: "prerequisite", source: "initial", note: "", createdAt: F.now)
    }

    private func setUpSubunit(_ machine: inout TimelineMachine) {
        for id in ["law", "sci", "vector"] { machine.put("test", F.skill(id)) }
        var goal = F.skill("goal.sub")
        goal.unitId = "sub"
        goal.kind = "combination"
        machine.put("test", goal)
        machine.put("test", edge("e1", from: "goal.sub", requires: "law"))
        machine.put("test", edge("e2", from: "goal.sub", requires: "vector"))
    }

    private func time(_ day: String, _ minute: Int) -> String {
        String(format: "%@T%02d:%02d:00.000000Z", day, 10 + minute / 60, minute % 60)
    }

    /// 1 日の記録を再生する: 直近5問中4問で先へ進み、その時点でゴールを出せる。ほかのスキルを 10 枚解いたら 1 回目の不意打ち。
    /// 同じ日の ○ では定着せず、翌日の 3 枚目以降の不意打ちの ○ で定着する。
    func testReplayedDayClearsOpensTheGoalAndMastersByASurpriseOnTheNextDay() throws {
        var machine = F.machine(now: "2026-11-15T13:00:00.000000Z")
        setUpSubunit(&machine)
        for (index, correct) in [false, true, true, false, true, true].enumerated() {
            answer(&machine, "l\(index)", skill: "law", correct: correct, at: time("2026-11-15", index))
        }
        XCTAssertTrue(machine.clearedSkills.contains("law"))
        XCTAssertEqual(machine.clearedPoint("law")?.attemptID, "l5")
        let goal = try XCTUnwrap(machine.goalStates(subunitIDs: ["sub"]).first)
        XCTAssertTrue(goal.ready)
        XCTAssertFalse(goal.cleared)
        XCTAssertFalse(machine.surpriseDueSkills.contains("law"))

        for index in 0..<10 { answer(&machine, "s\(index)", skill: "sci", correct: index % 3 != 0, at: time("2026-11-15", 30 + index)) }
        XCTAssertEqual(machine.surpriseDueSkills, ["law"])

        // 束の受け取り: ゴールと不意打ちのカードが無い・スキルの段の上限を超えた → 1 回だけ作り直し。2 回目は受け取る。
        let request: LedgerJSON = .object(["goal_ready": .array([.string("goal.sub")]), "surprise_due": .array([.string("law")]),
                                           "skill_level_caps": .object(["sci": .number(1)])])
        let batchID = machine.insertBatchRequest(purpose: "cards", request: request, accuracy: nil, levelCap: nil)
        let lawCard = F.draftJSON(level: 2, skills: ["law"])
        let sciTooHard = F.draftJSON(level: 2, skills: ["sci"])
        XCTAssertEqual(machine.applyBatch(id: batchID, batch: try F.batch(cards: [lawCard, sciTooHard])), .retry)
        let rejected = machine.batches[batchID]?.rejected ?? []
        XCTAssertTrue(rejected.contains { $0.contains("goal.sub") })
        XCTAssertTrue(rejected.contains { $0.contains("cap 1 for sci") })
        XCTAssertEqual(machine.applyBatch(id: batchID, batch: try F.batch(cards: [lawCard])), .applied(cards: 1))
        let surpriseCard = try XCTUnwrap(machine.queue.first { machine.surpriseSkill(of: $0) == "law" })
        XCTAssertFalse(machine.surpriseDueSkills.contains("law"))

        // 同じ日の不意打ちは ○ でも定着にしない。
        try answerSurprise(&machine, card: surpriseCard, id: "u1", correct: true, at: "2026-11-15T13:05:00.000000Z")
        XCTAssertEqual(machine.skills["law"]?.status, "practicing")
        XCTAssertFalse(machine.surpriseDueSkills.contains("law"))

        // 翌日: その日の数える答案が 2 枚たまってから 2 回目。○ で定着、次は 3 日後。
        machine.now = { "2026-11-16T06:00:00.000000Z" }
        answer(&machine, "d0", skill: "sci", correct: true, at: time("2026-11-16", 0))
        XCTAssertFalse(machine.surpriseDueSkills.contains("law"))
        answer(&machine, "d1", skill: "sci", correct: true, at: time("2026-11-16", 1))
        // sci も前の日に先へ進んでよいになっていた(5問目〜9問目で4問 ○)ので、同じく 2 回目の時期。
        XCTAssertEqual(machine.surpriseDueSkills, ["law", "sci"])
        var second = F.card("next-day", level: 2, skills: ["law"], payload: ["surprise": .string("law")])
        second.createdAt = time("2026-11-16", 2)
        machine.put("test", second)
        try answerSurprise(&machine, card: second, id: "u2", correct: true, at: "2026-11-16T10:05:00.000000Z")
        XCTAssertEqual(machine.skills["law"]?.status, "mastered")
        XCTAssertEqual(machine.skills["law"]?.nextReviewAt, "2026-11-19")
    }

    private func answerSurprise(_ machine: inout TimelineMachine, card: TimelineCardRecord, id: String, correct: Bool, at: String) throws {
        var answered = card
        answered.status = "answered"
        answered.updatedAt = at
        machine.put("test", answered)
        var attempt = F.attempt(id, card: card.id, verdict: correct ? "correct" : "wrong", createdAt: at)
        attempt.skillMarks = ["law": correct ? "correct" : "wrong"]
        machine.put("test", attempt)
        machine.applySkill(id: "law", card: answered, correct: correct, assisted: false, withinTime: true, firstTry: true, attemptID: id)
    }

    /// 答案が 5 問に足りない直接の前提があると、ゴールは出せず、その前提を先に出させる。
    func testShortPrerequisiteIsAskedForInsteadOfBlockingForever() {
        var machine = F.machine(now: "2026-11-15T13:00:00.000000Z")
        setUpSubunit(&machine)
        for index in 0..<5 { answer(&machine, "l\(index)", skill: "law", correct: true, at: time("2026-11-15", index)) }
        answer(&machine, "v0", skill: "vector", correct: true, at: time("2026-11-15", 10))
        let goal = machine.goalStates(subunitIDs: ["sub"]).first
        XCTAssertEqual(goal?.ready, false)
        XCTAssertEqual(goal?.needsEvidence, ["vector"])
    }

    /// 同じスキルで今日 3 回 ×(途中に誤りは除く)なら、止めずに × になった形と一緒に渡す。段の上限はスキルごと。
    func testStuckSkillsAndPerSkillLevelCaps() {
        var machine = F.machine(now: "2026-11-16T09:00:00.000000Z")
        setUpSubunit(&machine)
        answer(&machine, "a", skill: "sci", correct: false, at: time("2026-11-16", 0), level: 2, typeName: "書き直し")
        answer(&machine, "b", skill: "sci", correct: false, at: time("2026-11-16", 1), level: 2, grade: "partial", typeName: "書き直し")
        answer(&machine, "c", skill: "sci", correct: false, at: time("2026-11-16", 2), level: 2, typeName: "割り算")
        XCTAssertTrue(machine.stuckSkills.isEmpty)
        answer(&machine, "d", skill: "sci", correct: false, at: time("2026-11-16", 3), level: 2, typeName: "割り算")
        XCTAssertEqual(machine.stuckSkills.map(\.skill), ["sci"])
        XCTAssertEqual(machine.stuckSkills.first?.typeNames, ["書き直し", "割り算"])
        for index in 0..<3 { answer(&machine, "l\(index)", skill: "law", correct: true, at: time("2026-11-16", 10 + index), level: 3) }
        XCTAssertEqual(machine.skillLevelCaps["sci"], 1)
        XCTAssertNil(machine.skillLevelCaps["law"])
    }

    /// 判定を直して計算し直しても、前の版で定着した点(不意打ちの答案が無い)は定着のまま残す。
    func testRecomputeKeepsLegacyMastery() {
        var machine = F.machine(now: "2026-11-16T09:00:00.000000Z")
        var legacy = F.skill("old", status: "mastered", dates: ["2026-11-10", "2026-11-13", "2026-11-14"])
        legacy.nextReviewAt = "2026-11-17"
        machine.put("test", legacy)
        answer(&machine, "x", skill: "old", correct: false, at: time("2026-11-16", 0))
        machine.recomputeSkill("old")
        XCTAssertEqual(machine.skills["old"]?.status, "mastered")
        XCTAssertEqual(machine.skills["old"]?.nextReviewAt, "2026-11-17")
    }
}
