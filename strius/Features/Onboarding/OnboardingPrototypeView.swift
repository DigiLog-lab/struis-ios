import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct OnboardingPrototypeView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    @State private var step: OnboardingStep = .introduction
    @State private var answers = OnboardingAnswers()
    @State private var otherText = ""
    @State private var isUsingOther = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isFileImporterPresented = false
    @State private var selectedMaterialName: String?
    @State private var materialAttachments: [ComposerAttachment] = []
    @State private var isImportingMaterial = false
    @State private var materialError: String?
    @State private var didTryConnection = false
    @State private var didOpenChatGPTSettings = false
    @State private var showsWorkspaceHelp = false

    /// 最後の「最初の単元を作る」。回答と、選んだ教材(単元づくりの手がかり)を渡す。
    let onFinish: (OnboardingProfile, [ComposerAttachment]) -> Void

    private static let chatGPTSecuritySettingsURL = URL(string: "https://chatgpt.com/#settings/Security")!

    var body: some View {
        ZStack {
            LiquidWallpaper()

            VStack(spacing: 0) {
                if step.showsProgress {
                    progressHeader
                }

                ScrollView {
                    Group {
                        switch step {
                        case .introduction:
                            introduction
                        case .connection:
                            connection
                        case .grade:
                            questionPage(
                                title: "あなたの学年を\n教えてください",
                                detail: "いまの学習内容に近い選択肢を用意します。",
                                options: OnboardingPrototypeOptions.grades,
                                selection: $answers.grade
                            )
                        case .currentFocus:
                            questionPage(
                                title: "今、いちばん優先したい\nことは？",
                                detail: "最初に進めたいものを選んでください。",
                                options: OnboardingPrototypeOptions.currentFocus(for: answers.grade),
                                selection: $answers.currentFocus
                            )
                        case .subject:
                            questionPage(
                                title: "いちばん困っている\n科目は？",
                                detail: "点数が伸びない、授業についていきにくい科目でも大丈夫です。",
                                options: OnboardingPrototypeOptions.subjects,
                                selection: $answers.subject
                            )
                        case .confusion:
                            multiSelectQuestionPage(
                                title: "どんなときに\n「わからない」と感じますか？",
                                detail: "当てはまるものをすべて選んでください。",
                                options: OnboardingPrototypeOptions.confusions(for: answers.subject),
                                selections: $answers.confusions,
                                otherSelection: $answers.confusionOther
                            )
                        case .studyStyle:
                            questionPage(
                                title: "普段はどうやって\n勉強していますか？",
                                detail: "教材や答案を送りやすい方法を案内するために使います。",
                                options: OnboardingPrototypeOptions.studyStyles,
                                selection: $answers.studyStyle
                            )
                        case .material:
                            materialUpload
                        case .ready:
                            ready
                        }
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)

                if step.showsBottomAction {
                    bottomAction
                }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            // 何でも選べるようにして、渡せないものは名前と理由を示す(質問画面と同じ入口)。
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            Task { await importFiles(result) }
        }
        .onChange(of: selectedPhotos) { _, items in
            Task { await importPhotos(items) }
        }
        .task(id: connectionPollingID) {
            await pollConnectionUntilFinished()
        }
        .animation(.snappy(duration: 0.28), value: step)
    }

    private var progressHeader: some View {
        HStack(spacing: 14) {
            Button {
                goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textPrimary(scheme))
            .accessibilityLabel("戻る")

            HStack(spacing: 12) {
                ProgressView(value: step.progress)
                    .tint(Theme.accent(scheme))

                Text("\(step.progressNumber) / \(OnboardingStep.progressCount)")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("オンボーディングの進捗")
            .accessibilityValue("\(step.progressNumber) / \(OnboardingStep.progressCount)")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var introduction: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 64)

            Text("Struis")
                .font(Typography.heroSerif)
                .foregroundStyle(Theme.accent(scheme))

            OnboardingFlowDiagram()
                .padding(.top, 40)

            VStack(spacing: 18) {
                Text("今日も一問から")
                    .font(Typography.heading2)
                    .foregroundStyle(Theme.textPrimary(scheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)

                Text("単元を作ると、要点と例題から始まり、類題と演習を紙に解いて撮るだけで、できるまで進められます。")
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 12)
            }
            .padding(.top, 42)

            Spacer(minLength: 64)

            primaryButton("はじめる") {
                advance(to: .connection)
            }

            Text("このあと、ChatGPTアカウントを接続します。")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
                .padding(.top, 14)
                .padding(.bottom, 18)
        }
        .frame(minHeight: 760)
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 28) {
            screenHeading(
                eyebrow: "CHATGPT",
                title: connectionTitle,
                detail: connectionDetail
            )

            if let account = settings.account, account.isConnected {
                connectedAccount(account)
            } else if let code = settings.account?.userCode {
                verificationCode(code)
            } else {
                deviceCodePreparation
            }

            if let error = settings.errorMessage {
                connectionError(error)
            }
        }
        .padding(.top, 22)
        .task {
            if settings.account == nil {
                await settings.refresh()
            }
        }
    }

    private var connectionTitle: String {
        if settings.account?.isConnected == true {
            return "ChatGPTアカウントを\n接続しました"
        }
        if settings.account?.userCode != nil {
            return "認証コードを\n入力します"
        }
        return "接続の準備を\nします"
    }

    private var connectionDetail: String {
        if settings.account?.isConnected == true {
            return "Struisで説明・判定・質問を使う準備ができました。"
        }
        if settings.account?.userCode != nil {
            return "ChatGPTの認証ページを開き、表示されたコードを入力してください。"
        }
        return "はじめに、ChatGPTでDevice Code認証を許可します。設定は一度だけです。"
    }

    private var deviceCodePreparation: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                connectionStep(number: "1", title: "ChatGPTを開く")
                connectorLine
                connectionStep(number: "2", title: "プロフィール → 設定 → セキュリティ")
                connectorLine
                connectionStep(number: "3", title: "「Device code login」をオンにする")
            }
            .padding(20)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        showsWorkspaceHelp.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "building.2")
                            .foregroundStyle(Theme.accent(scheme))
                        Text("学校・組織のChatGPTを使っている場合")
                            .font(Typography.bodyCompact)
                            .foregroundStyle(Theme.textPrimary(scheme))
                        Spacer()
                        Image(systemName: showsWorkspaceHelp ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary(scheme))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityValue(showsWorkspaceHelp ? "説明を表示中" : "説明を閉じています")

                if showsWorkspaceHelp {
                    Text("ワークスペース管理者による許可が必要です。自分で変更できない場合は、管理者にDevice Code loginの許可を依頼してください。")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary(scheme))
                        .lineSpacing(3)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(18)
            .background(
                Theme.accent(scheme).opacity(0.08),
                in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("接続されるもの")
                    .font(Typography.bodyEmphasized)
                    .foregroundStyle(Theme.textPrimary(scheme))
                Text("ChatGPTの利用枠を、Struisの説明・判定・質問に使います。学習の記録はこのiPhoneの中に保存されます。")
                    .font(Typography.bodyCompact)
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .lineSpacing(3)
            }
        }
    }

    private func questionPage(
        title: String,
        detail: String,
        options: [String],
        selection: Binding<String?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            screenHeading(eyebrow: "ABOUT YOU", title: title, detail: detail)

            VStack(spacing: 10) {
                ForEach(options, id: \.self) { option in
                    optionButton(option, selection: selection)
                }

                Button {
                    if selection.wrappedValue != nil {
                        clearDependentAnswers(after: step)
                    }
                    isUsingOther = true
                    otherText = ""
                    selection.wrappedValue = nil
                } label: {
                    HStack(spacing: 12) {
                        Text("その他")
                            .font(Typography.bodyEmphasized)
                        Spacer()
                        Image(systemName: isUsingOther ? "checkmark.circle.fill" : "chevron.right")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(isUsingOther ? Theme.accent(scheme) : Theme.textPrimary(scheme))
                    .padding(.horizontal, 18)
                    .frame(minHeight: 56)
                    .background(optionBackground(isSelected: isUsingOther))
                }
                .buttonStyle(.plain)
                .accessibilityValue(isUsingOther ? "選択中" : "未選択")
                .accessibilityAddTraits(isUsingOther ? [.isSelected] : [])

                if isUsingOther {
                    TextField("自由に入力してください", text: $otherText, axis: .vertical)
                        .font(Typography.body)
                        .lineLimit(2...4)
                        .padding(16)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                .stroke(Theme.accent(scheme).opacity(0.45), lineWidth: 1)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityLabel("その他の回答")
                }
            }
        }
        .padding(.top, 22)
    }

    private func multiSelectQuestionPage(
        title: String,
        detail: String,
        options: [String],
        selections: Binding<[String]>,
        otherSelection: Binding<String?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            screenHeading(eyebrow: "ABOUT YOU", title: title, detail: detail)

            VStack(spacing: 10) {
                ForEach(options, id: \.self) { option in
                    multiSelectOptionButton(option, selections: selections)
                }

                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        if isUsingOther {
                            isUsingOther = false
                            otherText = ""
                            otherSelection.wrappedValue = nil
                        } else {
                            isUsingOther = true
                            otherText = otherSelection.wrappedValue ?? ""
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text("その他")
                            .font(Typography.bodyEmphasized)
                        Spacer()
                        Image(systemName: isUsingOther ? "checkmark.square.fill" : "square")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(isUsingOther ? Theme.accent(scheme) : Theme.textPrimary(scheme))
                    .padding(.horizontal, 18)
                    .frame(minHeight: 56)
                    .background(optionBackground(isSelected: isUsingOther))
                }
                .buttonStyle(.plain)
                .accessibilityValue(isUsingOther ? "選択中" : "未選択")
                .accessibilityAddTraits(isUsingOther ? [.isSelected] : [])

                if isUsingOther {
                    TextField("自由に入力してください", text: $otherText, axis: .vertical)
                        .font(Typography.body)
                        .lineLimit(2...4)
                        .padding(16)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                .stroke(Theme.accent(scheme).opacity(0.45), lineWidth: 1)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityLabel("その他の回答")
                }
            }
        }
        .padding(.top, 22)
    }

    private var materialUpload: some View {
        VStack(alignment: .leading, spacing: 26) {
            screenHeading(
                eyebrow: "YOUR MATERIAL",
                title: "教材があれば、ここで\n追加できます",
                detail: "演習問題と解説がまとまった範囲があると、つまずいた場所まで戻って一緒に確認できます。"
            )

            MaterialRangeDiagram()

            VStack(spacing: 12) {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 8, matching: .images) {
                    uploadChoice(
                        title: "写真から選ぶ",
                        detail: "8ページまで",
                        systemImage: "photo.on.rectangle.angled"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isImportingMaterial)

                Button {
                    isFileImporterPresented = true
                } label: {
                    uploadChoice(
                        title: "ファイルから選ぶ",
                        detail: AttachmentIntake.limitDescription,
                        systemImage: "doc"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isImportingMaterial)
            }

            if isImportingMaterial {
                HStack(spacing: 10) {
                    ProgressView().progressViewStyle(StruisProgressViewStyle())
                        .controlSize(.small)
                    Text("教材を読み込んでいます…")
                }
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
            }

            if let selectedMaterialName {
                HStack(spacing: 12) {
                    Label(selectedMaterialName, systemImage: "checkmark.circle.fill")
                        .font(Typography.bodyEmphasized)
                        .foregroundStyle(Theme.growth(scheme))
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    Button("解除") {
                        clearMaterial()
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Theme.accent(scheme))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("選んだ教材を解除")
                }
                .padding(.horizontal, 4)
            }

            if let materialError {
                Label(materialError, systemImage: "exclamationmark.circle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.regress(scheme))
                    .lineSpacing(3)
            }

            Text("教材はあとから質問画面でも追加できます。")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
        }
        .padding(.top, 22)
    }

    private var ready: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 54)

            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.textOnAccent(scheme))
                .frame(width: 68, height: 68)
                .background(Theme.accent(scheme), in: Circle())

            VStack(spacing: 12) {
                Text("準備ができました")
                    .font(Typography.heading1)
                    .foregroundStyle(Theme.textPrimary(scheme))
                Text("この回答をもとに、最初の単元を一緒に決めます。")
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            VStack(spacing: 0) {
                summaryRow("学年", answers.grade)
                summaryDivider
                summaryRow("優先したいこと", answers.currentFocus)
                summaryDivider
                summaryRow("困っている科目", answers.subject)
                summaryDivider
                summaryRow("わからないこと", answers.confusionSummary)
                summaryDivider
                summaryRow("普段の勉強方法", answers.studyStyle)
                if selectedMaterialName != nil {
                    summaryDivider
                    summaryRow("選んだ教材", selectedMaterialName)
                }
            }
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous)
            )

            Spacer(minLength: 34)
        }
    }

    private var bottomAction: some View {
        VStack(spacing: 10) {
            if step == .connection {
                if settings.account?.isConnected == true {
                    primaryButton("次へ") {
                        advance(to: .grade)
                    }
                } else if settings.account?.userCode != nil {
                    primaryButton("認証ページを開く") {
                        openVerificationPage()
                    }

                    HStack(spacing: 8) {
                        ProgressView().progressViewStyle(StruisProgressViewStyle())
                            .controlSize(.small)
                        Text("接続を待っています…")
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
                } else {
                    primaryButton(connectionPrimaryActionTitle) {
                        performConnectionPrimaryAction()
                    }
                    .disabled(settings.busy)
                    .opacity(settings.busy ? 0.6 : 1)

                    if !settings.busy {
                        Button(connectionSecondaryActionTitle) {
                            performConnectionSecondaryAction()
                        }
                        .font(Typography.caption)
                        .foregroundStyle(Theme.accent(scheme))
                        .frame(minHeight: 44)
                    }
                }
            } else if step == .material {
                if materialAttachments.isEmpty {
                    Button("今は追加しない") {
                        advance(to: .ready)
                    }
                    .font(Typography.bodyEmphasized)
                    .foregroundStyle(Theme.accent(scheme))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(isImportingMaterial)
                } else {
                    primaryButton("この教材で進む") {
                        advance(to: .ready)
                    }
                    .disabled(isImportingMaterial)
                    .opacity(isImportingMaterial ? 0.6 : 1)
                }
            } else if step == .ready {
                primaryButton("最初の単元を作る") {
                    onFinish(profile, materialAttachments)
                }
                .accessibilityIdentifier("onboarding-create-first-unit")
            } else {
                primaryButton("次へ") {
                    saveCurrentAnswerAndAdvance()
                }
                .disabled(!canAdvanceQuestion)
                .opacity(canAdvanceQuestion ? 1 : 0.38)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private func screenHeading(eyebrow: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eyebrow)
                .font(Typography.eyebrow)
                .foregroundStyle(Theme.accent(scheme))
                .tracking(1.4)
            Text(title)
                .font(Typography.heading1)
                .foregroundStyle(Theme.textPrimary(scheme))
                .lineSpacing(3)
            Text(detail)
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary(scheme))
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionPrimaryActionTitle: String {
        if settings.busy {
            return "認証コードを準備しています…"
        }
        if didTryConnection, settings.errorMessage != nil {
            return "もう一度試す"
        }
        if didOpenChatGPTSettings {
            return "設定できた"
        }
        return "ChatGPTの設定を開く"
    }

    private var connectionSecondaryActionTitle: String {
        didOpenChatGPTSettings ? "設定をもう一度開く" : "すでに設定済み"
    }

    private func performConnectionPrimaryAction() {
        if didOpenChatGPTSettings || didTryConnection {
            startConnection()
        } else {
            openChatGPTSettings()
        }
    }

    private func performConnectionSecondaryAction() {
        if didOpenChatGPTSettings {
            openChatGPTSettings()
        } else {
            startConnection()
        }
    }

    private func openChatGPTSettings() {
        didOpenChatGPTSettings = true
        openURL(Self.chatGPTSecuritySettingsURL)
    }

    private func startConnection() {
        didTryConnection = true
        Task { await settings.connect() }
    }

    private func openVerificationPage() {
        guard let rawURL = settings.account?.verificationURL,
              let url = URL(string: rawURL) else {
            return
        }
        openURL(url)
    }

    private var connectionPollingID: String {
        guard step == .connection,
              settings.account?.status == .connecting,
              settings.account?.userCode != nil else {
            return "idle"
        }
        return settings.account?.loginID ?? "connecting"
    }

    private func pollConnectionUntilFinished() async {
        guard connectionPollingID != "idle" else { return }

        while !Task.isCancelled,
              step == .connection,
              settings.account?.status == .connecting {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await settings.pollConnection()
        }
    }

    private func connectionStep(number: String, title: String) -> some View {
        HStack(spacing: 14) {
            Text(number)
                .font(Typography.caption)
                .foregroundStyle(Theme.textOnAccent(scheme))
                .frame(width: 30, height: 30)
                .background(Theme.accent(scheme), in: Circle())
            Text(title)
                .font(Typography.bodyEmphasized)
                .foregroundStyle(Theme.textPrimary(scheme))
            Spacer()
        }
    }

    private var connectorLine: some View {
        Rectangle()
            .fill(Theme.separator(scheme))
            .frame(width: 1, height: 24)
            .padding(.leading, 15)
    }

    private func connectedAccount(_ account: CodexAccount) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Theme.growth(scheme))
            VStack(alignment: .leading, spacing: 3) {
                Text("接続しました")
                    .font(Typography.bodyEmphasized)
                    .foregroundStyle(Theme.textPrimary(scheme))
                Text(account.accountEmail ?? "ChatGPTアカウント")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
            }
            Spacer()
        }
        .padding(18)
        .background(Theme.growth(scheme).opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func verificationCode(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("認証コード")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
            Text(code)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary(scheme))
                .textSelection(.enabled)

            Divider()

            Label("コードはChatGPTの認証ページだけに入力してください。人には送らないでください。", systemImage: "lock.shield")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
                .lineSpacing(3)
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func connectionError(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.regress(scheme))
            Text(message)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
                .lineSpacing(3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.regress(scheme).opacity(0.08),
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        )
    }

    private func optionButton(_ option: String, selection: Binding<String?>) -> some View {
        let isSelected = !isUsingOther && selection.wrappedValue == option

        return Button {
            if selection.wrappedValue != option {
                clearDependentAnswers(after: step)
            }
            isUsingOther = false
            otherText = ""
            selection.wrappedValue = option
        } label: {
            HStack(spacing: 12) {
                Text(option)
                    .font(Typography.bodyEmphasized)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Theme.accent(scheme) : Theme.textPrimary(scheme))
            .padding(.horizontal, 18)
            .frame(minHeight: 56)
            .background(optionBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "選択中" : "未選択")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func multiSelectOptionButton(_ option: String, selections: Binding<[String]>) -> some View {
        let isSelected = selections.wrappedValue.contains(option)

        return Button {
            if isSelected {
                selections.wrappedValue.removeAll { $0 == option }
            } else {
                selections.wrappedValue.append(option)
            }
        } label: {
            HStack(spacing: 12) {
                Text(option)
                    .font(Typography.bodyEmphasized)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Theme.accent(scheme) : Theme.textPrimary(scheme))
            .padding(.horizontal, 18)
            .frame(minHeight: 56)
            .background(optionBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "選択中" : "未選択")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func optionBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(
                isSelected
                    ? Theme.accent(scheme).opacity(scheme == .dark ? 0.18 : 0.10)
                    : Color(uiColor: .secondarySystemGroupedBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(isSelected ? Theme.accent(scheme).opacity(0.55) : Color.clear, lineWidth: 1)
            }
    }

    private func uploadChoice(title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: 15) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.accent(scheme))
                .frame(width: 44, height: 44)
                .background(Theme.accent(scheme).opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typography.bodyEmphasized)
                    .foregroundStyle(Theme.textPrimary(scheme))
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary(scheme))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 70)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func summaryRow(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))
            Text(value ?? "未回答")
                .font(Typography.bodyEmphasized)
                .foregroundStyle(Theme.textPrimary(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(Theme.separator(scheme))
            .frame(height: 0.5)
            .padding(.leading, 18)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.bodyEmphasized)
                .frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(Theme.textOnAccent(scheme))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(Theme.accent(scheme), in: Capsule())
    }

    private var canAdvanceQuestion: Bool {
        if isUsingOther {
            return !otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        switch step {
        case .grade: return answers.grade != nil
        case .currentFocus: return answers.currentFocus != nil
        case .subject: return answers.subject != nil
        case .confusion: return !answers.confusions.isEmpty
        case .studyStyle: return answers.studyStyle != nil
        default: return true
        }
    }

    private var profile: OnboardingProfile {
        OnboardingProfile(
            grade: answers.grade, currentFocus: answers.currentFocus, subject: answers.subject,
            confusion: answers.confusionSummary, studyStyle: answers.studyStyle, materialName: selectedMaterialName
        )
    }

    /// 教材の取り込みは質問画面と同じ入口(`AttachmentIntake`: PDF と画像、件数・合計容量の上限、主スレッドの外、理由の表示)。
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isImportingMaterial = true
        materialError = nil
        defer { isImportingMaterial = false }
        var outcomes: [AttachmentIntake.Outcome] = []
        var budget = AttachmentIntake.Budget(existing: [])
        for item in items {
            guard let file = try? await item.loadTransferable(type: PhotoFile.self) else {
                outcomes.append(.rejected(AttachmentIntake.Rejection(filename: "写真", reason: "読み込めませんでした")))
                continue
            }
            let outcome = await AttachmentIntake.importPhoto(file, budget: budget)
            if case .accepted(let attachment, _) = outcome {
                budget.count -= 1
                budget.bytes -= attachment.bytes
            }
            outcomes.append(outcome)
        }
        applyMaterial(outcomes, photos: true)
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        guard let urls = try? result.get() else {
            materialError = "ファイルを読み込めませんでした。もう一度選んでください。"
            return
        }
        guard !urls.isEmpty else { return }
        isImportingMaterial = true
        materialError = nil
        defer { isImportingMaterial = false }
        applyMaterial(await AttachmentIntake.importFiles(urls, budget: AttachmentIntake.Budget(existing: [])), photos: false)
    }

    private func applyMaterial(_ outcomes: [AttachmentIntake.Outcome], photos: Bool) {
        var imported: [ComposerAttachment] = []
        var lines: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .accepted(let attachment, let notice):
                imported.append(attachment)
                if let notice { lines.append(notice) }
            case .rejected(let rejection):
                lines.append(rejection.line)
            case .needsPassword(let locked):
                AttachmentIntake.discard(locked)
                lines.append("\(locked.filename): パスワード付きのPDFです。質問画面で添付すると、パスワードを入れて開けます")
            }
        }
        if imported.isEmpty {
            clearMaterial(keepingError: true)
        } else {
            if !photos { selectedPhotos = [] }
            materialAttachments = imported
            selectedMaterialName = imported.count == 1
                ? (photos ? "写真を1枚選択" : imported[0].filename)
                : (photos ? "写真を\(imported.count)枚選択" : "\(imported.count)件のファイル")
        }
        materialError = lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func clearMaterial(keepingError: Bool = false) {
        selectedPhotos = []
        selectedMaterialName = nil
        materialAttachments = []
        if !keepingError {
            materialError = nil
        }
    }

    private func saveCurrentAnswerAndAdvance() {
        if isUsingOther {
            let value = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch step {
            case .grade:
                if answers.grade != value {
                    clearDependentAnswers(after: .grade)
                }
                answers.grade = value
            case .currentFocus: answers.currentFocus = value
            case .subject:
                if answers.subject != value {
                    clearDependentAnswers(after: .subject)
                }
                answers.subject = value
            case .confusion: answers.confusionOther = value
            case .studyStyle: answers.studyStyle = value
            default: break
            }
        } else if step == .confusion {
            answers.confusionOther = nil
        }

        switch step {
        case .grade: advance(to: .currentFocus)
        case .currentFocus: advance(to: .subject)
        case .subject: advance(to: .confusion)
        case .confusion: advance(to: .studyStyle)
        case .studyStyle: advance(to: .material)
        default: break
        }
    }

    private func advance(to next: OnboardingStep) {
        restoreOtherAnswer(for: next)
        withAnimation(.snappy(duration: 0.28)) {
            step = next
        }
    }

    private func clearDependentAnswers(after changedStep: OnboardingStep) {
        switch changedStep {
        case .grade:
            answers.currentFocus = nil
        case .subject:
            answers.confusions = []
            answers.confusionOther = nil
        default:
            break
        }
    }

    private func restoreOtherAnswer(for target: OnboardingStep) {
        otherText = ""
        isUsingOther = false

        if target == .confusion {
            guard let other = answers.confusionOther else { return }
            otherText = other
            isUsingOther = true
            return
        }

        guard let answer = answers.answer(for: target),
              !OnboardingPrototypeOptions.options(for: target, answers: answers).contains(answer) else {
            return
        }

        otherText = answer
        isUsingOther = true
    }

    private func goBack() {
        guard let previous = step.previous else { return }
        advance(to: previous)
    }

}

