import SwiftUI
import XCTest
@testable import strius

/// 設定の小さな決まり: 通知の時刻を分まで持つことと、内部の配布の見分け。
final class SettingsRulesTests: XCTestCase {
    func testReminderTimeKeepsHourAndMinuteThroughADate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let time = ReminderTime(hour: 21, minute: 35)
        XCTAssertEqual(ReminderTime(date: time.date(calendar: calendar), calendar: calendar), time)
    }

    func testOnlyPreviewBundlesArePrototypes() {
        XCTAssertTrue(InternalBuild.isPrototype(bundleIdentifier: "com.digiloglab.strius.preview.s01"))
        XCTAssertFalse(InternalBuild.isPrototype(bundleIdentifier: "com.digiloglab.strius"))
        XCTAssertFalse(InternalBuild.isPrototype(bundleIdentifier: nil))
    }

    func testThemePreferenceKeepsTheStoredValuesAndMapsToColorSchemes() {
        XCTAssertEqual(ThemePreference(rawValue: "system"), .system)
        XCTAssertNil(ThemePreference.system.colorScheme)
        XCTAssertEqual(ThemePreference(rawValue: "dark")?.colorScheme, .dark)
        XCTAssertEqual(ThemePreference(rawValue: "light")?.colorScheme, .light)
    }
}
