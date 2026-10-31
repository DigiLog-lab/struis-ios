import Foundation

/// オンボーディングの回答と完了(§7.2、#40)。端末の設定(UserDefaults)に保存し、計画づくり・単元づくり・小単元のモデルの
/// ターンに文脈として渡す。学年などを聞き直さないため。生年月日は持たない(年齢は判定の結果だけ)。
nonisolated struct OnboardingProfile: Codable, Hashable, Sendable {
    /// 何をするか(旧版の A・B・C・U)。
    nonisolated enum Route: String, Codable, Sendable {
        /// A: やる範囲が決まっている。
        case range
        /// B: 苦手な単元をやり直したい。
        case weak
        /// C: 何をやればいいか分からない。
        case unsure
        /// U: 大学生・それ以外。
        case university
    }

    /// 学年(「中3」)。大学生・それ以外は `universityGrade`。
    var grade: String?
    var ageBand: AgeBand?
    /// Declared Age Range の `ageRangeDeclaration`(`guardianDeclared` かどうかを後で使う)。生年月日で判定した時は `birthdate`。
    var ageDeclaration: String?
    var ageCheckedAt: String?
    var termsAcceptedAt: String?
    /// 写真(答案)の扱いへの同意(App Store 審査ガイドライン 5.1.2(i))。
    var photoConsentAt: String?
    var route: Route?
    /// 選んだ単元(A・B)。
    var unit: String?
    /// 次のテストまで(A)。
    var untilTest: String?
    /// 撮った問題のページ・授業の資料の数(A・U)。
    var materialCount: Int?
    /// 解いたお試しの問題(順に)。
    var trial: [TrialRecord] = []
    /// 何を勉強するか・何ができるようになりたいか(U)。
    var universityTopic: String?
    var universityGoal: String?
    /// 途中で閉じた時に続きから開く画面(`OnboardingStep` の名前)。
    var resumeStep: String?

    static let universityGrade = "大学生・それ以外"

    static let profileKey = "onboarding.profile.v2"
    static let completedKey = "onboarding.completed.v1"
    static let unitCreationThreadKey = "onboarding.unitCreationThread.v1"
    /// 保存したが、まだ単元づくりの起動メッセージに渡せていない教材(起動が失敗した時に残す)。
    static let pendingUnitCreationAttachmentsKey = "onboarding.pendingUnitCreationAttachments.v1"
    /// 前の版の回答(読まずに消す)。
    static let legacyProfileKey = "onboarding.profile.v1"

    static func pendingUnitCreationAttachments(_ defaults: UserDefaults = .standard) -> [ChatTurns.Attachment] {
        guard let data = defaults.data(forKey: pendingUnitCreationAttachmentsKey) else { return [] }
        return (try? JSONDecoder().decode([ChatTurns.Attachment].self, from: data)) ?? []
    }

    static func setPendingUnitCreationAttachments(_ attachments: [ChatTurns.Attachment], _ defaults: UserDefaults = .standard) {
        if attachments.isEmpty {
            defaults.removeObject(forKey: pendingUnitCreationAttachmentsKey)
        } else if let data = try? JSONEncoder().encode(attachments) {
            defaults.set(data, forKey: pendingUnitCreationAttachmentsKey)
        }
    }

    /// 教科は当面数学だけ。
    var subject: String? { grade == nil ? nil : "数学" }

    var isUniversity: Bool { grade == Self.universityGrade || route == .university }

    var routeText: String? {
        switch route {
        case .range: "やる範囲が決まっている"
        case .weak: "苦手な単元をやり直したい"
        case .unsure: "何をやればいいか分からない"
        case .university: "大学生・それ以外の勉強"
        case nil: nil
        }
    }

    /// モデルに渡す 1 段落。空なら nil。
    var promptSummary: String? {
        let trialText = trial.isEmpty ? nil : "お試しの問題: " + trial.map { "\($0.label) \($0.correct ? "○" : "×")" }.joined(separator: "、")
        let lines = [
            grade.map { "学年: \($0)" }, subject.map { "科目: \($0)" }, routeText.map { "いまやりたいこと: \($0)" },
            unit.map { "単元: \($0)" }, untilTest.map { "次のテストまで: \($0)" }, trialText,
            universityTopic.map { "勉強すること: \($0)" }, universityGoal.map { "できるようになりたいこと: \($0)" },
        ].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func load(_ defaults: UserDefaults = .standard) -> OnboardingProfile? {
        guard let data = defaults.data(forKey: profileKey) else { return nil }
        return try? JSONDecoder().decode(OnboardingProfile.self, from: data)
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.profileKey) }
    }

    static func isCompleted(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedKey)
    }

    static func markCompleted(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
    }

    /// サインアウトの時に消す。次にサインインした学習者に、前の学習者の回答や作りかけの単元づくりを渡さない。
    /// 年齢の結果・規約の同意・お試しの数は端末の記録(`OnboardingRecords`)に残す(入れ直しても戻らない)。
    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: profileKey)
        defaults.removeObject(forKey: legacyProfileKey)
        defaults.removeObject(forKey: completedKey)
        defaults.removeObject(forKey: unitCreationThreadKey)
        ChatStore.removeStoredAttachments(pendingUnitCreationAttachments(defaults))
        defaults.removeObject(forKey: pendingUnitCreationAttachmentsKey)
    }
}
