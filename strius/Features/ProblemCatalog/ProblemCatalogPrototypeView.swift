import SwiftUI

/// 問題カタログのエントリー。シート型カタログ(ホーム/シート詳細/整理中/問題詳細)を
/// NavigationStackで束ねる。AppRootViewからの呼び出しシグネチャは旧グラフ版と同一。
struct ProblemCatalogPrototypeView: View {
    @Environment(APIClient.self) private var apiClient

    private let initialViewID: String?
    @Binding private var actionError: String?
    private let openingProblemBundleID: UUID?
    private let onOpenProblem: ((UUID, String?) -> Void)?
    private let onCancelOpenProblem: () -> Void
    private let onClose: () -> Void

    init(
        initialViewID: String? = nil,
        actionError: Binding<String?> = .constant(nil),
        openingProblemBundleID: UUID? = nil,
        onOpenProblem: ((UUID, String?) -> Void)? = nil,
        onCancelOpenProblem: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.initialViewID = initialViewID
        self._actionError = actionError
        self.openingProblemBundleID = openingProblemBundleID
        self.onOpenProblem = onOpenProblem
        self.onCancelOpenProblem = onCancelOpenProblem
        self.onClose = onClose
    }

    var body: some View {
        APIBackedProblemCatalogSheetsView(
            client: apiClient,
            actionError: $actionError,
            openingProblemBundleID: openingProblemBundleID,
            onOpenProblem: onOpenProblem,
            onCancelOpenProblem: onCancelOpenProblem,
            onClose: onClose
        )
    }
}

private struct APIBackedProblemCatalogSheetsView: View {
    @State private var store: ProblemCatalogSheetStore
    @Binding var actionError: String?

    let openingProblemBundleID: UUID?
    let onOpenProblem: ((UUID, String?) -> Void)?
    let onCancelOpenProblem: () -> Void
    let onClose: () -> Void

    init(
        client: APIClient,
        actionError: Binding<String?>,
        openingProblemBundleID: UUID?,
        onOpenProblem: ((UUID, String?) -> Void)?,
        onCancelOpenProblem: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        _store = State(
            initialValue: ProblemCatalogSheetStore(
                service: APIProblemCatalogSheetService(client: client)
            )
        )
        self._actionError = actionError
        self.openingProblemBundleID = openingProblemBundleID
        self.onOpenProblem = onOpenProblem
        self.onCancelOpenProblem = onCancelOpenProblem
        self.onClose = onClose
    }

    var body: some View {
        ProblemCatalogSheetsNavigationView(
            store: store,
            actionError: $actionError,
            openingProblemBundleID: openingProblemBundleID,
            onOpenProblem: onOpenProblem,
            onCancelOpenProblem: onCancelOpenProblem,
            onClose: onClose
        )
    }
}

struct ProblemCatalogSheetsNavigationView: View {
    let store: ProblemCatalogSheetStore
    @Binding var actionError: String?
    let openingProblemBundleID: UUID?
    let onOpenProblem: ((UUID, String?) -> Void)?
    let onCancelOpenProblem: () -> Void
    let onClose: () -> Void
    var initialDestinations: [ProblemCatalogDestination] = []

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ProblemCatalogSheetsHomeView(
                store: store,
                onClose: onClose,
                onOpenProblemDetail: { context in
                    path.append(ProblemCatalogDestination.problem(context))
                }
            )
                .navigationDestination(for: ProblemCatalogDestination.self) { destination in
                    switch destination {
                    case .sheet(let sheetID):
                        if let sheet = store.sheet(withID: sheetID) {
                            ProblemCatalogSheetDetailView(sheet: sheet)
                        } else {
                            ProblemCatalogStateView(
                                symbol: "tray",
                                title: "この単元を表示できませんでした",
                                detail: "一覧を更新してからもう一度開いてください",
                                actionTitle: nil,
                                action: {}
                            )
                        }
                    case .organizing:
                        ProblemCatalogOrganizingListView(slots: store.organizingSlots)
                    case .problem(let context):
                        ProblemCatalogProblemDetailView(
                            store: store,
                            context: context,
                            actionError: actionError,
                            openingProblemBundleID: openingProblemBundleID,
                            onOpenProblem: onOpenProblem.map { action in
                                { bundleID, draft in
                                    actionError = nil
                                    action(bundleID, draft)
                                }
                            }
                        )
                        .onDisappear {
                            onCancelOpenProblem()
                        }
                    }
                }
        }
        .task {
            guard !initialDestinations.isEmpty else { return }
            while store.loadState == .idle || store.loadState == .loading {
                try? await Task.sleep(for: .milliseconds(60))
            }
            for destination in initialDestinations {
                path.append(destination)
            }
        }
    }
}

