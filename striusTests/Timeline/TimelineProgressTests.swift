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

    // MARK: レビューの指摘(PR #156)

    /// law を 1 日目に先へ進んでよいにする(直近5問中4問)。
    private func clearLaw(_ machine: inout TimelineMachine) {
        for (index, correct) in [true, true, false, true, true].enumerated() {
            answer(&machine, "l\(index)", skill: "law", correct: correct, at: time("2026-11-15", index))
        }
    }

    private func surprise(_ machine: inout TimelineMachine, id: String, skills: [String], marks: [String: String], verdict: String,
                          assisted: Bool = false, at: String) {
        let card = F.card("card-\(id)", status: "answered", skills: skills, createdAt: at, payload: ["surprise": .string("law")])
        machine.put("test", card)
        var attempt = F.attempt(id, card: card.id, verdict: verdict, createdAt: at)
        attempt.skillMarks = marks
        attempt.assisted = assisted
        machine.put("test", attempt)
        for skill in skills {
            machine.applySkill(id: skill, card: card, correct: marks[skill] == "correct", assisted: assisted, withinTime: true, firstTry: true, attemptID: id)
        }
    }

    /// 2 つのスキルを使う不意打ち: 答案全体は × でも、不意打ちのスキルに ○ がつけば定着。計算し直しても同じ。
    func testSurpriseUsesTheSkillsOwnMark() {
        var machine = F.machine(now: "2026-11-16T10:00:00.000000Z")
        setUpSubunit(&machine)
        clearLaw(&machine)
        surprise(&machine, id: "u", skills: ["law", "sci"], marks: ["law": "correct", "sci": "wrong"], verdict: "wrong", at: time("2026-11-16", 0))
        XCTAssertEqual(machine.skills["law"]?.status, "mastered")
        machine.recomputeSkill("law")
        XCTAssertEqual(machine.skills["law"]?.status, "mastered", "差分で反映した時と、並べ直した時で同じ")
    }

    /// やり方を見てから解いた不意打ちは、○ でも定着にしない(思い出せなかったものとして扱う)。
    func testHintedSurpriseDoesNotMaster() {
        var machine = F.machine(now: "2026-11-16T10:00:00.000000Z")
        setUpSubunit(&machine)
        clearLaw(&machine)
        surprise(&machine, id: "u", skills: ["law"], marks: ["law": "correct"], verdict: "correct", assisted: true, at: time("2026-11-16", 0))
        XCTAssertEqual(machine.skills["law"]?.status, "practicing")
        machine.recomputeSkill("law")
        XCTAssertEqual(machine.skills["law"]?.status, "practicing")
    }

    /// 前の版で定着した点: 不意打ちの × の後に計算し直しても、定着は外さず、次の確かめを 3 日後にする。
    func testLegacyMasterySurvivesAMissedSurpriseOnRecompute() {
        var machine = F.machine(now: "2026-11-16T10:00:00.000000Z")
        machine.put("test", F.skill("law", status: "mastered", dates: ["2026-11-10", "2026-11-12", "2026-11-14"]))
        surprise(&machine, id: "u", skills: ["law"], marks: ["law": "wrong"], verdict: "wrong", at: time("2026-11-16", 0))
        XCTAssertEqual(machine.skills["law"]?.status, "mastered")
        XCTAssertEqual(machine.skills["law"]?.nextReviewAt, "2026-11-19")
        machine.recomputeSkill("law")
        XCTAssertEqual(machine.skills["law"]?.status, "mastered")
        XCTAssertEqual(machine.skills["law"]?.nextReviewAt, "2026-11-19")
    }

    /// 答案の足りない前提(needs_evidence)のカードが無い5枚も、1 回だけ作り直させる。
    func testMissingEvidenceCardAsksForOneRetry() throws {
        var machine = F.machine(now: "2026-11-16T10:00:00.000000Z")
        setUpSubunit(&machine)
        let request: LedgerJSON = .object(["needs_evidence": .array([.string("vector")])])
        let batchID = machine.insertBatchRequest(purpose: "cards", request: request, accuracy: nil, levelCap: nil)
        let lawCard = F.draftJSON(level: 2, skills: ["law"])
        XCTAssertEqual(machine.applyBatch(id: batchID, batch: try F.batch(cards: [lawCard])), .retry)
        XCTAssertTrue(machine.batches[batchID]?.rejected.contains { $0.contains("vector") } ?? false)
    }

    /// 大きすぎる数(無限大になる)は読めない数として断り、どの値とも等しくしない。
    func testOverflowingLiteralIsNotEqualToAnything() {
        XCTAssertNil(TimelineExpression.equivalent("1e999", "42"))
        XCTAssertFalse(TimelineExpression.close(.infinity, .infinity, tolerance: 1e-6))
        XCTAssertFalse(TimelineExpression.close(.infinity, 42, tolerance: 1e-6))
    }

    /// 範囲を固定している時は、必ず入れさせるスキルも範囲の中だけにする(範囲の外は出せないので)。
    func testRequiredSkillsFollowThePinnedUnit() {
        let saved = TimelineScope.unitID
        defer { TimelineScope.unitID = saved }
        var workbook = WorkbookMachine()
        let unitA = workbook.createUnit(title: "A", outcome: "", source: "consult", subunits: [.init(title: "a", n: 2)], firstStage: 3)
        let unitB = workbook.createUnit(title: "B", outcome: "", source: "consult", subunits: [.init(title: "b", n: 2)], firstStage: 3)
        var machine = F.machine(now: "2026-11-16T10:00:00.000000Z")
        var inA = F.skill("inA")
        inA.unitId = unitA
        var inB = F.skill("inB")
        inB.unitId = unitB
        machine.put("test", inA)
        machine.put("test", inB)
        for skill in ["inA", "inB"] {
            for index in 0..<3 { answer(&machine, "\(skill)\(index)", skill: skill, correct: false, at: time("2026-11-16", index)) }
        }
        TimelineScope.unitID = unitA
        let stuck = TimelineTurns.progressRequest(workbook: workbook, timeline: machine)["stuck_today"]?.arrayValue?.compactMap { $0["skill_id"]?.stringValue }
        XCTAssertEqual(stuck, ["inA"])
    }

    /// 前の版で定着し、すでに 1 回確かめていた点: 不意打ちの ○ で 2 回目になり、関係のない判定の直しで並べ直しても 2 回目のまま。
    func testLegacyReviewCountIsTheReplayBaseline() {
        var machine = F.machine(now: "2026-11-16T10:00:00.000000Z")
        var legacy = F.skill("law", status: "mastered", dates: ["2026-11-01", "2026-11-03", "2026-11-05"])
        legacy.reviewCount = 1
        legacy.nextReviewAt = "2026-11-12"
        machine.put("test", legacy)
        surprise(&machine, id: "u", skills: ["law"], marks: ["law": "correct"], verdict: "correct", at: time("2026-11-16", 0))
        XCTAssertEqual(machine.skills["law"]?.reviewCount, 2)
        let next = machine.skills["law"]?.nextReviewAt
        answer(&machine, "other", skill: "law", correct: false, at: time("2026-11-16", 5))
        machine.recomputeSkill("law")
        XCTAssertEqual(machine.skills["law"]?.status, "mastered")
        XCTAssertEqual(machine.skills["law"]?.reviewCount, 2)
        XCTAssertEqual(machine.skills["law"]?.nextReviewAt, next)
    }

    /// 不意打ちで定着した点: その不意打ちを × に直したら、定着も外れる(前の版の定着とは扱わない)。
    func testRevisingTheMasteringSurpriseWithdrawsMastery() {
        var machine = F.machine(now: "2026-11-16T10:00:00.000000Z")
        setUpSubunit(&machine)
        clearLaw(&machine)
        surprise(&machine, id: "u", skills: ["law"], marks: ["law": "correct"], verdict: "correct", at: time("2026-11-16", 0))
        XCTAssertEqual(machine.skills["law"]?.status, "mastered")
        XCTAssertNil(machine.revise(attemptID: "u", grade: "wrong", marks: ["law": "wrong"], note: "読み違い"))
        XCTAssertEqual(machine.skills["law"]?.status, "practicing")
        XCTAssertNil(machine.revise(attemptID: "u", grade: "correct", marks: ["law": "correct"], note: "やはり正しい"))
        XCTAssertEqual(machine.skills["law"]?.status, "mastered")
        XCTAssertNil(machine.revise(attemptID: "u", grade: "wrong", marks: ["law": "wrong"], note: "やはり違う"))
        XCTAssertEqual(machine.skills["law"]?.status, "practicing", "並べ直しで定着した後に × に直しても、前の版の定着として残さない")
    }

    /// 見直しで決まった印が、新しい不意打ちより後に届いた: 時刻の順に並べ直す(古い ○ → 新しい × なら、間隔は 3 日に戻る)。
    func testLateSurpriseMarksAreAppliedInTimeOrder() {
        var machine = F.machine(now: "2026-11-20T10:00:00.000000Z")
        machine.put("test", F.skill("law", status: "mastered", dates: ["2026-11-01", "2026-11-03", "2026-11-05"]))
        // 新しい × が先に反映される。
        surprise(&machine, id: "new", skills: ["law"], marks: ["law": "wrong"], verdict: "wrong", at: "2026-11-20T09:00:00.000000Z")
        // 古い ○ が後から届く。
        surprise(&machine, id: "old", skills: ["law"], marks: ["law": "correct"], verdict: "correct", at: "2026-11-18T09:00:00.000000Z")
        XCTAssertEqual(machine.skills["law"]?.status, "mastered")
        XCTAssertEqual(machine.skills["law"]?.reviewCount, 0, "最後(11/20)の × で 0 に戻る")
        XCTAssertEqual(machine.skills["law"]?.nextReviewAt, "2026-11-23")
    }

    /// 途中に誤り(○ と扱う)で定着した不意打ちを × に直すと、印が変わらなくても定着は外れる。
    func testRevisingAPartialSurpriseToWrongWithdrawsMastery() {
        var machine = F.machine(now: "2026-11-16T10:00:00.000000Z")
        setUpSubunit(&machine)
        clearLaw(&machine)
        let card = F.card("card-p", status: "answered", skills: ["law"], createdAt: time("2026-11-16", 0), payload: ["surprise": .string("law")])
        machine.put("test", card)
        var attempt = F.attempt("p", card: card.id, verdict: "wrong", createdAt: time("2026-11-16", 0))
        attempt.grade = "partial"
        attempt.skillMarks = ["law": "wrong"]
        machine.put("test", attempt)
        machine.applySkill(id: "law", card: card, correct: false, assisted: false, withinTime: true, firstTry: true, attemptID: "p")
        XCTAssertEqual(machine.skills["law"]?.status, "mastered")
        XCTAssertNil(machine.revise(attemptID: "p", grade: "wrong", marks: nil, note: "答えも違う"))
        XCTAssertEqual(machine.skills["law"]?.status, "practicing")
    }

    /// 同じ日に答えた不意打ちの採点が日付をまたいで終わっても、別の日に思い出せたことにはしない。
    func testGradingAfterMidnightDoesNotMakeASameDayAnswerALaterDay() {
        var machine = F.machine(now: "2026-11-16T00:05:00.000000Z")
        setUpSubunit(&machine)
        clearLaw(&machine)
        let card = F.card("card-m", status: "answered", skills: ["law"], createdAt: "2026-11-15T23:58:00.000000Z", payload: ["surprise": .string("law")])
        machine.put("test", card)
        var attempt = F.attempt("m", card: card.id, verdict: "correct", createdAt: "2026-11-15T23:58:00.000000Z")
        attempt.gradedAt = "2026-11-16T00:01:00.000000Z"
        attempt.skillMarks = ["law": "correct"]
        machine.put("test", attempt)
        machine.applySkill(id: "law", card: card, correct: true, assisted: false, withinTime: true, firstTry: true, attemptID: "m")
        XCTAssertEqual(machine.skills["law"]?.status, "practicing")
        machine.recomputeSkill("law")
        XCTAssertEqual(machine.skills["law"]?.status, "practicing")
    }
}
