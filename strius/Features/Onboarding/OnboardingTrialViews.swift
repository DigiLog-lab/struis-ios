import SwiftUI

/// お試しの1問(#40 の 5・6・14)。iPhone は紙に解いて撮る。iPad は右側全体が紙で、画面に直接書ける(撮るも残す)。
/// 採点を待つ間と結果では、送った答案を右に残し(書き足しはできない)、結果は左の列に出す。
struct OnboardingTrialView: View {
    let model: OnboardingModel
    let learnerData: LearnerData
    let isPad: Bool
    @State private var isCameraPresented = false
    @State private var ink = TimelineInkController()
    @State private var hasInk = false
    @State private var isDrawing = false
    @State private var isInkZoomed = false
    @State private var inkGeneration = 0

    var body: some View {
        Group {
            if isPad { padBody } else { phoneBody }
        }
        .background {
            ChatCameraPresentation(isPresented: $isCameraPresented) { data in submit(data, fromInk: false) }
        }
        .onChange(of: model.problem?.id) { _, _ in
            // 問題を替えた・もう1問: 書いた線を消して、新しい紙にする。
            inkGeneration += 1
            hasInk = false
        }
    }

    private func submit(_ data: Data, fromInk: Bool) {
        model.submitAnswer(data, fromInk: fromInk, assets: learnerData.assets, turns: learnerData.turns, runner: learnerData.runner)
    }

    private var badge: String { "お試し \(model.trialNumber) / \(OnboardingRecords.trialLimit)" }

    // MARK: - iPhone

    @ViewBuilder
    private var phoneBody: some View {
        switch model.step {
        case .grading: phoneGrading
        case .result: phoneResult
        default: phoneSolve
        }
    }

