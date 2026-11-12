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

    /// 生年月日の欄の初めの値は、選んだ学年に合わせる(大学生がそのまま「次へ」を押しても 16 歳未満にならない)。
    func testDefaultBirthdateFollowsTheGrade() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12))!
        func year(_ grade: String, _ at: Date) -> Int { calendar.component(.year, from: OnboardingModel.defaultBirthdate(grade: grade, now: at, calendar: calendar)) }
        XCTAssertEqual(year("中2", now), 2012)
        XCTAssertEqual(year("高1", now), 2010)
        XCTAssertEqual(year(OnboardingProfile.universityGrade, now), 2007)
        XCTAssertEqual(AgeBand.from(birthdate: OnboardingModel.defaultBirthdate(grade: OnboardingProfile.universityGrade, now: now, calendar: calendar), now: now, calendar: calendar), .adult)
        // 1〜3 月は、前の年の 4 月に始まった年度。
        let winter = calendar.date(from: DateComponents(year: 2027, month: 2, day: 1))!
        XCTAssertEqual(year("中2", winter), 2012)
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

    // MARK: - 規約の版(#78)

    func testConsentWithoutAVersionCountsAsNotAccepted() {
        let local = MemoryValueStore([OnboardingRecords.legacyTermsKey: "2026-10-31T00:00:00Z"])
        let records = OnboardingRecords(values: MirroredValues(local: local, cloud: MemoryValueStore()))
        XCTAssertFalse(records.hasAcceptedCurrentTerms, "版の記録が無い同意(規約の本文が無い時に押された同意)は数えない")
        XCTAssertNil(records.termsAcceptedAt)
        XCTAssertFalse(records.allowsAI, "同意するまで AI を使えない")
    }

    func testConsentToAnOlderVersionIsAskedAgainAndTheVersionIsKeptWithTheDate() throws {
        let local = MemoryValueStore()
        let cloud = MemoryValueStore()
        let records = OnboardingRecords(values: MirroredValues(local: local, cloud: cloud))
        let earlier = Date(timeIntervalSince1970: 1_790_000_000)
        records.acceptTerms(at: earlier, version: "2026-01-01")
        XCTAssertFalse(records.hasAcceptedCurrentTerms, "前の版への同意は、今の版の同意に数えない")
        XCTAssertEqual(records.termsAcceptance?.version, "2026-01-01")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        records.acceptTerms(at: now)
        XCTAssertTrue(records.hasAcceptedCurrentTerms)
        XCTAssertEqual(records.termsAcceptedAt, now)
        let stored = try XCTUnwrap(cloud.string(OnboardingRecords.termsKey))
        XCTAssertTrue(stored.contains(LegalVersion.terms), "iCloud にも版と日時を書く: \(stored)")
        XCTAssertEqual(local.string(OnboardingRecords.termsKey), stored, "Keychain と iCloud の両方に書く")
    }

    func testAcceptanceOfTheCurrentVersionOnAnotherDeviceIsNotHiddenByThisDevicesOlderOne() {
        let local = MemoryValueStore()
        let cloud = MemoryValueStore()
        OnboardingRecords(values: MirroredValues(local: local, cloud: MemoryValueStore())).acceptTerms(at: Date(), version: "2026-01-01")
        OnboardingRecords(values: MirroredValues(local: MemoryValueStore(), cloud: cloud)).acceptTerms()
        let records = OnboardingRecords(values: MirroredValues(local: local, cloud: cloud))
        XCTAssertTrue(records.hasAcceptedCurrentTerms, "別の端末で今の版に同意したら、この端末でも同意した扱い")
    }

    func testReconsentShowsTheTermsAndWhatIsSentThenFinishesWithoutTouchingTheOnboarding() {
        let records = records()
        var profile = profile(trial: 1, resume: .notify)
        profile.termsAcceptedAt = "2026-10-31T00:00:00Z"
        let model = OnboardingModel(profile: profile, records: records, hasPlan: { true }, isClaudeAvailable: { true }, reconsent: true)
        var finished = false
        model.onReconsented = { finished = true }
        XCTAssertEqual(model.step, .terms)
        model.acceptTerms()
        XCTAssertTrue(records.hasAcceptedCurrentTerms)
        XCTAssertEqual(model.step, .consent, "送る内容の文面が変わったので、前に同意していても読み直してもらう")
        model.acceptPhotoConsent()
        XCTAssertTrue(finished)
        XCTAssertEqual(model.profile.resumeStep, OnboardingStep.notify.rawValue, "終わったオンボーディングの続きの画面を書き換えない")
    }

    func testOnboardingAsksForWhatIsSentAfterTheTermsEvenWhenConsentedBefore() {
        let records = records()
        records.saveAge(AgeResult(band: .adult, declaration: "selfDeclared", checkedAt: Date()))
        records.values.set("2026-10-31T00:00:00Z", OnboardingRecords.legacyTermsKey)
        let model = OnboardingModel(profile: profile(), records: records, hasPlan: { false }, isClaudeAvailable: { true })
        XCTAssertEqual(model.step, .terms, "版の記録が無い同意は、規約から聞き直す")
        model.acceptTerms()
        XCTAssertEqual(model.step, .consent)
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

    // MARK: - 確認の1問だけ

    func testEverySubunitOfThePlanHasACheckProblemAndTappingMarksIt() throws {
        let mock = MockTurnRunner.onboardingPlan(["unit": "二次方程式", "trial": []])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: mock), as: UTF8.self)
        let plan = try XCTUnwrap(OnboardingTurns.parsePlan(text))
        XCTAssertTrue(plan.subunits.allSatisfy { $0.check != nil })
        XCTAssertEqual(plan.subunits[1].check?.math, "x^2 + 2x - 15 = 0")
        // 前の版の下書き(確かめる1問が無い)も読める。
        let old = #"{"unit_title":"u","outcome":"","heading":"","lead":"","subunits":[{"title":"s","outcome":"","n":4,"scoring_unit":"","note":""}],"first_problem":{"prompt":"p","math":"","answer_key":"a"}}"#
        XCTAssertNil(try XCTUnwrap(OnboardingTurns.parsePlan(old)).subunits[0].check)
    }

    func testACheckOfASubunitWithMathInItsNameShowsReadableText() async throws {
        // 本物の Claude は小単元の名前に式を入れる(2026-11-09 に Dev Box で確かめた)。説明文と見出しに `$` を出さない。
        let json = #"{"unit_title":"二次方程式","outcome":"","heading":"","lead":"","subunits":[{"title":"$(x+p)^2=q$ の形と解の公式","outcome":"","n":4,"scoring_unit":"","note":"","check":{"prompt":"次の二次方程式を解きなさい。","math":"x^2+3x+1=0","answer_key":"x=\\frac{-3\\pm\\sqrt{5}}{2}"}}]}"#
        UserDefaults.standard.set(Data(json.utf8), forKey: OnboardingModel.draftKey)
        defer { UserDefaults.standard.removeObject(forKey: OnboardingModel.draftKey) }
        let model = OnboardingModel(profile: profile(trial: 1), records: records(), hasPlan: { true }, isClaudeAvailable: { true }, start: .plan)
        model.toggleCheck(0)
        let started = await model.begin(ledger: try Ledger.inMemory())
        XCTAssertFalse(started)
        XCTAssertEqual(model.step, .check)
        XCTAssertFalse(model.checkTitle.contains("$"), model.checkTitle)
        XCTAssertFalse(model.problem?.label.contains("$") ?? true, model.problem?.label ?? "")
        XCTAssertEqual(model.problem?.math, "x^2+3x+1=0")
    }

    func testRebuildingForADifferentGoalDoesNotLeaveTheDeletedPlanToGoBackTo() {
        let json = #"{"unit_title":"u","outcome":"","heading":"","lead":"","subunits":[{"title":"s","outcome":"","n":4,"scoring_unit":"","note":""}]}"#
        UserDefaults.standard.set(Data(json.utf8), forKey: OnboardingModel.draftKey)
        defer { UserDefaults.standard.removeObject(forKey: OnboardingModel.draftKey) }
        let model = OnboardingModel(profile: profile(trial: 1), records: records(), hasPlan: { true }, isClaudeAvailable: { true }, start: .intent)
        model.go(.unit)
        model.go(.plan)
        model.rebuildPlan(tooHard: false)
        XCTAssertEqual(model.step, .intent)
        XCTAssertNil(model.draft)
        model.back()
        XCTAssertNotEqual(model.step, .plan, "消した計画の画面に戻らない")
        XCTAssertNotEqual(model.step, .unit)
    }

    func testTheTimelineDoesNotStudySubunitsPassedByCheck() {
        var workbook = WorkbookMachine()
        let unitID = workbook.createUnit(title: "二次方程式", outcome: "", source: "consult",
                                         subunits: [.init(title: "1", n: 4), .init(title: "2", n: 4), .init(title: "3", n: 4)])
        let ids = workbook.orderedSubunits(unitID: unitID).map(\.id)
        workbook.passByCheck(subunitID: ids[1])
        var timeline = TimelineMachine()
        _ = TimelineTurns.insertGraphRequest(.build, timeline: &timeline, workbook: workbook, profile: nil)
        let goals = Set(timeline.skills.values.compactMap(\.unitId))
        XCTAssertTrue(goals.contains(ids[0]))
        XCTAssertFalse(goals.contains(ids[1]), "確認の1問で合格にした小単元は目標に入れない")
        XCTAssertTrue(goals.contains(ids[2]))
    }

    func testCheckedSubunitsArePassedWithoutStudyAndTheNextOneStarts() {
        var machine = WorkbookMachine()
        let unitID = machine.createUnit(title: "二次方程式", outcome: "", source: "consult",
                                        subunits: [.init(title: "1", n: 4), .init(title: "2", n: 4), .init(title: "3", n: 4), .init(title: "4", n: 4)])
        let ids = machine.orderedSubunits(unitID: unitID).map(\.id)
        // 先の小単元(pending)は合格の印だけ。今の小単元はそのまま。
        machine.passByCheck(subunitID: ids[1])
        XCTAssertEqual(machine.subunits[ids[1]]?.status, "passed")
        XCTAssertEqual(machine.subunits[ids[0]]?.status, "active")
        // 今の小単元(active)を合格にすると、合格していない次の小単元(3)が始まる。
        machine.passByCheck(subunitID: ids[0])
        XCTAssertEqual(machine.subunits[ids[0]]?.status, "passed")
        XCTAssertEqual(machine.subunits[ids[2]]?.status, "active")
        XCTAssertEqual(machine.subunits[ids[3]]?.status, "pending")
        XCTAssertEqual(machine.subunits[ids[0]]?.metadata["passed_by"]?.stringValue, "onboarding_check")
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

    // MARK: - 単元を作る(#132)

    func testDeadlineFromTheChoiceAndTheNextHolidayEnd() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d))! }
        let today = day(2026, 11, 11)
        XCTAssertEqual(StudyDeadline.date(for: "1週間以内", from: today, calendar: calendar), day(2026, 11, 18))
        XCTAssertEqual(StudyDeadline.date(for: "2週間くらい", from: today, calendar: calendar), day(2026, 11, 25))
        XCTAssertEqual(StudyDeadline.date(for: "1か月くらい", from: today, calendar: calendar), day(2026, 12, 11))
        XCTAssertNil(StudyDeadline.date(for: "まだ先・決まっていない", from: today, calendar: calendar))
        // 休みの終わり: 今日より後で一番近いもの(冬 1/7・春 4/5・夏 8/31)。
        XCTAssertEqual(StudyDeadline.date(for: OnboardingCatalog.untilHoliday, from: today, calendar: calendar), day(2027, 1, 7))
        XCTAssertEqual(StudyDeadline.holidayEnd(after: day(2027, 7, 20), calendar: calendar), day(2027, 8, 31))
        XCTAssertEqual(StudyDeadline.holidayEnd(after: day(2027, 3, 20), calendar: calendar), day(2027, 4, 5))
        XCTAssertEqual(StudyDeadline.holidayEnd(after: day(2027, 8, 31), calendar: calendar), day(2028, 1, 7), "終わりの当日は次の休み")
        XCTAssertEqual(StudyDeadline.label(day(2027, 8, 31), calendar: calendar), "8月31日まで")
        XCTAssertEqual(StudyDeadline.isoDay(day(2027, 1, 7), calendar: calendar), "2027-01-07")
        XCTAssertTrue(OnboardingCatalog.untilTest.contains(OnboardingCatalog.untilHoliday))
    }

    func testUnitCreationStartsFromTheChoicesAndLeavesTheOnboardingAnswersAlone() {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: OnboardingProfile.profileKey)
        defer { if let saved { defaults.set(saved, forKey: OnboardingProfile.profileKey) } else { defaults.removeObject(forKey: OnboardingProfile.profileKey) } }
        var onboarding = profile(grade: "高1", trial: 1)
        onboarding.route = .weak
        onboarding.unit = "数と式"
        onboarding.save()

        let model = OnboardingModel(records: records(), hasPlan: { true }, isClaudeAvailable: { true }, purpose: .unitCreation)
        XCTAssertEqual(model.step, .intent, "中高生は「ここから何をしますか」から")
        XCTAssertNil(model.selectedUnit, "前の単元の選び方は引き継がない")
        XCTAssertEqual(model.profile.trial.count, 1, "お試しの結果は使う")
        model.existingUnits = ["二次関数"]
        model.choose(route: .range)
        XCTAssertEqual(model.step, .unit)
        model.chooseUnitGrade("中3")
        XCTAssertEqual(model.unitListGrade, "中3")
        model.chooseUnitGrade("高1")
        XCTAssertNil(model.unitGrade, "今の学年に戻したら nil")
        model.selectedUnit = "二次不等式"
        model.selectUntilTest(OnboardingCatalog.untilHoliday)
        XCTAssertNotNil(model.deadline)
        model.commitUnitWithDeadline()
        XCTAssertEqual(model.step, .planWait)

        let request = model.planRequest()
        XCTAssertEqual(request["unit"]?.stringValue, "二次不等式")
        XCTAssertEqual(request["grade"]?.stringValue, "高1")
        XCTAssertEqual(request["until_test"]?.stringValue, OnboardingCatalog.untilHoliday)
        XCTAssertEqual(request["deadline"]?.stringValue, StudyDeadline.isoDay(model.deadline!))
        XCTAssertEqual(request["existing_units"]?.arrayValue?.compactMap(\.stringValue), ["二次関数"])
        XCTAssertEqual(model.planChips, [], "期限は日付のボタンで出す")

        let after = OnboardingProfile.load()
        XCTAssertEqual(after?.route, .weak, "オンボーディングの回答を書き換えない")
        XCTAssertEqual(after?.unit, "数と式")
        XCTAssertNil(after?.resumeStep, "続きの画面を書き換えない")
    }

    func testUniversityUnitCreationStartsFromTheCameraAndWithoutMaterialAsksForAUniversityPlan() {
        var university = profile(grade: OnboardingProfile.universityGrade)
        university.route = .university
        university.universityTopic = "前の授業"
        let model = OnboardingModel(profile: university, records: records(), hasPlan: { true }, isClaudeAvailable: { true }, purpose: .unitCreation)
        XCTAssertEqual(model.step, .capture, "大学生は撮るのが先")
        XCTAssertEqual(model.universityTopic, "", "前に書いた勉強することは引き継がない")
        model.skipMaterials()
        XCTAssertEqual(model.step, .universityChoices)
        model.universityTopic = "線形代数"
        model.universityPurpose = "次の学期の予習"
        model.selectUntilTest(OnboardingCatalog.untilHoliday)
        model.commitUniversityChoices()
        XCTAssertEqual(model.step, .planWait)
        let request = model.planRequest()
        XCTAssertEqual(request["route"]?.stringValue, "university", "大学生の計画として頼む")
        XCTAssertEqual(request["topic"]?.stringValue, "線形代数")
        XCTAssertEqual(request["goal"]?.stringValue, "次の学期の予習")
        XCTAssertNotNil(request["deadline"]?.stringValue)
        XCTAssertNil(request["material"], "資料が無ければ読み取った範囲も無い")
    }

    func testReadingASyllabusLetsTheLearnerChooseHowFarTheLecturesWent() throws {
        let mock = MockTurnRunner.materialReading(["grade": OnboardingProfile.universityGrade])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: mock), as: UTF8.self)
        let reading = try XCTUnwrap(OnboardingTurns.parseReading("```json\n\(text)\n```"))
        XCTAssertTrue(reading.isCourse)
        XCTAssertEqual(reading.lectures.count, 15)
        XCTAssertEqual(reading.testDate, "2027-01-26")
        XCTAssertNil(OnboardingTurns.parseReading("読めませんでした"))

        let model = OnboardingModel(profile: profile(grade: OnboardingProfile.universityGrade), records: records(), hasPlan: { true },
                                    isClaudeAvailable: { true }, purpose: .unitCreation)
        let request = model.readingRequest()
        XCTAssertEqual(request["task"]?.stringValue, "read_material")
        XCTAssertEqual(request["units"]?.arrayValue?.count, 0, "大学生には中高の単元を渡さない")
        XCTAssertEqual(OnboardingModel(profile: profile(grade: "高1"), records: records(), hasPlan: { true }, isClaudeAvailable: { true },
                                       purpose: .unitCreation).readingRequest()["units"]?.arrayValue?.compactMap(\.stringValue).contains("二次関数"), true)
        // 学年が分からない時も、中高の学年として頼む(大学生として読ませない)。
        XCTAssertEqual(OnboardingModel(profile: profile(grade: nil), records: records(), hasPlan: { true }, isClaudeAvailable: { true },
                                       purpose: .unitCreation).readingRequest()["grade"]?.stringValue, "中3")
    }

    func testReadingIsNewWorkForTheUsageGate() async throws {
        // 採点の続きとして猶予を使わない(読み取りは新しい作業)。
        let plan = try await OnboardingTurns.readingPlan(assets: AssetCache(), planID: "p", request: .object(["task": .string("read_material")]), imagePaths: [])
        XCTAssertFalse(UsageRequest.of(kind: plan.kind, turnAdmitted: false).finishing)
    }

    func testRetakingAndRebuildingDropTheReading() {
        let model = OnboardingModel(profile: profile(grade: "高1"), records: records(), hasPlan: { true }, isClaudeAvailable: { true }, purpose: .unitCreation)
        model.choose(route: .range)
        model.chooseUnitGrade("高2")
        model.startCapture()
        model.go(.reading)
        model.retake()
        XCTAssertEqual(model.step, .capture)
        model.back()
        XCTAssertEqual(model.step, .unit, "撮り直した後の戻るで、捨てた読み取りの画面に戻らない")
        XCTAssertEqual(model.unitListGrade, "高2")

        // 大学生がシラバスの計画を「やりたいことと違う」で捨てた時は、その試験日を次の計画に持ち込まない。
        let university = OnboardingModel(profile: profile(grade: OnboardingProfile.universityGrade), records: records(), hasPlan: { true },
                                         isClaudeAvailable: { true }, purpose: .unitCreation)
        university.deadline = StudyDeadline.day(from: "2027-01-26")
        university.rebuildPlan(tooHard: false)
        XCTAssertEqual(university.step, .capture, "大学生は撮る画面に戻る")
        XCTAssertNil(university.deadline)
        XCTAssertNil(university.reading)

        // シラバスの授業名も、捨てた計画と一緒に捨てる(選び直す画面に見えないまま残さない)。
        let syllabus = OnboardingTurns.parseReading(String(decoding: try! JSONSerialization.data(
            withJSONObject: MockTurnRunner.materialReading(["grade": OnboardingProfile.universityGrade])), as: UTF8.self))
        university.reading = syllabus
        university.confirmReading()
        XCTAssertEqual(university.universityTopic, "線形代数Ⅱ")
        university.rebuildPlan(tooHard: false)
        XCTAssertEqual(university.universityTopic, "")
        XCTAssertNil(university.profile.universityTopic)

        // 「資料なしで作る」で「いつまでに」を選び、戻ってもう一度「資料なしで作る」にしても、選んだ期限を送る。
        university.skipMaterials()
        university.selectUntilTest("1週間以内")
        university.back()
        XCTAssertEqual(university.step, .capture)
        university.skipMaterials()
        XCTAssertEqual(university.profile.untilTest, "1週間以内")
        XCTAssertNotNil(university.deadline)
        // 読み取った試験日だけがある時は、それを持ち込まない。
        university.back()
        university.profile.untilTest = nil
        university.deadline = StudyDeadline.day(from: "2027-01-26")
        university.skipMaterials()
        XCTAssertNil(university.deadline)
    }

    func testReadingARangeSheetMakesARangePlanWithItsPagesAndTestDate() throws {
        let mock = MockTurnRunner.materialReading(["grade": "高1"])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: mock), as: UTF8.self)
        let reading = try XCTUnwrap(OnboardingTurns.parseReading(text))
        XCTAssertFalse(reading.isCourse)
        XCTAssertEqual(reading.pages, "p.62〜p.96")
        XCTAssertEqual(reading.workbookPages, "ニューアクションα p.40〜p.52")

        // 試験日の無い資料(教科書の目次など)を撮った時は、本人が選んだ「いつまでに」を残す。
        let model = OnboardingModel(profile: profile(grade: "高1"), records: records(), hasPlan: { true }, isClaudeAvailable: { true }, purpose: .unitCreation)
        model.choose(route: .range)
        model.selectUntilTest("1週間以内")
        let chosen = try XCTUnwrap(model.deadline)
        var withoutDate = reading
        withoutDate.testDate = ""
        model.reading = withoutDate
        model.confirmReading()
        XCTAssertEqual(model.deadline, chosen)
        XCTAssertEqual(model.planRequest()["until_test"]?.stringValue, "1週間以内")
        // 試験日が読み取れた時は、それを期限にする。
        model.reading = reading
        model.confirmReading()
        XCTAssertEqual(model.deadline, StudyDeadline.day(from: "2026-12-03"))
        XCTAssertNil(model.profile.untilTest)
    }

    func testAnotherGradesUnitIsOnlyForTheRangeRoute() {
        let model = OnboardingModel(profile: profile(grade: "高1"), records: records(), hasPlan: { true }, isClaudeAvailable: { true }, purpose: .unitCreation)
        model.choose(route: .range)
        model.chooseUnitGrade("中3")
        model.selectUntilTest("1週間以内")
        XCTAssertEqual(model.planRequest()["grade"]?.stringValue, "中3")
        // 「作り直す」→「やりたいことと違う」で別の選び方にした時は、今の学年で頼む。
        model.choose(route: .unsure)
        XCTAssertEqual(model.planRequest()["grade"]?.stringValue, "高1")
        XCTAssertNil(model.unitGrade)
        XCTAssertNil(model.deadline, "前の期限を持ち込まない")
    }

    func testTheDeadlineSurvivesClosingTheAppDuringOnboarding() {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: OnboardingProfile.profileKey)
        defer { if let saved { defaults.set(saved, forKey: OnboardingProfile.profileKey) } else { defaults.removeObject(forKey: OnboardingProfile.profileKey) } }
        OnboardingProfile().save()
        let first = OnboardingModel(records: records(), hasPlan: { true }, isClaudeAvailable: { true }, start: .intent)
        first.choose(route: .range)
        first.selectUntilTest(OnboardingCatalog.untilHoliday)
        let edited = Calendar.current.date(byAdding: .day, value: 3, to: first.deadline!)!
        first.deadline = edited
        // 閉じて開き直した(計画の画面に戻る)。
        let reopened = OnboardingModel(records: records(), hasPlan: { true }, isClaudeAvailable: { true }, start: .plan)
        XCTAssertEqual(reopened.deadline.map { StudyDeadline.isoDay($0) }, StudyDeadline.isoDay(edited), "直した期限が残っている")
        XCTAssertEqual(reopened.planRequest()["deadline"]?.stringValue, StudyDeadline.isoDay(edited))
        // 単元を作る時は、オンボーディングの期限を使わない。
        let creation = OnboardingModel(records: records(), hasPlan: { true }, isClaudeAvailable: { true }, purpose: .unitCreation)
        XCTAssertNil(creation.deadline)
    }
}
