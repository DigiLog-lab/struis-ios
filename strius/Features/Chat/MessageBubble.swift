import SwiftUI
import UIKit
import Foundation

struct MessageBubble: View {
    let message: ChatMessage
    let threadID: UUID?
    var onProposalStarted: ((WorkbookProposalDTO) -> Void)?
    /// 先頭から何個の数式・強調に淡い面の色をつけるか(§6)。
    var highlightCount = 0
    /// 色をつけている間、吹き出しの位置を知らせる(例題バーへ運ぶチップの出どころ)。
    var onHighlightFrame: ((CGRect) -> Void)?
    /// 止まった返事の後に次の返事が来た(D15)。「停止しました。」を小さな 1 行に畳み、「送り直す」を出さない。
    var folded = false

    @Environment(\.colorScheme) private var scheme
    /// Optional so previews and screens without the chat store still render.
    @Environment(ChatStore.self) private var chat: ChatStore?

    init(
        message: ChatMessage, threadID: UUID? = nil, onProposalStarted: ((WorkbookProposalDTO) -> Void)? = nil,
        highlightCount: Int = 0, onHighlightFrame: ((CGRect) -> Void)? = nil, folded: Bool = false
    ) {
        self.folded = folded
        self.threadID = threadID
        self.message = message
        self.onProposalStarted = onProposalStarted
        self.highlightCount = highlightCount
        self.onHighlightFrame = onHighlightFrame
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if message.role == .user { Spacer(minLength: 36) }
            bubble
            if message.role != .user { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            if folded {
                foldedReply
            } else if message.status == .pending {
                // §7 返事待ち(要点・例題の起動も同じ。A1): 空の吹き出しではなく、「考えています」の行(実際の出来事で差し替える)と
                // 書かれている本文を出す(信頼性計画 P2 の 2)。
                ChatLiveReply(
                    messageID: message.id, startedAt: message.turnCreatedAt ?? message.createdAt,
                    onStop: chat.map { chat in { Task { await chat.interrupt() } } }
                )
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if message.status == .completed, message.answersLearner, let seconds = message.thinkingSeconds {
                        ChatThoughtLabel(seconds: seconds)
                    }
                    assistantBubble
                    retryButton
                }
            }
        case .system:
            systemBubble
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(message.attachmentBlocks.enumerated()), id: \.offset) { _, block in
                rendered(block)
            }
            if !message.textualDisplayText.isEmpty {
                KaTeXMathText(
                    message.textualDisplayText,
                    foregroundColor: Self.textOnAccentColor(scheme),
                    fontSize: 15,
                    fontWeight: 500
                )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.accent(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
            }
        }
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.status == .pending {
                pendingIndicator
            } else if !message.renderableBlocks.isEmpty {
                ForEach(Array(message.renderableBlocks.enumerated()), id: \.offset) { index, block in
                    rendered(block, highlightCount: index == 0 ? highlightCount : 0)
                }
            } else {
                Text("…")
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary(scheme))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityIdentifier("assistant-message-\(message.id.uuidString)")
        .frame(maxWidth: .infinity, alignment: .leading)
        .struisSurface(radius: Theme.Radius.bubble)
        .modifier(HighlightFrameReporter(onFrame: onHighlightFrame))
        .modifier(WorkbookProposalAttachment(proposalID: message.workbookProposalID, onStarted: onProposalStarted))
    }

    /// 次の返事が来た後の、止まった返事(D15)。モデルは続けて送られた文をまとめて踏まえて答えるので、
    /// 送り直しを促さず、止まったことだけを小さく残す。
    private var foldedReply: some View {
        Label {
            Text((message.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "停止しました" : message.plainText ?? "")
                .lineLimit(1)
        } icon: {
            Image(systemName: "stop.circle")
        }
        .font(Typography.caption)
        .foregroundStyle(Theme.textTertiary(scheme))
        .padding(.horizontal, 4)
        .accessibilityIdentifier("assistant-folded-\(message.id.uuidString)")
    }

    /// 「送り直す」 under a reply that stopped or failed (E2E H1・H3).
    @ViewBuilder
    private var retryButton: some View {
        if message.isRetryable, let chat {
            Button {
                Task { await chat.retry(assistantMessageID: message.id) }
            } label: {
                Label("送り直す", systemImage: "arrow.clockwise")
                    .font(Typography.bodyEmphasized)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("assistant-retry-\(message.id.uuidString)")
        }
    }

    @ViewBuilder
    private func rendered(_ block: RenderableMessageBlock, highlightCount: Int = 0) -> some View {
        switch block {
        case .text(let text):
            KaTeXMathText(readableAssistantText(text), foregroundColor: Self.textPrimaryColor(scheme), highlightCount: highlightCount)
        case .math(let latex, let display):
            KaTeXMathText(
                latex,
                display: display,
                foregroundColor: Self.textPrimaryColor(scheme),
                fontSize: 15,
                fontWeight: 500
            )
                .padding(.vertical, display ? 4 : 0)
        case .notice(let title, let body):
            VStack(alignment: .leading, spacing: 4) {
                if !title.isEmpty {
                    Text(title)
                        .font(Typography.bodyEmphasized)
                }
                KaTeXMathText(body, foregroundColor: Self.textPrimaryColor(scheme))
            }
            .foregroundStyle(Theme.textPrimary(scheme))
        case .image(let assetPath, let caption):
            RemoteMessageImage(assetPath: assetPath, caption: caption)
        case .file(let filename, let contentType, let bytes):
            MessageFileAttachment(filename: filename, contentType: contentType, bytes: bytes)
        }
    }

    /// この吹き出しが描く数式の本文と、その幅(`KaTeXPrefetcher` で画面に出る前に高さを測る)。`rendered` と同じ本文・色・大きさ。
    /// `timelineWidth` は会話の行の幅(左右の余白を除いたもの)。
    @MainActor
    static func katexItems(_ message: ChatMessage, scheme: ColorScheme, timelineWidth: CGFloat) -> [KaTeXPrefetcher.Item] {
        let padding: CGFloat = 28
        switch message.role {
        case .user:
            let text = message.textualDisplayText
            guard !text.isEmpty else { return [] }
            return [KaTeXPrefetcher.Item(raw: text, display: false, color: textOnAccentColor(scheme), fontSize: 15, fontWeight: 500,
                                         width: timelineWidth - 36 - padding)]
        case .assistant:
            guard message.status != .pending else { return [] }
            let width = timelineWidth - padding
            let color = textPrimaryColor(scheme)
            return message.renderableBlocks.compactMap { block in
                switch block {
                case .text(let text):
                    KaTeXPrefetcher.Item(raw: ChatTextReadability.formatAssistantText(text), display: false, color: color, fontSize: 15, fontWeight: 500, width: width)
                case .math(let latex, let display):
                    KaTeXPrefetcher.Item(raw: latex, display: display, color: color, fontSize: 15, fontWeight: 500, width: width)
                case .notice(_, let body):
                    KaTeXPrefetcher.Item(raw: body, display: false, color: color, fontSize: 15, fontWeight: 500, width: width)
                default:
                    nil
                }
            }
        case .system:
            return []
        }
    }

    private func readableAssistantText(_ text: String) -> String {
        message.role == .assistant ? ChatTextReadability.formatAssistantText(text) : text
    }

    private var systemBubble: some View {
        Text(message.plainText ?? "")
            .font(Typography.caption)
            .foregroundStyle(Theme.textTertiary(scheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
    }

    private var pendingIndicator: some View {
        ProgressView().progressViewStyle(StruisProgressViewStyle())
            .controlSize(.small)
    }

    static func textPrimaryColor(_ scheme: ColorScheme) -> UIColor {
        scheme == .dark
            ? UIColor(red: 0.953, green: 0.910, blue: 0.831, alpha: 1)
            : UIColor(red: 0.122, green: 0.102, blue: 0.078, alpha: 1)
    }

    private static func textOnAccentColor(_ scheme: ColorScheme) -> UIColor {
        scheme == .dark
            ? UIColor(red: 0.063, green: 0.071, blue: 0.078, alpha: 1)
            : UIColor.white
    }
}

private enum RenderableMessageBlock: Hashable {
    case text(String)
    case math(String, display: Bool)
    case notice(title: String, body: String)
    case image(assetPath: String, caption: String?)
    case file(filename: String, contentType: String?, bytes: Double?)
}

private extension ChatMessage {
    var displayText: String {
        if let text = plainText, !text.isEmpty { return text }
        return renderableBlocks.compactMap(\.plainPreview).joined(separator: "\n\n")
    }

    var renderableBlocks: [RenderableMessageBlock] {
        let normalized = blocks.compactMap(\.renderable)
        if let text = plainText,
           !text.isEmpty,
           !normalized.contains(where: \.providesNarrativeText) {
            return [.text(text)] + normalized
        }
        if !normalized.isEmpty { return normalized }
        if status == .failed {
            return [.notice(title: "応答を生成できませんでした", body: "少し時間をおいて、もう一度送信してください。")]
        }
        return []
    }

    var textualDisplayText: String {
        if let text = plainText, !text.isEmpty { return text }
        return renderableBlocks
            .filter { !$0.isAttachment }
            .compactMap(\.plainPreview)
            .joined(separator: "\n\n")
    }

    var attachmentBlocks: [RenderableMessageBlock] {
        renderableBlocks.filter(\.isAttachment)
    }
}

enum ChatTextReadability {
    static func formatAssistantText(_ value: String) -> String {
        let text = bulletize(emboldenHeadings(value
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        guard !text.isEmpty, !text.contains("\n") else { return text }

        let units = splitSentenceUnits(text)
        guard units.count > 1 else { return text }

        let totalLength = units.reduce(0) { $0 + $1.count }
        return units.count >= 3 || totalLength > 70 ? units.joined(separator: "\n") : text
    }

    /// Markdown の見出し(行頭の `# ` 〜 `###### `)を強調(`**…**`)の 1 行にする。テキスト表示と数式の WebView 表示は
    /// 強調だけを読むので、見出しの `#` が文字のまま出ないようにここで直す。
    static func emboldenHeadings(_ text: String) -> String {
        guard text.contains("#") else { return text }
        return text.components(separatedBy: "\n").map { line in
            let body = line.drop { $0 == " " }
            let level = body.prefix { $0 == "#" }.count
            guard (1...6).contains(level), body.dropFirst(level).first == " " else { return line }
            let title = body.dropFirst(level).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "")
            return title.isEmpty ? line : "**" + title + "**"
        }.joined(separator: "\n")
    }

    /// Markdown の箇条書き(行頭の `- ` / `* ` / `+ `)を「•」にする。テキスト表示と数式の WebView 表示の
    /// 両方が同じ文字列を描くので、ここで直せば両方で箇条書きになる。入れ子は全角の字下げで表す。
    static func bulletize(_ text: String) -> String {
        guard text.contains("- ") || text.contains("* ") || text.contains("+ ") else { return text }
        return text.components(separatedBy: "\n").map { line in
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let body = line.dropFirst(indent)
            guard body.count > 2, let first = body.first, "-*+".contains(first), body.dropFirst().first == " " else { return line }
            let rest = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return line }
            // 箇条書きにするのは日本語で始まる項目と、数式の区切り(`$`、`\(`、`\[`)・強調(`**`)で始まる項目(D6:
            // `- $D>0$: 異なる 2 つの実数解`)。区切りの外にある `-` は符号ではなく箇条書きの印。
            // 区切りの無い式で始まる行(`- 3x + 6 = 0`、`+ 2`、`- sin x`、`- x は 3 より小さい`、`+ 2 を両辺に足す`)は、
            // 行頭の演算子で始まる式として、そのまま残す(符号を消さない)。
            guard let head = rest.first,
                  Self.containsJapanese(String(head)) || Self.startsWithMarkup(rest)
            else { return line }
            return String(repeating: "\u{3000}", count: min(indent / 2, 3)) + "• " + rest
        }.joined(separator: "\n")
    }

    /// 数式の区切りか強調で始まる(箇条書きの項目の頭)。
    private static func startsWithMarkup(_ text: String) -> Bool {
        text.hasPrefix("$") || text.hasPrefix("\\(") || text.hasPrefix("\\[") || text.hasPrefix("**")
    }

    private static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3000...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value)
        }
    }

    private static func splitSentenceUnits(_ value: String) -> [String] {
        var units: [String] = []
        var current = ""
        for character in value {
            current.append(character)
            if sentenceTerminators.contains(character) {
                let unit = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !unit.isEmpty { units.append(unit) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { units.append(rest) }
        return units
    }

    private static let sentenceTerminators: Set<Character> = ["。", "！", "？", "!", "?"]
}

private extension MessageBlock {
    var renderable: RenderableMessageBlock? {
        switch kind {
        case "text", "markdown":
            guard let text = payload.textValue else { return nil }
            return .text(text)
        case "math":
            guard let latex = payload.firstString(for: ["latex", "content_latex", "text"]) else { return nil }
            return .math(latex, display: payload.boolValue(for: "display") ?? true)
        case "system_notice":
            let title = payload.firstString(for: ["title"]) ?? ""
            let body = payload.firstString(for: ["body", "text"]) ?? ""
            return .notice(title: title, body: body)
        case "problem_card", "problem":
            let title = payload.firstString(for: ["source", "title"]) ?? "Problem"
            let body = payload.firstString(for: ["body", "prompt"]) ?? ""
            let note = payload.firstString(for: ["note"])
            return .notice(title: title, body: [body, note].compactMap { $0 }.joined(separator: "\n\n"))
        case "image":
            // On-device attachments live in the App container (`ChatTurns.attachmentsRoot`).
            let local = payload.firstString(for: ["relative_path"]).map { LocalMessageImage.prefix + $0 }
            guard let assetPath = local ?? payload.firstString(for: ["asset_path", "assetPath", "path"]) else { return nil }
            let caption = payload.firstString(for: ["caption", "filename", "alt"])
            return .image(assetPath: assetPath, caption: caption)
        case "file":
            let filename = payload.firstString(for: ["filename", "name"]) ?? "添付ファイル"
            return .file(
                filename: filename,
                contentType: payload.firstString(for: ["content_type", "contentType"]),
                bytes: payload.numberValue(for: "bytes")
            )
        case "problem_catalog_view":
            // The catalog has its own screen; chat never renders it inline.
            // Historical messages may still carry this block, so it is dropped here.
            return nil
        default:
            guard let preview = payload.previewText else { return nil }
            return .text(preview)
        }
    }
}

private extension RenderableMessageBlock {
    var plainPreview: String? {
        switch self {
        case .text(let text):
            text
        case .math(let latex, _):
            latex
        case .notice(let title, let body):
            [title, body].filter { !$0.isEmpty }.joined(separator: "\n")
        case .image(_, let caption):
            caption
        case .file(let filename, _, _):
            filename
        }
    }

    var isAttachment: Bool {
        switch self {
        case .image, .file:
            true
        case .text, .math, .notice:
            false
        }
    }

    var providesNarrativeText: Bool {
        switch self {
        case .text, .math, .notice:
            true
        case .image, .file:
            false
        }
    }
}

private extension AnyJSON {
    var textValue: String? {
        firstString(for: ["text", "body", "message"])
    }

    var previewText: String? {
        firstString(for: ["text", "body", "message", "prompt", "title", "latex", "content_latex"])
    }

    func firstString(for keys: [String]) -> String? {
        for key in keys {
            if let value = value[key]?.stringValue, !value.isEmpty {
                return value.replacingOccurrences(of: "\\n", with: "\n")
            }
        }
        if case .string(let raw) = value, !raw.isEmpty {
            return raw.replacingOccurrences(of: "\\n", with: "\n")
        }
        return nil
    }

    func boolValue(for key: String) -> Bool? {
        if case .bool(let bool)? = value[key] {
            return bool
        }
        return nil
    }

    func numberValue(for key: String) -> Double? {
        if case .number(let number)? = value[key] {
            return number
        }
        return nil
    }
}

private struct RemoteMessageImage: View {
    let assetPath: String
    let caption: String?

    @Environment(APIClient.self) private var apiClient
    @Environment(\.colorScheme) private var scheme
    @State private var phase: Phase = .loading
    @State private var showingPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .lineLimit(1)
            }
        }
        .task(id: assetPath) {
            await load()
        }
        .fullScreenCover(isPresented: $showingPreview) {
            if case .loaded(let image) = phase {
                FullScreenMessageImagePreview(image: image, caption: caption, assetPath: assetPath)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                ProgressView().progressViewStyle(StruisProgressViewStyle())
                    .tint(Theme.accent(scheme))
            }
            .frame(width: 220, height: 160)
        case .loaded(let image):
            Button {
                showingPreview = true
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(scheme == .dark ? 0.08 : 0.18), lineWidth: 0.5)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.48), in: Circle())
                            .padding(8)
                    }
                    .accessibilityLabel(caption ?? "添付画像")
                    .accessibilityHint("拡大表示します")
            }
            .buttonStyle(.plain)
        case .failed:
            MessageFileAttachment(filename: caption.map { "\($0)(画像を読み込めませんでした)" } ?? "画像を読み込めませんでした", contentType: "image", bytes: nil)
        }
    }

    @MainActor
    private func load() async {
        phase = .loading
        do {
            let image: UIImage
            if let local = try await LocalMessageImage.load(assetPath, maxPixelSize: LocalMessageImage.bubblePixelSize) {
                image = local
            } else {
                image = try await apiClient.image(for: .asset(relativePath: assetPath))
            }
            guard !Task.isCancelled else { return }
            phase = .loaded(image)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }

    private enum Phase {
        case loading
        case loaded(UIImage)
        case failed
    }
}