private enum OnboardingStep: Int, CaseIterable {
    case introduction
    case connection
    case grade
    case currentFocus
    case subject
    case confusion
    case studyStyle
    case material
    case ready

    static let progressCount = 8

    var showsProgress: Bool {
        self != .introduction
    }

    var showsBottomAction: Bool {
        self != .introduction
    }

    var progressNumber: Int {
        min(max(rawValue, 1), Self.progressCount)
    }

    var progress: Double {
        Double(progressNumber) / Double(Self.progressCount)
    }

    var previous: OnboardingStep? {
        switch self {
        case .introduction: return nil
        case .connection: return .introduction
        case .grade: return .connection
        case .currentFocus: return .grade
        case .subject: return .currentFocus
        case .confusion: return .subject
        case .studyStyle: return .confusion
        case .material: return .studyStyle
        case .ready: return .material
        }
    }
}

private struct OnboardingAnswers {
    var grade: String?
    var currentFocus: String?
    var subject: String?
    var confusions: [String] = []
    var confusionOther: String?
    var studyStyle: String?

    var confusionSummary: String? {
        let values = confusions + [confusionOther].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: "、")
    }

    func answer(for step: OnboardingStep) -> String? {
        switch step {
        case .grade: return grade
        case .currentFocus: return currentFocus
        case .subject: return subject
        case .confusion: return confusionSummary
        case .studyStyle: return studyStyle
        default: return nil
        }
    }
}

