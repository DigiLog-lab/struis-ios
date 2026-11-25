#if DEBUG || STRUIS_INTERNAL
import SwiftUI
import UIKit

/// 開発者向けの「ChatGPT でサインイン」の状態(画面どうしで共有する)。内部の配布と Debug だけ。
@MainActor @Observable
final class ChatGPTSettingsModel {
    static let shared = ChatGPTSettingsModel()

    private(set) var credentials: ChatGPTCredentials? = ChatGPTAccount.current
    private(set) var models: [ChatGPTAccount.Model] = []
    private(set) var signingIn = false
    private(set) var signInFailed: String?
    private(set) var lastFailure: ChatGPTFailureLog.Entry? = ChatGPTFailureLog.last
    var prefersChatGPT: Bool = ChatGPTPreferences.prefersChatGPT {
        didSet { ChatGPTPreferences.prefersChatGPT = prefersChatGPT }
    }
    var model: String? = ChatGPTPreferences.model {
        didSet { ChatGPTPreferences.model = model }
    }

    var isSignedIn: Bool { credentials?.canUsePlan == true }
    /// ChatGPT に送っている(選んでいて、サインインしている)。
    var isActive: Bool { prefersChatGPT && isSignedIn }

    private var signIn: ChatGPTSignIn?

    init() {
        #if DEBUG
        // 画面の確認用(`STRUIS_CHATGPT_PREVIEW=signed-in`): サインインした後の画面を、本物の OpenAI に繋がずに出す。
        if ProcessInfo.processInfo.environment["STRUIS_CHATGPT_PREVIEW"] == "signed-in" {
            credentials = ChatGPTCredentials(clientID: "oaiapp_preview", accessToken: "", refreshToken: "", expiresAt: .distantFuture,
                                             scopes: [ChatGPTConfig.planScope], email: "student@example.com")
            models = [ChatGPTAccount.Model(slug: "model-a", displayName: "[モデル A]"), ChatGPTAccount.Model(slug: "model-b", displayName: "[モデル B]")]
            model = "model-a"
            prefersChatGPT = true
            lastFailure = ChatGPTFailureLog.Entry(at: Date(), summary: "上限に達しました", detail: "preview")
        }
        #endif
    }

    func startSignIn() {
        guard !signingIn else { return }
        signingIn = true
        signInFailed = nil
        let flow = ChatGPTSignIn()
        signIn = flow
        Task {
            defer {
                signingIn = false
                signIn = nil
            }
            do {
                credentials = try await flow.run()
                await loadModels()
            } catch ChatGPTSignIn.Failure.cancelled {
                // 利用者が取りやめた時は何も出さない。
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                signInFailed = text
                ChatGPTFailureLog.record(summary: "サインインできませんでした", detail: "sign-in\n\(text)")
            }
        }
    }

    func signOut() {
        Task {
            await ChatGPTAccount.shared.signOut()
            credentials = nil
            models = []
            prefersChatGPT = false
        }
    }

    /// このアカウントで使えるモデルを取ってくる。選んでいなければ最初のものにする。
    func loadModels() async {
        guard isSignedIn, credentials?.clientID != "oaiapp_preview" else { return }
        do {
            models = try await ChatGPTAccount.shared.models()
            if model.map({ selected in !models.contains { $0.slug == selected } }) ?? true { model = models.first?.slug }
            credentials = ChatGPTAccount.current
        } catch {
            ChatGPTFailureLog.record(summary: "モデルを取れませんでした", detail: "models\n\((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
        }
    }

    func refreshFailure() { lastFailure = ChatGPTFailureLog.last }

    /// 画面に出すモデルの名前。
    var modelName: String {
        guard let model else { return "未選択" }
        return models.first { $0.slug == model }?.displayName ?? model
    }
}

/// 開発者向け: ChatGPT のサインイン・モデル・直近の失敗。
struct ChatGPTSettingsView: View {
    @State private var model = ChatGPTSettingsModel.shared
    @State private var copied = false

    var body: some View {
        SettingsScreen(title: "ChatGPT") {
            if model.isSignedIn {
                signedIn
            } else {
                signedOut
            }
        }
        .task { if model.isSignedIn, model.models.isEmpty { await model.loadModels() } }
        .onReceive(NotificationCenter.default.publisher(for: .chatGPTFailureRecorded)) { _ in model.refreshFailure() }
    }