#if DEBUG
/// シミュレーター/Canvas確認用。バックエンドなしでシート型カタログ全画面を触れる。
/// 起動引数 `-problem-catalog-lab` で AppRootView から直接開く。
struct ProblemCatalogLabView: View {
    @State private var store = ProblemCatalogSheetStore(
        service: PreviewProblemCatalogSheetService(mode: .loaded),
        queryDrafter: PreviewProblemCatalogQueryDrafter()
    )
    @State private var actionError: String?

    /// ヘッドレス動作確認用: 起動引数で特定画面へ直行する。
    private static var labDestinations: [ProblemCatalogDestination] {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-problem-catalog-lab-problem") {
            let sheetIndex = ProblemCatalogSheetIndexDTO.preview
            let sheet = sheetIndex.sheets[0]
            let slot = sheet.slots.first { $0.tileState == "retry" } ?? sheet.slots[0]
            return [
                .sheet(sheet.sheetID),
                .problem(
                    ProblemCatalogProblemContext(
                        slot: slot,
                        breadcrumb: "\(sheet.subjectLabel) · \(sheet.displayTitle)"
                    )
                )
            ]
        }
        if arguments.contains("-problem-catalog-lab-sheet") {
            return [.sheet(ProblemCatalogSheetIndexDTO.preview.sheets[0].sheetID)]
        }
        if arguments.contains("-problem-catalog-lab-organizing") {
            return [.organizing]
        }
        return []
    }

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("-problem-catalog-lab-tile-preview") {
            tilePreviewGallery
        } else {
            ProblemCatalogSheetsNavigationView(
                store: store,
                actionError: $actionError,
                openingProblemBundleID: nil,
                onOpenProblem: { _, _ in },
                onCancelOpenProblem: {},
                onClose: {},
                initialDestinations: Self.labDestinations
            )
        }
    }

    /// 長押しプレビューカードの描画確認用ギャラリー(ヘッドレス検証で使う)。
    private var tilePreviewGallery: some View {
        ScrollView {
            VStack(spacing: 24) {
                let sheets = ProblemCatalogSheetIndexDTO.preview.sheets
                if let retrySlot = sheets[0].slots.first(where: { $0.tileState == "retry" }) {
                    ProblemCatalogTilePreviewCard(slot: retrySlot)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                }
                if let mathSlot = sheets.last?.slots.first {
                    ProblemCatalogTilePreviewCard(slot: mathSlot)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(24)
        }
    }
}

#Preview("ラボ") {
    ProblemCatalogLabView()
}

#Preview("長押しプレビュー") {
    ScrollView {
        VStack(spacing: 24) {
            if let slot = ProblemCatalogSheetIndexDTO.preview.sheets[0].slots.first(
                where: { $0.tileState == "retry" }
            ) {
                ProblemCatalogTilePreviewCard(slot: slot)
            }
            if let slot = ProblemCatalogSheetIndexDTO.preview.sheets.last?.slots.first {
                ProblemCatalogTilePreviewCard(slot: slot)
            }
        }
        .padding(24)
    }
}
#endif
