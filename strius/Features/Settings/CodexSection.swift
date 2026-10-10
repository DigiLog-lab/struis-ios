import SwiftUI

struct CodexSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(spacing: 0) {
                statusRow
                divider
                if settings.account?.isConnected == true {
                    syncRow
                    divider
                    disconnectRow
                } else {
                    connectRow
                }
                if let pending = settings.account, pending.status == .connecting, let code = pending.userCode {
                    divider
                    verificationRow(code: code, url: pending.verificationURL)
                }
                if let message = settings.errorMessage {
                    divider
                    errorRow(message)
                }
            }
            .glassSurface(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ChatGPT / Codex").font(Typography.title)
            Text("自分のChatGPT (Plus / Pro / Team) を Struis に接続する")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
        }
        .padding(.horizontal, 4)
    }

    private var statusRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("接続状態").font(Typography.bodyEmphasized)
                Text(statusText).font(Typography.caption).foregroundStyle(Theme.textSecondary(scheme))
            }
            Spacer()
            statusPill
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var statusPill: some View {
        let connected = settings.account?.isConnected == true
        return HStack(spacing: 6) {
            Circle()
                .fill(connected ? Theme.growth(scheme) : Theme.textTertiary(scheme))
                .frame(width: 8, height: 8)
            Text(connected ? "接続済み" : "未接続")
                .font(Typography.caption)
                .foregroundStyle(Theme.textPrimary(scheme))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(.thin, in: Capsule())
    }

    private var statusText: String {
        guard let account = settings.account else { return "未取得" }
        switch account.status {
        case .connected:
            if let plan = CodexPlanName.display(account.planType) { return "\(plan) で接続中" }
            return "接続中"
        case .rateLimited: return "レート制限中"
        case .connecting: return "接続待ち"
        case .disconnected: return "未接続"
        case .error: return account.error ?? "エラー"
        }
    }

    private var connectRow: some View {
        Button { Task { await settings.connect() } } label: {
            HStack {
                Image(systemName: "sparkles")
                Text("ChatGPT / Codex に接続").font(Typography.bodyEmphasized)
                Spacer()
                if settings.busy {
                    ProgressView().progressViewStyle(StruisProgressViewStyle()).controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
        .disabled(settings.busy)
    }

    private var syncRow: some View {
        Button { Task { await settings.sync() } } label: {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("使用量を同期").font(Typography.bodyEmphasized)
                Spacer()
                if let synced = settings.account?.lastSyncedAt {
                    Text(synced.formatted(date: .omitted, time: .shortened))
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .disabled(settings.busy)
    }

    private var disconnectRow: some View {
        Button { Task { await settings.disconnect() } } label: {
            HStack {
                Text("接続解除").font(Typography.bodyEmphasized).foregroundStyle(Theme.regress(scheme))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .disabled(settings.busy)
    }

    private func verificationRow(code: String, url: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("認証コード").font(Typography.caption).foregroundStyle(Theme.textSecondary(scheme))
            Text(code).font(.system(size: 22, weight: .semibold, design: .monospaced))
            if let url, let link = URL(string: url) {
                Link("認証ページを開く", destination: link)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.accent(scheme))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func errorRow(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.regress(scheme))
            Text(message)
                .font(Typography.caption)
                .foregroundStyle(Theme.regress(scheme))
                .multilineTextAlignment(.leading)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.separator(scheme))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}