private enum OnboardingPrototypeOptions {
    static let grades = [
        "中学1年生", "中学2年生", "中学3年生",
        "高校1年生", "高校2年生", "高校3年生",
        "大学生"
    ]

    static let subjects = ["数学", "英語", "国語", "理科", "社会"]

    static let studyStyles = [
        "紙のノートを使う",
        "iPad・ノートアプリを使う",
        "スマートフォン中心",
        "紙とデジタルの両方",
        "まだ決まっていない"
    ]

    static func options(for step: OnboardingStep, answers: OnboardingAnswers) -> [String] {
        switch step {
        case .grade: return grades
        case .currentFocus: return currentFocus(for: answers.grade)
        case .subject: return subjects
        case .confusion: return confusions(for: answers.subject)
        case .studyStyle: return studyStyles
        default: return []
        }
    }

    static func currentFocus(for grade: String?) -> [String] {
        guard let grade else {
            return ["定期テストの勉強", "授業の復習", "受験の勉強", "苦手のやり直し"]
        }

        if grade.contains("小学") {
            return ["学校の宿題", "授業の復習", "中学の先取り", "苦手のやり直し", "学校以外の学習"]
        }
        if grade.contains("中学") {
            return ["定期テストの勉強", "高校受験の勉強", "授業の復習", "苦手のやり直し", "学校以外の学習"]
        }
        if grade.contains("高校") {
            return ["定期テストの勉強", "大学受験の勉強", "授業の復習", "苦手のやり直し", "学校以外の学習"]
        }
        return ["授業・試験の勉強", "資格試験の勉強", "専門分野の学習", "基礎のやり直し", "独学している"]
    }

