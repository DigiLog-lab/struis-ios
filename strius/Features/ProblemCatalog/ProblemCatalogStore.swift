import Foundation
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

private let problemCatalogLog = Logger(subsystem: "com.digiloglab.strius", category: "problem-catalog")

@MainActor
protocol ProblemCatalogServing {
    func loadTree(
        parentID: String?,
        cursor: String?,
        catalogGeneration: String?
    ) async throws -> ProblemCatalogViewDTO
    func query(_ request: ProblemCatalogQueryRequest) async throws -> ProblemCatalogViewDTO
    func loadView(id: String) async throws -> ProblemCatalogViewDTO
    func loadProblem(
        ref: ProblemCatalogProblemRefDTO,
        catalogGeneration: String
    ) async throws -> ProblemCatalogProblemDetailDTO
}

@MainActor
struct APIProblemCatalogService: ProblemCatalogServing {
    let client: APIClient

    func loadTree(
        parentID: String?,
        cursor: String?,
        catalogGeneration: String?
    ) async throws -> ProblemCatalogViewDTO {
        try await client.send(
            .problemCatalogTree(
                parentID: parentID,
                cursor: cursor,
                catalogGeneration: catalogGeneration
            )
        )
    }

    func query(_ request: ProblemCatalogQueryRequest) async throws -> ProblemCatalogViewDTO {
        try await client.send(.problemCatalogQuery, body: request)
    }

