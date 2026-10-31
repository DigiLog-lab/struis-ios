import SwiftUI

/// オンボーディングの見た目の決まり(#40、Design キャンバス「Struis オンボーディング 2026-10-30」)。
enum OnboardingMetrics {
    static let horizontal: CGFloat = 20
    /// iPad の選ぶだけの画面の列の幅。
    static let padColumn: CGFloat = 520
    static let buttonHeight: CGFloat = 52
}

/// 見出しと補足。
struct OnboardingTitle: View {
    let title: String
    var detail: String? = nil
    var size: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typography.sans(size: size, weight: .bold, relativeTo: .title))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(Typography.sans(size: 15, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 銅色の主ボタン。押せない時は薄くする。
struct OnboardingPrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var isEnabled = true
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 16, weight: .semibold)) }
                Text(title).font(Typography.sans(size: 17, weight: .bold, relativeTo: .headline))
            }
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: OnboardingMetrics.buttonHeight)
            .background(Theme.accentColor.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// 淡い銅色の補助ボタン。
struct OnboardingSecondaryButton: View {
    let title: String
    var symbol: String? = nil
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)) }
                Text(title).font(Typography.sans(size: 15, weight: .medium))
            }
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, minHeight: OnboardingMetrics.buttonHeight)
            .background(Theme.accentColor.opacity(0.18), in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.accentColor.opacity(0.22), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// 文字だけのボタン(「別の問題にする」「ないので進む」)。
struct OnboardingTextButton: View {
    let title: String
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.sans(size: 14, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// 丸い選択肢(学年・次のテストまで・知らせる時間)。選ぶと銅色。
struct OnboardingPill: View {
    let title: String
    let isSelected: Bool
    var height: CGFloat = OnboardingMetrics.buttonHeight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.sans(size: 15, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? Theme.onAccent : Theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(isSelected ? AnyShapeStyle(Theme.accentColor) : AnyShapeStyle(Theme.card), in: Capsule())
                .overlay { Capsule().strokeBorder(isSelected ? Color.clear : Theme.hairline, lineWidth: 1) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// 小さい丸い選択肢(やり直す単元・科目の例)。
struct OnboardingChip: View {
    let title: String
    var isSelected = false
    var tinted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.sans(size: 14, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? Theme.onAccent : Theme.primaryText)
                .padding(.horizontal, 15)
                .frame(minHeight: tinted ? 34 : 40)
                .background(isSelected ? AnyShapeStyle(Theme.accentColor) : (tinted ? AnyShapeStyle(Theme.accentColor.opacity(0.18)) : AnyShapeStyle(Theme.card)), in: Capsule())
                .overlay { Capsule().strokeBorder(isSelected || tinted ? Color.clear : Theme.hairline, lineWidth: 1) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// 情報のチップ(「テストまで 2週間くらい」)。
struct OnboardingInfoChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.sans(size: 13, weight: .medium))
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.accentColor.opacity(0.18), in: Capsule())
    }
}

/// 淡い銅色の地の注意書き(鍵・保護者)。
struct OnboardingNote: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 20)
            Text(text)
                .font(Typography.sans(size: 13, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// 一覧のカード(項目の間に細い線)。
struct OnboardingListCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .struisSurface(radius: Theme.Radius.cardLarge)
    }
}

/// 太字の見出しと説明の 1 行(規約の要点・写真の扱い)。
struct OnboardingPointRow: View {
    var symbol: String? = nil
    let title: String
    let detail: String
    var showsDivider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accentColor)
                        .frame(width: 22)
                        .padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Typography.sans(size: 15, weight: .bold)).foregroundStyle(Theme.primaryText)
                    Text(detail).font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)
            if showsDivider { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .padding(.horizontal, 18)
        .accessibilityElement(children: .combine)
    }
}

/// 戻る(左上)。
struct OnboardingBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("戻る")
        .accessibilityIdentifier("onboarding-back")
    }
}

/// 1 画面の骨組み: 上に戻る(とお試しの数)、中に本文(長ければ動かせる)、下にボタン。iPad は幅 520pt の列を中央に置く。
struct OnboardingScaffold<Content: View, Footer: View>: View {
    var onBack: (() -> Void)? = nil
    var badge: String? = nil
    var showsBrand = false
    var isPad = false
    var columnWidth: CGFloat = OnboardingMetrics.padColumn
    var centersVertically = false
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let onBack {
                    OnboardingBackButton(action: onBack).padding(.leading, -12)
                } else if showsBrand {
                    StruisBrandHeader()
                }
                Spacer()
                if let badge {
                    Text(badge)
                        .font(Typography.sans(size: 12, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accentColor.opacity(0.18), in: Capsule())
                        .accessibilityIdentifier("onboarding-trial-badge")
                }
            }
            .frame(height: 44)
            .padding(.top, 12)
            .padding(.horizontal, isPad ? 40 : OnboardingMetrics.horizontal)
            .opacity(onBack == nil && !showsBrand && badge == nil ? 0 : 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if centersVertically { Spacer(minLength: 0) }
                    content
                    if centersVertically { Spacer(minLength: 0) }
                }
                .frame(maxWidth: isPad ? columnWidth : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, OnboardingMetrics.horizontal)
                .padding(.top, isPad ? 40 : 28)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 10) { footer }
                .frame(maxWidth: isPad ? min(columnWidth, 400) : .infinity)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, OnboardingMetrics.horizontal)
                .padding(.bottom, 12)
        }
        .background(Theme.ground.ignoresSafeArea())
    }
}

/// 「中1」「中2」… を 3 つずつ並べる。
struct OnboardingPillGrid: View {
    let options: [String]
    let selection: String?
    var columns = 3
    let onSelect: (String) -> Void

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: options.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(options[start..<min(start + columns, options.count)], id: \.self) { option in
                        OnboardingPill(title: option, isSelected: selection == option) { onSelect(option) }
                    }
                }
            }
        }
    }
}

/// 折り返して並べる(やり直す単元・科目の例)。
struct OnboardingFlow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        StruisFlowLayout(spacing: 8, lineSpacing: 8) { content }
    }
}
