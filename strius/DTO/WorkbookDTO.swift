import Foundation

// 問題集型のDTO。バックエンド `services/workbook.py` の契約を写す。
// APIClient は snake_case → camelCase 変換を行うため CodingKeys は ID 表記の統一にだけ使う。

enum WorkbookStage: Int, Codable, Sendable, CaseIterable {
    case introduction = 1
    case jointExample = 2
    case soloExample = 3
    case practice = 4

    var label: String {
        switch self {
        case .introduction: "要点"
        case .jointExample: "例題"
        case .soloExample: "類題"
        case .practice: "演習"
        }
    }

    /// 段階 1・2 はモデルの仕事(質問画面)。3・4 は学習者の仕事(一枚)。
    var isModelWork: Bool { self == .introduction || self == .jointExample }
}

struct WorkbookWindowDTO: Decodable, Hashable, Sendable {
    let n: Int
    let threshold: Double
    let count: Int
    let correct: Int
    let score: Double?
    let passed: Bool
    let requiredCorrect: Int
}

struct WorkbookProblemTileDTO: Decodable, Identifiable, Hashable, Sendable {
    enum State: String, Decodable, Sendable {
        case notStarted = "not_started"
        case correct
        case wrong
        case unknown
    }

    let id: String
    let position: Int
    let prompt: String
    let source: String
    let state: State
    let attemptCount: Int
    let assisted: Bool
    let errorTag: String
    let hintGiven: Bool
    let lastAttemptAt: String?
}

struct WorkbookSetResultDTO: Decodable, Hashable, Sendable {
    let correct: Int
    let total: Int
    let score: Double
    let passed: Bool
    let note: String
}

struct WorkbookSetDTO: Decodable, Identifiable, Hashable, Sendable {
    /// 過去の `remedial`(補習、2026-09-24 廃止)は演習として読む。
    enum Kind: String, Decodable, Sendable {
        case example, practice

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .practice
        }

        var label: String {
            switch self {
            case .example: "類題"
            case .practice: "演習"
            }
        }
    }

    enum Status: String, Decodable, Sendable {
        case generating, open, graded, superseded, failed
    }

    let id: String
    let subunitId: String
    let stage: Int
    let stageLabel: String
    let kind: Kind
    let status: Status
    let problems: [WorkbookProblemTileDTO]
    let result: WorkbookSetResultDTO?
    let error: String?
    let createdAt: String
    /// 一枚の問題数(組み終える前は `problems` より多い。§3.2: 1 問できたら出す)。
    var count: Int? = nil
}

struct WorkbookSubunitDTO: Decodable, Identifiable, Hashable, Sendable {
    enum Status: String, Decodable, Sendable {
        case pending, active, passed
    }

    let id: String
    let unitId: String
    let unitTitle: String
    let title: String
    let outcome: String
    let position: Int
    let stage: Int
    let stageLabel: String
    let status: Status
    let n: Int
    let threshold: Double
    let scoringUnit: String
    let window: WorkbookWindowDTO
    let tiles: [WorkbookProblemTileDTO]
    let openSetId: String?
    let lastResult: WorkbookSetResultDTO?
    let canAdvance: Bool
    let updatedAt: String
    /// 合格の窓に入った演習の答え(古い順、最大 n)。マスはこれを並べる。
    var windowTiles: [WorkbookProblemTileDTO]? = nil
    /// 段階 2 の例題(ヘッダーの下に固定する)。
    var exampleProblem: String? = nil
    /// 段階 2 で、モデルがこの回の例題について「類題を自力で解けそう」と判断した(`<struis_workbook_example_ready/>`)。
    /// true の時だけ「先に進む」を出す(§13.13 の 5)。
    var exampleReady: Bool? = nil
    /// 「例題に戻る」で段階 2 に来た時の、戻る前の段。
    var returnStage: Int? = nil
    /// 小単元ごとの会話 thread。
    var threadId: String? = nil
    /// 段階 1・2 でモデルのターンを起こす単位と、起こした時の起動メッセージ。
    var kickoffKey: String? = nil
    var kickoffMessageId: String? = nil

