import SwiftUI

enum Theme {
    enum Palette {
        static let accentLight = Color(red: 0.722, green: 0.451, blue: 0.227)
        static let accentDark = Color(red: 0.831, green: 0.580, blue: 0.353)

        static let textPrimaryLight = Color(red: 0.122, green: 0.102, blue: 0.078)
        static let textPrimaryDark = Color(red: 0.937, green: 0.898, blue: 0.824)

        static let textSecondaryLight = Color(red: 0.353, green: 0.314, blue: 0.267)
        static let textSecondaryDark = Color(red: 0.682, green: 0.631, blue: 0.549)

        static let textTertiaryLight = Color(red: 0.541, green: 0.498, blue: 0.435)
        static let textTertiaryDark = Color(red: 0.486, green: 0.443, blue: 0.380)
        static let textOnAccentLight = Color.white
        static let textOnAccentDark = Color(red: 0.063, green: 0.071, blue: 0.078)

        static let growthLight = Color(red: 0.247, green: 0.561, blue: 0.384)
        static let growthDark = Color(red: 0.498, green: 0.749, blue: 0.584)

        static let regressLight = Color(red: 0.753, green: 0.439, blue: 0.376)
        static let regressDark = Color(red: 0.847, green: 0.584, blue: 0.525)

        static let separatorLight = Color.black.opacity(0.08)
        static let separatorDark = Color(red: 1, green: 0.910, blue: 0.784).opacity(0.10)
    }

    enum Radius {
        static let card: CGFloat = 18
        static let cardLarge: CGFloat = 22
        static let bubble: CGFloat = 20
        static let bubbleTail: CGFloat = 6
        static let pill: CGFloat = 26
        static let stat: CGFloat = 16
        static let input: CGFloat = 24
        static let chip: CGFloat = 22
    }

    enum Duration {
        static let quick: Double = 0.15
        static let standard: Double = 0.25
        static let slow: Double = 0.45
    }

    // 面。地は純黒・純白から離し、カードは地より一段明るく置く。
    // ライトの「生成りの紙に明るい面が載る」関係を、ダークでも同じ向きに保つ。
    static let ground = dynamic(light: (0.961, 0.941, 0.902), dark: (0.114, 0.098, 0.082))
    static let card = dynamic(light: (1.0, 0.992, 0.976), dark: (0.176, 0.157, 0.129))
    static let cardLow = dynamic(light: (0.984, 0.969, 0.937), dark: (0.153, 0.133, 0.110))

    // scheme を引かずに使える文字色。.secondary / .tertiary(冷灰)の置き換え先。
    static let primaryText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Palette.textPrimaryDark) : UIColor(Palette.textPrimaryLight) })
    static let secondaryText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Palette.textSecondaryDark) : UIColor(Palette.textSecondaryLight) })
    static let tertiaryText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Palette.textTertiaryDark) : UIColor(Palette.textTertiaryLight) })
    static let accentColor = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Palette.accentDark) : UIColor(Palette.accentLight) })
    static let growthColor = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Palette.growthDark) : UIColor(Palette.growthLight) })
    static let regressColor = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Palette.regressDark) : UIColor(Palette.regressLight) })
    /// 赤ペン(誤答の答案に先生が入れる赤)。暗い地では明るくし、どちらでも生徒の線と見分けられる濃さにする。
    static let redPenUIColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1.0, green: 0.42, blue: 0.40, alpha: 1) : UIColor(red: 0.84, green: 0.09, blue: 0.10, alpha: 1) }
    static let redPen = Color(uiColor: redPenUIColor)
    /// 白地の答案の画像に重ねる赤(画像はライトモードの色で描くので、こちらも明るい地の赤)。
    static let redPenOnPaper = Color(red: 0.84, green: 0.09, blue: 0.10)
    static let onAccent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Palette.textOnAccentDark) : UIColor(Palette.textOnAccentLight) })
    static let hairline = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Palette.separatorDark) : UIColor(Palette.separatorLight) })

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Palette.accentDark : Palette.accentLight
    }

    static func textPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Palette.textPrimaryDark : Palette.textPrimaryLight
    }

    static func textSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Palette.textSecondaryDark : Palette.textSecondaryLight
    }

    static func textTertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Palette.textTertiaryDark : Palette.textTertiaryLight
    }

    static func textOnAccent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Palette.textOnAccentDark : Palette.textOnAccentLight
    }

    static func growth(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Palette.growthDark : Palette.growthLight
    }

    static func regress(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Palette.regressDark : Palette.regressLight
    }

    static func separator(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Palette.separatorDark : Palette.separatorLight
    }
}

/// 不透明なコンテンツ面。微グラデ + 1px のリム + 上縁の光 + 落ち影で、地から一段持ち上げる。
private struct StruisSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(
                LinearGradient(colors: [Theme.card, Theme.cardLow], startPoint: .top, endPoint: .bottom),
                in: shape
            )
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Theme.hairline.opacity(scheme == .dark ? 1.6 : 1), Theme.hairline],
                        startPoint: .top, endPoint: .center
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.06), radius: 1, y: 1)
            .shadow(color: (scheme == .dark ? Color.black.opacity(0.45) : Color(red: 0.24, green: 0.16, blue: 0.04).opacity(0.14)), radius: 10, y: 8)
    }
}

extension View {
    func struisSurface(radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(StruisSurface(radius: radius))
    }
}
