import Foundation
import OSLog

private let onboardingTurnLog = Logger(subsystem: "com.digiloglab.strius", category: "onboarding-turns")

/// お試しの見本(#40)。中1〜高3 の数学を 3 問ずつ、問題文・正答・採点の観点をアプリに埋め込む。
nonisolated struct TrialProblem: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var grade: String
    var unit: String
    var prompt: String
    var math: String
    var answer: String
    var rubric: [String]

    /// 「中3 数学・二次方程式」。
    var label: String { "\(grade) 数学・\(unit)" }

    private struct File: Decodable { var problems: [TrialProblem] }

    static let all: [TrialProblem] = {
        guard let url = BundledAssets.main.root?.appendingPathComponent("onboarding_trial_problems.json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.problems
    }()

    static func problems(grade: String, in all: [TrialProblem] = TrialProblem.all) -> [TrialProblem] {
        all.filter { $0.grade == grade }
    }

    /// 同じ学年の次の見本(「別の問題にする」)。解いた問題の次から順に回す。
    static func next(after current: TrialProblem?, grade: String, solved: Set<String>, in all: [TrialProblem] = TrialProblem.all) -> TrialProblem? {
        let pool = problems(grade: grade, in: all)
        guard !pool.isEmpty else { return nil }
        let start = current.flatMap { current in pool.firstIndex { $0.id == current.id } }.map { $0 + 1 } ?? 0
        let ordered = (0..<pool.count).map { pool[(start + $0) % pool.count] }
        return ordered.first { !solved.contains($0.id) && $0.id != current?.id } ?? ordered.first { $0.id != current?.id } ?? pool.first
    }
}

/// お試しの1問の採点の結果。
nonisolated struct TrialVerdict: Codable, Hashable, Sendable {
    var readable: Bool
    /// correct | partial | wrong
    var grade: String
    var learnerAnswer: String
    var comment: String
    var solution: String

    var isCorrect: Bool { grade == "correct" }

    enum CodingKeys: String, CodingKey {
        case readable, grade, comment, solution
        case learnerAnswer = "learner_answer"
    }
}

/// 解いたお試しの1問(端末に残す。計画づくりに渡す)。
nonisolated struct TrialRecord: Codable, Hashable, Sendable {
    var problemID: String
    var label: String
    var correct: Bool
    var learnerAnswer: String
    var comment: String
}

/// 計画づくりの結果(計画の画面に出し、「はじめる」で単元にする)。
nonisolated struct OnboardingPlanDraft: Codable, Hashable, Sendable {
    nonisolated struct Subunit: Codable, Hashable, Sendable {
        var title: String
        var outcome: String
        var n: Int
        var scoringUnit: String
        var note: String

        enum CodingKeys: String, CodingKey {
            case title, outcome, n, note
            case scoringUnit = "scoring_unit"
        }
    }

    nonisolated struct FirstProblem: Codable, Hashable, Sendable {
        var prompt: String
        var math: String
        var answerKey: String

        enum CodingKeys: String, CodingKey {
            case prompt, math
            case answerKey = "answer_key"
        }
    }

    var unitTitle: String
    var outcome: String
    var heading: String
    var lead: String
    var subunits: [Subunit]
    var firstProblem: FirstProblem?

    enum CodingKeys: String, CodingKey {
        case outcome, heading, lead, subunits
        case unitTitle = "unit_title"
        case firstProblem = "first_problem"
    }

    /// 見出しが無い時の既定(「二次方程式を6つに分けて進めます」)。
    var displayHeading: String {
        let trimmed = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(unitTitle)を\(subunits.count)つに分けて進めます" : trimmed
    }

    /// お試しの結果をどう反映したかが、どこにも書かれていない(モデルが書き落とした)。
    var mentionsTrial: Bool {
        lead.contains("お試し") || subunits.contains { $0.note.contains("お試し") }
    }
}

