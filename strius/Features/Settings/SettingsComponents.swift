import SwiftUI

/// 設定の画面の土台。生成りの地に節を 24pt 空けて積む。画面の題はナビゲーションバーの 1 か所だけに置く。
struct SettingsScreen<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 36)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 節。小見出し(任意)・行の面・注記(任意)の 3 段。
struct SettingsSection<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                content
            }
            .settingsCard()
            if let footer {
                SettingsNote(text: footer)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// 節の下や計器の下に置く注記。
struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Theme.secondaryText)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 行の区切り(0.5pt、左に 16pt 字下げ)。
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

/// 別の画面へ進む行。
struct SettingsLinkRow<Destination: View>: View {
    let title: String
    var value: String? = nil
    @ViewBuilder let destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(Typography.body)
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 12)
                if let value {
                    Text(value)
                        .font(Typography.body)
                        .foregroundStyle(Theme.secondaryText)
                        .monospacedDigit()
                }
                SettingsChevron()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// アプリの外(Safari)で開く行。
struct SettingsExternalLinkRow: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Text(title)
                    .font(Typography.body)
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 12)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 値を読むだけの行。
struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(Typography.body)
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
    }
}

/// 行全体を押す操作。押せない時は理由を `detail` に書く。
struct SettingsButtonRow: View {
    enum Tone {
        case primary, secondary, destructive
    }

    let title: String
    var detail: String? = nil
    var tone: Tone = .primary
    /// 行の右に置く SF Symbol。
    var systemImage: String? = nil
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typography.body)
                        .foregroundStyle(titleColor)
                    if let detail {
                        Text(detail)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                if let systemImage {
                    if systemImage == SettingsChevron.symbolName {
                        SettingsChevron()
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var titleColor: Color {
        if disabled { return Theme.secondaryText }
        switch tone {
        case .primary: return Theme.primaryText
        case .secondary: return Theme.secondaryText
        case .destructive: return Theme.regressColor
        }
    }
}

/// 問題が起きている時だけホームの一番上に出す知らせ。
struct SettingsNotice: View {
    let title: String
    let detail: String
    var actionTitle: String? = nil
    var actionDisabled: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.body)
                    .foregroundStyle(Theme.primaryText)
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Theme.primaryText.opacity(0.09), in: Capsule())
                    .buttonStyle(.plain)
                    .disabled(actionDisabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.card, in: shape)
        .overlay { shape.strokeBorder(Theme.regressColor.opacity(0.35), lineWidth: 1) }
    }
}

/// 進む行の右の矢印。
struct SettingsChevron: View {
    static let symbolName: String = "chevron.right"

    var body: some View {
        Image(systemName: Self.symbolName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.tertiaryText)
    }
}

extension View {
    /// 設定の行を載せる面。影は付けず、1px の縁だけで地から分ける。
    func settingsCard(cornerRadius: CGFloat = Theme.Radius.cardLarge) -> some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Theme.card, in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Theme.hairline, lineWidth: 1) }
    }
}
