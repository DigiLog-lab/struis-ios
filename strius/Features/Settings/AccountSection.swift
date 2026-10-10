import SwiftUI

struct AccountSection: View {
    let displayName: String
    let email: String
    let onLogout: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("アカウント", subtitle: "Struisに表示される学習者情報")

            VStack(spacing: 0) {
                row {
                    HStack(spacing: 12) {
                        avatar
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName).font(Typography.bodyEmphasized)
                            Text(email.isEmpty ? "メール未設定" : email)
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary(scheme))
                        }
                    }
                }
                divider
                row {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("この端末からログアウト").font(Typography.bodyEmphasized)
                        Text("保存済みの学習データは削除されません")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary(scheme))
                    }
                    Spacer()
                    Button("ログアウト", action: onLogout)
                        .font(Typography.bodyEmphasized)
                        .foregroundStyle(Theme.regress(scheme))
                }
            }
            .glassSurface(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
        }
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(Theme.accent(scheme).opacity(0.18)).frame(width: 40, height: 40)
            Text(String(displayName.prefix(1)).uppercased())
                .font(Typography.bodyEmphasized)
                .foregroundStyle(Theme.accent(scheme))
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typography.title)
            Text(subtitle).font(Typography.caption).foregroundStyle(Theme.textSecondary(scheme))
        }
        .padding(.horizontal, 4)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 0) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.separator(scheme))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}
