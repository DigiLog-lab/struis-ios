import SwiftUI

enum ProblemCatalogDestination: Hashable {
    case sheet(String)
    case organizing
    case problem(ProblemCatalogProblemContext)
}

struct ProblemCatalogSheetsHomeView: View {
    let store: ProblemCatalogSheetStore
    let onClose: () -> Void
    /// タイルのタップ/長押しメニューから問題詳細へpushする(NavigationLinkはcontextMenu内で使えないため)。
    var onOpenProblemDetail: (ProblemCatalogProblemContext) -> Void = { _ in }

    @State private var isSearchCollapsed = false
    @FocusState private var isSearchFocused: Bool
    @Namespace private var glassNamespace

    var body: some View {
        content
            .navigationTitle("問題カタログ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("問題カタログを閉じる")
                }
            }
            .safeAreaInset(edge: .bottom) {
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            .task {
                await store.loadInitial()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.loadState {
        case .idle, .loading:
            ProgressView("問題を集めています").progressViewStyle(StruisProgressViewStyle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ProblemCatalogStateView(
                symbol: "wifi.exclamationmark",
                title: message,
                detail: "接続を確認して、もう一度お試しください",
                actionTitle: "もう一度読み込む"
            ) {
                Task { await store.retry() }
            }
        case .empty:
            ProblemCatalogStateView(
                symbol: "tray",
                title: "ここには問題がまだありません",
                detail: "問題をアップロードすると、ここに並びはじめます",
                actionTitle: nil,
                action: {}
            )
        case .loaded:
            loadedContent
        }
    }

    private var loadedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let errorMessage = store.errorMessage {
                    ProblemCatalogErrorBanner(message: errorMessage)
                }

                if let results = store.searchResults {
                    searchResultsSection(results)
                } else {
                    sheetSections
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .struisRefreshable { await store.refresh() }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { oldValue, newValue in
            guard !isSearchFocused else { return }
            let delta = newValue - oldValue
            if newValue < 32 || delta < -8 {
                setSearchCollapsed(false)
            } else if delta > 8 {
                setSearchCollapsed(true)
            }
        }
    }

    @ViewBuilder
    private var sheetSections: some View {
        if let headline = store.headline {
            Text(headline)
                .font(.title3.weight(.semibold))
                .lineLimit(3)
                .padding(.trailing, 8)
        }

        if store.subjectFilters.count > 1 {
            subjectChips
        }

        legendRow
            .padding(.bottom, 2)

        ForEach(store.activeSheets) { sheet in
            ProblemCatalogSheetCard(
                sheet: sheet,
                showsSubject: store.selectedSubject == nil,
                onOpenProblemDetail: onOpenProblemDetail
            )
        }

        if store.selectedSubject == nil, !store.organizingSlots.isEmpty {
            NavigationLink(value: ProblemCatalogDestination.organizing) {
                ProblemCatalogOrganizingCard(count: store.organizingSlots.count)
            }
            .buttonStyle(.plain)
        }

        if !store.completedSheets.isEmpty {
            Text("やりきった単元")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            ForEach(store.completedSheets) { sheet in
                NavigationLink(value: ProblemCatalogDestination.sheet(sheet.sheetID)) {
                    ProblemCatalogCompletedSheetRow(sheet: sheet)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func searchResultsSection(_ results: [ProblemCatalogProblemContext]) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.searchNotice ?? "検索結果")
                    .font(.subheadline.weight(.semibold))
                Text("\(results.count)問")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("終了") {
                store.clearSearch()
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.bottom, 4)

        if results.isEmpty {
            ProblemCatalogStateView(
                symbol: "magnifyingglass",
                title: "該当する問題が見つかりませんでした",
                detail: "言い方を少し変えて試せます",
                actionTitle: nil,
                action: {}
            )
            .frame(minHeight: 220)
        } else {
            VStack(spacing: 0) {
                ForEach(results) { result in
                    NavigationLink(value: ProblemCatalogDestination.problem(result)) {
                        ProblemCatalogProblemRow(context: result)
                    }
                    .buttonStyle(.plain)
                    if result.id != results.last?.id {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// 科目の絞り込みチップ。2科目以上あるときだけ表示される。
    private var subjectChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                subjectChip(title: "すべて", subject: nil)
                ForEach(store.subjectFilters, id: \.self) { subject in
                    subjectChip(title: subject, subject: subject)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func subjectChip(title: String, subject: String?) -> some View {
        let isSelected = store.selectedSubject == subject
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                store.selectedSubject = subject
            }
        } label: {
            Text(title)
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isSelected
                        ? AnyShapeStyle(Color(uiColor: .label))
                        : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: Capsule()
                )
                .foregroundStyle(
                    isSelected
                        ? Color(uiColor: .systemBackground)
                        : Color(uiColor: .label)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)で絞り込む")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 凡例と全体在庫を兼ねる行。Text連結なので大きな文字サイズでも自然に折り返す。
    private var legendRow: some View {
        let counts = store.tileCounts
        return (
            Text("●")
                .foregroundStyle(ProblemCatalogSheetPalette.solvedStandard)
            + Text(" \(counts.solved) 正解済み(濃いほど定着)  ")
            + Text("●")
                .foregroundStyle(ProblemCatalogSheetPalette.retry)
            + Text(" \(counts.retry) 解き直し待ち  ")
            + Text("○")
                .foregroundStyle(.secondary)
            + Text(" \(counts.notStarted) 未着手")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var searchBar: some View {
        GlassEffectContainer {
            HStack {
                Spacer(minLength: 0)
                if isSearchCollapsed && !isSearchFocused {
                    Button {
                        setSearchCollapsed(false)
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.medium))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("catalog-search", in: glassNamespace)
                    .accessibilityLabel("問題を検索")
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("前に符号で間違えた二次関数", text: searchQueryBinding)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .focused($isSearchFocused)
                            .onSubmit {
                                Task { await store.search() }
                            }

                        if store.isSearching {
                            ProgressView().progressViewStyle(StruisProgressViewStyle())
                                .controlSize(.small)
                        } else if !store.searchQuery.isEmpty {
                            Button {
                                store.clearSearch()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("検索文を消す")
                        }
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("catalog-search", in: glassNamespace)
                }
            }
        }
        .animation(.spring(duration: 0.32), value: isSearchCollapsed)
    }

    private func setSearchCollapsed(_ collapsed: Bool) {
        guard isSearchCollapsed != collapsed else { return }
        withAnimation(.spring(duration: 0.32)) {
            isSearchCollapsed = collapsed
        }
    }

    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { store.searchQuery },
            set: { store.searchQuery = $0 }
        )
    }
}

struct ProblemCatalogSheetCard: View {
    let sheet: ProblemCatalogSheetDTO
    var showsSubject = true
    var onOpenProblemDetail: (ProblemCatalogProblemContext) -> Void = { _ in }

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: 5),
        count: 6
    )

    private var isNearCompletion: Bool {
        sheet.remainingCount <= 2 && !sheet.isCompleted
    }

    private var firstRetrySlot: ProblemCatalogSheetSlotDTO? {
        sheet.slots.first { $0.tileState == "retry" }
    }

    private var breadcrumb: String {
        "\(sheet.subjectLabel) · \(sheet.displayTitle)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: ProblemCatalogDestination.sheet(sheet.sheetID)) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if showsSubject {
                        Text(sheet.subjectLabel)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.5), in: Capsule())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(sheet.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Group {
                        if isNearCompletion {
                            Text("あと\(sheet.remainingCount)問で完成")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color(red: 0.09, green: 0.55, blue: 0.42))
                        } else {
                            Text("\(sheet.solvedCount) / \(sheet.slots.count)問")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .layoutPriority(1)
                    .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(sheet.displayTitle)、\(sheet.slots.count)問中\(sheet.solvedCount)問正解、一覧を開く"
            )

            LazyVGrid(columns: Self.columns, spacing: 5) {
                ForEach(sheet.slots) { slot in
                    tileButton(for: slot)
                }
                ForEach(0..<max(0, sheet.capacity - sheet.slots.count), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityHidden(true)
                }
            }

            if let retrySlot = firstRetrySlot {
                HStack(spacing: 5) {
                    Text("解き直し待ち")
                        .foregroundStyle(ProblemCatalogSheetPalette.retry)
                    Text(retryCalloutText(for: retrySlot))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if isNearCompletion || firstRetrySlot != nil {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        (firstRetrySlot != nil
                            ? ProblemCatalogSheetPalette.retry
                            : Color(red: 0.09, green: 0.55, blue: 0.42)
                        ).opacity(0.4),
                        lineWidth: 1
                    )
            }
        }
    }

    /// タップ=開く、長押し=ちょい見せ。iOSの既存文法だけで組む。
    private func tileButton(for slot: ProblemCatalogSheetSlotDTO) -> some View {
        let context = ProblemCatalogProblemContext(slot: slot, breadcrumb: breadcrumb)
        return Button {
            onOpenProblemDetail(context)
        } label: {
            ProblemCatalogTileView(slot: slot)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onOpenProblemDetail(context)
            } label: {
                Label("開く", systemImage: "arrow.up.right")
            }
        } preview: {
            ProblemCatalogTilePreviewCard(slot: slot)
        }
    }

    private func retryCalloutText(for slot: ProblemCatalogSheetSlotDTO) -> String {
        if let errorLabel = slot.errorLabels.first {
            return "\(slot.title) — \(errorLabel)でミス"
        }
        return slot.title
    }
}

struct ProblemCatalogOrganizingCard: View {
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("整理中")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ProblemCatalogSheetPalette.organizing)
                Text("\(count)問 · 科目の判定待ち")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(ProblemCatalogSheetPalette.organizing.opacity(0.35), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("整理中の問題、\(count)問")
    }
}

struct ProblemCatalogCompletedSheetRow: View {
    let sheet: ProblemCatalogSheetDTO

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    ProblemCatalogSheetPalette.completed,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(sheet.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(sheet.subjectLabel) · 全\(sheet.slots.count)問正解")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(sheet.displayTitle)、全\(sheet.slots.count)問正解")
    }
}

struct ProblemCatalogStateView: View {
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 58, height: 58)
                    .background(.quaternary.opacity(0.5), in: Circle())

                VStack(spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let actionTitle {
                    Button(actionTitle, action: action)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

struct ProblemCatalogErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(ProblemCatalogSheetPalette.retry)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            ProblemCatalogSheetPalette.retry.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

#if DEBUG
@MainActor
private func makePreviewHomeStore(
    mode: PreviewProblemCatalogSheetService.Mode
) -> ProblemCatalogSheetStore {
    ProblemCatalogSheetStore(
        service: PreviewProblemCatalogSheetService(mode: mode),
        queryDrafter: PreviewProblemCatalogQueryDrafter()
    )
}

@MainActor
struct PreviewProblemCatalogQueryDrafter: ProblemCatalogQueryDrafting {
    func draft(for rawQuery: String) async -> ProblemCatalogClientQueryDraft? { nil }
}

#Preview("通常") {
    NavigationStack {
        ProblemCatalogSheetsHomeView(
            store: makePreviewHomeStore(mode: .loaded),
            onClose: {}
        )
    }
}

#Preview("ダーク") {
    NavigationStack {
        ProblemCatalogSheetsHomeView(
            store: makePreviewHomeStore(mode: .loaded),
            onClose: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("空") {
    NavigationStack {
        ProblemCatalogSheetsHomeView(
            store: makePreviewHomeStore(mode: .empty),
            onClose: {}
        )
    }
}

#Preview("読み込み失敗 / 小型端末") {
    NavigationStack {
        ProblemCatalogSheetsHomeView(
            store: makePreviewHomeStore(mode: .failed),
            onClose: {}
        )
    }
    .frame(width: 320)
}

#Preview("大文字") {
    NavigationStack {
        ProblemCatalogSheetsHomeView(
            store: makePreviewHomeStore(mode: .loaded),
            onClose: {}
        )
    }
    .environment(\.dynamicTypeSize, .accessibility5)
}
#endif
