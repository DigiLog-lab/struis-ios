import SwiftUI

/// 計画づくりを待つ画面と、計画(#40 の 8)。iPad は説明を左、小単元の一覧を右に置く。
struct OnboardingPlanView: View {
    let model: OnboardingModel
    let learnerData: LearnerData
    let isPad: Bool
    @State private var isRebuildPresented = false
    @State private var isDeadlinePresented = false

    var body: some View {
        Group {
            if model.step == .plan, let draft = model.draft {
                plan(draft)
            } else {
                waiting
            }
        }
        .task(id: model.step) {
            if model.step == .planWait {
                model.makePlan(assets: learnerData.assets, turns: learnerData.turns, runner: learnerData.runner)
            }
        }
    }

    private var subject: String {
        model.profile.route == .university ? (model.profile.universityTopic ?? "") : (model.profile.unit ?? "\(model.profile.grade ?? "") 数学")
    }

    // MARK: - 待つ

    private var waiting: some View {
        OnboardingScaffold(isPad: isPad) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingTitle(title: "\(subject)の計画を作っています")
                VStack(alignment: .leading, spacing: 14) {
                    if !model.profile.trial.isEmpty { doneRow("お試しの\(model.profile.trial.count)問の結果を読みました") }
                    if !model.materials.isEmpty {
                        doneRow(model.profile.route == .university ? "資料を読みました(\(model.materials.count)件)" : "撮ったページを読みました(\(model.materials.count)枚)")
                    }
                    if let error = model.planError {
                        TrialErrorText(text: error)
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack(spacing: 10) {
                                StruisLoadingIndicator().controlSize(.regular)
                                Text("小単元を並べています").font(Typography.sans(size: 15, weight: .medium)).foregroundStyle(Theme.primaryText)
                                Text("\(max(0, Int(context.date.timeIntervalSince(model.planStartedAt ?? context.date))))秒")
                                    .font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.tertiaryText).monospacedDigit()
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("onboarding-plan-waiting")
                    }
                }
            }
            .padding(.top, isPad ? 60 : 20)
        } footer: {
            if model.planError != nil {
                OnboardingPrimaryButton(title: "もう一度作る", identifier: "onboarding-plan-retry") {
                    model.makePlan(assets: learnerData.assets, turns: learnerData.turns, runner: learnerData.runner)
                }
            }
        }
    }

    private func doneRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            VerdictMark(correct: true, size: 22)
            Text(text).font(Typography.sans(size: 15, weight: .medium)).foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 計画

    @ViewBuilder
    private func plan(_ draft: OnboardingPlanDraft) -> some View {
        if isPad {
            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 16) {
                    description(draft)
                    Spacer()
                    VStack(spacing: 4) {
                        startButton
                        rebuildButton
                    }
                    .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
                    subunitList(draft)
                    checkHint
                }
                .frame(width: 380)
            }
            .padding(.horizontal, 100)
            .padding(.top, 80)
            .padding(.bottom, 32)
            .background(Theme.ground.ignoresSafeArea())
        } else {
            OnboardingScaffold {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        OnboardingTitle(title: draft.displayHeading)
                        // 説明文には式が入る(`$x+1=5$`)。iPad の横並びと同じく、数式を組む部品で描く。
                        if !draft.lead.isEmpty {
                            TimelineRichText(text: draft.lead, size: 15, color: Theme.secondaryText)
                        }
                    }
                    chips
                    subunitList(draft)
                    checkHint
                    footer(draft)
                }
                .padding(.top, 12)
            } footer: {
                startButton
                rebuildButton
            }
        }
    }

    private func description(_ draft: OnboardingPlanDraft) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingTitle(title: draft.displayHeading)
            chips
            if !draft.lead.isEmpty {
                TimelineRichText(text: draft.lead, size: 14, color: Theme.secondaryText)
            }
            footer(draft)
        }
    }

    @ViewBuilder
    private var chips: some View {
        if model.deadline != nil || !model.planChips.isEmpty {
            HStack(spacing: 8) {
                if let deadline = model.deadline { deadlineButton(deadline) }
                ForEach(model.planChips, id: \.self) { OnboardingInfoChip(text: $0) }
            }
        }
    }

    /// 期限(「8月31日まで」)。押すと日付を直せる(#132)。
    private func deadlineButton(_ deadline: Date) -> some View {
        Button { isDeadlinePresented = true } label: {
            HStack(spacing: 6) {
                Text(StudyDeadline.label(deadline)).font(Typography.sans(size: 14, weight: .medium))
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Theme.primaryText.opacity(0.09), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("期限の日付を変えます")
        .accessibilityIdentifier("onboarding-plan-deadline")
        .sheet(isPresented: $isDeadlinePresented) {
            NavigationStack {
                DatePicker("期限", selection: Binding(get: { model.deadline ?? deadline }, set: { model.deadline = $0 }),
                           in: Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(.horizontal, 20)
                    .navigationTitle("いつまでに")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完了") { isDeadlinePresented = false }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .presentationDetents([.medium, .large])
            .environment(\.locale, Locale(identifier: "ja_JP"))
        }
    }

    private func footer(_ draft: OnboardingPlanDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note = model.trialFallbackNote {
                Text(note).font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
            }
            Text(model.planFooter).font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.planError { TrialErrorText(text: error) }
        }
    }

    private func subunitList(_ draft: OnboardingPlanDraft) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(draft.subunits.enumerated()), id: \.offset) { index, subunit in
                let checked = model.checkOnly.contains(index)
                Button { model.toggleCheck(index) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(index + 1)").font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText).monospacedDigit()
                            .frame(width: 14, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                TimelineRichText(text: subunit.title, size: 15, weight: .medium, color: checked ? Theme.secondaryText : Theme.primaryText)
                                if let ref = subunit.ref {
                                    Text(ref).font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText).monospacedDigit()
                                        .fixedSize()
                                }
                            }
                            if !subunit.note.isEmpty {
                                // 補足にも式が入る(`$\mathbb{R}^n$` など)ので、数式として組む。
                                TimelineRichText(text: subunit.note, size: 12, weight: .medium, color: Theme.secondaryText)
                            }
                        }
                        Spacer(minLength: 0)
                        if checked {
                            Text("確認の1問だけ")
                                .font(Typography.sans(size: 11, weight: .bold))
                                .foregroundStyle(Theme.accentColor)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .overlay(Capsule().strokeBorder(Theme.accentColor, lineWidth: 1))
                                .fixedSize()
                        }
                    }
                    .padding(.vertical, 11)
                    .padding(.horizontal, 12)
                    .background(checked ? Theme.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(subunit.check == nil)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(checked ? .isSelected : [])
                .accessibilityHint(subunit.check == nil ? "" : "押すと、確認の1問だけにします")
                .accessibilityIdentifier("onboarding-plan-subunit-\(index + 1)")
            }
        }
        .padding(.vertical, 6)
        .struisSurface(radius: Theme.Radius.cardLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-plan-subunits")
    }

    @ViewBuilder
    private var checkHint: some View {
        if model.canCheck {
            Text("知っている小単元はタップすると、確認の1問だけにできます")
                .font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
                .accessibilityIdentifier("onboarding-plan-check-hint")
        }
    }

    private var startButton: some View {
        OnboardingPrimaryButton(title: "はじめる", isEnabled: !model.isStarting, identifier: "onboarding-plan-start") {
            Task { _ = await model.begin(ledger: learnerData.ledger) }
        }
    }

    /// 「作り直す」: 難しすぎる(手前から作り直す)か、やりたいことと違う(何をするかを選び直す)か。
    private var rebuildButton: some View {
        OnboardingTextButton(title: "作り直す", identifier: "onboarding-plan-rebuild") { isRebuildPresented = true }
            // iPad の吹き出し(confirmationDialog)は、透けた下の「はじめる」の銅色で選択肢が読みにくくなるので、真ん中に出す。
            .alert("どこが合っていませんか", isPresented: $isRebuildPresented) {
                Button("難しすぎる") { model.rebuildPlan(tooHard: true) }
                Button("やりたいことと違う") { model.rebuildPlan(tooHard: false) }
                Button("やめる", role: .cancel) {}
            } message: {
                Text("難しすぎる時は、もっと手前から作り直します。やりたいことと違う時は、何をするかを選び直します。")
            }
            .disabled(model.isStarting)
    }
}