    static func confusions(for subject: String?) -> [String] {
        switch subject {
        case "数学":
            return [
                "問題文から式を作れない",
                "途中で計算が合わなくなる",
                "解説を読んでも流れがつかめない",
                "どこまで戻ればよいかわからない",
                "覚えたはずなのに解けない"
            ]
        case "英語":
            return [
                "英文の意味をつかめない",
                "文法の使い分けがわからない",
                "単語を覚えても使えない",
                "英作文で何から書けばよいかわからない",
                "長文になると途中で迷う"
            ]
        case "国語":
            return [
                "文章の要点をつかめない",
                "選択肢を絞れない",
                "記述問題で何を書けばよいかわからない",
                "古文・漢文の読み方がわからない"
            ]
        case "理科":
            return [
                "公式をいつ使うのかわからない",
                "現象と用語が結びつかない",
                "計算問題の進め方がわからない",
                "グラフや実験結果を読み取れない"
            ]
        case "社会":
            return [
                "出来事のつながりがわからない",
                "用語を覚えても問題で使えない",
                "資料やグラフを読み取れない",
                "記述問題で何を書けばよいかわからない"
            ]
        default:
            return [
                "問題の意味をつかめない",
                "途中から進めなくなる",
                "解説を読んでも納得できない",
                "どこまで戻ればよいかわからない"
            ]
        }
    }
}

