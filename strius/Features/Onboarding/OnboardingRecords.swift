import Foundation

/// 利用規約とプライバシーポリシー。本文はまだ無いので、仮の URL をここ 1 か所に置く(#40)。
nonisolated enum LegalLinks {
    static let terms = URL(string: "https://struis.digiloglab.com/terms")!
    static let privacy = URL(string: "https://struis.digiloglab.com/privacy")!
}

/// 利用規約とプライバシーポリシーの版(#78)。本文を変えて同意を取り直す時に、アプリの更新でここを上げる(サーバーからは知らせない)。
/// 保存した版と違う利用者には、次に開いた時に規約と送る内容の同意の画面を出す。保護者の同意の版(#76)とは別に持つ。
nonisolated enum LegalVersion {
    static let terms = "2026-11-06"
}

/// 規約に同意した版と日時。
nonisolated struct TermsAcceptance: Codable, Hashable, Sendable {
    var version: String
    var acceptedAt: Date
}

/// 年齢の区分。18 は成年かどうか、16 は 16 歳未満の個人情報の扱いを定めた改正法への備え。
nonisolated enum AgeBand: String, Codable, Sendable {
    case under16
    case under18
    case adult

    var isMinor: Bool { self != .adult }

    /// Declared Age Range の範囲(年齢の区切り 16・18 で聞いた結果)から。決められなければ nil。
    static func from(lowerBound: Int?, upperBound: Int?) -> AgeBand? {
        if let lowerBound, lowerBound >= 18 { return .adult }
        if let upperBound, upperBound < 16 { return .under16 }
        if let lowerBound, lowerBound >= 16, let upperBound, upperBound < 18 { return .under18 }
        if let upperBound, upperBound < 18 { return .under18 }
        return nil
    }

    /// 生年月日から(端末の中で判定にだけ使い、生年月日は残さない)。
    static func from(birthdate: Date, now: Date = Date(), calendar: Calendar = .current) -> AgeBand {
        let age = calendar.dateComponents([.year], from: birthdate, to: now).year ?? 0
        if age < 16 { return .under16 }
        if age < 18 { return .under18 }
        return .adult
    }
}

/// 年齢の判定の結果(生年月日は持たない)。
nonisolated struct AgeResult: Codable, Hashable, Sendable {
    var band: AgeBand
    /// `selfDeclared` | `guardianDeclared` | `confirmed` など(Declared Age Range)、生年月日で判定した時は `birthdate`。
    var declaration: String
    var checkedAt: Date

    /// 結果だけを残すので、18 歳になったことはアプリでは分からない。1 年ごとに取り直す。
    func needsRecheck(now: Date = Date()) -> Bool {
        now.timeIntervalSince(checkedAt) >= 365 * 24 * 60 * 60
    }
}