    func loadView(id: String) async throws -> ProblemCatalogViewDTO {
        try await client.send(.problemCatalogView(id: id))
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

@MainActor
protocol ProblemCatalogQueryDrafting {
    func draft(for rawQuery: String) async -> ProblemCatalogClientQueryDraft?
}

@MainActor
struct FoundationModelProblemCatalogQueryDrafter: ProblemCatalogQueryDrafting {
    func draft(for rawQuery: String) async -> ProblemCatalogClientQueryDraft? {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel(useCase: .contentTagging)
        guard model.availability == .available,
              model.supportsLocale(Locale(identifier: "ja_JP")) else {
            return nil
        }

        let session = LanguageModelSession(
            model: model,
            instructions: """
            あなたは学習者の入力が問題カタログ検索かを判定し、検索文を整理します。
            過去に解いた問題、アップロードした問題、問題同士の関連、到達状況を探す入力は検索です。
            目の前の問題の解説、解き方、ヒント、答えを求める入力は not_catalog です。
            入力にない問題名、教材名、期間、誤りを補いません。
            IDを生成しません。短い検索語だけを返します。
            """
        )

        do {
            let response = try await session.respond(
                to: "次の検索文を整理してください。検索文: \(rawQuery)",
                generating: GeneratedProblemCatalogQueryDraft.self
            )
            let content = response.content
            return ProblemCatalogClientQueryDraft(
                intent: content.intent,
                terms: content.terms,
                subject: content.subject?.nilIfBlank,
                unit: content.unit?.nilIfBlank,
                subunit: content.subunit?.nilIfBlank,
                skillTerms: content.skillTerms,
                sourceTerms: content.sourceTerms,
                errorTerms: content.errorTerms,
                progressStates: content.progressStates
            )
        } catch is CancellationError {
            return nil
        } catch {
            problemCatalogLog.info("Foundation Models query draft unavailable: \(String(describing: error))")
            return nil
        }
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@Generable(description: "問題カタログ検索の候補条件")
private struct GeneratedProblemCatalogQueryDraft {
    @Guide(
        description: "検索目的",
        .anyOf([
            "find_problem",
            "find_related",
            "find_progress",
            "find_source",
            "browse_scope",
            "not_catalog"
        ])
    )
    var intent: String?

    @Guide(description: "検索文からそのまま抜き出した重要語", .maximumCount(8))
    var terms: [String]

    @Guide(description: "科目。入力になければ空文字")
    var subject: String?

    @Guide(description: "単元。入力になければ空文字")
    var unit: String?

    @Guide(description: "細かい単元。入力になければ空文字")
    var subunit: String?

    @Guide(description: "解法や技能の語", .maximumCount(6))
    var skillTerms: [String]

    @Guide(description: "プリント、問題集、模試、アップロード時期など出典の語", .maximumCount(4))
    var sourceTerms: [String]

    @Guide(description: "符号ミス、場合分け不足など誤りの語", .maximumCount(4))
    var errorTerms: [String]

    @Guide(description: "not_started、in_progress、solved、improvedのうち検索文に対応する状態", .maximumCount(4))
    var progressStates: [String]
}
#endif

@Observable
@MainActor
final class ProblemCatalogStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle
    private(set) var catalogView: ProblemCatalogViewDTO?
    private(set) var selectedNodeID: String?
    private(set) var selectedProblem: ProblemCatalogProblemDetailDTO?
    private(set) var problemDetailError: String?
    private(set) var isWorking = false
    private(set) var isLoadingProblem = false
    private(set) var isShowingSearchResults = false
    private(set) var errorMessage: String?

    var query = ""

    var canLoadNextPage: Bool {
        guard catalogView?.nextCursor != nil else { return false }
        return catalogView?.viewKind == "tree" || activeQuery != nil
    }

    private let service: any ProblemCatalogServing
    private let queryDrafter: any ProblemCatalogQueryDrafting
    private let initialViewID: String?
    private var browseParentID: String?
    private var browseScopePath: [ProblemCatalogScopeItemDTO] = []
    private var activeQuery: String?
    private var activeQueryDraft: ProblemCatalogClientQueryDraft?
    private var activeQueryRequest: ProblemCatalogQueryRequest?
    private var problemDetailTask: Task<Void, Never>?
    private var problemDetailRequestID: UUID?

    init(
        service: any ProblemCatalogServing,
        queryDrafter: (any ProblemCatalogQueryDrafting)? = nil,
        initialViewID: String? = nil
    ) {
        self.service = service
        self.queryDrafter = queryDrafter ?? FoundationModelProblemCatalogQueryDrafter()
        self.initialViewID = initialViewID
    }

    func loadInitial() async {
        guard loadState == .idle else { return }
        loadState = .loading

        do {
            let response: ProblemCatalogViewDTO
            if let initialViewID, !initialViewID.isEmpty {
                response = try await service.loadView(id: initialViewID)
                restoreSavedViewContext(response)
                isShowingSearchResults = response.viewKind == "query"
            } else {
                response = try await service.loadTree(
                    parentID: nil,
                    cursor: nil,
                    catalogGeneration: nil
                )
                browseParentID = nil
                browseScopePath = response.scopePath
            }
            apply(response)
        } catch is CancellationError {
            return
        } catch {
            problemCatalogLog.error("initial catalog load failed: \(String(describing: error))")
            loadState = .failed(Self.message(for: error))
        }
    }

    func retry() async {
        loadState = .idle
        await loadInitial()
    }

    func openView(id: String) async {
        guard !id.isEmpty, !isWorking else { return }

        isWorking = true
        errorMessage = nil
        prepareForViewChange()
        defer { isWorking = false }

        do {
            let response = try await service.loadView(id: id)
            restoreSavedViewContext(response)
            isShowingSearchResults = response.viewKind == "query"
            apply(response)
        } catch is CancellationError {
            return
        } catch {
            problemCatalogLog.error("catalog view load failed: \(String(describing: error))")
            errorMessage = Self.message(for: error)
        }
    }

    func open(_ node: ProblemCatalogNodeDTO) async {
        if node.isProblem {
            await selectProblem(node)
            return
        }

        await loadTree(parentID: node.id)
    }

    func openScope(_ scope: ProblemCatalogScopeItemDTO?) async {
        await loadTree(parentID: scope?.nodeID)
    }

    func search() async {
        let rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawQuery.isEmpty, !isWorking else { return }

        isWorking = true
        errorMessage = nil
        prepareForViewChange()
        defer { isWorking = false }

        let draft = await queryDrafter.draft(for: rawQuery)
        guard !Task.isCancelled else { return }

        do {
            let request = ProblemCatalogQueryRequest(
                query: rawQuery,
                scopePath: browseScopePath,
                clientQueryDraft: draft
            )
            let response = try await service.query(request)
            activeQuery = rawQuery
            activeQueryDraft = draft
            activeQueryRequest = response.queryRequest ?? request
            isShowingSearchResults = true
            apply(response)
        } catch is CancellationError {
            return
        } catch {
            problemCatalogLog.error("catalog query failed: \(String(describing: error))")
            errorMessage = Self.message(for: error)
        }
    }

    func clearSearch() async {
        query = ""
        await loadTree(parentID: browseParentID)
    }

    func dismissProblemDetail() {
        cancelProblemDetailRequest()
        selectedNodeID = nil
        selectedProblem = nil
        problemDetailError = nil
        errorMessage = nil
    }

    func loadNextPage() async {
        guard !isWorking, let cursor = catalogView?.nextCursor else { return }

        isWorking = true
        errorMessage = nil
        prepareForViewChange()
        defer { isWorking = false }

        do {
            let response: ProblemCatalogViewDTO
            if let activeQueryRequest {
                response = try await service.query(
                    ProblemCatalogQueryRequest(
                        query: activeQueryRequest.query,
                        anchorProblemBundleID: activeQueryRequest.anchorProblemBundleID,
                        scopePath: activeQueryRequest.scopePath,
                        clientQueryDraft: activeQueryRequest.clientQueryDraft,
                        limit: activeQueryRequest.limit,
                        cursor: cursor,
                        catalogGeneration: catalogView?.catalogGeneration
                    )
                )
            } else {
                response = try await service.loadTree(
                    parentID: browseParentID,
                    cursor: cursor,
                    catalogGeneration: catalogView?.catalogGeneration
                )
            }
            apply(response)
        } catch is CancellationError {
            return
        } catch {
            problemCatalogLog.error("catalog next page load failed: \(String(describing: error))")
            errorMessage = Self.message(for: error)
        }
    }

    private func loadTree(parentID: String?) async {
        guard !isWorking else { return }

        isWorking = true
        errorMessage = nil
        prepareForViewChange()
        defer { isWorking = false }

        do {
            let response = try await service.loadTree(
                parentID: parentID,
                cursor: nil,
                catalogGeneration: catalogView?.catalogGeneration
            )
            browseParentID = parentID
            browseScopePath = response.scopePath
            activeQuery = nil
            activeQueryDraft = nil
            activeQueryRequest = nil
            isShowingSearchResults = false
            apply(response)
        } catch is CancellationError {
            return
        } catch {
            problemCatalogLog.error("catalog tree load failed: \(String(describing: error))")
            errorMessage = Self.message(for: error)
        }
    }

    private func selectProblem(_ node: ProblemCatalogNodeDTO) async {
        cancelProblemDetailRequest()
        selectedNodeID = node.id
        selectedProblem = nil
        problemDetailError = nil
        errorMessage = nil

        guard let problemRef = node.problemRef,
              let catalogGeneration = catalogView?.catalogGeneration,
              !catalogGeneration.isEmpty else {
            problemDetailError = "問題カタログのデータを読み取れませんでした"
            return
        }

        let requestID = UUID()
        problemDetailRequestID = requestID
        isLoadingProblem = true

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishProblemDetailRequest(requestID: requestID) }

            do {
                let response = try await self.service.loadProblem(
                    ref: problemRef,
                    catalogGeneration: catalogGeneration
                )
                guard self.isCurrentProblemDetailRequest(
                    requestID: requestID,
                    nodeID: node.id,
                    catalogGeneration: catalogGeneration
                ) else { return }
                self.selectedProblem = response
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.isCurrentProblemDetailRequest(
                          requestID: requestID,
                          nodeID: node.id,
                          catalogGeneration: catalogGeneration
                      ) else { return }
                problemCatalogLog.error("catalog problem load failed: \(String(describing: error))")
                self.problemDetailError = Self.message(for: error)
            }
        }
        problemDetailTask = task
        await task.value
    }

    private func prepareForViewChange() {
        cancelProblemDetailRequest()
        selectedNodeID = nil
        selectedProblem = nil
        problemDetailError = nil
    }

    private func cancelProblemDetailRequest() {
        problemDetailTask?.cancel()
        problemDetailTask = nil
        problemDetailRequestID = nil
        isLoadingProblem = false
    }

    private func isCurrentProblemDetailRequest(
        requestID: UUID,
        nodeID: String,
        catalogGeneration: String
    ) -> Bool {
        !Task.isCancelled
            && problemDetailRequestID == requestID
            && selectedNodeID == nodeID
            && catalogView?.catalogGeneration == catalogGeneration
    }

    private func finishProblemDetailRequest(requestID: UUID) {
        guard problemDetailRequestID == requestID else { return }
        problemDetailTask = nil
        problemDetailRequestID = nil
        isLoadingProblem = false
    }

    private func apply(_ response: ProblemCatalogViewDTO) {
        let limited = response.limited(
            maximumNodes: ProblemCatalogViewDTO.maximumFullScreenNodes,
            maximumEdges: ProblemCatalogViewDTO.maximumFullScreenEdges
        )
        catalogView = limited
        loadState = limited.nodes.isEmpty ? .empty : .loaded
        errorMessage = nil
    }

    private func restoreSavedViewContext(_ response: ProblemCatalogViewDTO) {
        browseScopePath = response.scopePath
        browseParentID = response.scopePath.last?.nodeID
        guard response.viewKind == "query" else {
            activeQuery = nil
            activeQueryDraft = nil
            activeQueryRequest = nil
            return
        }

        let savedRequest = response.queryRequest
        let savedQuery = savedRequest?.query.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? response.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        activeQuery = savedQuery.isEmpty ? nil : savedQuery
        activeQueryDraft = savedRequest?.clientQueryDraft ?? response.clientQueryDraft
        activeQueryRequest = savedRequest ?? (
            savedQuery.isEmpty
                ? nil
                : ProblemCatalogQueryRequest(
                    query: savedQuery,
                    scopePath: response.scopePath,
                    clientQueryDraft: response.clientQueryDraft,
                    catalogGeneration: response.catalogGeneration
                )
        )
        query = savedQuery
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
