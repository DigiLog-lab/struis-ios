import Foundation
import OSLog
import SwiftUI

private let sceneChatLog = Logger(subsystem: "com.digiloglab.strius", category: "scene-chat")

/// シーン専用の文脈 chat ストア。
/// シーンごとに thread を lazy 作成し (`source: "immersion_scene"`)、
/// chip が有効なら `immersion_scene_context` を添えて送信する。
/// アシスタント応答は送信後のポーリングで受け取る (realtime 購読は
/// メイン ChatStore が占有しているため、trial ではポーリングに寄せる)。
@Observable
@MainActor
final class SceneChatStore {
    private(set) var messages: [ChatMessage] = []
    private(set) var threadID: UUID?
    private(set) var isSending = false
    private(set) var sendError: String?

    /// 一度でも質問したか (パネル再表示の判断に使う)。
    var hasConversation: Bool { !messages.isEmpty }

    private let client: APIClient
    private let sceneID: String
    private let threadTitle: String
    private var pollTask: Task<Void, Never>?

    init(client: APIClient, sceneID: String, threadTitle: String) {
        self.client = client
        self.sceneID = sceneID
        self.threadTitle = threadTitle
    }

    @discardableResult
    func send(
        text rawText: String,
        stage: String,
        prediction: ScenePrediction?,
        includeSceneContext: Bool
    ) async -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return false }

        if Self.usesSimulatorFixtures {
            appendFixtureExchange(text: text)
            return true
        }

        isSending = true
        sendError = nil
        defer { isSending = false }

        do {
            let thread = try await ensureThread()
            messages.append(
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    status: .completed,
                    plainText: text,
                    blocks: [],
                    metadata: nil,
                    createdAt: Date(),
                    completedAt: Date()
                )
            )
            let context: ImmersionSceneContext? = includeSceneContext
                ? ImmersionSceneContext(
                    sceneID: sceneID,
                    stage: stage,
                    prediction: prediction.map {
                        switch $0 {
                        case .number(let value): .number(value)
                        case .text(let value): .text(value)
                        }
                    }
                )
                : nil
            let response: CreateMessageResponse = try await client.send(
                .postMessage(threadID: thread.uuidString),
                body: CreateMessageRequest(text: text, immersionSceneContext: context)
            )
            if !messages.contains(where: { $0.id == response.assistantMessageId }) {
                messages.append(
                    ChatMessage(
                        id: response.assistantMessageId,
                        role: .assistant,
                        status: .pending,
                        plainText: nil,
                        blocks: [],
                        metadata: nil,
                        createdAt: Date(),
                        completedAt: nil
                    )
                )
            }
            startPollingUntilSettled(thread: thread)
            return true
        } catch {
            sceneChatLog.error("scene chat send failed: \(String(describing: error))")
            sendError = Self.message(for: error)
            if let threadID {
                await refreshMessages(for: threadID)
            }
            return false
        }
    }

    func clearSendError() {
        sendError = nil
    }

    // MARK: - 内部

    private func ensureThread() async throws -> UUID {
        if let threadID { return threadID }
        let created: CreateThreadResponse = try await client.send(
            .createThread,
            body: CreateThreadRequest(title: threadTitle, source: "immersion_scene")
        )
        threadID = created.id
        return created.id
    }

    /// 最後の assistant メッセージが完了するまで再取得を続ける。
    private func startPollingUntilSettled(thread: UUID) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(180)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self else { return }
                await self.refreshMessages(for: thread)
                let pending = await MainActor.run {
                    self.messages.contains { $0.role == .assistant && $0.status == .pending }
                }
                if !pending { return }
            }
        }
    }

    private func refreshMessages(for id: UUID) async {
        do {
            let payload: [ChatMessage] = try await client.send(.listMessages(threadID: id.uuidString))
            guard threadID == id else { return }
            messages = payload.sorted { $0.createdAt < $1.createdAt }
        } catch {
            sceneChatLog.error("scene chat refresh failed: \(String(describing: error))")
        }
    }

    private func appendFixtureExchange(text: String) {
        messages.append(
            ChatMessage(
                id: UUID(),
                role: .user,
                status: .completed,
                plainText: text,
                blocks: [],
                metadata: nil,
                createdAt: Date(),
                completedAt: Date()
            )
        )
        let pendingID = UUID()
        messages.append(
            ChatMessage(
                id: pendingID,
                role: .assistant,
                status: .pending,
                plainText: nil,
                blocks: [],
                metadata: nil,
                createdAt: Date(),
                completedAt: nil
            )
        )
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                if let index = self.messages.firstIndex(where: { $0.id == pendingID }) {
                    self.messages[index] = ChatMessage(
                        id: pendingID,
                        role: .assistant,
                        status: .completed,
                        plainText: "いま画面で動かしたものを、もう一度ゆっくり動かしてみて。どこで予想とずれ始めましたか。",
                        blocks: [],
                        metadata: nil,
                        createdAt: Date(),
                        completedAt: Date()
                    )
                }
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized: return "ログインし直すと続けられます"
            case .transport: return "ネットワークに接続できません"
            case .server(let status, _): return "サーバーエラー (\(status))"
            case .decoding, .invalidResponse: return "サーバー応答を読み取れませんでした"
            }
        }
        return error.localizedDescription
    }

    private static var usesSimulatorFixtures: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["STRUIS_IOS_USE_FIXTURES"] == "0" {
            return false
        }
        return true
        #else
        false
        #endif
    }
}

