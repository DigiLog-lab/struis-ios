import XCTest
@testable import strius

/// 無料体験の文言の組み立て(`FreeTrialOffer`)と、設定の「利用枠」のプラン名(`UsageStatus.planTitle`)。
/// 商品の読み込み・対象かどうかは `SubscriptionStoreTests` が StoreKit の設定ファイルで確かめる。
final class FreeTrialTextTests: XCTestCase {
    private let lightMonthly: FreeTrialOffer = FreeTrialOffer(
        trial: FreeTrialOffer.Length(value: 1, unit: .week), renewal: FreeTrialOffer.Length(value: 1, unit: .month),
        currencyCode: "JPY", displayPrice: "¥1,480")

    func testLightOneWeekTrialTexts() {
        XCTAssertEqual(lightMonthly.badgeText, "最初の1週間は無料")
        XCTAssertEqual(lightMonthly.noticeText, "1週間無料、その後は月額1,480円で自動更新されます。無料期間中に解約すれば請求はありません。")
    }

    func testPeriodAndPriceComeFromTheOffer() {
        let offer: FreeTrialOffer = FreeTrialOffer(
            trial: FreeTrialOffer.Length(value: 3, unit: .day), renewal: FreeTrialOffer.Length(value: 1, unit: .year), currencyCode: "JPY", displayPrice: "¥12,800")
        XCTAssertEqual(offer.badgeText, "最初の3日間は無料")
        XCTAssertEqual(offer.noticeText, "3日間無料、その後は年額12,800円で自動更新されます。無料期間中に解約すれば請求はありません。")

        let twoWeeks: FreeTrialOffer = FreeTrialOffer(
            trial: FreeTrialOffer.Length(value: 14, unit: .day), renewal: FreeTrialOffer.Length(value: 1, unit: .month), currencyCode: "JPY", displayPrice: "¥3,980")
        XCTAssertEqual(twoWeeks.trial, FreeTrialOffer.Length(value: 2, unit: .week), "7 日の倍数は週にそろえる")
        XCTAssertEqual(twoWeeks.noticeText, "2週間無料、その後は月額3,980円で自動更新されます。無料期間中に解約すれば請求はありません。")
    }

    func testFullWidthYenSignIsDroppedToo() {
        let offer: FreeTrialOffer = FreeTrialOffer(
            trial: FreeTrialOffer.Length(value: 1, unit: .week), renewal: FreeTrialOffer.Length(value: 1, unit: .month),
            currencyCode: "JPY", displayPrice: "￥1,480")
        XCTAssertEqual(offer.renewalPriceText, "月額1,480円")
    }

    func testOtherCurrenciesUseTheAppStoreDisplayPrice() {
        let offer: FreeTrialOffer = FreeTrialOffer(
            trial: FreeTrialOffer.Length(value: 1, unit: .week), renewal: FreeTrialOffer.Length(value: 1, unit: .month), currencyCode: "USD", displayPrice: "$9.99")
        XCTAssertEqual(offer.renewalPriceText, "月額$9.99")
    }

    func testPlanTitleOfTheUsageScreen() throws {
        XCTAssertEqual(UsageStatus.planTitle(nil, freeTrialEndsAt: nil), "プランなし", "買う前は「お試し」ではなく「プランなし」")
        XCTAssertEqual(UsageStatus.planTitle(.light, freeTrialEndsAt: nil), "ライト")
        XCTAssertEqual(UsageStatus.planTitle(.standard, freeTrialEndsAt: nil), "スタンダード")
        let endsAt: Date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 21, minute: 40)))
        XCTAssertEqual(UsageStatus.planTitle(.light, freeTrialEndsAt: endsAt), "ライト（無料体験中・11月21日まで）")
    }
}
