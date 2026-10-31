import Foundation
import OSLog
import UserNotifications

private let reminderLog = Logger(subsystem: "com.digiloglab.strius", category: "reminder")

/// 勉強する時間の通知(#40)。前置きの画面の「次へ」で iOS の確認を出し(使う時に求める)、選んだ時刻に毎日、その日にやることを 1 つ知らせる。
nonisolated enum StudyReminder {
    static let identifier = "struis.study-reminder"
    static let hourKey = "reminder.hour.v1"
    static let titleKey = "reminder.subunit.v1"

    /// 選んだ時刻(未設定なら nil)。
    static var hour: Int? {
        let value = UserDefaults.standard.object(forKey: hourKey) as? Int
        return value
    }

    /// 確認を出し、許可されたら毎日の通知を置く。許可されなくても先に進む(あとから設定で変えられる)。
    @discardableResult
    static func request(hour: Int, subunitTitle: String) async -> Bool {
        UserDefaults.standard.set(hour, forKey: hourKey)
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
        await schedule(hour: hour, subunitTitle: subunitTitle)
        return true
    }

    /// 毎日の通知を置き直す(小単元が進んだ時に中身を替える)。
    static func schedule(hour: Int, subunitTitle: String) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let content = UNMutableNotificationContent()
        content.title = "Struis"
        content.body = "今日は「\(subunitTitle)」です。"
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: 0), repeats: true)
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        } catch {
            reminderLog.error("schedule failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 通知を止める(設定の「通知」で「知らせない」を選んだ時)。
    static func cancel() {
        UserDefaults.standard.removeObject(forKey: hourKey)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