    @ViewBuilder
    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                SettingsButtonRow(title: model.signingIn ? "サインインしています" : "ChatGPT でサインイン", systemImage: "arrow.up.right",
                                  disabled: model.signingIn) { model.startSignIn() }
                    .accessibilityIdentifier("settings-chatgpt-sign-in")
            }
            .settingsCard()
            if model.signInFailed != nil {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.regressColor)
                    Text("サインインできませんでした")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings-chatgpt-sign-in-failed")
            }
        }
    }

    @ViewBuilder
    private var signedIn: some View {
        VStack(spacing: 0) {
            SettingsValueRow(title: "アカウント", value: model.credentials?.email ?? model.credentials?.name ?? "接続済み")
                .accessibilityIdentifier("settings-chatgpt-account")
        }
        .settingsCard()

        SettingsSection(header: "モデル") {
            if model.models.isEmpty {
                SettingsValueRow(title: "読み込んでいます", value: "")
            }
            ForEach(Array(model.models.enumerated()), id: \.element.id) { index, item in
                if index > 0 { SettingsDivider() }
                Button {
                    model.model = item.slug
                } label: {
                    HStack(spacing: 12) {
                        Text(item.displayName)
                            .font(Typography.body)
                            .foregroundStyle(Theme.primaryText)
                        Spacer(minLength: 12)
                        if model.model == item.slug {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.accentColor)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.model == item.slug ? .isSelected : [])
                .accessibilityIdentifier("settings-chatgpt-model-\(item.slug)")
            }
        }

        if let failure = model.lastFailure {
            SettingsSection(header: "直近の失敗") {
                HStack(spacing: 12) {
                    Text(failure.summary)
                        .font(Typography.body)
                        .foregroundStyle(Theme.primaryText)
                    Spacer(minLength: 12)
                    Text(failure.at.formatted(date: .omitted, time: .shortened))
                        .font(Typography.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                SettingsDivider()
                SettingsButtonRow(title: copied ? "コピーしました" : "詳細をコピー", tone: .secondary) {
                    UIPasteboard.general.string = "\(failure.at.ISO8601Format())\n\(failure.summary)\n\(failure.detail)"
                    copied = true
                }
                .accessibilityIdentifier("settings-chatgpt-copy-failure")
            }
        }

        VStack(spacing: 0) {
            SettingsButtonRow(title: "サインアウト", tone: .destructive) { model.signOut() }
                .accessibilityIdentifier("settings-chatgpt-sign-out")
        }
        .settingsCard()
    }
}

/// ChatGPT の利用上限で止まった時の案内(内部の配布だけ)。自動では Claude に戻さず、押した時だけ戻す。
/// 単元の全画面や設定のシートが出ていても見えるように、いちばん上に出ている画面からシートで出す。
private struct ChatGPTLimitGuide: ViewModifier {
    func body(content: Content) -> some View {
        content
            #if DEBUG
            .task {
                // 画面の確認用(`STRUIS_CHATGPT_PREVIEW=limit`)。
                if ProcessInfo.processInfo.environment["STRUIS_CHATGPT_PREVIEW"] == "limit" {
                    try? await Task.sleep(for: .seconds(3))
                    ChatGPTLimitPresenter.present()
                }
            }
            #endif
            .onReceive(NotificationCenter.default.publisher(for: .chatGPTLimitReached)) { _ in ChatGPTLimitPresenter.present() }
    }
}

@MainActor
enum ChatGPTLimitPresenter {
    static func present() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        guard !(top is UIHostingController<ChatGPTLimitSheet>) else { return }
        let holder = WeakController()
        let host = UIHostingController(rootView: ChatGPTLimitSheet { holder.controller?.dismiss(animated: true) })
        holder.controller = host
        if let controller = host.sheetPresentationController {
            controller.detents = [.custom { _ in 230 }]
            controller.prefersGrabberVisible = true
        }
        top.present(host, animated: true)
    }
}

private final class WeakController {
    weak var controller: UIViewController?
}

struct ChatGPTLimitSheet: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("ChatGPT の上限に達しました")
                .font(Typography.sans(size: 17, weight: .bold, relativeTo: .headline))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                OnboardingPrimaryButton(title: "Claude に切り替える", identifier: "chatgpt-limit-switch") {
                    ChatGPTSettingsModel.shared.prefersChatGPT = false
                    close()
                }
                Button(action: close) {
                    Text("閉じる")
                        .font(Typography.body)
                        .foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.accentColor.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chatgpt-limit-close")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.card.ignoresSafeArea())
        .accessibilityIdentifier("chatgpt-limit-sheet")
    }
}

extension View {
    /// ChatGPT の上限で止まったら案内のシートを出す。
    func chatGPTLimitGuide() -> some View {
        modifier(ChatGPTLimitGuide())
    }
}
#endif