private struct FullScreenMessageImagePreview: View {
    let image: UIImage
    let caption: String?
    let assetPath: String
    @Environment(APIClient.self) private var apiClient
    @State private var originalImage: UIImage?

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                Image(uiImage: originalImage ?? image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(lastScale * value, 1), 5)
                            }
                            .onEnded { _ in
                                lastScale = scale
                            }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(Typography.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .padding(.top, 16)
            .padding(.trailing, 16)
        }
        .task(id: assetPath) {
            let original: UIImage?
            if let local = try? await LocalMessageImage.load(assetPath, maxPixelSize: LocalMessageImage.fullScreenPixelSize) {
                original = local
            } else {
                original = try? await apiClient.image(for: .asset(relativePath: assetPath), maxPixelSize: nil)
            }
            guard !Task.isCancelled else { return }
            originalImage = original
        }
    }
}

/// Images attached on this device: `local:<relative path under ChatTurns.attachmentsRoot>`.
enum LocalMessageImage {
    static let prefix = "local:"
    /// 吹き出し(220×160pt)を 3 倍の画面で描くのに足りる画素。
    static let bubblePixelSize = 660
    /// 全画面表示(拡大 5 倍まで)の上限。原寸(48MP・パノラマ)はデコードしない。
    static let fullScreenPixelSize = 4096

