import SwiftUI

/// 問題詳細。自分がこの問題とどう付き合ってきたかの記録+解き直しの起点。
struct ProblemCatalogProblemDetailView: View {
    let store: ProblemCatalogSheetStore
    let context: ProblemCatalogProblemContext
    let actionError: String?
    let openingProblemBundleID: UUID?
    let onOpenProblem: ((UUID, String?) -> Void)?

    @State private var detail: ProblemCatalogProblemDetailDTO?
    @State private var detailError: String?
    @State private var isLoadingDetail = false
    @State private var relatedProblems: [ProblemCatalogRelatedProblem] = []

    private var problem: ProblemCatalogProblemDTO? { detail?.problem }

    private var state: ProblemCatalogTileState {
        if let progress = problem?.progress {
            if progress.correctCount > 0 { return .solved }
            if progress.attemptCount > 0 { return .retry }
            return .notStarted
        }
        return ProblemCatalogTileState(rawTileState: context.tileState)
    }

    private var breadcrumbText: String? {
        if let problem, !problem.taxonomyPath.isEmpty {
            return problem.taxonomyPath.map(\.title).joined(separator: " › ")
        }
        return context.breadcrumb?.nilIfBlankValue
    }

    private var problemBundleID: UUID? {
        problem?.problemRef.problemBundleUUID ?? context.ref.problemBundleUUID
    }

    private var isOpeningProblem: Bool {
        guard let openingProblemBundleID, let problemBundleID else { return false }
        return openingProblemBundleID == problemBundleID
    }

