import XCTest
import UIKit
@testable import strius

/// 数式を含む文(問題文・問い・式)は、画面の文字サイズの設定(Dynamic Type)の大きさで描く(2026-11-10)。
@MainActor
final class TypographyScalingTests: XCTestCase {
    func testMathTextFollowsTheTextSizeSetting() {
        let standard = NativeMathStyle(color: .black, fontSize: 22, fontWeight: 700, scale: 2, category: .large)
        let extraLarge = NativeMathStyle(color: .black, fontSize: 22, fontWeight: 700, scale: 2, category: .extraLarge)
        XCTAssertGreaterThan(extraLarge.textFont.pointSize, standard.textFont.pointSize, "文字サイズの設定(XL)が文字の大きさに効いていない")
        XCTAssertGreaterThan(extraLarge.mathSize, standard.mathSize, "文字サイズの設定(XL)が式の大きさに効いていない")
        XCTAssertNotEqual(extraLarge, standard, "文字サイズの設定が違うのに、描いた式の画像を使い回してしまう")
    }

    /// 標準の文字サイズでは、今までの大きさ(`Typography.sansUIFont`)と変わらない。
    func testStandardTextSizeKeepsTheTypographySize() {
        let standard = NativeMathStyle(color: .black, fontSize: 22, fontWeight: 700, scale: 2, category: .large)
        let typography = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont.systemFont(ofSize: 22), compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        XCTAssertEqual(standard.boldFont.pointSize, typography.pointSize, accuracy: 0.01)
        XCTAssertEqual(standard.boldFont.pointSize, 22, accuracy: 0.01)
    }
}
