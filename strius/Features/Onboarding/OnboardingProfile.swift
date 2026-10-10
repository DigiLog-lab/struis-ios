import Foundation

/// オンボーディングの回答と完了(§7.2)。端末の設定(UserDefaults)に保存し、単元づくりや
/// 小単元のモデルのターンに文脈として渡す。学年などを聞き直さないため。
nonisolated struct OnboardingProfile: Codable, Hashable, Sendable {
    var grade: String?
    var currentFocus: String?
    var subject: String?
    var confusion: String?
    var studyStyle: String?
    var materialName: String?

    static let profileKey = "onboarding.profile.v1"
    static let completedKey = "onboarding.completed.v1"
    static let unitCreationThreadKey = "onboarding.unitCreationThread.v1"
    /// 保存したが、まだ単元づくりの起動メッセージに渡せていない教材(起動が失敗した時に残す)。
    static let pendingUnitCreationAttachmentsKey = "onboarding.pendingUnitCreationAttachments.v1"

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

    var isEmpty: Bool { [grade, currentFocus, subject, confusion, studyStyle].allSatisfy { ($0 ?? "").isEmpty } }

    /// モデルに渡す 1 段落。空なら nil。
    var promptSummary: String? {
        let lines = [
            grade.map { "学年: \($0)" }, currentFocus.map { "いちばん優先したいこと: \($0)" },
            subject.map { "いちばん困っている科目: \($0)" }, confusion.map { "わからないと感じるとき: \($0)" },
            studyStyle.map { "普段の勉強のしかた: \($0)" }, materialName.map { "オンボーディングで選んだ教材: \($0)" },
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
    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: profileKey)
        defaults.removeObject(forKey: completedKey)
        defaults.removeObject(forKey: unitCreationThreadKey)
        ChatStore.removeStoredAttachments(pendingUnitCreationAttachments(defaults))
        defaults.removeObject(forKey: pendingUnitCreationAttachmentsKey)
    }
}
