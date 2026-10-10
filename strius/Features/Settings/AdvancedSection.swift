import SwiftUI

struct AdvancedSection: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("詳細設定").font(Typography.title)
                Text("端末に残るデータの管理")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                row(title: "下書き", detail: "未送信の入力を破棄")
                divider
                row(title: "オフラインキャッシュ", detail: "Web版でのみ利用")
            }
            .glassSurface(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
        }
    }

    private func row(title: String, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.bodyEmphasized)
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
            }
            Spacer()
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
