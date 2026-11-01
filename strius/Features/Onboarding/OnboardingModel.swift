import Foundation
import OSLog
import PDFKit
import UIKit

private let onboardingLog = Logger(subsystem: "com.digiloglab.strius", category: "onboarding")

/// オンボーディングの画面(#40)。学年 → 年齢 → 規約 → 写真の扱い → お試しの1問 → 採点 → 購入 → 何をするか → 計画 → 通知。
nonisolated enum OnboardingStep: String, CaseIterable, Codable, Sendable {
    /// App Attest が使えない(Mac・想定外の失敗)。
    case unsupported
    case grade
    case birthdate
    case terms
    case consent
    case trial
    case grading
    case result
    case trialDone
    case paywall
    case intent
    /// A: 単元・次のテストまで・問題のページ。
    case unit
    case untilTest
    case pages
    /// B: やり直す単元。
    case weak
    /// U: 何を勉強するか・授業の資料・やりたいこと。
    case topic
    case material
    case goal
    case planWait
    case plan
    case notify

    /// 左上の戻るを出すか(デザインのとおり)。
    var showsBack: Bool {
        switch self {
        case .birthdate, .terms, .consent, .trial, .unit, .untilTest, .pages, .weak, .topic, .material, .goal: true
        default: false
        }
    }
}

/// 途中で閉じた時に、次に開いて続ける画面(#40 の 15)。年齢の結果・規約の同意・お試しの数は端末の記録に残る。
nonisolated enum OnboardingResume {
    static func step(profile: OnboardingProfile, age: AgeResult?, termsAccepted: Bool, trialUsed: Int, hasPlan: Bool, hasDraft: Bool, now: Date = Date()) -> OnboardingStep {
        guard profile.grade != nil else { return .grade }
        guard let age, !age.needsRecheck(now: now) else { return .grade }
        _ = age
        guard termsAccepted else { return .terms }
        guard profile.photoConsentAt != nil else { return .consent }
        let saved = profile.resumeStep.flatMap(OnboardingStep.init(rawValue:))
        switch saved {
        case .notify:
            return .notify
        case .plan where hasDraft:
            return .plan
        case .paywall:
            return hasPlan ? afterPurchase(profile) : .paywall
        case .intent, .unit, .untilTest, .pages, .weak, .topic, .material, .goal, .planWait, .plan:
            return hasPlan ? afterPurchase(profile) : (profile.trial.isEmpty && !profile.isUniversity ? .trial : .intent)
        default:
            break
        }
        if profile.isUniversity { return hasPlan ? .topic : .paywall }
        // 採点の後・計画の前なら「ここから何をしますか」から(購入していなければ、計画を作る前に購入画面を挟む)。
        if !profile.trial.isEmpty { return trialUsed >= OnboardingRecords.trialLimit && !hasPlan ? .trialDone : .intent }
        if trialUsed >= OnboardingRecords.trialLimit { return hasPlan ? .intent : .trialDone }
        return .trial
    }

    static func afterPurchase(_ profile: OnboardingProfile) -> OnboardingStep {
        profile.isUniversity ? .topic : .intent
    }
}

/// オンボーディングで添えた資料(撮ったページ・写真・PDF のページ)。`StruisPaths.captures` の下に JPEG で置く。
nonisolated struct OnboardingMaterial: Hashable, Sendable, Identifiable {
    var id: String
    /// `StruisPaths.captures` からの相対パス。
    var path: String
    var name: String
}

@Observable
@MainActor
final class OnboardingModel {
    private(set) var step: OnboardingStep
    private var history: [OnboardingStep] = []
    var profile: OnboardingProfile
    let records: OnboardingRecords
    let isClaudeAvailable: () -> Bool
    /// 購入しているか(StoreKit の今の契約)。
    let hasPlan: () -> Bool
    /// 計画を作ろうとした時に購入画面を挟んだ(買えたら計画づくりに戻る)。
    private var plansAfterPurchase = false

    // 学年
    var selectedGrade: String?
    var isCheckingAge = false
    // 生年月日(判定にだけ使い、判定が終わったらすぐに消す。保存しない)。
    var birthdate: Date = OnboardingModel.defaultBirthdate

