import SwiftUI

/// 問題。問題文、答案履歴、「解き直す」(＝この問題を撮る)。
struct WorkbookProblemView: View {
    @Environment(WorkbookStore.self) private var store
    @Environment(WorkbookCoordinator.self) private var coordinator
    let problemID: String

    private var detail: WorkbookProblemDetailDTO? { store.problems[problemID] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let detail {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(detail.unitTitle) · \(detail.subunitTitle)")
                            .font(Typography.micro)
                            .foregroundStyle(Theme.secondaryText)
                        WorkbookPromptText(text: detail.tile.prompt, lineLimit: nil)
                            .font(Typography.body)
                        HStack(spacing: 8) {
                            WorkbookTile(state: detail.tile.state, assisted: detail.tile.assisted, size: 18)
                            if detail.tile.hintGiven {
                                Text("ヒントあり")
                                    .font(Typography.micro)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            if detail.tile.source == "capture" {
                                Text("紙から")
                                    .font(Typography.micro)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .struisSurface(radius: Theme.Radius.card)

                    if !detail.attempts.isEmpty {
                        Text("答案")
                            .font(Typography.eyebrow)
                            .foregroundStyle(Theme.secondaryText)
                        ForEach(Array(detail.attempts.enumerated()), id: \.offset) { _, attempt in
                            Button {
                                coordinator.open(.capture(attempt.captureId))
                            } label: {
                                HStack(spacing: 12) {
                                    WorkbookVerdictMark(verdict: attempt.verdict)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 8) {
                                            if !attempt.errorTag.isEmpty {
                                                Text(attempt.errorTag)
                                                    .font(Typography.caption)
                                                    .foregroundStyle(WorkbookPalette.wrong)
                                            }
                                            if attempt.assisted {
                                                Text("ヒントあり")
                                                    .font(Typography.micro)
                                                    .foregroundStyle(Theme.secondaryText)
                                            }
                                        }
                                        if !attempt.note.isEmpty {
                                            Text(attempt.note)
                                                .font(Typography.caption)
                                                .foregroundStyle(Theme.secondaryText)
                                        }
                                    }
                                    Spacer()
                                    WorkbookRelativeTime(iso: attempt.createdAt)
                                        .font(Typography.micro)
                                        .foregroundStyle(Theme.tertiaryText)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .struisSurface(radius: Theme.Radius.stat)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 96)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle("問題")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                WorkbookQuestionPill {
                    coordinator.ask(WorkbookQuestionContext(
                        subunitId: detail?.subunitId, setId: nil, title: detail?.subunitTitle,
                        stageLabel: nil, initialDraft: nil
                    ))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button {
                    coordinator.capture(context: WorkbookViewRef(subunitId: detail?.subunitId, setId: nil))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                        Text("解き直す")
                    }
                    .font(Typography.bodyEmphasized)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .glassEffect(.regular.tint(Theme.Palette.accentLight).interactive(), in: Capsule())
                .accessibilityIdentifier("workbook-problem-retry")
                Spacer()
            }
            .padding(.bottom, 8)
        }
        .task(id: problemID) { _ = await store.loadProblem(id: problemID) }
    }
}