    private var canRetry: Bool {
        (problem?.status ?? context.problemStatus) == "resolved"
            && problemBundleID != nil
            && onOpenProblem != nil
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header

                if let message = detailError ?? actionError {
                    HStack(spacing: 8) {
                        ProblemCatalogErrorBanner(message: message)
                        if detailError != nil {
                            Button("再読込") {
                                Task { await loadDetail() }
                            }
                            .font(.footnote.weight(.semibold))
                        }
                    }
                }

                promptCard
                attemptsSection
                retryButton
                relatedSection
                managementSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle("問題")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: context.ref.problemID) {
            await loadDetail()
            relatedProblems = await store.loadRelatedProblems(for: context)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let breadcrumbText {
                Text(breadcrumbText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ProblemCatalogRichText(
                    text: problem?.title ?? context.title,
                    font: .headline,
                    katexFontSize: 17,
                    katexFontWeight: 700,
                    lineLimit: 3,
                    maxKatexHeight: 60
                )
                Spacer(minLength: 4)
                if isLoadingDetail {
                    ProgressView().progressViewStyle(StruisProgressViewStyle())
                        .controlSize(.small)
                } else {
                    ProblemCatalogStatusBadge(
                        state: state,
                        isOrganizing: (problem?.status ?? context.problemStatus) == "unresolved"
                    )
                    .layoutPriority(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    @ViewBuilder
    private var promptCard: some View {
        let promptText = problem?.prompt.nilIfBlankValue
        VStack(alignment: .leading, spacing: 10) {
            if let promptText {
                ProblemCatalogRichText(
                    text: promptText,
                    font: .subheadline,
                    katexFontSize: 14,
                    katexFontWeight: 400,
                    lineLimit: nil,
                    maxKatexHeight: 220
                )
            } else if isLoadingDetail {
                Text("問題文を読み込んでいます…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("問題文を表示できませんでした")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let sourceLabel = (problem?.sourceLabel ?? context.sourceLabel)?.nilIfBlankValue {
                Divider()
                Label(sourceLabel, systemImage: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var attemptsSection: some View {
        if let detail, !detail.recentAttempts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("これまでの挑戦")
                    .font(.footnote.weight(.semibold))

                VStack(spacing: 0) {
                    ForEach(detail.recentAttempts) { attempt in
                        HStack(spacing: 10) {
                            Image(
                                systemName: attempt.result == "correct"
                                    ? "checkmark.circle.fill"
                                    : "xmark.circle"
                            )
                            .foregroundStyle(
                                attempt.result == "correct"
                                    ? Color(red: 0.09, green: 0.55, blue: 0.42)
                                    : ProblemCatalogSheetPalette.retry
                            )

                            Text(attemptLabel(attempt))
                                .font(.subheadline)

                            Spacer(minLength: 8)

                            if let date = ProblemCatalogDateFormatting.shortDate(
                                fromISO: attempt.createdAt
                            ) {
                                Text(date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if attempt.id != detail.recentAttempts.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    /// チャット入力欄へ流し込む下書き。送信ボタンひとつで解き直しが始まる文にする。
    private var retryDraft: String {
        let mistake = (problem?.errorLabels.isEmpty == false ? problem?.errorLabels : context.errorLabels)?.first
        switch state {
        case .retry:
            if let mistake {
                return "この問題を解き直します。前回は\(mistake)でミスしたので、そこに気をつけて挑戦します。もう一度出題してください。"
            }
            return "この問題を解き直します。もう一度出題してください。"
        case .solved:
            return "この問題をもう一度解いて、定着しているか確かめたいです。出題してください。"
        case .notStarted:
            return "この問題に挑戦します。出題してください。"
        }
    }

    @ViewBuilder
    private var retryButton: some View {
        if canRetry, let problemBundleID, let onOpenProblem {
            Button {
                onOpenProblem(problemBundleID, retryDraft)
            } label: {
                HStack(spacing: 8) {
                    if isOpeningProblem {
                        ProgressView().progressViewStyle(StruisProgressViewStyle())
                            .controlSize(.small)
                    }
                    Text(retryButtonTitle)
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .disabled(isOpeningProblem)
            .accessibilityHint("この問題の会話に戻って解き直します")
        } else if let problem, problem.status != "resolved" {
            Label(availabilityLabel(problem.status), systemImage: "archivebox")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var relatedSection: some View {
        if !relatedProblems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("つながりのある問題")
                    .font(.footnote.weight(.semibold))

                VStack(spacing: 0) {
                    ForEach(relatedProblems) { related in
                        NavigationLink(
                            value: ProblemCatalogDestination.problem(related.context)
                        ) {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    ProblemCatalogRichText(
                                        text: related.context.title,
                                        font: .subheadline,
                                        katexFontSize: 14,
                                        katexFontWeight: 500,
                                        lineLimit: 2,
                                        maxKatexHeight: 40
                                    )
                                    if let relationLabel = related.relationLabel {
                                        Text(relationLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if related.id != relatedProblems.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var managementSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            managementRow(title: "分類", value: breadcrumbText ?? "整理中")
            Divider().padding(.leading, 14)
            managementRow(
                title: "出典",
                value: (problem?.sourceLabel ?? context.sourceLabel)?.nilIfBlankValue ?? "不明"
            )
            if let revision = detail?.revisions.first(where: \.isCurrent)?.revision {
                Divider().padding(.leading, 14)
                managementRow(title: "版", value: "第\(revision)版")
            }
        }
        .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func managementRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.footnote)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var retryButtonTitle: String {
        switch state {
        case .retry: "解き直す"
        case .solved: "もう一度解く"
        case .notStarted: "解いてみる"
        }
    }

    private func attemptLabel(_ attempt: ProblemCatalogAttemptSummaryDTO) -> String {
        switch attempt.result {
        case "correct": "正解"
        case "incorrect":
            (problem?.errorLabels.first).map { "\($0)でミス" } ?? "不正解"
        case "needs_revision": "要確認"
        default: attempt.status == "completed" ? "完了" : "途中で手が止まった"
        }
    }

    private func availabilityLabel(_ status: String) -> String {
        switch status {
        case "retired": "この問題は履歴のみ残っています"
        case "unresolved": "取り込み内容を確認しています"
        default: "元の問題を開けません"
        }
    }

    private func loadDetail() async {
        detailError = nil
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            detail = try await store.loadProblemDetail(ref: context.ref)
        } catch is CancellationError {
            return
        } catch {
            detailError = "問題の詳細を読み込めませんでした"
        }
    }
}

#if DEBUG
@MainActor
private func makePreviewDetailStore() -> ProblemCatalogSheetStore {
    let store = ProblemCatalogSheetStore(
        service: PreviewProblemCatalogSheetService(mode: .loaded),
        queryDrafter: PreviewProblemCatalogQueryDrafter()
    )
    Task { await store.loadInitial() }
    return store
}

private let previewProblemContext = ProblemCatalogProblemContext(
    slot: .sample(
        problemID: "mech-8",
        title: "作用・反作用とつり合い",
        tileState: "retry",
        errorLabels: ["力の向き"],
        attemptCount: 2,
        correctCount: 0,
        lastAttemptAt: "2026-08-01T21:04:00Z"
    ),
    breadcrumb: "物理 · 力学:運動の法則"
)

#Preview("通常") {
    NavigationStack {
        ProblemCatalogProblemDetailView(
            store: makePreviewDetailStore(),
            context: previewProblemContext,
            actionError: nil,
            openingProblemBundleID: nil,
            onOpenProblem: { _, _ in }
        )
    }
}

#Preview("ダーク") {
    NavigationStack {
        ProblemCatalogProblemDetailView(
            store: makePreviewDetailStore(),
            context: previewProblemContext,
            actionError: nil,
            openingProblemBundleID: nil,
            onOpenProblem: { _, _ in }
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("小型端末") {
    NavigationStack {
        ProblemCatalogProblemDetailView(
            store: makePreviewDetailStore(),
            context: previewProblemContext,
            actionError: nil,
            openingProblemBundleID: nil,
            onOpenProblem: { _, _ in }
        )
    }
    .frame(width: 320)
}

#Preview("大文字") {
    NavigationStack {
        ProblemCatalogProblemDetailView(
            store: makePreviewDetailStore(),
            context: previewProblemContext,
            actionError: nil,
            openingProblemBundleID: nil,
            onOpenProblem: { _, _ in }
        )
    }
    .environment(\.dynamicTypeSize, .accessibility5)
}
#endif
