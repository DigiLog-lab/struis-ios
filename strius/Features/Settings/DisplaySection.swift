import SwiftUI

struct DisplaySection: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("表示").font(Typography.title)
                Text("テーマと外観の設定")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                row(title: "テーマ", detail: "システム設定に追従")
                divider
                row(title: "ライトモード時の文字", detail: "標準")
                divider
                row(title: "ダイナミックタイプ", detail: "システム設定")
            }
            .glassSurface(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
        }
    }

    private func row(title: String, detail: String) -> some View {
        HStack {
            Text(title).font(Typography.bodyEmphasized)
            Spacer()
            Text(detail)
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary(scheme))
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
