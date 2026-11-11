import Foundation

/// 「いつまでに」の選択肢から決める期限の日付(#132)。計画の画面で押すと直せる。
nonisolated enum StudyDeadline {
    /// 長期休みの終わり(月・日)。今日の後で一番近いものを使う。夏休み 8/31・冬休み 1/7・春休み 4/5。
    static let holidayEnds: [(month: Int, day: Int)] = [(8, 31), (1, 7), (4, 5)]

    /// 選択肢から期限を決める。期限の無い選択肢(「まだ先・決まっていない」)は nil。
    static func date(for choice: String, from today: Date, calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: today)
        switch choice {
        case "1週間以内": return calendar.date(byAdding: .day, value: 7, to: start)
        case "2週間くらい": return calendar.date(byAdding: .day, value: 14, to: start)
        case "1か月くらい": return calendar.date(byAdding: .month, value: 1, to: start)
        case OnboardingCatalog.untilHoliday: return holidayEnd(after: today, calendar: calendar)
        default: return nil
        }
    }

    /// 今日より後の、一番近い長期休みの終わり。
    static func holidayEnd(after today: Date, calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: today)
        let year = calendar.component(.year, from: start)
        let candidates: [Date] = [year, year + 1].flatMap { y in
            holidayEnds.compactMap { calendar.date(from: DateComponents(year: y, month: $0.month, day: $0.day)) }
        }
        return candidates.filter { $0 > start }.min()
    }

    /// 「8月31日まで」。
    static func label(_ date: Date, calendar: Calendar = .current) -> String {
        "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日まで"
    }

    /// モデルとデータに渡す形(「2027-08-31」)。
    static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
