import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

nonisolated struct ComposerAttachment: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable {
        case photoLibrary = "photo_library"
        case files = "files"
    }

    let id = UUID()
    let filename: String
    let contentType: String
    /// アプリの一時フォルダに置いた写し(`AttachmentIntake.stagingRoot`)。中身はメモリに持たない。
    let fileURL: URL
    let bytes: Int
    let source: Source
    /// 入力欄に添える説明(「PDF・200ページ」「1170×20000・11枚に分けて渡します」など)。
    var detail: String? = nil

    var isImage: Bool {
        contentType.starts(with: "image/")
    }
}

struct ChatComposer: View {
    @Binding var text: String
    @Binding var attachments: [ComposerAttachment]
    let focused: FocusState<Bool>.Binding
    let isSending: Bool
    var deliveryReady = true
    let learningSessionAvailable: Bool
    @Binding var learningContextEnabled: Bool
    let onSend: () -> Void
    var placeholder = "聞きたいことを書く"
    var allowsAttachments = true
    /// While a reply is running, the send button becomes 停止 and calls this (`turn/interrupt`).
    var onStop: (() -> Void)? = nil
    /// 返事の生成中でも、何か書いてあれば送信ボタンを出す(止めてから送るのは呼び手)。
    var sendsWhileBusy = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isAttachmentPalettePresented = false
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var attachmentError: String?
    @State private var isCameraPresented = false
    @State private var surfaceImpulse = 0
    @State private var sendFeedback = 0
    @State private var surfaceHeight: CGFloat = 0
    /// 読み込み中の取り込みの数。0 になるまで送信できない(写真が次のメッセージへ回らないように)。
    @State private var importsInFlight = 0
    /// 受け付けなかった添付の理由や、受け付けた添付についての知らせ。
    @State private var intakeLines: [String] = []
    @State private var lockedPDF: AttachmentIntake.LockedPDF?
    @State private var password = ""

    var body: some View {
        GlassEffectContainer(spacing: 20) {
            composerSurface
        }
    }

