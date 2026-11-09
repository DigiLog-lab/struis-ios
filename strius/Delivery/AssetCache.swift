import CryptoKit
import Foundation

/// 役割ごとの Claude のモデルと考える深さ。
nonisolated struct TurnModel: Hashable, Sendable {
    var model: String
    var effort: String
    var provider: ModelProvider? = nil
}

nonisolated enum AssetError: Error, LocalizedError, Sendable {
    case missing(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name): "アプリのデータ \(name) が見つかりません"
        case .unreadable(let name): "アプリのデータ \(name) を読めません"
        }
    }
}

/// アプリに同梱した指示文・schema・Skill を読む。読んだ本文はメモリに持つ。
actor AssetCache {
    nonisolated let bundled: BundledAssets
    private var memory: [String: String] = [:]
    /// 設定で選んだタイムラインの Claude のモデル(`TimelineModelPreference`)。テストでは差し替える。
    nonisolated let timelineClaudeModel: @Sendable () -> String

    init(bundled: BundledAssets = .main,
         timelineClaudeModel: @escaping @Sendable () -> String = { TimelineModelPreference.current }) {
        self.bundled = bundled
        self.timelineClaudeModel = timelineClaudeModel
    }

    /// 役割(`astra` / `luna` / `timeline` / `timeline_graph`)の Claude のモデル(`ClaudeModels`・`TimelineModels`)。
    func model(_ role: String) -> TurnModel {
        let fallback: TurnModel = role == "luna"
            ? TurnModel(model: ClaudeModels.lunaModel, effort: ClaudeModels.lunaEffort)
            : TurnModel(model: ClaudeModels.astraModel, effort: ClaudeModels.astraEffort)
        var model: TurnModel = TimelineModels.fallback(role: role) ?? fallback
        model.provider = .anthropic
        // 出題・採点・見直しは、設定で選んだモデルを使う(考える深さは `TimelineTurns.tutorEffort`)。
        if role == TimelineModels.role { model.model = timelineClaudeModel() }
        return model
    }

    /// プランに書く参照: 同梱ファイルの名前と sha256。
    func ref(_ name: String, append: String? = nil) throws -> TurnPlan.AssetRef {
        guard let data: Data = bundled.data(name) else { throw AssetError.missing(name) }
        return TurnPlan.AssetRef(asset: name, sha256: Self.sha256Hex(data), append: append)
    }

    func text(_ name: String) throws -> String {
        if let cached: String = memory[name] { return cached }
        guard let data: Data = bundled.data(name) else { throw AssetError.missing(name) }
        guard let text: String = String(data: data, encoding: .utf8) else { throw AssetError.unreadable(name) }
        memory[name] = text
        return text
    }

    func text(_ ref: TurnPlan.AssetRef) throws -> String {
        var body: String = try text(ref.asset)
        if let append: String = ref.append, !append.isEmpty { body += "\n\n" + append }
        return body
    }

    func json(_ name: String) throws -> LedgerJSON {
        guard let value: LedgerJSON = LedgerJSON.parse(try text(name)) else { throw AssetError.unreadable(name) }
        return value
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// アプリに同梱した prompt・schema・Skill・Python スクリプト。`prompt:` / `schema:` / `skill:` の名前で引く。
nonisolated struct BundledAssets: Sendable {
    /// 同梱ファイルの置き場(アプリの `Prompts/`)。
    let root: URL?

    static let main = BundledAssets(root: Bundle.main.url(forResource: "Prompts", withExtension: nil))

    /// 名前と同梱ファイルの対応表。
    static let files: [String: String] = [
        // 質問の会話・下調べ・ワークブック。
        "prompt:base": "base_instructions.md",
        "prompt:developer": "developer_instructions.md",
        "prompt:agents": "AGENTS.md",
        "prompt:luna_child": "luna_child_instructions.md",
        "prompt:delegate_py": "delegate.py",
        "prompt:tutor_memory_py": "struis_tutor_memory.py",
        "prompt:reply_lint_py": "struis_reply_lint.py",
        "prompt:grading_instructions": "grading_instructions.md",
        "prompt:set_instructions": "set_instructions.md",
        "prompt:unit_instructions": "unit_instructions.md",
        "schema:workbook_grading": "workbook_grading.json",
        "schema:workbook_set": "workbook_set.json",
        "schema:workbook_unit": "workbook_unit.json",
        "schema:luna_lookup": "luna_lookup.json",
        "schema:progress_update": "progress_update.json",
        "skill:struis_document": "skills/struis-document/SKILL.md",
        // タイムライン(Issue #46)。
        "prompt:timeline_shared": "timeline_shared.md",
        "prompt:timeline_instructions": "timeline_instructions.md",
        "prompt:timeline_grading_instructions": "timeline_grading_instructions.md",
        "prompt:timeline_graph_instructions": "timeline_graph_instructions.md",
        "prompt:timeline_decompose_instructions": "timeline_decompose_instructions.md",
        "prompt:timeline_misconceptions_instructions": "timeline_misconceptions_instructions.md",
        "prompt:timeline_review_instructions": "timeline_review_instructions.md",
        "prompt:timeline_marks_instructions": "timeline_marks_instructions.md",
        "prompt:timeline_answer_instructions": "timeline_answer_instructions.md",
        "schema:timeline_batch": "timeline_batch.json",
        "schema:timeline_grading": "timeline_grading.json",
        // オンボーディング(#40): お試しの1問の採点と、最初の計画。
        "prompt:onboarding_grading_instructions": "onboarding_grading_instructions.md",
        "schema:onboarding_grading": "onboarding_grading.json",
        "prompt:onboarding_plan_instructions": "onboarding_plan_instructions.md",
        "schema:onboarding_plan": "onboarding_plan.json",
        "schema:timeline_graph": "timeline_graph.json",
        "schema:timeline_decompose": "timeline_decompose.json",
        "schema:timeline_misconceptions": "timeline_misconceptions.json",
        "schema:timeline_review": "timeline_review.json",
        "schema:timeline_marks": "timeline_marks.json",
        "schema:timeline_answer": "timeline_answer.json",
        "skill:timeline_query": "skills/timeline-query/SKILL.md",
    ]

    static var names: [String] { files.keys.sorted() }

    func url(_ name: String) -> URL? {
        guard let root, let relative = Self.files[name] else { return nil }
        return root.appendingPathComponent(relative)
    }

    func data(_ name: String) -> Data? {
        url(name).flatMap { try? Data(contentsOf: $0) }
    }
}

/// タイムラインのモデルの別名(Issue #46)。
nonisolated enum TimelineModels {
    /// 次の5枚と採点。
    static let role = "timeline"
    /// 知識グラフを作る・見直す上位モデル。
    static let graphRole = "timeline_graph"

    static func fallback(role: String) -> TurnModel? {
        switch role {
        case Self.role: TurnModel(model: "claude-sonnet-5-5", effort: "low")
        case Self.graphRole: TurnModel(model: "claude-opus-5-5", effort: "medium")
        default: nil
        }
    }
}