/// 端末に残すオンボーディングの記録。Keychain と本人の iCloud の Key-Value ストアに置く(入れ直しても戻らず、
/// 同じ Apple ID の iPhone と iPad で共有)。サインアウトでは消さない。
nonisolated struct OnboardingRecords: Sendable {
    let values: MirroredValues

    static let ageKey = "onboarding.age.v1"
    /// 版の無い同意の日時(#78 より前)。未同意として扱い、読まない(規約の本文が無い時に押された同意を、公開版の同意に数えない)。
    static let legacyTermsKey = "onboarding.termsAcceptedAt.v1"
    /// 同意した規約の版と日時(`TermsAcceptance` の JSON)。
    static let termsKey = "onboarding.terms.v2"
    static let trialUsedKey = "onboarding.trialUsed.v1"
    /// 保護者の同意の控え(`GuardianConsent` の JSON。#76)。
    static let guardianConsentKey = "onboarding.guardianConsent.v1"
    /// 運営者側に記録を送れた同意番号(控えの番号と違えば未送信)。
    static let guardianConsentSentKey = "onboarding.guardianConsentSent.v1"
    /// お試しは 3 問まで無料。
    static let trialLimit = 3

    static let shared = OnboardingRecords.makeShared()

    private static func makeShared() -> OnboardingRecords {
        #if DEBUG
        // 画面の確認用: `STRUIS_AGE_RANGE`・`STRUIS_TRIAL_USED` を渡したら、端末の記録を触らずにメモリの中で始める。
        let environment = ProcessInfo.processInfo.environment
        if environment["STRUIS_TRIAL_USED"] != nil || environment["STRUIS_AGE_RANGE"] != nil || environment["STRUIS_ONBOARDING_START"] != nil
            || environment["STRUIS_GUARDIAN_CONSENT_VERSION"] != nil {
            let records = OnboardingRecords(values: MirroredValues(local: MemoryValueStore(), cloud: MemoryValueStore()))
            if let used = environment["STRUIS_TRIAL_USED"].flatMap(Double.init) { records.values.setNumber(min(3, max(0, used)), trialUsedKey) }
            // `STRUIS_GUARDIAN_CONSENT_VERSION=<版>`: 16 歳未満で、その版の保護者の同意の控えがある状態から始める(版が上がった時の確認用)。
            if let version = environment["STRUIS_GUARDIAN_CONSENT_VERSION"] {
                records.saveAge(AgeResult(band: .under16, declaration: "selfDeclared", checkedAt: Date()))
                records.acceptTerms()
                records.markGuardianConsentSent(records.recordGuardianConsent(textVersion: version))
            }
            return records
        }
        if ProcessInfo.processInfo.arguments.contains("-reset-onboarding") {
            let records = OnboardingRecords(values: .device)
            records.resetForTesting()
            return records
        }
        #endif
        return OnboardingRecords(values: .device)
    }

    // MARK: - 年齢

    var age: AgeResult? {
        guard let text = values.string(Self.ageKey), let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgeResult.self, from: data)
    }

    func saveAge(_ result: AgeResult) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(result) else { return }
        values.set(String(decoding: data, as: UTF8.self), Self.ageKey)
    }

    // MARK: - 規約

    /// 同意の記録。Keychain と iCloud の両方を読み、今の版の方を採る(別の端末で同意し直した版を、この端末の古い版で隠さない)。
    var termsAcceptance: TermsAcceptance? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored: [TermsAcceptance] = [values.local.string(Self.termsKey), values.cloud.string(Self.termsKey)].compactMap { text in
            text.flatMap { $0.data(using: .utf8) }.flatMap { try? decoder.decode(TermsAcceptance.self, from: $0) }
        }
        return stored.first { $0.version == LegalVersion.terms } ?? stored.max { $0.acceptedAt < $1.acceptedAt }
    }

    /// 今の版に同意しているか。版の記録が無い同意・前の版への同意は、同意していない扱い。
    var hasAcceptedCurrentTerms: Bool { termsAcceptance?.version == LegalVersion.terms }

    /// 今の版に同意した日時(今の版に同意していなければ nil)。
    var termsAcceptedAt: Date? { hasAcceptedCurrentTerms ? termsAcceptance?.acceptedAt : nil }

    func acceptTerms(at date: Date = Date(), version: String = LegalVersion.terms) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(TermsAcceptance(version: version, acceptedAt: date)) else { return }
        values.set(String(decoding: data, as: UTF8.self), Self.termsKey)
    }

    /// AI の機能を使ってよいか(今の版の規約に同意している)。`DeviceUsageGate` が送る前に確かめる。
    var allowsAI: Bool {
        #if DEBUG
        if Self.debugAssumesConsent { return true }
        #endif
        return hasAcceptedCurrentTerms && !needsGuardianConsent(band: age?.band)
    }

    #if DEBUG
    /// DEBUG の起動の差し替えで、同意を済ませた扱いにする: オンボーディングを飛ばす起動と、記録をメモリに置く画面の確認
    /// (`STRUIS_TRIAL_USED`・`STRUIS_AGE_RANGE`・`STRUIS_ONBOARDING_START`・`STRUIS_GUARDIAN_CONSENT_VERSION`)。
    static var debugAssumesConsent: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if ["-skip-onboarding", "-learning-feed-e2e", "-workbook"].contains(where: arguments.contains) { return true }
        let environment = ProcessInfo.processInfo.environment
        return ["STRUIS_TRIAL_USED", "STRUIS_AGE_RANGE", "STRUIS_ONBOARDING_START", "STRUIS_GUARDIAN_CONSENT_VERSION"].contains { environment[$0] != nil }
    }
    #endif

    // MARK: - 保護者の同意(#76)

    /// 同意の控え。Keychain と iCloud の両方を読み、今の版の方を採る(別の端末で同意し直した版を、この端末の古い版で隠さない)。
    var guardianConsent: GuardianConsent? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored: [GuardianConsent] = [values.local.string(Self.guardianConsentKey), values.cloud.string(Self.guardianConsentKey)].compactMap { text in
            text.flatMap { $0.data(using: .utf8) }.flatMap { try? decoder.decode(GuardianConsent.self, from: $0) }
        }
        return stored.first { $0.textVersion == GuardianConsentText.version } ?? stored.max { $0.acceptedAt < $1.acceptedAt }
    }

    /// 16 歳未満で、今の版の同意の控えが無い(版が上がった時も出し直す)。
    func needsGuardianConsent(band: AgeBand?) -> Bool {
        band == .under16 && guardianConsent?.textVersion != GuardianConsentText.version
    }

    /// 同意した時: 新しい同意番号で控えを残す(運営者側へはまだ送っていない)。
    @discardableResult
    func recordGuardianConsent(at date: Date = Date(), textVersion: String = GuardianConsentText.version) -> GuardianConsent {
        let consent = GuardianConsent(id: UUID(), acceptedAt: date, textVersion: textVersion)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(consent) { values.set(String(decoding: data, as: UTF8.self), Self.guardianConsentKey) }
        return consent
    }

    /// まだ運営者側へ送れていない控え。
    var pendingGuardianConsent: GuardianConsent? {
        guard let consent = guardianConsent, values.string(Self.guardianConsentSentKey) != consent.number else { return nil }
        return consent
    }

    func markGuardianConsentSent(_ consent: GuardianConsent) {
        values.set(consent.number, Self.guardianConsentSentKey)
    }

    // MARK: - お試し

    /// 解いたお試しの数(大きい方を採る。入れ直しても、別の端末でも戻らない)。
    var trialUsed: Int { min(Self.trialLimit, Int(values.number(Self.trialUsedKey))) }
    var trialRemaining: Int { max(0, Self.trialLimit - trialUsed) }

    func recordTrialSolved() {
        values.setNumber(Double(min(Self.trialLimit, trialUsed + 1)), Self.trialUsedKey)
    }

    #if DEBUG
    /// `-reset-onboarding`(UI テスト): 端末の記録も最初からにする。
    func resetForTesting() {
        values.set(nil, Self.ageKey)
        values.set(nil, Self.termsKey)
        values.set(nil, Self.legacyTermsKey)
        values.set(nil, Self.trialUsedKey)
        values.set(nil, Self.guardianConsentKey)
        values.set(nil, Self.guardianConsentSentKey)
    }
    #endif
}
