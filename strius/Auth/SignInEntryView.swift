import SwiftUI

struct SignInEntryView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 12) {
                    // ロゴマーク＋brandName(2026-10-30 に斜体のセリフ体をやめた)。
                    StruisBrandHeader()
                        .padding(.bottom, 4)

                    Text("つまずきの根を、ひとつずつほどく。")
                        .font(Typography.heading2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textPrimary(scheme))
                        .padding(.horizontal, 32)

                    Text("わからない、を入口に。\nあなたの教科書に寄り添う、静かな伴走者です。")
                        .font(Typography.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textSecondary(scheme))
                        .padding(.horizontal, 32)
                }

                Spacer()

                VStack(spacing: 14) {
                    if case .restoreFailed(let message) = auth.status {
                        Text(message)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.regress(scheme))
                            .multilineTextAlignment(.center)

                        Button {
                            Task { await auth.retrySessionRestore() }
                        } label: {
                            Text("もう一度確認")
                                .font(Typography.bodyEmphasized)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .foregroundStyle(.white)
                        }
                        .background(Theme.accent(scheme), in: Capsule())
                    } else {
                        if let diagnostic = auth.sessionDiagnostic {
                            Text(diagnostic)
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary(scheme))
                                .multilineTextAlignment(.center)
                        }

                        Button {
                            Task { await auth.login() }
                        } label: {
                            Text("ログイン")
                                .font(Typography.bodyEmphasized)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .foregroundStyle(.white)
                        }
                        .background(Theme.accent(scheme), in: Capsule())

                        Button {
                            Task { await auth.login(screenHint: "signup") }
                        } label: {
                            Text("アカウントを作成")
                                .font(Typography.bodyEmphasized)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .foregroundStyle(Theme.textPrimary(scheme))
                        }
                        .glassSurface(.regular, in: Capsule())

                        if case .failed(let message) = auth.status {
                            Text(message)
                                .font(Typography.caption)
                                .foregroundStyle(Theme.regress(scheme))
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
            }
            .padding(.top, 64)
        }
    }
}

#if DEBUG
#Preview {
    let client = APIClient()
    let auth = AuthStore(client: client)
    SignInEntryView()
        .environment(auth)
}
#endif