    private var composerSurface: some View {
        let radius: CGFloat = attachments.isEmpty && attachmentError == nil && intakeLines.isEmpty && importsInFlight == 0 ? 27 : 22
        let motionDisabled = reduceMotion
        return VStack(alignment: .leading, spacing: 8) {
            if learningSessionAvailable {
                Button {
                    learningContextEnabled.toggle()
                } label: {
                    Label(
                        learningContextEnabled ? "この画面について" : "学習に戻る",
                        systemImage: learningContextEnabled ? "rectangle.and.text.magnifyingglass" : "arrow.uturn.backward"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("learning-context-toggle")
            }
            if !attachments.isEmpty {
                attachmentTray
            }
            if importsInFlight > 0 {
                HStack(spacing: 6) {
                    ProgressView().progressViewStyle(StruisProgressViewStyle()).controlSize(.mini)
                    Text("添付を読み込んでいます…")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary(scheme))
                }
                .padding(.horizontal, 10)
                .accessibilityIdentifier("composer-attachment-loading")
            }
            if let attachmentError {
                Text(attachmentError)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.regress(scheme))
                    .padding(.horizontal, 10)
            }
            if !intakeLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(intakeLines, id: \.self) { line in
                        Text(line)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.regress(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 10)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("composer-attachment-intake")
            }

            HStack(alignment: .center, spacing: 8) {
                if allowsAttachments {
                    attachmentMenu
                }

                ComposerTextEditor(
                    text: $text,
                    placeholder: placeholder,
                    maximumLines: dynamicTypeSize.isAccessibilitySize ? 3 : 5,
                    onTap: { _ in
                        if !reduceMotion { surfaceImpulse &+= 1 }
                    }
                )
                    .focused(focused)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder)
                                .font(Typography.body)
                                .foregroundStyle(Theme.tertiaryText)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .frame(minHeight: 38)
                    .accessibilityIdentifier("chat-composer-input")


                sendButton
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height.rounded()
        } action: { height in
            surfaceHeight = height
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: surfaceHeight)
        .keyframeAnimator(initialValue: CGFloat.zero, trigger: surfaceImpulse) { surface, dent in
            surface.glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous).inset(by: motionDisabled ? 0 : dent)
            )
        } keyframes: { _ in
            CubicKeyframe(1.8, duration: 0.08)
            SpringKeyframe(-0.5, duration: 0.17, spring: .smooth)
            SpringKeyframe(0, duration: 0.25, spring: .smooth)
        }
        .glassEffectID("composer", in: glassNamespace)
        .overlay(alignment: .bottomLeading) {
            if isAttachmentPalettePresented {
                attachmentPalette
                    .offset(x: 2, y: -58)
            }
        }
        .onChange(of: photoItems) { _, items in
            Task { await importPhotos(items) }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: isAttachmentPalettePresented)
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $photoItems,
            maxSelectionCount: max(1, AttachmentIntake.maxCount - attachments.count),
            matching: .images
        )
        .fileImporter(
            isPresented: $isFileImporterPresented,
            // 何でも選べるようにして、渡せないものは入力欄で理由を示す(灰色で選べないだけでは理由が分からない)。
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            Task { await importFiles(result) }
        }
        .alert("パスワードが必要なPDFです", isPresented: Binding(
            get: { lockedPDF != nil },
            set: { if !$0, let locked = lockedPDF { lockedPDF = nil; AttachmentIntake.discard(locked) } }
        ), presenting: lockedPDF) { locked in
            SecureField("パスワード", text: $password)
                .accessibilityIdentifier("composer-pdf-password")
            Button("開く") {
                // 閉じる時の setter より先に外す(先に外さないと、解錠の前に一時ファイルを消してしまう)。
                let entered = password
                password = ""
                lockedPDF = nil
                importsInFlight += 1
                Task { await unlock(locked, password: entered) }
            }
            Button("やめる", role: .cancel) {
                lockedPDF = nil
                password = ""
                AttachmentIntake.discard(locked)
                intakeLines.append("\(locked.filename): パスワードを入れなかったので添付しませんでした")
            }
        } message: { locked in
            Text("「\(locked.filename)」を開くパスワードを入れてください。パスワードは保存しません。")
        }
        .background {
            ChatCameraPresentation(isPresented: $isCameraPresented) { data in
                attachmentError = nil
                intakeLines = []
                guard attachments.count < AttachmentIntake.maxCount else {
                    intakeLines = ["一度に添付できるのは\(AttachmentIntake.maxCount)件までです"]
                    return
                }
                if let photo = AttachmentIntake.staged(
                    data: data, filename: "photo-\(attachments.count + 1).jpg", contentType: "image/jpeg", source: .photoLibrary
                ) {
                    attachments.append(photo)
                } else {
                    attachmentError = "写真を読み込めませんでした"
                }
            }
        }
    }

    private var attachmentMenu: some View {
        ChatAttachmentButton(
            expanded: isAttachmentPalettePresented,
            enabled: !isSending,
            tint: UIColor(Theme.accent(scheme)),
            onTap: { isAttachmentPalettePresented.toggle() },
            onCamera: {
                isAttachmentPalettePresented = false
                isCameraPresented = true
            }
        )
        .frame(width: 44, height: 44)
    }

    private var attachmentPalette: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                attachmentPaletteButton(
                    systemImage: "camera",
                    accessibilityLabel: "撮る"
                ) {
                    isAttachmentPalettePresented = false
                    isCameraPresented = true
                }
                attachmentPaletteButton(
                    systemImage: "photo.on.rectangle",
                    accessibilityLabel: "写真を選ぶ"
                ) {
                    isAttachmentPalettePresented = false
                    isPhotoPickerPresented = true
                }
                attachmentPaletteButton(
                    systemImage: "folder",
                    accessibilityLabel: "ファイル"
                ) {
                    isAttachmentPalettePresented = false
                    isFileImporterPresented = true
                }
            }
        }
        .padding(6)
        .glassSurface(.thin, in: RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
        .glassEffectID("attachment-palette", in: glassNamespace)
        .glassEffectTransition(.matchedGeometry)
        .padding(.leading, 2)

    }

    private func attachmentPaletteButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(
                    Theme.card.opacity(scheme == .dark ? 0.46 : 0.72),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent(scheme))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("composer-attach-\(systemImage)")
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachmentChip(attachment)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func attachmentChip(_ attachment: ComposerAttachment) -> some View {
        HStack(spacing: 7) {
            attachmentThumbnail(attachment)
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textPrimary(scheme))
                    .lineLimit(1)
                if let detail = attachment.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary(scheme))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 150, alignment: .leading)
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary(scheme))
            .frame(width: 44, height: 44)
            .accessibilityLabel("\(attachment.filename)を解除")
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(Theme.card.opacity(0.78), in: Capsule())
    }

    @ViewBuilder
    private func attachmentThumbnail(_ attachment: ComposerAttachment) -> some View {
        if attachment.isImage || attachment.contentType == "application/pdf" {
            ComposerImageThumbnail(attachment: attachment)
        } else {
            Image(systemName: "doc")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Theme.accent(scheme).opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(Theme.accent(scheme))
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if isSending, let onStop, !(sendsWhileBusy && hasDraft) {
            Button(action: onStop) {
                ZStack {
                    Circle()
                        .fill(Theme.accent(scheme))
                        .frame(width: 36, height: 36)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(ComposerSendButtonStyle())
            .accessibilityLabel("停止")
        } else {
            sendOnlyButton
        }
    }

    private var sendOnlyButton: some View {
        Button(action: triggerSend) {
            ZStack {
                Circle()
                    .fill(canSend ? Theme.accent(scheme) : Theme.accent(scheme).opacity(0.35))
                    .frame(width: 36, height: 36)
                if isSending, !sendsWhileBusy {
                    ProgressView().progressViewStyle(StruisProgressViewStyle()).tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(ComposerSendButtonStyle())
        .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: sendFeedback)
        .disabled(!canSend)
        .frame(width: 44, height: 44)
        .accessibilityLabel("送信")
    }

    private var hasDraft: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var canSend: Bool {
        hasDraft && (!isSending || sendsWhileBusy) && deliveryReady && importsInFlight == 0 && lockedPDF == nil
    }

    /// 下書きと添付を空にするのは呼び手(受け付けた時だけ空にする。止めてから送る待ちの間に打った下書きを消さない)。
    private func triggerSend() {
        guard canSend else { return }
        sendFeedback &+= 1
        intakeLines = []
        attachmentError = nil
        onSend()
        isAttachmentPalettePresented = false
        focused.wrappedValue = false
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        photoItems = []
        attachmentError = nil
        intakeLines = []
        importsInFlight += 1
        defer { importsInFlight -= 1 }
        for item in items {
            let budget = AttachmentIntake.Budget(existing: attachments)
            do {
                guard let file = try await item.loadTransferable(type: PhotoFile.self) else {
                    intakeLines.append("写真を読み込めませんでした(写真が見つかりません)")
                    continue
                }
                apply(await AttachmentIntake.importPhoto(file, budget: budget))
            } catch {
                intakeLines.append("写真を読み込めませんでした(\(error.localizedDescription))")
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        attachmentError = nil
        intakeLines = []
        guard let urls = try? result.get() else {
            attachmentError = "ファイルを読み込めませんでした"
            return
        }
        importsInFlight += 1
        defer { importsInFlight -= 1 }
        let outcomes = await AttachmentIntake.importFiles(urls, budget: AttachmentIntake.Budget(existing: attachments))
        outcomes.forEach(apply)
    }

    private func apply(_ outcome: AttachmentIntake.Outcome) {
        switch outcome {
        case .accepted(let attachment, let notice):
            attachments.append(attachment)
            if let notice { intakeLines.append(notice) }
        case .rejected(let rejection):
            intakeLines.append(rejection.line)
        case .needsPassword(let locked):
            if lockedPDF == nil {
                password = ""
                lockedPDF = locked
            } else {
                AttachmentIntake.discard(locked)
                intakeLines.append("\(locked.filename): パスワード付きのPDFは1件ずつ添付してください")
            }
        }
    }

    /// 呼ぶ前に `importsInFlight` を 1 つ増やしておく(送信をすぐ止めるため)。
    private func unlock(_ locked: AttachmentIntake.LockedPDF, password entered: String) async {
        defer { importsInFlight -= 1 }
        guard let outcome = await AttachmentIntake.unlock(locked, password: entered) else {
            AttachmentIntake.discard(locked)
            intakeLines.append("\(locked.filename): パスワードが違うため開けませんでした。もう一度添付してください")
            return
        }
        apply(outcome)
    }
}

#if DEBUG
/// 高さの伸縮だけを見るためのホスト。長文でもカプセルからはみ出さないことを確認する。
private struct ChatComposerPreviewHost: View {
    @State var text: String
    @State private var attachments: [ComposerAttachment] = []
    @State private var learningContextEnabled = true
    @FocusState private var focused: Bool

    var body: some View {
        ChatComposer(
            text: $text,
            attachments: $attachments,
            focused: $focused,
            isSending: false,
            learningSessionAvailable: false,
            learningContextEnabled: $learningContextEnabled,
            onSend: {}
        )
        .padding(12)
    }
}

private let longSample = "水は毎分2cmずつ流れ込みます。タンクにはすでに少し水がたまっていて、10分たったら水面はどこまで上がるのでしょうか。これって一次関数のグラフに書き込んだりできるんですよね？"

#Preview("空") {
    ChatComposerPreviewHost(text: "")
}

#Preview("長文") {
    ChatComposerPreviewHost(text: longSample)
}

#Preview("長文 / ダーク") {
    ChatComposerPreviewHost(text: longSample)
        .preferredColorScheme(.dark)
}

#Preview("長文 / 小型端末") {
    ChatComposerPreviewHost(text: longSample)
        .frame(width: 320)
}

#Preview("長文 / 大文字") {
    ChatComposerPreviewHost(text: longSample)
        .environment(\.dynamicTypeSize, .accessibility5)
}
#endif

private struct ComposerImageThumbnail: View {
    let attachment: ComposerAttachment
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.clear.overlay { ProgressView().progressViewStyle(StruisProgressViewStyle()).controlSize(.mini) }
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: attachment.id) {
            guard image == nil else { return }
            // QuickLook の縮小表示(PDF の 1 ページ目も)。原寸はデコードしない。
            let decoded = await PreparedImage.thumbnail(of: attachment.fileURL, pixelSize: 112)
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}

private struct ComposerSendButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.92 : 1))
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

/// Keep UIKit's marked text and selection intact while SwiftUI updates the surrounding chat.
private struct ComposerTextEditor: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let maximumLines: Int
    let onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        view.backgroundColor = .clear
        view.textColor = .label
        view.tintColor = UIColor(Theme.accent(.light))
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.keyboardDismissMode = .interactive
        view.returnKeyType = .default
        view.alwaysBounceVertical = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "chat-composer-input"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let font = UIFont(name: Typography.SansFontName.regular.rawValue, size: 15) ?? .systemFont(ofSize: 15)
        let scaledFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
        if view.font != scaledFont { view.font = scaledFont }
        view.adjustsFontForContentSizeCategory = true
        // Never replace marked text or reset the cursor for unrelated renders.
        if view.markedTextRange == nil && view.text != text {
            let selection = view.selectedRange
            view.text = text
            let length = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
        }
        view.accessibilityLabel = placeholder

    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? 20
        return CGSize(width: width, height: min(max(ceil(fitted.height), ceil(lineHeight)), ceil(lineHeight * CGFloat(maximumLines))))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ComposerTextEditor
        init(_ parent: ComposerTextEditor) { self.parent = parent }
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            parent.onTap(gesture.location(in: gesture.view))
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }

    }
}