    /// Returns nil for non-local paths; throws when a local file is missing or unreadable.
    /// 長い辺を `maxPixelSize` px までに縮めて、ImageIO のサブサンプリングでデコードする(画面倍率を掛けない)。
    nonisolated static func load(_ assetPath: String, maxPixelSize: Int) async throws -> UIImage? {
        guard assetPath.hasPrefix(prefix) else { return nil }
        let relative = String(assetPath.dropFirst(prefix.count))
        guard !relative.split(separator: "/").contains("..") else { throw CocoaError(.fileReadInvalidFileName) }
        let url = ChatTurns.attachmentsRoot.appendingPathComponent(relative)
        return try await PreparedImage.decode(contentsOf: url, maxPixelSize: maxPixelSize)
    }
}

private struct MessageFileAttachment: View {
    let filename: String
    let contentType: String?
    let bytes: Double?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent(scheme))
                .frame(width: 30, height: 30)
                .background(Theme.accent(scheme).opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(filename)
                    .font(Typography.bodyEmphasized)
                    .foregroundStyle(Theme.textPrimary(scheme))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary(scheme))
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var detail: String? {
        let size = formattedBytes
        switch (contentType, size) {
        case (.some(let contentType), .some(let size)):
            return "\(contentType) · \(size)"
        case (.some(let contentType), .none):
            return contentType
        case (.none, .some(let size)):
            return size
        case (.none, .none):
            return nil
        }
    }

    private var formattedBytes: String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

