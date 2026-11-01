import SwiftUI

enum Typography {
    enum SansFontName: String {
        case regular = "ZenKakuGothicNew-Regular"
        case medium = "ZenKakuGothicNew-Medium"
        case bold = "ZenKakuGothicNew-Bold"

        var systemWeight: UIFont.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .bold: .bold
            }
        }
    }

    enum SerifFontName: String {
        case regular = "CormorantGaramond-Light"
        case italic = "CormorantGaramond-LightItalic"
    }

    /// 和欧混植。欧文と数字は SF、和文は Zen Kaku Gothic New。
    /// Zen Kaku の数字は字幅が狭く線が細いので、数字が並ぶ場所(点数・時刻・進み)で素人っぽく見える。
    /// SF を主書体にして Zen Kaku を cascade の先頭に置くと、かな・漢字だけが Zen Kaku に落ちる。
    static func sans(
        size: CGFloat,
        weight: SansFontName = .regular,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> Font {
        Font(sansUIFont(size: size, weight: weight, relativeTo: textStyle))
    }

    /// `sans` と同じ書体の `UIFont`(UIKit で本文を描く所: `NativeMathText`)。Dynamic Type の倍率込み。
    static func sansUIFont(
        size: CGFloat,
        weight: SansFontName = .regular,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> UIFont {
        let latin = UIFont.systemFont(ofSize: size, weight: weight.systemWeight)
        let japanese = UIFontDescriptor(fontAttributes: [.name: weight.rawValue])
        let descriptor = latin.fontDescriptor.addingAttributes([.cascadeList: [japanese]])
        let mixed = UIFont(descriptor: descriptor, size: size)
        return UIFontMetrics(forTextStyle: textStyle.uiTextStyle).scaledFont(for: mixed)
    }

    static func serif(
        size: CGFloat,
        weight: SerifFontName = .regular,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> Font {
        .custom(weight.rawValue, size: size, relativeTo: textStyle)
    }

    static func serifItalic(size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        serif(size: size, weight: .italic, relativeTo: textStyle)
    }

    static let navBrand = serifItalic(size: 18, relativeTo: .headline)
    static let brand = serifItalic(size: 24, relativeTo: .title2)
    static let eyebrow = serifItalic(size: 11, relativeTo: .caption)
    static let counter = serifItalic(size: 30, relativeTo: .largeTitle)
    static let heroSerif = serifItalic(size: 40, relativeTo: .largeTitle)

    /// ロゴマークの横の「Struis」(2026-10-30 に斜体のセリフ体をやめた。オンボーディングとサインインの画面)。
    static let brandName = sans(size: 17, weight: .bold, relativeTo: .headline)
    static let heading1 = sans(size: 26, weight: .bold, relativeTo: .title)
    static let heading2 = sans(size: 22, weight: .bold, relativeTo: .title2)
    static let title = sans(size: 20, weight: .bold, relativeTo: .headline)
    static let body = sans(size: 15, weight: .medium)
    static let bodyEmphasized = sans(size: 15, weight: .medium)
    static let bodyCompact = sans(size: 14, weight: .medium)
    static let caption = sans(size: 12, weight: .medium, relativeTo: .caption)
    static let micro = sans(size: 11, weight: .medium, relativeTo: .caption2)
    static let ordinal = serifItalic(size: 17, relativeTo: .body)
}

private extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .caption: .caption1
        case .caption2: .caption2
        case .footnote: .footnote
        default: .body
        }
    }
}
