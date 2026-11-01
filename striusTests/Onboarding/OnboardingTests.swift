import XCTest
@testable import strius

/// オンボーディング(#40): 年齢の区分、端末に残す記録、お試しの見本、続きからの再開、AI の返事の読み取り、最初のカード。
@MainActor
final class OnboardingTests: XCTestCase {
    private func records() -> OnboardingRecords {
        OnboardingRecords(values: MirroredValues(local: MemoryValueStore(), cloud: MemoryValueStore()))
    }

    // MARK: - 年齢

    func testAgeBandFromDeclaredAgeRangeWithGates16And18() {
        XCTAssertEqual(AgeBand.from(lowerBound: nil, upperBound: 15), .under16)
        XCTAssertEqual(AgeBand.from(lowerBound: 13, upperBound: 15), .under16)
        XCTAssertEqual(AgeBand.from(lowerBound: 16, upperBound: 17), .under18)
        XCTAssertEqual(AgeBand.from(lowerBound: 18, upperBound: nil), .adult)
        XCTAssertNil(AgeBand.from(lowerBound: nil, upperBound: nil), "範囲が分からなければ生年月日を聞く")
    }

    func testAgeBandFromBirthdate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31))!
        func birth(_ year: Int, _ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day))! }
        XCTAssertEqual(AgeBand.from(birthdate: birth(2011, 4, 15), now: now, calendar: calendar), .under16)
        XCTAssertEqual(AgeBand.from(birthdate: birth(2010, 10, 31), now: now, calendar: calendar), .under18, "16 歳の誕生日")
        XCTAssertEqual(AgeBand.from(birthdate: birth(2008, 11, 1), now: now, calendar: calendar), .under18, "18 歳の前日")
        XCTAssertEqual(AgeBand.from(birthdate: birth(2008, 10, 31), now: now, calendar: calendar), .adult, "18 歳の誕生日")
    }

    func testBirthdateIsDiscardedAndOnlyTheBandIsKept() throws {
        let model = OnboardingModel(profile: OnboardingProfile(), records: records(), hasPlan: { false }, isClaudeAvailable: { true }, start: .birthdate)
        model.birthdate = Calendar.current.date(byAdding: .year, value: -20, to: Date())!
        model.commitBirthdate()
        XCTAssertEqual(model.records.age?.band, .adult)
        XCTAssertEqual(model.records.age?.declaration, "birthdate")
        XCTAssertEqual(model.birthdate, OnboardingModel.defaultBirthdate, "判定が終わったら生年月日を消す")
        let saved = String(decoding: try JSONEncoder().encode(model.profile), as: UTF8.self)
        XCTAssertFalse(saved.contains("birth\""), "回答に生年月日を持たない")
        XCTAssertEqual(model.step, .terms)
    }

    func testAgeIsCheckedAgainAfterAYear() {
        let now = Date()
        XCTAssertFalse(AgeResult(band: .under18, declaration: "selfDeclared", checkedAt: now.addingTimeInterval(-300 * 86_400)).needsRecheck(now: now))
        XCTAssertTrue(AgeResult(band: .under18, declaration: "selfDeclared", checkedAt: now.addingTimeInterval(-366 * 86_400)).needsRecheck(now: now))
    }

    // MARK: - 端末の記録

    func testTrialCountTakesTheLargerStoreAndStopsAtThree() {
        let local = MemoryValueStore()
        let cloud = MemoryValueStore([OnboardingRecords.trialUsedKey: "2"])
        let records = OnboardingRecords(values: MirroredValues(local: local, cloud: cloud))
        XCTAssertEqual(records.trialUsed, 2, "入れ直した端末でも、iCloud に残った数から続ける")
        records.recordTrialSolved()
        records.recordTrialSolved()
        XCTAssertEqual(records.trialUsed, 3)
        XCTAssertEqual(records.trialRemaining, 0)
        XCTAssertEqual(local.string(OnboardingRecords.trialUsedKey).flatMap(Double.init), 3)
    }

    func testTermsAndAgeSurviveClearingTheProfile() {
        let records = records()
        records.acceptTerms()
        records.saveAge(AgeResult(band: .under18, declaration: "guardianDeclared", checkedAt: Date()))
        OnboardingProfile.clear(UserDefaults(suiteName: "onboarding-tests-\(UUID().uuidString)")!)
        XCTAssertNotNil(records.termsAcceptedAt)
        XCTAssertEqual(records.age?.declaration, "guardianDeclared")
    }

    // MARK: - お試しの見本

    func testEighteenSamplesThreePerGradeWithAnswersAndRubrics() {
        let all = TrialProblem.all
        XCTAssertEqual(all.count, 18)
        for grade in OnboardingCatalog.grades {
            let problems = TrialProblem.problems(grade: grade)
            XCTAssertEqual(problems.count, 3, grade)
            for problem in problems {
                XCTAssertFalse(problem.prompt.isEmpty, problem.id)
                XCTAssertFalse(problem.answer.isEmpty, problem.id)
                XCTAssertFalse(problem.rubric.isEmpty, problem.id)
            }
        }
        XCTAssertEqual(Set(all.map(\.id)).count, 18, "ID が重ならない")
    }

    func testAnotherProblemIsADifferentSampleOfTheSameGrade() {
        let first = TrialProblem.next(after: nil, grade: "中3", solved: [])!
        let second = TrialProblem.next(after: first, grade: "中3", solved: [])!
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.grade, "中3")
        let third = TrialProblem.next(after: second, grade: "中3", solved: [first.id])!
        XCTAssertNotEqual(third.id, first.id, "解いた見本は後に回す")
        XCTAssertNotEqual(third.id, second.id)
    }

    // MARK: - 続きから

    private func profile(grade: String? = "中3", terms: Bool = true, consent: Bool = true, trial: Int = 0, resume: OnboardingStep? = nil) -> OnboardingProfile {
        var profile = OnboardingProfile()
        profile.grade = grade
        profile.photoConsentAt = consent ? "2026-10-31T00:00:00Z" : nil
        profile.trial = (0..<trial).map { TrialRecord(problemID: "p\($0)", label: "中3 数学・二次方程式", correct: true, learnerAnswer: "", comment: "") }
        profile.resumeStep = resume?.rawValue
        return profile
    }

    private let age = AgeResult(band: .adult, declaration: "selfDeclared", checkedAt: Date())

    func testResumeContinuesWhereTheLearnerLeft() {
        XCTAssertEqual(OnboardingResume.step(profile: profile(grade: nil), age: nil, termsAccepted: false, trialUsed: 0, hasPlan: false, hasDraft: false), .grade)
        XCTAssertEqual(OnboardingResume.step(profile: profile(), age: nil, termsAccepted: false, trialUsed: 0, hasPlan: false, hasDraft: false), .grade, "年齢がまだなら学年から")
        XCTAssertEqual(OnboardingResume.step(profile: profile(), age: age, termsAccepted: false, trialUsed: 0, hasPlan: false, hasDraft: false), .terms)
        XCTAssertEqual(OnboardingResume.step(profile: profile(consent: false), age: age, termsAccepted: true, trialUsed: 0, hasPlan: false, hasDraft: false), .consent)
        XCTAssertEqual(OnboardingResume.step(profile: profile(), age: age, termsAccepted: true, trialUsed: 0, hasPlan: false, hasDraft: false), .trial)
        // 採点の後・計画の前なら「ここから何をしますか」から。
        XCTAssertEqual(OnboardingResume.step(profile: profile(trial: 1, resume: .result), age: age, termsAccepted: true, trialUsed: 1, hasPlan: false, hasDraft: false), .intent)
        XCTAssertEqual(OnboardingResume.step(profile: profile(trial: 1, resume: .unit), age: age, termsAccepted: true, trialUsed: 1, hasPlan: true, hasDraft: false), .intent)
        // 3 問解き終えて買っていなければ、解き終えた画面から購入へ。
        XCTAssertEqual(OnboardingResume.step(profile: profile(trial: 3), age: age, termsAccepted: true, trialUsed: 3, hasPlan: false, hasDraft: false), .trialDone)
        XCTAssertEqual(OnboardingResume.step(profile: profile(), age: age, termsAccepted: true, trialUsed: 3, hasPlan: false, hasDraft: false), .trialDone, "入れ直してもお試しの数は戻らない")
        XCTAssertEqual(OnboardingResume.step(profile: profile(trial: 1, resume: .plan), age: age, termsAccepted: true, trialUsed: 1, hasPlan: true, hasDraft: true), .plan)
        XCTAssertEqual(OnboardingResume.step(profile: profile(trial: 1, resume: .notify), age: age, termsAccepted: true, trialUsed: 1, hasPlan: true, hasDraft: false), .notify)
        // 大学生・それ以外はお試しが無い。買っていなければ購入画面へ。
        XCTAssertEqual(OnboardingResume.step(profile: profile(grade: OnboardingProfile.universityGrade), age: age, termsAccepted: true, trialUsed: 0, hasPlan: false, hasDraft: false), .paywall)
        XCTAssertEqual(OnboardingResume.step(profile: profile(grade: OnboardingProfile.universityGrade), age: age, termsAccepted: true, trialUsed: 0, hasPlan: true, hasDraft: false), .topic)
    }

    func testPlanningAsksToPurchaseFirstThenReturnsToPlanning() {
        var purchased = false
        let model = OnboardingModel(profile: profile(trial: 1), records: records(), hasPlan: { purchased }, isClaudeAvailable: { true }, start: .intent)
        model.choose(route: .unsure)
        XCTAssertEqual(model.step, .paywall, "計画づくりは購入の後")
        purchased = true
        model.afterPurchase()
        XCTAssertEqual(model.step, .planWait)
        model.afterPurchase()
        XCTAssertEqual(model.step, .planWait, "2 回目の知らせでは動かない")
    }

    func testUnsupportedDeviceShowsTheUnsupportedScreen() {
        let model = OnboardingModel(profile: OnboardingProfile(), records: records(), hasPlan: { false }, isClaudeAvailable: { false })
        XCTAssertEqual(model.step, .unsupported)
    }

    // MARK: - AI の返事

    func testVerdictAndPlanAreReadFromTheStructuredReply() throws {
        let verdict = try XCTUnwrap(OnboardingTurns.parseVerdict(#"{"readable":true,"grade":"wrong","learner_answer":"x = -2, -3","comment":"符号が逆です。","solution":"$(x-2)(x-3)=0$"}"#))
        XCTAssertFalse(verdict.isCorrect)
        XCTAssertEqual(verdict.learnerAnswer, "x = -2, -3")
        let mock = MockTurnRunner.onboardingPlan(["unit": "二次方程式", "trial": [["correct": true]]])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: mock), as: UTF8.self)
        let plan = try XCTUnwrap(OnboardingTurns.parsePlan("```json\n\(text)\n```"))
        XCTAssertEqual(plan.subunits.count, 6)
        XCTAssertEqual(plan.displayHeading, "二次方程式を6つに分けて進めます")
        XCTAssertTrue(plan.mentionsTrial)
        XCTAssertEqual(plan.firstProblem?.math, "x^2 - 9 = 0")
        XCTAssertNil(OnboardingTurns.parsePlan(#"{"unit_title":"","outcome":"","heading":"","lead":"","subunits":[],"first_problem":{"prompt":"","math":"","answer_key":""}}"#))
    }

    func testPlanRequestCarriesTheChoicesAndTheTrialResults() {
        var profile = profile(trial: 1)
        profile.route = .range
        profile.unit = "二次方程式"
        profile.untilTest = "2週間くらい"
        let model = OnboardingModel(profile: profile, records: records(), hasPlan: { true }, isClaudeAvailable: { true }, start: .planWait)
        let request = model.planRequest()
        XCTAssertEqual(request["route"]?.stringValue, "range")
        XCTAssertEqual(request["unit"]?.stringValue, "二次方程式")
        XCTAssertEqual(request["until_test"]?.stringValue, "2週間くらい")
        XCTAssertEqual(request["trial"]?.arrayValue?.count, 1)
        XCTAssertEqual(model.planChips, ["テストまで 2週間くらい"])
    }

    // MARK: - タイムラインの 1 枚目

    func testStarterCardIsTheNextCardOfTheQueueAndPointsAtSubunitOne() {
        var machine = TimelineMachine()
        let id = machine.addStarterCard(prompt: "$x = 3$ は、この方程式の解ですか。", math: "x^2 - 9 = 0", answerKey: "はい", unitID: "u1", subunitID: "s1")
        let card = machine.queue.first
        XCTAssertEqual(card?.id, id)
        XCTAssertEqual(card?.estimatedSeconds, 30)
        XCTAssertEqual(card?.level, 1, "答えだけで OK")
        XCTAssertEqual(card?.subunitId, "s1")
        XCTAssertEqual(card?.payload["starter"]?.boolValue, true)
    }
}