    // お試し
    private(set) var problem: TrialProblem?
    private(set) var answerImagePath: String?
    private(set) var answerFromInk = false
    private(set) var verdict: TrialVerdict?
    var trialError: String?
    private(set) var gradingStartedAt: Date?

    // ルート
    var selectedUnit: String?
    var universityTopic = ""
    var universityGoal = ""
    private(set) var materials: [OnboardingMaterial] = []
    var materialError: String?
    var isImportingMaterial = false

    // 計画
    private(set) var draft: OnboardingPlanDraft?
    var planError: String?
    private(set) var planStartedAt: Date?
    private(set) var isStarting = false
    private var planTask: Task<Void, Never>?

    // 通知
    var reminderHour = 20

    static let draftKey = "onboarding.planDraft.v1"
    static var defaultBirthdate: Date {
        Calendar.current.date(from: DateComponents(year: Calendar.current.component(.year, from: Date()) - 15, month: 4, day: 15)) ?? Date()
    }

    init(profile: OnboardingProfile? = nil, records: OnboardingRecords = .shared, hasPlan: @escaping () -> Bool, isClaudeAvailable: @escaping () -> Bool, start: OnboardingStep? = nil) {
        var profile = profile ?? OnboardingProfile.load() ?? OnboardingProfile()
        self.records = records
        self.isClaudeAvailable = isClaudeAvailable
        self.hasPlan = hasPlan
        // 端末の記録(年齢・規約)は、サインアウトで消えた回答にも戻す。
        if let age = records.age, profile.ageBand == nil {
            profile.ageBand = age.band
            profile.ageDeclaration = age.declaration
            profile.ageCheckedAt = ISO8601DateFormatter().string(from: age.checkedAt)
        }
        if let terms = records.termsAcceptedAt, profile.termsAcceptedAt == nil { profile.termsAcceptedAt = ISO8601DateFormatter().string(from: terms) }
        self.profile = profile
        selectedGrade = profile.grade
        selectedUnit = profile.unit
        universityTopic = profile.universityTopic ?? ""
        universityGoal = profile.universityGoal ?? ""
        let saved = UserDefaults.standard.data(forKey: Self.draftKey).flatMap { try? JSONDecoder().decode(OnboardingPlanDraft.self, from: $0) }
        draft = saved
        let resumed = start ?? OnboardingResume.step(
            profile: profile, age: records.age, termsAccepted: records.termsAcceptedAt != nil, trialUsed: records.trialUsed,
            hasPlan: hasPlan(), hasDraft: saved != nil
        )
        step = isClaudeAvailable() ? resumed : .unsupported
        if step == .trial || step == .grading || step == .result { problem = nextProblem(after: nil) }
    }

    // MARK: - 移り方

    func go(_ next: OnboardingStep, remember: Bool = true) {
        if remember, step != next { history.append(step) }
        step = next
        if ![.unsupported, .grading, .birthdate].contains(next) {
            profile.resumeStep = next.rawValue
            profile.save()
        }
    }

    var canGoBack: Bool { step.showsBack && !history.isEmpty }

    func back() {
        guard let previous = history.popLast() else { return }
        step = previous
    }

    /// 「もう一度確かめる」(Claude を使えない端末の画面)。
    func recheckAvailability() {
        guard isClaudeAvailable() else { return }
        step = OnboardingResume.step(profile: profile, age: records.age, termsAccepted: records.termsAcceptedAt != nil,
                                     trialUsed: records.trialUsed, hasPlan: hasPlan(), hasDraft: draft != nil)
        if step == .trial { problem = nextProblem(after: nil) }
    }

    // MARK: - 学年・年齢

    func chooseGrade(_ grade: String) {
        selectedGrade = grade
    }

    /// 学年の「次へ」の後: 年齢の結果が残っていて 1 年以内なら、聞き直さない。
    var needsAgeCheck: Bool {
        guard let age = records.age else { return true }
        return age.needsRecheck()
    }

    func commitGrade() {
        guard let grade = selectedGrade else { return }
        if profile.grade != grade {
            profile.grade = grade
            if grade == OnboardingProfile.universityGrade { profile.route = .university }
            else if profile.route == .university { profile.route = nil }
        }
        profile.save()
    }

