import Foundation
import OSLog

private let sheetCatalogLog = Logger(subsystem: "com.digiloglab.strius", category: "problem-catalog-sheets")

@MainActor
protocol ProblemCatalogSheetServing {
    func loadSheetIndex() async throws -> ProblemCatalogSheetIndexDTO
    func query(_ request: ProblemCatalogQueryRequest) async throws -> ProblemCatalogViewDTO
    func loadProblem(
        ref: ProblemCatalogProblemRefDTO,
        catalogGeneration: String
    ) async throws -> ProblemCatalogProblemDetailDTO
}

@MainActor
struct APIProblemCatalogSheetService: ProblemCatalogSheetServing {
    let client: APIClient

    func loadSheetIndex() async throws -> ProblemCatalogSheetIndexDTO {
        try await client.send(.problemCatalogSheets())
    }

    func query(_ request: ProblemCatalogQueryRequest) async throws -> ProblemCatalogViewDTO {
        try await client.send(.problemCatalogQuery, body: request)
    }

    func loadProblem(
        ref: ProblemCatalogProblemRefDTO,
        catalogGeneration: String
    ) async throws -> ProblemCatalogProblemDetailDTO {
        try await client.send(
            .problemCatalogProblem(ref: ref, catalogGeneration: catalogGeneration)
        )
    }
}

/// 問題詳細画面へ渡す最小コンテキスト。シートのマス・検索結果のどちらからでも作れる。
struct ProblemCatalogProblemContext: Hashable, Identifiable {
    let ref: ProblemCatalogProblemRefDTO
    let title: String
    let problemStatus: String?
    let tileState: String
    let errorLabels: [String]
    let sourceLabel: String?
    let progress: ProblemCatalogProgressDTO
    let breadcrumb: String?

    var id: String { ref.problemID }

    init(slot: ProblemCatalogSheetSlotDTO, breadcrumb: String?) {
        ref = slot.problemRef
        title = slot.title
        problemStatus = slot.problemStatus
        tileState = slot.tileState
        errorLabels = slot.errorLabels
        sourceLabel = slot.sourceLabel
        progress = slot.progress
        self.breadcrumb = breadcrumb
    }

    init?(node: ProblemCatalogNodeDTO) {
        guard node.isProblem, let problemRef = node.problemRef else { return nil }
        ref = problemRef
        title = node.title
        problemStatus = node.problemStatus
        if node.progress.correctCount > 0 {
            tileState = "solved"
        } else if node.progress.attemptCount > 0 {
            tileState = "retry"
        } else {
            tileState = "not_started"
        }
        errorLabels = []
        sourceLabel = node.sourceLabel
        progress = node.progress
        breadcrumb = node.taxonomyPath.map(\.title).joined(separator: " · ")
    }
}

struct ProblemCatalogRelatedProblem: Identifiable, Hashable {
    let context: ProblemCatalogProblemContext
    let relationLabel: String?

    var id: String { context.id }
}