// MARK: - Chat pane (canvas 領域に並存するタイムライン)

/// chat 並存時に canvas 領域へ重なるタイムライン。canvas はこの下でマウント
/// 維持されており、「学習に戻る」で同じ状態に戻る。
struct SceneChatPane: View {
    let store: SceneChatStore

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            if let sendError = store.sendError {
                Text(sendError)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.regress(scheme))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .glassSurface(.thin, in: Capsule())
                    .padding(.top, 8)
            }
            ChatTimeline(messages: store.messages, threadID: store.threadID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scene-chat-pane")
    }
}

// MARK: - 実 composer (常設・chip 着脱)

/// 没頭シェルの常設 composer (実働)。
/// chip on = 「この画面について」の文脈 chat、off = 「別のことを聞く」。
struct SceneChatComposer: View {
    @Binding var text: String
    @Binding var contextChipOn: Bool
    let isSending: Bool
    let onSend: () -> Void
    let onFocus: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if contextChipOn {
                HStack(spacing: 6) {
                    Text("この画面について")
                    Button {
                        withAnimation(.easeInOut(duration: Theme.Duration.quick)) { contextChipOn = false }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Theme.accent(scheme).opacity(0.18), in: Circle())
                    }
                }
                .font(Typography.micro.weight(.medium))
                .foregroundStyle(Theme.accent(scheme))
                .padding(.leading, 11)
                .padding(.trailing, 6)
                .frame(height: 26)
                .background(Theme.accent(scheme).opacity(0.14), in: Capsule())
            } else {
                HStack(spacing: 8) {
                    Button("この画面について") {
                        withAnimation(.easeInOut(duration: Theme.Duration.quick)) { contextChipOn = true }
                    }
                    .font(Typography.micro)
                    .foregroundStyle(Theme.textTertiary(scheme))
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .overlay(Capsule().stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Theme.textTertiary(scheme).opacity(0.6)))
                    Text("別のことを聞く")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }

            HStack(spacing: 8) {
                TextField("聞きたいことを書く", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .font(Typography.bodyCompact)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($isFocused)
                    .onChange(of: isFocused) { _, focused in
                        if focused { onFocus() }
                    }
                    .onSubmit(submit)
                    .accessibilityIdentifier("scene-composer-input")
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(canSend ? Theme.textOnAccent(scheme) : .white)
                        .frame(width: 38, height: 38)
                        .background(
                            canSend ? Theme.accent(scheme) : Theme.textPrimary(scheme).opacity(0.18),
                            in: Circle()
                        )
                }
                .disabled(!canSend)
                .accessibilityLabel("送信")
                .accessibilityIdentifier("scene-composer-send")
            }
        }
        .padding(.top, 7)
        .padding(.bottom, 8)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .glassSurface(.thin, in: RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous))
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func submit() {
        guard canSend else { return }
        onSend()
    }
}
