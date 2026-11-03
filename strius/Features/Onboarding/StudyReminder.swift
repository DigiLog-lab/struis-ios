import Foundation
import OSLog
import UserNotifications

nonisolated private let reminderLog = Logger(subsystem: "com.digiloglab.strius", category: "reminder")

/// 通知の時刻。オンボーディングは 17:00・20:00・21:00 の 3 択、設定は分まで自由に選べる。
nonisolated struct ReminderTime: Equatable, Sendable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    init(date: Date, calendar: Calendar = .current) {
        let parts: DateComponents = calendar.dateComponents([.hour, .minute], from: date)
        hour = parts.hour ?? 0
        minute = parts.minute ?? 0
    }

    /// その日のこの時刻(設定の時刻の選択に渡す)。
    func date(on day: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}

/// 勉強する時間の通知(#40)。前置きの画面の「次へ」で iOS の確認を出し(使う時に求める)、選んだ時刻に毎日、その日にやることを 1 つ知らせる。
nonisolated enum StudyReminder {
    static let identifier = "struis.study-reminder"
    static let hourKey = "reminder.hour.v1"
    /// 分。無ければ 0 分(分を持つ前に選んだ時刻)。
    static let minuteKey = "reminder.minute.v1"
    /// 通知をオフにする前の時(オンに戻した時に使う)。
    static let lastHourKey = "reminder.last-hour.v1"
    static let titleKey = "reminder.subunit.v1"

    /// 選んだ時刻(未設定なら nil)。
    static var hour: Int? {
        let value = UserDefaults.standard.object(forKey: hourKey) as? Int
        return value
    }

    /// 選んだ時刻(オフなら nil)。
    static var time: ReminderTime? {
        hour.map { ReminderTime(hour: $0, minute: UserDefaults.standard.integer(forKey: minuteKey)) }
    }

    /// 通知をオンに戻す時の時刻。前の時刻が無ければ 20:00。
    static var lastTime: ReminderTime {
        let lastHour: Int? = UserDefaults.standard.object(forKey: lastHourKey) as? Int
        guard let lastHour else { return ReminderTime(hour: 20, minute: 0) }
        return ReminderTime(hour: lastHour, minute: UserDefaults.standard.integer(forKey: minuteKey))
    }

    /// iOS の設定で通知が拒否されているか。
    static func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// 設定で選び直した時刻を保存して、通知を置き直す。届けられなければ false。
    @discardableResult
    static func update(to time: ReminderTime) async -> Bool {
        let title: String = UserDefaults.standard.string(forKey: titleKey) ?? "今日の小単元"
        return await request(hour: time.hour, minute: time.minute, subunitTitle: title)
    }

    /// 確認を出し、許可されたら毎日の通知を置く。許可されなくても先に進む(あとから設定で変えられる)。
    @discardableResult
    static func request(hour: Int, minute: Int = 0, subunitTitle: String) async -> Bool {
        UserDefaults.standard.set(hour, forKey: hourKey)
        UserDefaults.standard.set(minute, forKey: minuteKey)
        UserDefaults.standard.set(subunitTitle, forKey: titleKey)
        let center = UNUserNotificationCenter.current()
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            reminderLog.error("authorization failed: \(String(describing: error), privacy: .public)")
            return false
        }
        guard granted else { return false }
        await schedule(hour: hour, minute: minute, subunitTitle: subunitTitle)
        return true
    }

    /// 毎日の通知を置き直す(小単元が進んだ時に中身を替える)。
    static func schedule(hour: Int, minute: Int = 0, subunitTitle: String) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let content = UNMutableNotificationContent()
        content.title = "Struis"
        content.body = "今日は「\(subunitTitle)」です。"
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute), repeats: true)
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        } catch {
            reminderLog.error("schedule failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 通知を止める(設定の「通知」をオフにした時)。時刻はオンに戻す時のために控える。
    static func cancel() {
        if let hour { UserDefaults.standard.set(hour, forKey: lastHourKey) }
        UserDefaults.standard.removeObject(forKey: hourKey)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