@Observable
@MainActor
final class ProblemCatalogSheetStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle
    private(set) var sheetIndex: ProblemCatalogSheetIndexDTO?
    private(set) var isSearching = false
    private(set) var searchResults: [ProblemCatalogProblemContext]?
    private(set) var searchNotice: String?
    private(set) var errorMessage: String?

    var searchQuery = ""
    /// 科目チップの選択。nil = すべて。
    var selectedSubject: String?

    private let service: any ProblemCatalogSheetServing
    private let queryDrafter: any ProblemCatalogQueryDrafting

    init(
        service: any ProblemCatalogSheetServing,
        queryDrafter: (any ProblemCatalogQueryDrafting)? = nil
    ) {
        self.service = service
        self.queryDrafter = queryDrafter ?? FoundationModelProblemCatalogQueryDrafter()
    }

    /// 登場順を保った科目一覧。2科目以上あるときだけチップを出す。
    var subjectFilters: [String] {
        var seen: [String] = []
        for sheet in sheetIndex?.sheets ?? [] where !seen.contains(sheet.subjectLabel) {
            seen.append(sheet.subjectLabel)
        }
        return seen
    }

    /// 科目チップ適用後のシート。
    private var filteredSheets: [ProblemCatalogSheetDTO] {
        let sheets = sheetIndex?.sheets ?? []
        guard let selectedSubject else { return sheets }
        return sheets.filter { $0.subjectLabel == selectedSubject }
    }

    /// 完成に一番近いシートが先頭。解き直し待ちを含むシートは同率なら前へ。
    var activeSheets: [ProblemCatalogSheetDTO] {
        filteredSheets
            .filter { !$0.isCompleted }
            .sorted { lhs, rhs in
                if lhs.remainingCount != rhs.remainingCount {
                    return lhs.remainingCount < rhs.remainingCount
                }
                if (lhs.retryCount > 0) != (rhs.retryCount > 0) {
                    return lhs.retryCount > 0
                }
                return lhs.displayTitle < rhs.displayTitle
            }
    }

    var completedSheets: [ProblemCatalogSheetDTO] {
        filteredSheets.filter(\.isCompleted)
    }

    var organizingSlots: [ProblemCatalogSheetSlotDTO] {
        sheetIndex?.organizing ?? []
    }

    /// 画面の第一声。いま一番言いたいことを1文で言う。科目チップに追従する。
    /// 優先順位: 解き直しあり > 完成間近 > 整理中あり > 通常。
    var headline: String? {
        guard let sheetIndex,
              !(sheetIndex.sheets.isEmpty && sheetIndex.organizing.isEmpty) else {
            return nil
        }
        let sheets = filteredSheets
        let retrySlots = sheets.flatMap(\.slots).filter { $0.tileState == "retry" }
        if retrySlots.count == 1,
           let slot = retrySlots.first,
           !slot.title.containsCatalogLaTeX {
            return "「\(slot.title)」の解き直しが残っています"
        }
        if retrySlots.count >= 1 {
            return "解き直し待ちが\(retrySlots.count)問あります"
        }
        if let nearest = activeSheets.first,
           nearest.remainingCount > 0,
           nearest.remainingCount <= 2 {
            return "あと\(nearest.remainingCount)問で「\(nearest.displayTitle)」が完成します"
        }
        if selectedSubject == nil, !sheetIndex.organizing.isEmpty {
            return "\(sheetIndex.organizing.count)問が科目の判定待ちです"
        }
        let problemCount = sheets.reduce(0) { $0 + $1.slots.count }
        if let selectedSubject {
            return "\(selectedSubject)の\(problemCount)問を整理しています"
        }
        return "これまでの\(sheetIndex.problemCount)問を、科目ごとに整理しています"
    }

    /// 凡例に兼務させる在庫(科目チップ適用後のシート内スロットのみ。整理中は別枠)。
    var tileCounts: (solved: Int, retry: Int, notStarted: Int) {
        var solved = 0
        var retry = 0
        var notStarted = 0
        for sheet in filteredSheets {
            for slot in sheet.slots {
                switch slot.tileState {
                case "solved": solved += 1
                case "retry": retry += 1
                default: notStarted += 1
                }
            }
        }
        return (solved, retry, notStarted)
    }

    func sheet(withID id: String) -> ProblemCatalogSheetDTO? {
        sheetIndex?.sheets.first { $0.sheetID == id }
    }

    func loadInitial() async {
        guard loadState == .idle else { return }
        await reload(showLoading: true)
    }

    func retry() async {
        await reload(showLoading: true)
    }

    func refresh() async {
        await reload(showLoading: false)
    }

    private func reload(showLoading: Bool) async {
        if showLoading { loadState = .loading }
        do {
            let response = try await service.loadSheetIndex()
            sheetIndex = response
            if let selectedSubject,
               !response.sheets.contains(where: { $0.subjectLabel == selectedSubject }) {
                self.selectedSubject = nil
            }
            let isEmpty = response.sheets.isEmpty && response.organizing.isEmpty
            loadState = isEmpty ? .empty : .loaded
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            sheetCatalogLog.error("sheet index load failed: \(String(describing: error))")
            if sheetIndex == nil {
                loadState = .failed(Self.message(for: error))
            } else {
                errorMessage = Self.message(for: error)
            }
        }
    }

    func search() async {
        let rawQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawQuery.isEmpty, !isSearching else { return }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        let draft = await queryDrafter.draft(for: rawQuery)
        guard !Task.isCancelled else { return }

        do {
            let response = try await service.query(
                ProblemCatalogQueryRequest(
                    query: rawQuery,
                    scopePath: [],
                    clientQueryDraft: draft
                )
            )
            searchResults = response.nodes.compactMap(ProblemCatalogProblemContext.init(node:))
            searchNotice = response.interpretation?.needsClarification == true
                ? "近い候補を表示しています"
                : nil
        } catch is CancellationError {
            return
        } catch {
            sheetCatalogLog.error("sheet catalog search failed: \(String(describing: error))")
            errorMessage = Self.message(for: error)
        }
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = nil
        searchNotice = nil
    }

    func loadProblemDetail(
        ref: ProblemCatalogProblemRefDTO
    ) async throws -> ProblemCatalogProblemDetailDTO {
        guard let catalogGeneration = sheetIndex?.catalogGeneration,
              !catalogGeneration.isEmpty else {
            throw APIError.invalidResponse
        }
        return try await service.loadProblem(ref: ref, catalogGeneration: catalogGeneration)
    }

    /// つながりのある問題。既存のqueryエンドポイントにanchorを渡して関連問題を得る。
    func loadRelatedProblems(
        for context: ProblemCatalogProblemContext
    ) async -> [ProblemCatalogRelatedProblem] {
        guard let bundleID = context.ref.problemBundleUUID else { return [] }
        do {
            let response = try await service.query(
                ProblemCatalogQueryRequest(
                    query: context.title,
                    anchorProblemBundleID: bundleID,
                    scopePath: [],
                    clientQueryDraft: nil,
                    limit: 8
                )
            )
            let anchorNodeIDs = Set(
                response.nodes
                    .filter { $0.problemRef?.problemID == context.ref.problemID }
                    .map(\.id)
            )
            var relationByNodeID: [String: String] = [:]
            for edge in response.edges {
                if anchorNodeIDs.contains(edge.fromNodeID) {
                    relationByNodeID[edge.toNodeID] = edge.label ?? Self.relationLabel(edge.relationType)
                } else if anchorNodeIDs.contains(edge.toNodeID) {
                    relationByNodeID[edge.fromNodeID] = edge.label ?? Self.relationLabel(edge.relationType)
                }
            }
            return response.nodes
                .filter { $0.isProblem && $0.problemRef?.problemID != context.ref.problemID }
                .compactMap { node in
                    guard let related = ProblemCatalogProblemContext(node: node) else { return nil }
                    return ProblemCatalogRelatedProblem(
                        context: related,
                        relationLabel: relationByNodeID[node.id]
                    )
                }
        } catch {
            sheetCatalogLog.info("related problems unavailable: \(String(describing: error))")
            return []
        }
    }

    private static func relationLabel(_ relationType: String) -> String {
        switch relationType {
        case "prerequisite_transfer": "前提からつながる"
        case "shared_error": "同じ間違いが出た"
        case "same_source": "同じ教材"
        case "shared_skill": "同じ解き方"
        default: "関連する問題"
        }
    }

    private static func message(for error: Error) -> String {
        guard let apiError = error as? APIError else {
            return "問題カタログを読み込めませんでした"
        }
        switch apiError {
        case .unauthorized:
            return "もう一度ログインしてください"
        case .transport:
            return "ネットワークに接続できません"
        case .server(let status, _):
            return "サーバーエラー（\(status)）"
        case .decoding, .invalidResponse:
            return "問題カタログのデータを読み取れませんでした"
        }
    }
}