    /// Declared Age Range の結果。共有されなかった・取れなかった時は生年月日を聞く。
    func applyAgeRange(band: AgeBand?, declaration: String?) {
        guard let band else {
            go(.birthdate)
            return
        }
        saveAge(AgeResult(band: band, declaration: declaration ?? "unknown", checkedAt: Date()))
        afterAge()
    }

    /// 生年月日の「次へ」: 端末の中で判定し、生年月日はすぐに消す(既定の日付に戻す)。
    func commitBirthdate() {
        let band = AgeBand.from(birthdate: birthdate)
        birthdate = Self.defaultBirthdate
        saveAge(AgeResult(band: band, declaration: "birthdate", checkedAt: Date()))
        afterAge()
    }

    private func saveAge(_ result: AgeResult) {
        records.saveAge(result)
        profile.ageBand = result.band
        profile.ageDeclaration = result.declaration
        profile.ageCheckedAt = ISO8601DateFormatter().string(from: result.checkedAt)
        profile.save()
    }

    func afterAge() {
        if records.termsAcceptedAt == nil { go(.terms) } else { afterTerms() }
    }

    var isMinor: Bool { (profile.ageBand ?? records.age?.band)?.isMinor ?? false }

    // MARK: - 規約・写真の扱い

    func acceptTerms() {
        let now = Date()
        records.acceptTerms(at: now)
        profile.termsAcceptedAt = ISO8601DateFormatter().string(from: now)
        profile.save()
        afterTerms()
    }

    private func afterTerms() {
        if profile.photoConsentAt == nil { go(.consent) } else { afterConsent() }
    }

    func acceptPhotoConsent() {
        profile.photoConsentAt = ISO8601DateFormatter().string(from: Date())
        profile.save()
        afterConsent()
    }

    /// 同意の後: お試しへ(大学生・それ以外は見本が無いので、お試しを飛ばして購入画面へ)。
    func afterConsent() {
        if profile.isUniversity {
            go(hasPlan() ? .topic : .paywall)
        } else if records.trialRemaining == 0 {
            go(hasPlan() ? .intent : .trialDone)
        } else {
            startTrial()
        }
    }

    // MARK: - お試し

    var trialNumber: Int { min(OnboardingRecords.trialLimit, records.trialUsed + 1) }
    var trialRemaining: Int { records.trialRemaining }

    private func nextProblem(after current: TrialProblem?) -> TrialProblem? {
        let grade = profile.grade ?? "中3"
        return TrialProblem.next(after: current, grade: grade, solved: Set(profile.trial.map(\.problemID)))
    }

    func startTrial() {
        problem = nextProblem(after: problem)
        verdict = nil
        trialError = nil
        answerImagePath = nil
        go(.trial)
    }

    /// 「別の問題にする」: 同じ学年の別の見本に替える。
    func swapProblem() {
        problem = nextProblem(after: problem)
        trialError = nil
    }

    /// 撮った答案(紙の写真)か、書いた答案(iPad の手書き)を採点に送る。
    func submitAnswer(_ data: Data, fromInk: Bool, assets: AssetCache, turns: TurnCoordinator, runner: any TurnRunning) {
        guard let problem, records.trialRemaining > 0 else { return }
        trialError = nil
        let path: String
        do {
            path = try Self.store(data, folder: "onboarding/trial")
        } catch {
            trialError = "答案を保存できませんでした。端末の空き容量を確かめて、もう一度送ってください。"
            return
        }
        answerImagePath = path
        answerFromInk = fromInk
        gradingStartedAt = Date()
        go(.grading)
        Task {
            do {
                let plan = try await OnboardingTurns.gradingPlan(assets: assets, planID: LedgerID.make(), problem: problem, imagePath: path)
                let text = try await OnboardingTurns.run(plan, turns: turns, runner: runner, limit: OnboardingTurns.gradingTimeLimit)
                guard let verdict = OnboardingTurns.parseVerdict(text) else { throw OnboardingTurns.Failure.malformed }
                finishGrading(verdict, problem: problem)
            } catch {
                onboardingLog.error("trial grading failed: \(String(describing: error), privacy: .public)")
                failGrading((error as? LocalizedError)?.errorDescription ?? "採点できませんでした。もう一度送ってください。")
            }
        }
    }