/// オンボーディングのモデルのターン(お試しの採点・最初の計画)。同梱のプロンプトとスキーマで、1 回の構造化ターンにする。
/// 採点はタイムラインの採点と同じ役(Sonnet 5.5)、計画は上位モデル(`timeline_graph` の役、Opus 5.5)。
nonisolated enum OnboardingTurns {
    static let gradingTimeLimit: Duration = .seconds(90)
    static let planTimeLimit: Duration = .seconds(240)

    nonisolated enum Failure: Error, LocalizedError {
        case failed(String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .failed(let message): message
            case .malformed: "AI の返事を読み取れませんでした。もう一度試してください。"
            }
        }
    }

    static func turnText(materials: LedgerJSON) -> String {
        "# 今回の材料\n\n" + TurnComposer.dump(materials)
    }

    private static func thread(assets: AssetCache, planID: String, instructions: String, role: String) async throws -> TurnPlan.ThreadSpec {
        let model = await assets.model(role)
        return TurnPlan.ThreadSpec(
            codexThreadID: nil, mode: .start, cwd: TurnPlan.guestWorkspace(id: planID), model: model.model, effort: model.effort,
            ephemeral: true, baseInstructions: try await assets.ref(instructions), developerInstructions: nil,
            developerText: "Answer only with one JSON object matching the supplied output schema.",
            injectDeveloperOnResume: false, config: TurnComposer.structuredConfig(effort: model.effort), lastTurnID: nil,
            provider: model.provider
        )
    }

    /// お試しの採点。`imagePath` は `StruisPaths.captures` の中の答案(紙の写真か、書く面の手書き)。
    static func gradingPlan(assets: AssetCache, planID: String, problem: TrialProblem, imagePath: String) async throws -> TurnPlan {
        let request: LedgerJSON = .object([
            "task": .string("grade_trial"), "problem_id": .string(problem.id), "grade": .string(problem.grade), "unit": .string(problem.unit),
            "problem": .string(problem.prompt), "math": .string(problem.math), "answer": .string(problem.answer),
            "rubric": .array(problem.rubric.map(LedgerJSON.string)),
        ])
        let ext = (imagePath as NSString).pathExtension.isEmpty ? "jpg" : (imagePath as NSString).pathExtension
        let image = TurnPlan.ImageRef(path: "tutor_desk/inbox/trial/\(planID).\(ext)", hostPath: StruisPaths.captures.appendingPathComponent(imagePath).path,
                                      maxDimension: TimelineCaptureImage.requestMaxDimension)
        return TurnPlan(
            id: planID, kind: .onboardingGrading, round: 1,
            thread: try await thread(assets: assets, planID: planID, instructions: "prompt:onboarding_grading_instructions", role: TimelineModels.role),
            turn: TurnPlan.TurnSpec(text: turnText(materials: request), images: [image],
                                    outputSchema: try await assets.json("schema:onboarding_grading"), sandboxPolicy: "dangerFullAccess"),
            workspace: TimelineTurns.workspace, delegation: nil, collect: [], limits: .structured, items: nil
        )
    }

    /// 最初の計画。`imagePaths` は `StruisPaths.captures` の中の撮ったページ・資料(8 枚まで)。
    static func planPlan(assets: AssetCache, planID: String, request: LedgerJSON, imagePaths: [String]) async throws -> TurnPlan {
        let images = imagePaths.prefix(8).enumerated().map { index, path in
            let ext = (path as NSString).pathExtension.isEmpty ? "jpg" : (path as NSString).pathExtension
            return TurnPlan.ImageRef(path: "tutor_desk/inbox/materials/page-\(index + 1).\(ext)", hostPath: StruisPaths.captures.appendingPathComponent(path).path,
                                     maxDimension: 2048)
        }
        return TurnPlan(
            id: planID, kind: .onboardingPlan, round: 1,
            thread: try await thread(assets: assets, planID: planID, instructions: "prompt:onboarding_plan_instructions", role: TimelineModels.graphRole),
            turn: TurnPlan.TurnSpec(text: turnText(materials: request), images: Array(images),
                                    outputSchema: try await assets.json("schema:onboarding_plan"), sandboxPolicy: "dangerFullAccess"),
            workspace: TimelineTurns.workspace, delegation: nil, collect: [], limits: .structured, items: nil
        )
    }

    static func parseVerdict(_ text: String) -> TrialVerdict? {
        guard let data = JSONExtraction.object(in: text) else { return nil }
        return try? JSONDecoder().decode(TrialVerdict.self, from: data)
    }

    static func parsePlan(_ text: String) -> OnboardingPlanDraft? {
        guard let data = JSONExtraction.object(in: text), var draft = try? JSONDecoder().decode(OnboardingPlanDraft.self, from: data) else { return nil }
        draft.subunits = draft.subunits.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(6).map { subunit in
            var subunit = subunit
            subunit.n = min(10, max(3, subunit.n))
            return subunit
        }
        guard !draft.unitTitle.isEmpty, !draft.subunits.isEmpty else { return nil }
        if let first = draft.firstProblem, first.prompt.trimmingCharacters(in: .whitespaces).isEmpty, first.math.isEmpty { draft.firstProblem = nil }
        return draft
    }

    /// 1 回の構造化ターンを、ほかのターンと同じ枠を取って走らせる。時間の上限を超えたら止めて失敗にする。
    static func run(_ plan: TurnPlan, turns: TurnCoordinator, runner: any TurnRunning, limit: Duration) async throws -> String {
        let acquired = await turns.acquire(kind: plan.kind, turnID: plan.id)
        defer {
            WorkspaceStager.cleanup(plan: plan)
            Task { await turns.release(turnID: plan.id, kind: plan.kind, acquired: acquired) }
        }
        guard acquired else { throw Failure.failed("AI を始められませんでした。もう一度試してください。") }
        let outcome: TurnOutcome = try await withThrowingTaskGroup(of: TurnOutcome?.self) { group in
            group.addTask { try await runner.run(plan) { _ in } }
            group.addTask {
                try await Task.sleep(for: limit)
                await runner.interrupt(planID: plan.id)
                return nil
            }
            defer { group.cancelAll() }
            while let next = try await group.next() {
                if let next { return next }
                throw Failure.failed("AI の返事が止まりました。もう一度試してください。")
            }
            throw Failure.malformed
        }
        guard outcome.status == .completed else {
            onboardingTurnLog.error("onboarding turn \(plan.kind.rawValue, privacy: .public) ended \(String(describing: outcome.status), privacy: .public): \(outcome.errorDetail ?? outcome.error ?? "", privacy: .public)")
            throw Failure.failed(outcome.error ?? "AI が返事を作れませんでした。もう一度試してください。")
        }
        return outcome.finalText
    }
}

/// 返事の本文から JSON のオブジェクトを取り出す(前後に文字やコードの囲みがあっても読む)。
nonisolated enum JSONExtraction {
    static func object(in text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { return data }
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(trimmed[start...end])
        guard let data = slice.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return data
    }
}