    var stageValue: WorkbookStage { WorkbookStage(rawValue: stage) ?? .introduction }
    var correctCount: Int { tiles.filter { $0.state == .correct }.count }
}

struct WorkbookUnitDTO: Decodable, Identifiable, Hashable, Sendable {
    enum Status: String, Decodable, Sendable {
        case active, passed, archived
    }

    let id: String
    let title: String
    let outcome: String
    let status: Status
    let source: String
    let subunitCount: Int
    let passedCount: Int
    let subunits: [WorkbookSubunitDTO]
    let createdAt: String
}

struct WorkbookCaptureVerdictDTO: Decodable, Hashable, Sendable {
    let problemId: String?
    let label: String
    let promptText: String
    let verdict: WorkbookProblemTileDTO.State
    let errorTag: String
    let note: String
}

struct WorkbookCaptureCandidateDTO: Decodable, Identifiable, Hashable, Sendable {
    let problemId: String
    let subunitId: String
    let subunitTitle: String
    let prompt: String
    let reason: String

    var id: String { problemId }
}

struct WorkbookCaptureDTO: Decodable, Identifiable, Hashable, Sendable {
    enum Status: String, Decodable, Sendable {
        case identifying, graded, triage, failed
    }

    let id: String
    let status: Status
    let createdAt: String
    let gradedAt: String?
    let subunitId: String?
    let subunitTitle: String?
    let unitId: String?
    let unitTitle: String?
    let setId: String?
    let verdicts: [WorkbookCaptureVerdictDTO]
    let summary: WorkbookSetResultDTO?
    let candidates: [WorkbookCaptureCandidateDTO]
    let nextSetId: String?
    let outcome: String?
    let error: String?
    let imagePath: String
    /// リザルト画面の値。判定前の答案や旧い答案では nil のことがある。
    var result: WorkbookResultDTO? = nil
    /// 一枚の今の様子。演習の一枚(2 問以上)から撮った答案だけ。
    var setProgress: WorkbookSetProgressDTO? = nil
    /// 何枚かをまとめて撮った答案の全ページ(順に)。nil なら `imagePath` の 1 枚。
    var pagePaths: [String]? = nil

    var pages: [String] { pagePaths ?? [imagePath] }

    /// 演習の一枚の全問に判定がそろう前の答案(分割採点 R2)。
    var isPartial: Bool { outcome == "partial" }
}

/// 一枚を何枚の写真に分けて撮る時の、一枚の今の様子(配信Skillの説明)。
struct WorkbookSetProgressDTO: Decodable, Hashable, Sendable {
    /// 一枚の順の各問の判定(一枚の中での初回)。まだなら `.notStarted`。
    let states: [WorkbookProblemTileDTO.State]
    /// その答案で判定した問題か。
    let capturedHere: [Bool]
    /// まだ判定の無い問題の、一枚の中の番号(1 始まり)。
    let missingPositions: [Int]
    /// まだ締めていない、今の段の一枚か。
    let isOpen: Bool
    /// 組み立てに失敗した一枚か。`states` は作れた問題だけで、作れなかった分は数えない。
    var isFailed = false

    var judgedCount: Int { states.count - missingPositions.count }

    /// 「14・15」「6〜15」「1・3〜5」。続く 3 つ以上の番号は「〜」でまとめる。
    static func positionsText(_ positions: [Int]) -> String {
        var parts: [String] = []
        var index = 0
        let sorted = positions.sorted()
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
            if end - index >= 2 {
                parts.append("\(sorted[index])〜\(sorted[end])")
            } else {
                parts.append(contentsOf: sorted[index...end].map(String.init))
            }
            index = end + 1
        }
        return parts.joined(separator: "・")
    }
}

struct WorkbookResultTileDTO: Decodable, Hashable, Sendable {
    let problemId: String
    let state: WorkbookProblemTileDTO.State
    /// 今回の答案で埋まったマス。
    let isCurrent: Bool
}