#if DEBUG
private func sampleMessage(_ role: MessageRole, _ text: String, status: MessageStatus = .completed) -> ChatMessage {
    ChatMessage(
        id: UUID(),
        role: role,
        status: status,
        plainText: text,
        blocks: [],
        metadata: nil,
        createdAt: Date(),
        completedAt: status == .pending ? nil : Date()
    )
}

#Preview("Bubble — Light") {
    VStack(spacing: 14) {
        MessageBubble(message: sampleMessage(.assistant, "今日は何から始めましょうか？前回は二次関数の頂点でつまずいていました。"))
        MessageBubble(message: sampleMessage(.user, "頂点をどう求めるのか、もう一度知りたいです。"))
        MessageBubble(message: sampleMessage(.assistant, "", status: .pending))
    }
    .padding(20)
    .background(LiquidWallpaper())
    .preferredColorScheme(.light)
}

#Preview("Bubble — Dark") {
    VStack(spacing: 14) {
        MessageBubble(
            message: sampleMessage(
                .assistant,
                "OKです。前にやっていた物理だと、候補は「斜方投射・速度の成分」と「物理学A 第4回の力・作用反作用」です。まずどちらからテスト対策しますか？選んでくれた方で、確認問題を1問出します。"
            )
        )
        MessageBubble(message: sampleMessage(.user, "了解しました。"))
    }
    .padding(20)
    .background(LiquidWallpaper())
    .preferredColorScheme(.dark)
}
#endif

extension ChatMessage {
    var conversationExportText: String { displayText }
}


/// 相談の返答に全体像カードを添える。metadata.workbook_proposal_id を持つ返信だけ。
private struct WorkbookProposalAttachment: ViewModifier {
    let proposalID: String?
    let onStarted: ((WorkbookProposalDTO) -> Void)?

    func body(content: Content) -> some View {
        if let proposalID {
            VStack(alignment: .leading, spacing: 10) {
                content
                WorkbookProposalCard(proposalID: proposalID, onStarted: onStarted)
            }
        } else {
            content
        }
    }
}

extension ChatMessage {
    var workbookProposalID: String? {
        metadata?.value["workbook_proposal_id"]?.stringValue
    }
}

/// 色をつけている返事の吹き出しの位置を知らせる(§6)。色をつけていない吹き出しでは位置を測らない。
private struct HighlightFrameReporter: ViewModifier {
    let onFrame: ((CGRect) -> Void)?

    func body(content: Content) -> some View {
        if let onFrame {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WorkbookSubunitView.coordinateSpace)) } action: { onFrame($0) }
        } else {
            content
        }
    }
}
