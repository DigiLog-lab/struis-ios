import DeclaredAgeRange
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// オンボーディング(#40)。年齢の確認と規約への同意 → お試しの1問(3問まで無料)→ プランの購入 → 自分の範囲の計画 → 通知。
/// 最後の行き先はタイムライン(`onFinish`)。iPhone と iPad の両方。
struct OnboardingFlowView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    @Environment(\.requestAgeRange) private var requestAgeRange
    @State private var model: OnboardingModel
    let learnerData: LearnerData
    let subscriptions: SubscriptionStore
    let onFinish: () -> Void

    init(learnerData: LearnerData, subscriptions: SubscriptionStore, start: OnboardingStep? = nil, onFinish: @escaping () -> Void) {
        self.learnerData = learnerData
        self.subscriptions = subscriptions
        self.onFinish = onFinish
        let model = OnboardingModel(
            hasPlan: { [subscriptions] in subscriptions.plan != nil },
            isClaudeAvailable: { [learnerData] in Self.claudeAvailable(learnerData: learnerData) },
            start: start
        )
        #if DEBUG
        if let start { model.prepareForPreview(start) }
        #endif
        _model = State(initialValue: model)
    }

    /// Claude(App Attest)を使えるか。DEBUG の模擬のターンでは使える扱い(`STRUIS_CLAUDE_AVAILABLE=0` で使えない画面を出す)。
    static func claudeAvailable(learnerData: LearnerData) -> Bool {
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["STRUIS_CLAUDE_AVAILABLE"] { return forced == "1" }
        if !learnerData.requiresDelivery { return true }
        #endif
        return ClaudeAccess.isAvailable
    }

    private var isPad: Bool { TimelineLayout.isPad(sizeClass) }

    var body: some View {
        Group {
            switch model.step {
            case .unsupported: unsupported
            case .grade: grade
            case .birthdate: birthdate
            case .terms: terms
            case .consent: consent
            case .trial, .grading, .result:
                OnboardingTrialView(model: model, learnerData: learnerData, isPad: isPad)
            case .trialDone: OnboardingTrialDoneView(model: model, isPad: isPad)
            case .paywall:
                OnboardingPaywallView(store: subscriptions, isPad: isPad, onPurchased: { model.afterPurchase() })
            case .intent: intent
            case .unit: unit
            case .untilTest: untilTest
            case .pages: pages
            case .weak: weakUnit
            case .topic: topic
            case .material: material
            case .goal: goal
            case .planWait, .plan:
                OnboardingPlanView(model: model, learnerData: learnerData, isPad: isPad)
            case .notify: notify
            }
        }
        .animation(.easeInOut(duration: Theme.Duration.standard), value: model.step)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-\(model.step.rawValue)")
        .onChange(of: subscriptions.plan) { _, plan in
            // 購入画面にいる間に契約が届いた(購入・復元・別の端末)。
            if plan != nil, model.step == .paywall { model.afterPurchase() }
        }
    }

    private var back: (() -> Void)? { model.canGoBack ? { model.back() } : nil }

    // MARK: - 1 学年

    private var grade: some View {
        OnboardingScaffold(showsBrand: true, isPad: isPad) {
            VStack(alignment: .leading, spacing: 22) {
                OnboardingTitle(title: "まず1問、解いてみましょう", detail: "どの学年の数学にしますか")
                OnboardingPillGrid(options: OnboardingCatalog.grades, selection: model.selectedGrade) { model.chooseGrade($0) }
                OnboardingPill(title: OnboardingProfile.universityGrade, isSelected: model.selectedGrade == OnboardingProfile.universityGrade) {
                    model.chooseGrade(OnboardingProfile.universityGrade)
                }
                .padding(.top, 4)
            }
            .padding(.top, isPad ? 60 : 32)
        } footer: {
            OnboardingPrimaryButton(title: "次へ", isEnabled: model.selectedGrade != nil && !model.isCheckingAge, identifier: "onboarding-grade-next") {
                Task { await commitGrade() }
            }
        }
    }

    /// 学年の次: 年齢の範囲を Declared Age Range で確かめる(共有されなかった・取れなかった時だけ生年月日)。
    private func commitGrade() async {
        model.commitGrade()
        guard model.needsAgeCheck else {
            model.afterAge()
            return
        }
        model.isCheckingAge = true
        defer { model.isCheckingAge = false }
        #if DEBUG
        // Simulator では Apple の確認を出せないので、結果を差し替える(`STRUIS_AGE_RANGE=under16|under18|adult|declined`)。
        if let forced = ProcessInfo.processInfo.environment["STRUIS_AGE_RANGE"] {
            model.applyAgeRange(band: AgeBand(rawValue: forced), declaration: forced == "declined" ? nil : "selfDeclared")
            return
        }
        #endif
        do {
            switch try await requestAgeRange(ageGates: 16, 18) {
            case .declinedSharing:
                model.applyAgeRange(band: nil, declaration: nil)
            case .sharing(let range):
                model.applyAgeRange(band: AgeBand.from(lowerBound: range.lowerBound, upperBound: range.upperBound),
                                    declaration: range.ageRangeDeclaration.map { String(describing: $0) })
            @unknown default:
                model.applyAgeRange(band: nil, declaration: nil)
            }
        } catch {
            model.applyAgeRange(band: nil, declaration: nil)
        }
    }

    // MARK: - 生年月日

    private var birthdate: some View {
        OnboardingScaffold(onBack: back, isPad: isPad) {
            VStack(alignment: .leading, spacing: 20) {
                OnboardingTitle(title: "生年月日を教えてください", detail: "18歳未満かどうかなど、年齢の区分を確かめるためだけに使います。")
                DatePicker("生年月日", selection: $model.birthdate, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "ja_JP"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipped()
                    .struisSurface(radius: Theme.Radius.cardLarge)
                    .accessibilityIdentifier("onboarding-birthdate-picker")
                OnboardingNote(symbol: "lock", text: "生年月日はこの端末の中で年齢の判定にだけ使い、判定が終わったらすぐに消します。Struis の運営者にも AI にも送りません。残すのは「16歳未満・18歳未満・18歳以上」のどれかの結果だけです。")
            }
        } footer: {
            OnboardingPrimaryButton(title: "次へ", identifier: "onboarding-birthdate-next") { model.commitBirthdate() }
        }
    }

    // MARK: - 規約への同意

    private var terms: some View {
        OnboardingScaffold(onBack: back, isPad: isPad) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingTitle(title: "はじめる前に", detail: "利用規約の大事なところです。")
                OnboardingListCard {
                    OnboardingPointRow(title: "採点と説明は AI が行います", detail: "間違えることがあります。おかしいと思ったら「質問」で確かめてください。")
                    OnboardingPointRow(title: "お試しは3問まで、続きは有料です", detail: "プランごとに1週間に使える量が決まっています。")
                    OnboardingPointRow(title: "解約と返金は App Store で行います", detail: "解約は端末の設定から、いつでもできます。", showsDivider: false)
                }
                if model.isMinor {
                    OnboardingNote(symbol: "person.2", text: "18歳未満の方は、保護者の方と一緒に読んで、同意をもらってから使ってください。")
                        .accessibilityIdentifier("onboarding-terms-minor")
                }
                VStack(spacing: 0) {
                    linkRow("利用規約を読む", url: LegalLinks.terms)
                    linkRow("プライバシーポリシーを読む", url: LegalLinks.privacy)
                }
            }
        } footer: {
            OnboardingPrimaryButton(title: "同意して続ける", identifier: "onboarding-terms-accept") { model.acceptTerms() }
            Text("押すと、利用規約とプライバシーポリシーに同意したことになります。")
                .font(Typography.sans(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    private func linkRow(_ title: String, url: URL) -> some View {
        Button { openURL(url) } label: {
            HStack {
                Text(title).font(Typography.sans(size: 15, weight: .medium)).foregroundStyle(Theme.primaryText)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 写真(答案)の扱い

    private var consent: some View {
        OnboardingScaffold(onBack: back, isPad: isPad) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingTitle(title: isPad ? "答案の扱いについて" : "写真の扱いについて")
                OnboardingListCard {
                    if isPad {
                        OnboardingPointRow(symbol: "pencil.line", title: "書いた答案と写真を AI に送ります",
                                           detail: "画面に書いた答案や、撮った答案・教材の写真は、採点と説明のために Anthropic の Claude に送ります。")
                    } else {
                        OnboardingPointRow(symbol: "camera", title: "写真を AI に送ります", detail: "答案や教材の写真は、採点と説明のために Anthropic の Claude に送ります。")
                    }
                    OnboardingPointRow(symbol: "cloud", title: "記録はこの端末と iCloud に残ります",
                                       detail: "解いた答案と学習の記録は、この端末と、同じ Apple ID の iCloud に保存します。Struis の運営者は読めません。")
                    OnboardingPointRow(symbol: "bell", title: "カメラと通知は、使う時に確認します",
                                       detail: "撮る時にカメラの、知らせる時間を決める時に通知の確認が端末から出ます。", showsDivider: false)
                }
                Button { openURL(LegalLinks.privacy) } label: {
                    Text("プライバシーポリシーを読む").font(Typography.sans(size: 13, weight: .medium)).underline().foregroundStyle(Theme.primaryText)
                }
                .buttonStyle(.plain)
            }
        } footer: {
            OnboardingPrimaryButton(title: "同意して続ける", identifier: "onboarding-consent-accept") { model.acceptPhotoConsent() }
            Text("同意しない場合は、採点と説明を使えません。")
                .font(Typography.sans(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - 6 何をするか

    private var intent: some View {
        OnboardingScaffold(isPad: isPad, columnWidth: isPad ? 800 : OnboardingMetrics.padColumn) {
            VStack(alignment: isPad ? .center : .leading, spacing: 20) {
                OnboardingTitle(title: "ここから何をしますか")
                    .multilineTextAlignment(isPad ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: isPad ? .center : .leading)
                let gradeText = model.profile.grade ?? "今の学年"
                let cards = [
                    (OnboardingProfile.Route.range, "やる範囲が決まっている", "授業・テストの範囲、塾や家の人に言われた範囲など"),
                    (.weak, "苦手な単元をやり直したい", "前の学年の単元も選べます"),
                    (.unsure, "何をやればいいか分からない", "\(gradeText) 数学の基本から始めます"),
                ]
                let layout = isPad ? AnyLayout(HStackLayout(alignment: .top, spacing: 14)) : AnyLayout(VStackLayout(spacing: 14))
                layout {
                    ForEach(cards, id: \.1) { route, title, detail in
                        Button { model.choose(route: route) } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(title).font(Typography.sans(size: 17, weight: .bold)).foregroundStyle(Theme.primaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(detail).font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                if !isPad { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.tertiaryText) }
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, minHeight: isPad ? 120 : 0, alignment: .topLeading)
                            .struisSurface(radius: Theme.Radius.cardLarge)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("onboarding-intent-\(route.rawValue)")
                    }
                }
            }
            .padding(.top, isPad ? 160 : 40)
        } footer: {
            EmptyView()
        }
    }

    // MARK: - A1 単元

    private var unit: some View {
        let units = OnboardingCatalog.units(grade: model.profile.grade ?? "中3")
        return OnboardingScaffold(onBack: back, isPad: isPad) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingTitle(title: "どの単元ですか", detail: "\(model.profile.grade ?? "") 数学")
                if isPad {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(units, id: \.self) { unit in unitRow(unit, card: true) }
                    }
                } else {
                    OnboardingListCard {
                        ForEach(Array(units.enumerated()), id: \.element) { index, unit in
                            unitRow(unit, card: false)
                            if index < units.count - 1 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 16) }
                        }
                    }
                }
            }
        } footer: {
            OnboardingPrimaryButton(title: "次へ", isEnabled: model.selectedUnit != nil, identifier: "onboarding-unit-next") { model.commitUnit() }
        }
    }

    private func unitRow(_ unit: String, card: Bool) -> some View {
        let selected = model.selectedUnit == unit
        return Button { model.selectedUnit = unit } label: {
            HStack {
                Text(unit).font(Typography.sans(size: 15, weight: selected ? .bold : .medium)).foregroundStyle(Theme.primaryText)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.primaryText) }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: card ? 44 : 48)
            .background {
                if card {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.accentColor.opacity(0.18) : Theme.card)
                        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.accentColor : Theme.hairline, lineWidth: 1) }
                } else if selected {
                    Theme.accentColor.opacity(0.18)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - A2 次のテストまで

    private var untilTest: some View {
        OnboardingScaffold(onBack: back, isPad: isPad) {
            VStack(alignment: .leading, spacing: 20) {
                OnboardingTitle(title: "次のテストまでどれくらいですか", detail: "進めるペースを決めます。")
                OnboardingPillGrid(options: OnboardingCatalog.untilTest, selection: model.profile.untilTest, columns: isPad ? 2 : 1) { value in
                    model.profile.untilTest = value
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        model.chooseUntilTest(value)
                    }
                }
            }
        } footer: {
            EmptyView()
        }
    }

    // MARK: - A3 問題のページ・U2 授業の資料

    @State private var isCameraPresented = false
    @State private var isSourceDialogPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    private var pages: some View {
        let unitTitle = model.profile.unit ?? "この単元"
        return OnboardingScaffold(onBack: back, isPad: isPad) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingTitle(title: "\(unitTitle)の問題のページはありますか", detail: "教科書やワーク、プリントの問題を撮ると、テストに近い問題で練習できます。")
                HStack(spacing: 10) {
                    ForEach(["教科書", "ワーク", isPad ? "プリント・PDF" : "プリント"], id: \.self) { name in pageSample(name) }
                }
                Text("解答のページもあれば、一緒に撮ってください。")
                    .font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
                materialStatus
            }
        } footer: {
            materialButtons(onSkip: { model.clearMaterials(); model.startPlanning() }, onDone: { model.startPlanning() }, doneTitle: "計画を作る", photoFirst: isPad)
        }
        .modifier(materialPickers)
    }

    private func pageSample(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(name).font(Typography.sans(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
            ForEach([1.0, 0.7, 0.85], id: \.self) { width in
                GeometryReader { geometry in
                    Capsule().fill(Theme.hairline).frame(width: geometry.size.width * width, height: 3)
                }
                .frame(height: 3)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1) }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var materialStatus: some View {
        if model.isImportingMaterial {
            HStack(spacing: 10) {
                StruisLoadingIndicator().controlSize(.small)
                Text("読み込んでいます").font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
            }
        }
        if !model.materials.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.growthColor)
                Text(model.profile.route == .university ? (model.materialSummary ?? "") : "撮ったページ \(model.materials.count)枚")
                    .font(Typography.sans(size: 15, weight: .bold)).foregroundStyle(Theme.primaryText)
                Spacer()
                Button("外す") { model.clearMaterials() }
                    .font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.accentColor)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("onboarding-materials")
        }
        if let error = model.materialError {
            Text(error).font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.regressColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func materialButtons(onSkip: @escaping () -> Void, onDone: @escaping () -> Void, doneTitle: String, photoFirst: Bool) -> some View {
        if model.materials.isEmpty {
            if photoFirst {
                OnboardingPrimaryButton(title: "写真・PDF から選ぶ", identifier: "onboarding-material-pick") { isSourceDialogPresented = true }
                OnboardingSecondaryButton(title: "撮る", identifier: "onboarding-material-camera") { isCameraPresented = true }
            } else {
                OnboardingPrimaryButton(title: "撮る", identifier: "onboarding-material-camera") { isCameraPresented = true }
                OnboardingSecondaryButton(title: "写真・PDF から選ぶ", identifier: "onboarding-material-pick") { isSourceDialogPresented = true }
            }
            OnboardingTextButton(title: "ないので進む", identifier: "onboarding-material-skip", action: onSkip)
        } else {
            OnboardingPrimaryButton(title: doneTitle, identifier: "onboarding-material-done", action: onDone)
            OnboardingSecondaryButton(title: "撮り足す", identifier: "onboarding-material-camera") { isCameraPresented = true }
            OnboardingTextButton(title: "写真・PDF から選ぶ") { isSourceDialogPresented = true }
        }
    }

    private var materialPickers: MaterialPickers {
        MaterialPickers(model: model, isCameraPresented: $isCameraPresented, isSourceDialogPresented: $isSourceDialogPresented,
                        isPhotoPickerPresented: $isPhotoPickerPresented, isFileImporterPresented: $isFileImporterPresented, selectedPhotos: $selectedPhotos)
    }

    // MARK: - B1 やり直す単元

    private var weakUnit: some View {
        OnboardingScaffold(onBack: back, isPad: isPad) {
            VStack(alignment: .leading, spacing: 20) {
                OnboardingTitle(title: "やり直したい単元はどれですか")
                ForEach(OnboardingCatalog.weakGroups(grade: model.profile.grade ?? "中3"), id: \.grade) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.grade).font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
                        OnboardingFlow {
                            ForEach(group.units, id: \.self) { unit in
                                OnboardingChip(title: unit, isSelected: model.selectedUnit == unit) { model.selectedUnit = unit }
                            }
                        }
                    }
                }
            }
        } footer: {
            OnboardingPrimaryButton(title: "計画を作る", isEnabled: model.selectedUnit != nil, identifier: "onboarding-weak-next") { model.commitWeakUnit() }
        }
    }

    // MARK: - U1〜U3

    @FocusState private var isTopicFocused: Bool

    private var topic: some View {
        OnboardingScaffold(onBack: back, isPad: isPad) {
            VStack(alignment: .leading, spacing: 16) {
                OnboardingTitle(title: "何を勉強しますか", detail: "授業名や分野の名前で構いません。")
                Text("科目・分野").font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                TextField("例: 解析学I", text: $model.universityTopic)
                    .font(Typography.sans(size: 16, weight: .medium))
                    .padding(.horizontal, 18)
                    .frame(minHeight: 52)
                    .background(Theme.card, in: Capsule())
                    .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
                    .focused($isTopicFocused)
                    .accessibilityIdentifier("onboarding-topic-field")
                OnboardingFlow {
                    ForEach(OnboardingCatalog.universityTopics, id: \.self) { topic in
                        OnboardingChip(title: topic, tinted: true) { model.universityTopic = topic }
                    }
                }
            }
        } footer: {
            OnboardingPrimaryButton(title: "次へ", isEnabled: !model.universityTopic.trimmingCharacters(in: .whitespaces).isEmpty, identifier: "onboarding-topic-next") {
                isTopicFocused = false
                model.commitTopic()
            }
        }
    }

    private var material: some View {
        OnboardingScaffold(onBack: back, isPad: isPad) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingTitle(title: "授業の資料はありますか", detail: "資料があると、その授業の言葉づかいと範囲に合わせて進めます。")
                OnboardingListCard {
                    ForEach(Array(OnboardingCatalog.universityMaterials.enumerated()), id: \.element) { index, name in
                        Text(name).font(Typography.sans(size: 14, weight: .medium)).foregroundStyle(Theme.primaryText)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 16)
                        if index < OnboardingCatalog.universityMaterials.count - 1 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 16) }
                    }
                }
                Text("資料は採点と説明のために Claude に送り、この端末と iCloud に保存します。")
                    .font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                materialStatus
            }
        } footer: {
            materialButtons(onSkip: { model.clearMaterials(); model.go(.goal) }, onDone: { model.go(.goal) }, doneTitle: "次へ", photoFirst: true)
        }
        .modifier(materialPickers)
    }

    @FocusState private var isGoalFocused: Bool

    private var goal: some View {
        OnboardingScaffold(onBack: back, isPad: isPad) {
            VStack(alignment: .leading, spacing: 14) {
                OnboardingTitle(title: "何ができるようになりたいですか", detail: "いつまでに、何を、どこまで。思いつくまま書いてください。")
                if let summary = model.materialSummary { OnboardingInfoChip(text: summary) }
                Text("やりたいこと").font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                TextEditor(text: $model.universityGoal)
                    .font(Typography.sans(size: 16, weight: .medium))
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .frame(minHeight: 150)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Theme.Radius.cardLarge, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1) }
                    .focused($isGoalFocused)
                    .accessibilityIdentifier("onboarding-goal-field")
            }
        } footer: {
            OnboardingPrimaryButton(title: "計画を作る", isEnabled: !model.universityGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, identifier: "onboarding-goal-next") {
                isGoalFocused = false
                model.commitGoal()
            }
        }
    }

    // MARK: - 通知

    @State private var isRequestingNotification = false

    private var notify: some View {
        OnboardingScaffold(isPad: isPad) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingTitle(title: "勉強する時間に知らせますか", detail: "選んだ時間に、その日にやることを1つ知らせます。")
                Text("通知の例").font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 12) {
                    StruisMark(size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Struis").font(Typography.sans(size: 14, weight: .bold)).foregroundStyle(Theme.primaryText)
                        Text(model.reminderExample).font(Typography.sans(size: 14, weight: .medium)).foregroundStyle(Theme.primaryText)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1) }
                Text("知らせる時間").font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText).padding(.top, 4)
                OnboardingPillGrid(options: OnboardingCatalog.reminderHours.map { "\($0):00" }, selection: "\(model.reminderHour):00") { value in
                    model.reminderHour = Int(value.prefix { $0 != ":" }) ?? 20
                }
            }
            .padding(.top, isPad ? 60 : 12)
        } footer: {
            // 前置きの画面のボタンは「次へ」の 1 つだけ(HIG: Privacy)。押すと iOS の確認が出る。
            OnboardingPrimaryButton(title: "次へ", isEnabled: !isRequestingNotification, identifier: "onboarding-notify-next") {
                isRequestingNotification = true
                Task {
                    await StudyReminder.request(hour: model.reminderHour, subunitTitle: model.draft?.subunits.first?.title ?? model.profile.unit ?? "今日の小単元")
                    isRequestingNotification = false
                    model.finish()
                    onFinish()
                }
            }
            Text("次へを押すと端末の確認が出ます。あとから設定で変えられます。")
                .font(Typography.sans(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Claude を使えない端末

    private var unsupported: some View {
        OnboardingScaffold(showsBrand: true, isPad: isPad) {
            VStack(spacing: 14) {
                Spacer(minLength: isPad ? 160 : 200)
                Text("?")
                    .font(Typography.sans(size: 30, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 72, height: 72)
                    .background(Theme.hairline.opacity(2.5), in: Circle())
                Text("この端末では採点と説明を使えません")
                    .font(Typography.sans(size: 22, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                Text("Claude を使うための確認が、この端末ではできませんでした。iPhone か iPad で開いてください。")
                    .font(Typography.sans(size: 14, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .frame(maxWidth: .infinity)
        } footer: {
            OnboardingSecondaryButton(title: "もう一度確かめる", identifier: "onboarding-unsupported-retry") { model.recheckAvailability() }
        }
    }
}

/// 撮る・写真・PDF から選ぶ(A3 問題のページ・U2 授業の資料)。
private struct MaterialPickers: ViewModifier {
    let model: OnboardingModel
    @Binding var isCameraPresented: Bool
    @Binding var isSourceDialogPresented: Bool
    @Binding var isPhotoPickerPresented: Bool
    @Binding var isFileImporterPresented: Bool
    @Binding var selectedPhotos: [PhotosPickerItem]

    func body(content: Content) -> some View {
        content
            .background {
                ChatCameraPresentation(isPresented: $isCameraPresented, batch: ChatCameraBatch(existingCount: model.materials.count, limit: 8) { photos in
                    model.addMaterialPhotos(photos)
                })
            }
            .confirmationDialog("資料を選ぶ", isPresented: $isSourceDialogPresented) {
                Button("写真から選ぶ") { isPhotoPickerPresented = true }
                Button("ファイル(PDF)から選ぶ") { isFileImporterPresented = true }
            }
            .photosPicker(isPresented: $isPhotoPickerPresented, selection: $selectedPhotos, maxSelectionCount: 8, matching: .images)
            .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
                guard let urls = try? result.get(), !urls.isEmpty else { return }
                model.isImportingMaterial = true
                Task {
                    model.addMaterial(await AttachmentIntake.importFiles(urls, budget: AttachmentIntake.Budget(existing: [])))
                    model.isImportingMaterial = false
                }
            }
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                model.isImportingMaterial = true
                Task {
                    var photos: [Data] = []
                    for item in items { if let file = try? await item.loadTransferable(type: PhotoFile.self), let data = try? Data(contentsOf: file.url) { photos.append(data) } }
                    model.addMaterialPhotos(photos, name: "写真")
                    selectedPhotos = []
                    model.isImportingMaterial = false
                }
            }
    }
}