    private var phoneSolve: some View {
        OnboardingScaffold(onBack: model.canGoBack ? { model.back() } : nil, badge: badge) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingTitle(title: "解いたら撮ってください")
                if let problem = model.problem { TrialProblemCard(problem: problem) }
                Text("お試しは3問まで解けます。続きはプランを選んでからです。")
                    .font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                if let error = model.trialError { TrialErrorText(text: error) }
            }
        } footer: {
            OnboardingPrimaryButton(title: "撮る", symbol: "camera", identifier: "onboarding-trial-capture") { isCameraPresented = true }
            OnboardingTextButton(title: "別の問題にする", identifier: "onboarding-trial-swap") { model.swapProblem() }
        }
    }

    private var phoneGrading: some View {
        VStack(spacing: 0) {
            submittedAnswer
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .struisSurface(radius: Theme.Radius.cardLarge)
                .padding(.horizontal, OnboardingMetrics.horizontal)
                .padding(.top, 20)
            Spacer()
            GradingStatus(startedAt: model.gradingStartedAt, vertical: true)
            Spacer()
            Spacer()
        }
        .background(Theme.ground.ignoresSafeArea())
    }

    private var phoneResult: some View {
        OnboardingScaffold {
            VStack(spacing: 18) {
                if let verdict = model.verdict {
                    VerdictMark(correct: verdict.isCorrect, size: 72)
                    VStack(spacing: 8) {
                        Text(verdict.isCorrect ? "正解" : "誤答").font(Typography.sans(size: 22, weight: .bold)).foregroundStyle(Theme.primaryText)
                            .accessibilityIdentifier("onboarding-verdict")
                        if !verdict.learnerAnswer.isEmpty { LearnerAnswerLine(answer: verdict.learnerAnswer, centered: true) }
                    }
                    VerdictComment(verdict: verdict)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 32)
        } footer: {
            resultButtons
        }
    }

    @ViewBuilder
    private var resultButtons: some View {
        OnboardingPrimaryButton(title: "自分の範囲で続ける", identifier: "onboarding-continue") { model.continueToRange() }
        if model.trialRemaining > 0 {
            OnboardingSecondaryButton(title: "もう1問やる（お試しはあと\(model.trialRemaining)問）", identifier: "onboarding-another") { model.anotherProblem() }
        }
    }

    /// 送った答案(紙の写真)。iPad で書いた答案は、右の紙にそのまま残す。
    @ViewBuilder
    private var submittedAnswer: some View {
        if let path = model.answerImagePath, !model.answerFromInk, let image = UIImage(contentsOfFile: StruisPaths.captures.appendingPathComponent(path).path) {
            Image(uiImage: image).resizable().scaledToFit().padding(12)
                .accessibilityLabel("撮った答案")
        } else {
            Color.clear
        }
    }

    // MARK: - iPad

    private var isSolving: Bool { model.step == .trial }

    private var padBody: some View {
        HStack(spacing: 0) {
            padColumn
                .padding(.leading, TimelineLayout.columnLeading)
                .frame(width: TimelineLayout.columnLeading + TimelineLayout.columnWidth, alignment: .leading)
                .padding(.trailing, 40)
            Rectangle().fill(Theme.hairline).frame(width: 1).ignoresSafeArea()
            padPaper
        }
        .background(LinearGradient(colors: [Theme.card, Theme.ground], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    @ViewBuilder
    private var padColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.step {
            case .trial:
                HStack {
                    if model.canGoBack { OnboardingBackButton { model.back() }.padding(.leading, -12) }
                    Spacer()
                    Text(badge).font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.primaryText)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.accentColor.opacity(0.18), in: Capsule())
                        .accessibilityIdentifier("onboarding-trial-badge")
                }
                .frame(height: 44)
                .padding(.top, 20)
                VStack(alignment: .leading, spacing: 18) {
                    OnboardingTitle(title: "解いたら送ってください", detail: "右側のどこにでも Apple Pencil や指で書けます。紙に解いて撮っても構いません。")
                    if let problem = model.problem { TrialProblemCard(problem: problem) }
                    Text("お試しは3問まで解けます。続きはプランを選んでからです。")
                        .font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                    if let error = model.trialError { TrialErrorText(text: error) }
                    OnboardingTextButton(title: "別の問題にする", identifier: "onboarding-trial-swap") { model.swapProblem() }
                        .frame(maxWidth: 160, alignment: .leading)
                }
                .padding(.top, 28)
                Spacer()
            case .grading:
                if let problem = model.problem { TrialProblemCard(problem: problem, compact: true).padding(.top, 72) }
                GradingStatus(startedAt: model.gradingStartedAt, vertical: false).padding(.top, 20)
                Spacer()
            default:
                if let problem = model.problem { TrialProblemCard(problem: problem, compact: true).padding(.top, 72) }
                if let verdict = model.verdict {
                    HStack(spacing: 14) {
                        VerdictMark(correct: verdict.isCorrect, size: 60)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verdict.isCorrect ? "正解" : "誤答").font(Typography.sans(size: 22, weight: .bold)).foregroundStyle(Theme.primaryText)
                                .accessibilityIdentifier("onboarding-verdict")
                            if !verdict.learnerAnswer.isEmpty { LearnerAnswerLine(answer: verdict.learnerAnswer, centered: false) }
                        }
                    }
                    .padding(.top, 18)
                    VerdictComment(verdict: verdict).padding(.top, 18)
                }
                Spacer()
                VStack(spacing: 10) { resultButtons }.padding(.bottom, 32)
            }
        }
    }

    private var padPaper: some View {
        ZStack(alignment: .bottomTrailing) {
            if model.answerFromInk || isSolving {
                TimelineInkCanvas(hasInk: $hasInk, isDrawing: $isDrawing, isZoomed: $isInkZoomed, controller: ink, showsToolPicker: isSolving)
                    .id(inkGeneration)
                    .allowsHitTesting(isSolving)
                    .accessibilityIdentifier("onboarding-ink")
            } else {
                submittedAnswer.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if isSolving, !hasInk, !isInkZoomed {
                VStack(spacing: 8) {
                    Image(systemName: TimelineSymbol.pencil).font(.system(size: 18, weight: .medium))
                    Text("どこにでも書けます").font(Typography.sans(size: 15, weight: .medium))
                }
                .foregroundStyle(Theme.tertiaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("onboarding-ink-hint")
            }
            if isSolving {
                VStack(spacing: 18) {
                    TimelineActionButton(symbol: TimelineSymbol.camera, label: "撮る", identifier: "onboarding-trial-capture") { isCameraPresented = true }
                    TimelineActionButton(symbol: TimelineSymbol.send, label: "送る", prominent: true, isEnabled: hasInk,
                                         diameter: TimelineLayout.sendDiameter, identifier: "onboarding-trial-send") {
                        if let data = ink.image() { submit(data, fromInk: true) }
                    }
                }
                .padding(.trailing, 28)
                .padding(.bottom, 32)
                .opacity(isDrawing ? 0.35 : 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !isSolving {
                Text("送った答案(書き足しはできません)")
                    .font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.hairline, in: Capsule())
                    .padding(.top, 32).padding(.trailing, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 問題のカード(「中3 数学・二次方程式」・問題文・式)。
struct TrialProblemCard: View {
    let problem: TrialProblem
    var compact = false

    var body: some View {
        VStack(alignment: compact ? .center : .leading, spacing: compact ? 8 : 14) {
            Text(problem.label).font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !compact || problem.math.isEmpty {
                TimelineRichText(text: problem.prompt, size: compact ? 13 : 15, color: compact ? Theme.secondaryText : Theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !problem.math.isEmpty {
                HStack {
                    Spacer(minLength: 0)
                    TimelineMath(latex: problem.math, size: compact ? 18 : 26).fixedSize()
                    Spacer(minLength: 0)
                }
                .opacity(compact ? 0.8 : 1)
            }
        }
        .padding(compact ? 16 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .struisSurface(radius: Theme.Radius.cardLarge)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding-trial-problem")
    }
}

/// ○ か ×。
struct VerdictMark: View {
    let correct: Bool
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            Circle().fill(correct ? Theme.growthColor : Theme.regressColor.opacity(0.2))
            if correct {
                Circle().strokeBorder(Theme.card, lineWidth: size * 0.075).frame(width: size * 0.38, height: size * 0.38)
            } else {
                Circle().strokeBorder(Theme.regressColor, lineWidth: 1.5)
                Image(systemName: "xmark").font(.system(size: size * 0.3, weight: .bold)).foregroundStyle(Theme.primaryText)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(correct ? "正解" : "誤答")
    }
}

/// 「書いた答え x = 2, 3」。
struct LearnerAnswerLine: View {
    let answer: String
    let centered: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("書いた答え").font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
            TimelineRichText(text: answer, size: 13, color: Theme.secondaryText).fixedSize()
        }
        .frame(maxWidth: centered ? .infinity : nil, alignment: centered ? .center : .leading)
    }
}

/// 採点の言葉(誤答の時は、線の下に正しい解き方)。
struct VerdictComment: View {
    let verdict: TrialVerdict

    var body: some View {
        let comment = verdict.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let solution = verdict.solution.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty || (!verdict.isCorrect && !solution.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                if !comment.isEmpty { TimelineRichText(text: comment, size: 15, weight: .medium) }
                if !verdict.isCorrect, !solution.isEmpty {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    TimelineRichText(text: solution, size: 14, color: Theme.secondaryText)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .struisSurface(radius: Theme.Radius.cardLarge)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onboarding-verdict-comment")
        }
    }
}

/// 「答えを読んでいます 4秒」。
struct GradingStatus: View {
    let startedAt: Date?
    let vertical: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt ?? context.date)))
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                StruisLoadingIndicator().controlSize(vertical ? .large : .regular)
                if vertical {
                    Text("答えを読んでいます").font(Typography.sans(size: 15, weight: .medium)).foregroundStyle(Theme.primaryText)
                    Text("\(seconds)秒").font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.tertiaryText).monospacedDigit()
                } else {
                    Text("答えを読んでいます").font(Typography.sans(size: 14, weight: .medium)).foregroundStyle(Theme.primaryText)
                    Text("\(seconds)秒").font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.tertiaryText).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding-grading")
    }
}

struct TrialErrorText: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(Typography.sans(size: 13, weight: .medium))
            .foregroundStyle(Theme.regressColor)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("onboarding-trial-error")
    }
}

/// お試しの3問を解き終えた(○×の結果から購入画面へ)。
struct OnboardingTrialDoneView: View {
    let model: OnboardingModel
    let isPad: Bool

    var body: some View {
        let records = model.profile.trial.suffix(OnboardingRecords.trialLimit)
        OnboardingScaffold(isPad: isPad) {
            VStack(alignment: .leading, spacing: 22) {
                OnboardingTitle(title: "お試しの3問を解き終えました")
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(records.last?.label ?? "\(model.profile.grade ?? "") 数学").font(Typography.sans(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Text("\(records.filter(\.correct).count) / \(OnboardingRecords.trialLimit)").font(Typography.sans(size: 16, weight: .bold)).foregroundStyle(Theme.primaryText)
                    }
                    HStack(spacing: 8) {
                        ForEach(0..<OnboardingRecords.trialLimit, id: \.self) { index in
                            let record = index < records.count ? Array(records)[index] : nil
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(record.map { $0.correct ? Theme.growthColor : Theme.regressColor.opacity(0.18) } ?? Theme.hairline)
                                if let record {
                                    if record.correct {
                                        Circle().strokeBorder(Theme.card, lineWidth: 2.5).frame(width: 16, height: 16)
                                    } else {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.regressColor, lineWidth: 1)
                                        Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.primaryText)
                                    }
                                }
                            }
                            .frame(height: 56)
                            .accessibilityLabel(record.map { $0.correct ? "正解" : "誤答" } ?? "記録なし")
                        }
                    }
                    Text("解いた3問の記録は残ります。プランを選ぶと、この結果をもとに自分の範囲の計画を作ります。")
                        .font(Typography.sans(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .struisSurface(radius: Theme.Radius.cardLarge)
            }
            .padding(.top, 20)
        } footer: {
            OnboardingPrimaryButton(title: "プランを選ぶ", identifier: "onboarding-trial-done-next") { model.go(.paywall) }
        }
    }
}
