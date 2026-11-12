import Foundation

// 規約の版・リンクと年齢の区分。本体と App Clip(#133)の両方でコンパイルする(OnboardingRecords.swift から移した)。

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