private struct OnboardingFlowDiagram: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    flowItem("教材・答案", systemImage: "book.closed")
                    verticalArrow
                    flowItem("Struis", systemImage: "s.circle")
                    verticalArrow
                    flowItem("解説・次へ", systemImage: "arrow.triangle.branch")
                }
            } else {
                HStack(spacing: 10) {
                    flowItem("教材・答案", systemImage: "book.closed")
                    arrow
                    flowItem("Struis", systemImage: "s.circle")
                    arrow
                    flowItem("解説・次へ", systemImage: "arrow.triangle.branch")
                }
            }
        }
    }

    private func flowItem(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.accent(scheme))
                .frame(width: 52, height: 52)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
            Text(title)
                .font(Typography.micro)
                .foregroundStyle(Theme.textSecondary(scheme))
                .lineLimit(1)
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textTertiary(scheme))
            .padding(.bottom, 23)
    }

    private var verticalArrow: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textSecondary(scheme))
    }
}

private struct MaterialRangeDiagram: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("この範囲をまとめて")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary(scheme))

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        pageBlock("例題・解説", systemImage: "text.book.closed")
                        pageBlock("練習問題", systemImage: "pencil.and.list.clipboard")
                        pageBlock("章末問題", systemImage: "checklist")
                    }
                } else {
                    HStack(spacing: 8) {
                        pageBlock("例題・解説", systemImage: "text.book.closed")
                        pageBlock("練習問題", systemImage: "pencil.and.list.clipboard")
                        pageBlock("章末問題", systemImage: "checklist")
                    }
                }
            }
        }
        .padding(18)
        .background(Theme.accent(scheme).opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge))
    }

    private func pageBlock(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Theme.accent(scheme))
            Text(title)
                .font(Typography.micro)
                .foregroundStyle(Theme.textPrimary(scheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 74)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

#if DEBUG
#Preview("Onboarding prototype") {
    let client = APIClient()
    OnboardingPrototypeView { _, _ in }
        .environment(SettingsStore(runtime: nil))
}
#endif