    private func finishGrading(_ verdict: TrialVerdict, problem: TrialProblem) {
        guard step == .grading else { return }
        guard verdict.readable else {
            // 答案が読めなかった: お試しの数には数えず、撮り直してもらう。
            failGrading("答案を読み取れませんでした。答案全体が入るように、明るい所で撮り直してください。")
            return
        }
        self.verdict = verdict
        records.recordTrialSolved()
        profile.trial.append(TrialRecord(problemID: problem.id, label: problem.label, correct: verdict.isCorrect, learnerAnswer: verdict.learnerAnswer, comment: verdict.comment))
        profile.save()
        go(.result, remember: false)
    }

    private func failGrading(_ message: String) {
        guard step == .grading else { return }
        trialError = message
        step = .trial
    }

    /// 「もう1問やる」。
    func anotherProblem() {
        guard records.trialRemaining > 0 else { return }
        startTrial()
    }

    /// 「自分の範囲で続ける」: 購入していなければ購入画面へ(計画づくりは上位モデルを使うので購入の後)。
    func continueToRange() {
        go(hasPlan() ? OnboardingResume.afterPurchase(profile) : .paywall)
    }

    /// 買えた(か、もう契約がある)。計画づくりの前に挟んだ購入画面なら、計画づくりに戻る。
    func afterPurchase() {
        // 購入の完了と、契約が届いた通知の両方から呼ばれる(2 回目は何もしない)。
        guard step == .paywall else { return }
        if plansAfterPurchase {
            plansAfterPurchase = false
            go(.planWait, remember: false)
        } else {
            go(OnboardingResume.afterPurchase(profile), remember: false)
        }
    }

    // MARK: - 何をするか

    func choose(route: OnboardingProfile.Route) {
        profile.route = route
        profile.save()
        switch route {
        case .range: go(.unit)
        case .weak: go(.weak)
        case .unsure: startPlanning()
        case .university: go(.topic)
        }
    }

    func commitUnit() {
        guard let selectedUnit else { return }
        profile.unit = selectedUnit
        profile.save()
        go(.untilTest)
    }

    func chooseUntilTest(_ value: String) {
        profile.untilTest = value
        profile.save()
        go(.pages)
    }

    func commitWeakUnit() {
        guard let selectedUnit else { return }
        profile.unit = selectedUnit
        profile.save()
        startPlanning()
    }

    func commitTopic() {
        profile.universityTopic = universityTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.save()
        go(.material)
    }

    func commitGoal() {
        profile.universityGoal = universityGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.save()
        startPlanning()
    }

    // MARK: - 資料

    func addMaterialPhotos(_ photos: [Data], name: String = "撮ったページ") {
        for data in photos {
            guard materials.count < 8, let path = try? Self.store(data, folder: "onboarding/materials") else { continue }
            materials.append(OnboardingMaterial(id: UUID().uuidString, path: path, name: "\(name) \(materials.count + 1)"))
        }
    }

