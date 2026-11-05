import SwiftUI
import XCTest
@testable import strius

/// 設定の小さな決まり: 通知の時刻を分まで持つこと、内部の配布の見分け、実行先は Claude だけ。
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

    /// 前の GPT の値(`"openai"`)や知らない値で保存したプラン・配信も Claude として読む。値が無ければ nil のまま。
    func testSavedProviderValuesAllDecodeAsClaude() throws {
        struct Holder: Decodable { let provider: ModelProvider? }
        for raw in ["\"anthropic\"", "\"openai\"", "\"something-new\""] {
            let data: Data = Data("{\"provider\": \(raw)}".utf8)
            XCTAssertEqual(try JSONDecoder().decode(Holder.self, from: data).provider, .anthropic, raw)
        }
        XCTAssertNil(try JSONDecoder().decode(Holder.self, from: Data("{}".utf8)).provider)
        XCTAssertNil(try JSONDecoder().decode(Holder.self, from: Data("{\"provider\": null}".utf8)).provider)
        let encoded: Data = try JSONEncoder().encode(ModelProvider.anthropic)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"anthropic\"")
    }
}
