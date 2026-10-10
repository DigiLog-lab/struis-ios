import Foundation

struct ProblemCatalogSheetIndexDTO: Decodable, Hashable, Sendable {
    let schemaVersion: Int
    let catalogGeneration: String
    let createdAt: String
    let sheets: [ProblemCatalogSheetDTO]
    let organizing: [ProblemCatalogSheetSlotDTO]
    let problemCount: Int
    let solvedCount: Int
    let retiredCount: Int

    init(
        schemaVersion: Int = 1,
        catalogGeneration: String,
        createdAt: String = "",
        sheets: [ProblemCatalogSheetDTO],
        organizing: [ProblemCatalogSheetSlotDTO] = [],
        problemCount: Int,
        solvedCount: Int,
        retiredCount: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.catalogGeneration = catalogGeneration
        self.createdAt = createdAt
        self.sheets = sheets
        self.organizing = organizing
        self.problemCount = problemCount
        self.solvedCount = solvedCount
        self.retiredCount = retiredCount
    }
}

struct ProblemCatalogSheetDTO: Decodable, Identifiable, Hashable, Sendable {
    let sheetID: String
    let title: String
    let subjectLabel: String
    let sheetIndex: Int
    let sheetTotal: Int
    let capacity: Int
    let slots: [ProblemCatalogSheetSlotDTO]
    let solvedCount: Int
    let retryCount: Int

    var id: String { sheetID }

    private enum CodingKeys: String, CodingKey {
        case sheetID = "sheetId"
        case title
        case subjectLabel
        case sheetIndex
        case sheetTotal
        case capacity
        case slots
        case solvedCount
        case retryCount
    }

    init(
        sheetID: String,
        title: String,
        subjectLabel: String,
        sheetIndex: Int = 1,
        sheetTotal: Int = 1,
        capacity: Int = 12,
        slots: [ProblemCatalogSheetSlotDTO],
        solvedCount: Int,
        retryCount: Int
    ) {
        self.sheetID = sheetID
        self.title = title
        self.subjectLabel = subjectLabel
        self.sheetIndex = sheetIndex
        self.sheetTotal = sheetTotal
        self.capacity = capacity
        self.slots = slots
        self.solvedCount = solvedCount
        self.retryCount = retryCount
    }

    /// 「力学:運動の法則 その2」のような表示名。シートが1枚だけなら連番を出さない。
    var displayTitle: String {
        sheetTotal > 1 ? "\(title) その\(sheetIndex)" : title
    }

    var remainingCount: Int { max(0, slots.count - solvedCount) }
    var isCompleted: Bool { !slots.isEmpty && solvedCount == slots.count }
}

struct ProblemCatalogSheetSlotDTO: Decodable, Identifiable, Hashable, Sendable {
    let problemRef: ProblemCatalogProblemRefDTO
    let title: String
    let problemStatus: String
    let tileState: String
    let progress: ProblemCatalogProgressDTO
    let errorLabels: [String]
    let sourceLabel: String?
    let promptPreview: String?

    var id: String { problemRef.problemID }

    init(
        problemRef: ProblemCatalogProblemRefDTO,
        title: String,
        problemStatus: String = "resolved",
        tileState: String,
        progress: ProblemCatalogProgressDTO = ProblemCatalogProgressDTO(),
        errorLabels: [String] = [],
        sourceLabel: String? = nil,
        promptPreview: String? = nil
    ) {
        self.problemRef = problemRef
        self.title = title
        self.problemStatus = problemStatus
        self.tileState = tileState
        self.progress = progress
        self.errorLabels = errorLabels
        self.sourceLabel = sourceLabel
        self.promptPreview = promptPreview
    }
}