/// リザルト画面(判定の後)の値。次の行動は学習者が選ぶ。
struct WorkbookResultDTO: Decodable, Hashable, Sendable {
    enum Action: String, Decodable, Sendable {
        case practice
        case retry
        case returnToExample = "return_to_example"
        case nextSubunit = "next_subunit"
        case finishUnit = "finish_unit"
        case ask
        /// 途中の答案: 同じ一枚の残りを撮る。
        case captureMore = "capture_more"
        /// 途中の答案: 判定のある問題で一枚を締める。
        case closeSet = "close_set"
        /// 全問正解の答案: 新しい一枚を作らず、作られた演習の一覧へ戻る(画面で「やり直す」から置き換える。台帳は出さない)。
        case returnToSet = "return_to_set"
    }

    let stageBefore: Int
    let stageAfter: Int
    let window: WorkbookWindowDTO?
    let windowTiles: [WorkbookResultTileDTO]
    let subunitPassed: Bool
    let unitPassed: Bool
    let nextSubunitId: String?
    var actions: [Action]

    var isPractice: Bool { window != nil }
}

struct WorkbookProblemAttemptDTO: Decodable, Hashable, Sendable {
    let captureId: String
    let verdict: WorkbookProblemTileDTO.State
    let assisted: Bool
    let errorTag: String
    let note: String
    let createdAt: String
}

struct WorkbookProblemDetailDTO: Decodable, Hashable, Sendable {
    let tile: WorkbookProblemTileDTO
    let subunitId: String
    let subunitTitle: String
    let unitTitle: String
    let attempts: [WorkbookProblemAttemptDTO]
}

struct WorkbookHomeDTO: Decodable, Hashable, Sendable {
    let now: [WorkbookSubunitDTO]
    let recent: [WorkbookCaptureDTO]
    let units: [WorkbookUnitDTO]
    let triageCount: Int
}

struct WorkbookProposalSubunitDTO: Decodable, Hashable, Sendable {
    let title: String
    let outcome: String
    let n: Int
    let scoringUnit: String
}

struct WorkbookProposalOverviewDTO: Decodable, Hashable, Sendable {
    let unitTitle: String
    let outcome: String
    let subunits: [WorkbookProposalSubunitDTO]
}

struct WorkbookProposalDTO: Decodable, Identifiable, Hashable, Sendable {
    enum Status: String, Decodable, Sendable {
        case generating, ready, started, failed
    }

    let id: String
    let status: Status
    let request: String
    let overview: WorkbookProposalOverviewDTO?
    let unitId: String?
    let threadId: String?
    let messageId: String?
    let error: String?
    let createdAt: String
}

// MARK: - Requests

/// 質問画面が今見ている場所。サーバーが `<struis_current_view>` を組む。
struct WorkbookViewRef: Encodable, Hashable, Sendable {
    let subunitId: String?
    let setId: String?
    var captureId: String? = nil

    init(subunitId: String? = nil, setId: String? = nil, captureId: String? = nil) {
        self.subunitId = subunitId
        self.setId = setId
        self.captureId = captureId
    }

    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

struct WorkbookCountRequest: Encodable, Sendable {
    let n: Int
    let reason: String
}

struct WorkbookCreateCaptureRequest: Encodable, Sendable {
    let uploadId: String
    let context: WorkbookViewRef?
}

struct WorkbookAssignRequest: Encodable, Sendable {
    struct NewProblem: Encodable, Sendable {
        let subunitId: String
    }

    struct NewSubunit: Encodable, Sendable {
        let unitId: String?
        let unitTitle: String
        let title: String
        let n: Int
    }

    var problemId: String? = nil
    var newProblem: NewProblem? = nil
    var newSubunit: NewSubunit? = nil
}

struct WorkbookCreateProposalRequest: Encodable, Sendable {
    let request: String
    let threadId: String?
}