    /// 写真・PDF から選んだもの(PDF は先頭のページを画像にする。合わせて 8 枚まで)。
    func addMaterial(_ outcomes: [AttachmentIntake.Outcome]) {
        var lines: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .accepted(let attachment, let notice):
                if let notice { lines.append(notice) }
                for image in Self.pageImages(of: attachment) where materials.count < 8 {
                    if let path = try? Self.store(image, folder: "onboarding/materials") {
                        materials.append(OnboardingMaterial(id: UUID().uuidString, path: path, name: attachment.filename))
                    }
                }
            case .rejected(let rejection):
                lines.append(rejection.line)
            case .needsPassword(let locked):
                AttachmentIntake.discard(locked)
                lines.append("\(locked.filename): パスワード付きの PDF は、あとで質問の画面から添えてください")
            }
        }
        materialError = lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func clearMaterials() {
        materials.removeAll()
        materialError = nil
    }

    /// 資料の名前(「解析学I_第5回.pdf ほか2件」)。
    var materialSummary: String? {
        let names = materials.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard let first = names.first else { return nil }
        return names.count > 1 ? "\(first) ほか\(names.count - 1)件" : first
    }

    nonisolated static func pageImages(of attachment: ComposerAttachment) -> [Data] {
        if attachment.contentType == "application/pdf" || attachment.fileURL.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: attachment.fileURL) else { return [] }
            return (0..<min(document.pageCount, 8)).compactMap { index in
                guard let page = document.page(at: index) else { return nil }
                let bounds = page.bounds(for: .mediaBox)
                let scale = min(2, 1600 / max(bounds.width, bounds.height, 1))
                return page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox).jpegData(compressionQuality: 0.8)
            }
        }
        return (try? Data(contentsOf: attachment.fileURL)).map { [$0] } ?? []
    }

    // MARK: - 計画

    /// 計画を作る前に購入を確かめる(途中から再開した時も、購入していなければ購入画面を挟む)。
    func startPlanning() {
        // 選び直した時は、前の計画の下書きを使わない。
        draft = nil
        UserDefaults.standard.removeObject(forKey: Self.draftKey)
        if hasPlan() {
            go(.planWait)
        } else {
            plansAfterPurchase = true
            go(.paywall)
        }
    }

    var planChips: [String] {
        var chips: [String] = []
        if profile.route == .range {
            if let until = profile.untilTest { chips.append(until.hasPrefix("まだ") ? "テストはまだ先" : "テストまで \(until)") }
            if !materials.isEmpty { chips.append("問題のページ \(materials.count)枚") }
        }
        if profile.route == .university, !materials.isEmpty { chips.append("資料 \(materials.count)件") }
        return chips
    }

    /// 計画の画面の最後の 1 文(アプリが決める。撮ったページの使い道を言い過ぎない)。
    var planFooter: String {
        var parts: [String] = []
        if !materials.isEmpty { parts.append("撮ったページ(\(materials.count)枚)をもとに小単元を分けました。") }
        switch profile.route {
        case .weak: parts.append("1 ができていれば、すぐ 2 に進みます。")
        case .unsure: parts.append("解けない問題が続いた時は、前の学年の内容に戻って確かめます。")
        case .university: parts.append("1 は要点と例題から始まります。証明や計算は紙に書いて撮ります。")
        default: parts.append("1 は要点と例題から始まります。")
        }
        return parts.joined()
    }

    /// 計画の画面の、お試しの反映(モデルが書き落とした時だけアプリが添える)。
    var trialFallbackNote: String? {
        guard let draft, !draft.mentionsTrial, let last = profile.trial.last else { return nil }
        return last.correct ? "お試しの1問でできていた所は、短めにしています。" : "お試しの1問でつまずいた所は、ていねいに進めます。"
    }

    func planRequest() -> LedgerJSON {
        var request: [String: LedgerJSON] = ["task": .string("onboarding_plan"), "route": .string((profile.route ?? .unsure).rawValue)]
        if let grade = profile.grade, grade != OnboardingProfile.universityGrade { request["grade"] = .string(grade) }
        if let unit = profile.unit, profile.route == .range || profile.route == .weak { request["unit"] = .string(unit) }
        if profile.route == .range, let until = profile.untilTest { request["until_test"] = .string(until) }
        if profile.route == .university {
            request["topic"] = .string(profile.universityTopic ?? "")
            request["goal"] = .string(profile.universityGoal ?? "")
        }
        request["trial"] = .array(profile.trial.map { record in
            .object(["problem": .string(record.label), "correct": .bool(record.correct), "learner_answer": .string(record.learnerAnswer), "comment": .string(record.comment)])
        })
        request["material_count"] = .number(Double(materials.count))
        return .object(request)
    }

    /// 計画づくり(上位モデル)。計画を待つ画面から呼ぶ。
    func makePlan(assets: AssetCache, turns: TurnCoordinator, runner: any TurnRunning) {
        guard planTask == nil else { return }
        planError = nil
        planStartedAt = Date()
        let request = planRequest()
        let images = materials.map(\.path)
        planTask = Task {
            defer { planTask = nil }
            do {
                let plan = try await OnboardingTurns.planPlan(assets: assets, planID: LedgerID.make(), request: request, imagePaths: images)
                let text = try await OnboardingTurns.run(plan, turns: turns, runner: runner, limit: OnboardingTurns.planTimeLimit)
                guard let draft = OnboardingTurns.parsePlan(text) else { throw OnboardingTurns.Failure.malformed }
                self.draft = draft
                if let data = try? JSONEncoder().encode(draft) { UserDefaults.standard.set(data, forKey: Self.draftKey) }
                if step == .planWait { go(.plan, remember: false) }
            } catch {
                onboardingLog.error("plan failed: \(String(describing: error), privacy: .public)")
                planError = (error as? LocalizedError)?.errorDescription ?? "計画を作れませんでした。もう一度試してください。"
            }
        }
    }

    /// 「はじめる」: 計画を単元にして、タイムラインの 1 枚目(小単元 1 から 30 秒で解ける問題)を入れる。
    func startPlan(ledger: Ledger) async -> Bool {
        guard let draft, !isStarting else { return false }
        isStarting = true
        defer { isStarting = false }
        let specs = draft.subunits.map { WorkbookMachine.SubunitSpec(title: $0.title, outcome: $0.outcome, n: $0.n, scoringUnit: $0.scoringUnit) }
        let overview: LedgerJSON = .object([
            "unit_title": .string(draft.unitTitle), "outcome": .string(draft.outcome), "source": .string("onboarding"),
            "subunits": .array(draft.subunits.map { .object(["title": .string($0.title), "outcome": .string($0.outcome), "n": .number(Double($0.n)), "scoring_unit": .string($0.scoringUnit), "note": .string($0.note)]) }),
        ])
        do {
            let (unitID, subunitID) = try await ledger.commit { db in
                var workbook = try WorkbookMachine(loading: db)
                let unitID = workbook.createUnit(title: draft.unitTitle, outcome: draft.outcome, source: "consult", subunits: specs, overview: overview)
                return (workbook.events, (unitID, workbook.orderedSubunits(unitID: unitID).first?.id))
            }
            if let first = draft.firstProblem, let subunitID {
                try await ledger.commit { db in
                    var timeline = try TimelineMachine(loading: db)
                    timeline.addStarterCard(prompt: first.prompt, math: first.math, answerKey: first.answerKey, unitID: unitID, subunitID: subunitID)
                    return (timeline.events, ())
                }
            }
        } catch {
            onboardingLog.error("start plan failed: \(String(describing: error), privacy: .public)")
            planError = "計画を保存できませんでした。もう一度押してください。"
            return false
        }
        UserDefaults.standard.removeObject(forKey: Self.draftKey)
        go(.notify, remember: false)
        return true
    }

    /// 通知の例(「今日は「平方根の考えで解く」です。」)。
    var reminderExample: String {
        let title = draft?.subunits.first?.title ?? profile.unit ?? "今日の小単元"
        return "今日は「\(title)」です。"
    }

    // MARK: - 保存

    /// 答案・資料を `StruisPaths.captures` の下に置き、相対パスを返す。
    nonisolated static func store(_ data: Data, folder: String) throws -> String {
        let directory = StruisPaths.captures.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString.lowercased()).jpg"
        let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
        try jpeg.write(to: directory.appendingPathComponent(name), options: .atomic)
        return "\(folder)/\(name)"
    }

    /// 終わった時: 計画の下書きと、途中の画面の印を消す。
    func finish() {
        profile.resumeStep = nil
        profile.save()
        UserDefaults.standard.removeObject(forKey: Self.draftKey)
    }

    #if DEBUG
    /// 画面の確認用(`STRUIS_ONBOARDING_START`): 途中の画面に要る中身を入れる。
    func prepareForPreview(_ start: OnboardingStep) {
        let environment = ProcessInfo.processInfo.environment
        if profile.grade == nil {
            let grade = environment["STRUIS_ONBOARDING_GRADE"] ?? "中3"
            profile.grade = grade
            selectedGrade = grade
            if grade == OnboardingProfile.universityGrade { profile.route = .university }
        }
        if let band = environment["STRUIS_AGE_RANGE"].flatMap(AgeBand.init(rawValue:)) { profile.ageBand = band }
        if [.grading, .result].contains(start), environment["STRUIS_ONBOARDING_INK"] == nil, let data = Self.sampleAnswerImage() {
            answerImagePath = try? Self.store(data, folder: "onboarding/trial")
        }
        if [.planWait, .plan].contains(start), environment["STRUIS_ONBOARDING_PAGES"] == "1", materials.isEmpty, let data = Self.sampleAnswerImage() {
            addMaterialPhotos([data, data, data, data])
        }
        if profile.route == .university {
            if universityTopic.isEmpty { universityTopic = "解析学I"; profile.universityTopic = "解析学I" }
        }
        if problem == nil { problem = TrialProblem.problems(grade: profile.grade ?? "中3").first(where: { $0.unit == "二次方程式" }) ?? TrialProblem.problems(grade: profile.grade ?? "中3").first }
        if [.result, .trialDone, .intent, .unit, .untilTest, .pages, .weak, .planWait, .plan, .notify].contains(start), profile.trial.isEmpty, let problem {
            let wrong = ProcessInfo.processInfo.environment["STRUIS_MOCK_TIMELINE_WRONG"] == "1"
            let verdictJSON = MockTurnRunner.onboardingGrading(["answer": problem.answer, "problem_id": problem.id])
            let verdict = TrialVerdict(readable: true, grade: wrong ? "wrong" : "correct", learnerAnswer: verdictJSON["learner_answer"] as? String ?? problem.answer,
                                       comment: verdictJSON["comment"] as? String ?? "", solution: verdictJSON["solution"] as? String ?? "")
            self.verdict = verdict
            let count = start == .trialDone ? 3 : 1
            for index in 0..<count {
                profile.trial.append(TrialRecord(problemID: problem.id, label: problem.label, correct: index == 1 ? false : !wrong, learnerAnswer: verdict.learnerAnswer, comment: verdict.comment))
            }
        }
        if let route = environment["STRUIS_ONBOARDING_ROUTE"].flatMap(OnboardingProfile.Route.init(rawValue:)), profile.route == nil || route == .university {
            profile.route = route
            if route == .weak { profile.unit = "関数 y = ax²"; selectedUnit = profile.unit }
            if route == .university { universityGoal = "来週の小テストまでに、連続性の ε-δ 論法で証明が書けるようになりたい"; profile.universityGoal = universityGoal }
        }
        if [.untilTest, .pages, .planWait, .plan, .notify].contains(start), profile.route == nil {
            profile.route = .range
            profile.unit = "二次方程式"
            selectedUnit = "二次方程式"
        }
        if [.pages, .planWait, .plan, .notify].contains(start), profile.untilTest == nil { profile.untilTest = "2週間くらい" }
        if [.plan, .notify].contains(start), draft == nil {
            let json = MockTurnRunner.onboardingPlan(["unit": profile.unit ?? "二次方程式", "trial": profile.trial.map { ["correct": $0.correct] }])
            if let data = try? JSONSerialization.data(withJSONObject: json) { draft = try? JSONDecoder().decode(OnboardingPlanDraft.self, from: data) }
        }
        if start == .grading { gradingStartedAt = Date().addingTimeInterval(-4) }
        if isClaudeAvailable() { step = start }
    }

    /// 画面の確認用の答案(手書きの代わりに、3 行の式を描いた画像)。
    static func sampleAnswerImage() -> Data? {
        let size = CGSize(width: 900, height: 700)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 58, weight: .medium), .foregroundColor: UIColor(white: 0.12, alpha: 1)]
            for (index, line) in ["x² − 5x + 6 = 0", "(x − 2)(x − 3) = 0", "x = 2, 3"].enumerated() {
                let text = NSAttributedString(string: line, attributes: attributes)
                let width = text.size().width
                text.draw(at: CGPoint(x: (size.width - width) / 2, y: 140 + CGFloat(index) * 140))
            }
        }
        return image.jpegData(compressionQuality: 0.85)
    }
    #endif
}
