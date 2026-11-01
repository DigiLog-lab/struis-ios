import SwiftUI

/// 計画づくりを待つ画面と、計画(#40 の 8)。iPad は説明を左、小単元の一覧を右に置く。
struct OnboardingPlanView: View {
    let model: OnboardingModel
    let learnerData: LearnerData
    let isPad: Bool

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
                    if !model.profile.trial.isEmpty { doneRow("お試しの1問の結果を読みました") }
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
                    startButton.frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                subunitList(draft).frame(width: 380)
            }
            .padding(.horizontal, 100)
            .padding(.top, 80)
            .padding(.bottom, 32)
            .background(Theme.ground.ignoresSafeArea())
        } else {
            OnboardingScaffold {
                VStack(alignment: .leading, spacing: 16) {
                    OnboardingTitle(title: draft.displayHeading, detail: draft.lead.isEmpty ? nil : draft.lead)
                    chips
                    subunitList(draft)
                    footer(draft)
                }
                .padding(.top, 12)
            } footer: {
                startButton
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
        if !model.planChips.isEmpty {
            HStack(spacing: 8) { ForEach(model.planChips, id: \.self) { OnboardingInfoChip(text: $0) } }
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
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(index + 1)").font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText).monospacedDigit()
                        .frame(width: 14, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        TimelineRichText(text: subunit.title, size: 15, weight: .medium)
                        if !subunit.note.isEmpty {
                            Text(subunit.note).font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 11)
                .padding(.horizontal, 18)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 6)
        .struisSurface(radius: Theme.Radius.cardLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-plan-subunits")
    }

    private var startButton: some View {
        OnboardingPrimaryButton(title: "はじめる", isEnabled: !model.isStarting, identifier: "onboarding-plan-start") {
            Task { _ = await model.startPlan(ledger: learnerData.ledger) }
        }
    }
}
