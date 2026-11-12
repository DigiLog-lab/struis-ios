import Foundation

/// オンラインの AI に「問題の型」を書かせる時の、依頼の中身と返事の点検(docs/offline-drill/format.md)。
/// 指示文は `strius/Resources/Prompts/drill_template_instructions.md`、型の JSON Schema は `drill_template.json`。
/// ここは依頼の文と返事の点検だけを持つ。AI を呼ぶ所にはまだつないでいない。

/// この学習者がその点で実際に解いた問題 1 問(型を書く時の手本)。
nonisolated struct DrillSolvedExample: Codable, Equatable, Sendable {
    var prompt: String
    var math: String
    var answer: String

    init(prompt: String, math: String = "", answer: String = "") {
        self.prompt = prompt
        self.math = math
        self.answer = answer
    }
}

/// 型を書かせる依頼 1 件。知識グラフの点が定着した時に、点ごとに 1 回だけ出す。
nonisolated struct DrillAuthoringRequest: Equatable, Sendable {
    /// 点の ID(`TimelineSkillRecord.id`)。
    var skillID: String
    /// 点の名前(`TimelineSkillRecord.name`)。
    var name: String
    /// 点の種類(`TimelineSkillRecord.kind`)。
    var kind: String
    var solved: [DrillSolvedExample]

    init(skillID: String, name: String, kind: String, solved: [DrillSolvedExample]) {
        self.skillID = skillID
        self.name = name
        self.kind = kind
        self.solved = solved
    }
}

/// 1 つの点についての結論。台帳に残すのはこれ。
nonisolated enum DrillAuthoringOutcome: Equatable, Sendable {
    /// 点検を通った型(キーの順をそろえた JSON)。
    case ready(json: String, numericallyChecked: Bool, problems: Int)
    /// 対象から外す。`declined` は AI が「型にできない」と答えた時、偽は 2 回とも点検に落ちた時。
    case excluded(reasons: [String], declined: Bool)
}

/// 返事を 1 つ受け取った後に、次にすること。
nonisolated enum DrillAuthoringStep: Equatable, Sendable {
    case finished(DrillAuthoringOutcome)
    /// 点検に落ちた。この文を AI に返して、もう 1 回だけ書かせる。
    case retry(message: String)
}

nonisolated enum DrillAuthoring {
    /// 型を書かせる点の種類。概念の理解(concept)と暗記事項(memorized)は、数字を入れ替える反復にならないので頼まない。
    static let candidateKinds: Set<String> = ["procedure", "combination"]

    static func isCandidate(kind: String) -> Bool {
        candidateKinds.contains(kind)
    }

    /// AI に渡す入力(指示文と JSON Schema に添える JSON)。
    static func input(for request: DrillAuthoringRequest) throws -> String {
        let payload: InputPayload = InputPayload(
            skill: InputSkill(id: request.skillID, name: request.name, kind: request.kind),
            solved: request.solved
        )
        let encoder: JSONEncoder = JSONEncoder()
        encoder.outputFormatting = [JSONEncoder.OutputFormatting.sortedKeys, JSONEncoder.OutputFormatting.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    /// 返事の JSON Schema(`{"template": 型か null, "reason": 文}`)。`templateSchema` は `drill_template.json` の中身。
    static func replySchema(templateSchema: String) throws -> String {
        let template: DrillJSON = try JSONDecoder().decode(DrillJSON.self, from: Data(templateSchema.utf8))
        let schema: DrillJSON = DrillJSON.object([
            "type": DrillJSON.string("object"),
            "additionalProperties": DrillJSON.bool(false),
            "required": DrillJSON.array([DrillJSON.string("template"), DrillJSON.string("reason")]),
            "properties": DrillJSON.object([
                "template": DrillJSON.object([
                    "description": DrillJSON.string("問題の型。型にできない点なら null。"),
                    "anyOf": DrillJSON.array([template, DrillJSON.object(["type": DrillJSON.string("null")])]),
                ]),
                "reason": DrillJSON.object([
                    "type": DrillJSON.string("string"),
                    "description": DrillJSON.string("型にできない時の理由(1 文)。型を書いた時は空。"),
                ]),
            ]),
        ])
        let encoder: JSONEncoder = JSONEncoder()
        encoder.outputFormatting = [JSONEncoder.OutputFormatting.sortedKeys, JSONEncoder.OutputFormatting.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(schema), as: UTF8.self)
    }

    /// 返事を読んだ結果。
    enum Review: Equatable, Sendable {
        case accepted(json: String, inspection: DrillInspection)
        case declined(reason: String)
        case rejected(reasons: [String])
    }

    /// 返事 1 つを点検する。型は、依頼した点のものであること、端末の点検(`DrillValidator`)を通ることを確かめる。
    static func review(reply: String, request: DrillAuthoringRequest, validator: DrillValidator) -> Review {
        let tree: DrillJSON
        do {
            tree = try JSONDecoder().decode(DrillJSON.self, from: Data(reply.utf8))
        } catch {
            return Review.rejected(reasons: ["返事を JSON として読めません。`{\"template\": 型, \"reason\": \"\"}` の形だけを返してください。"])
        }
        guard case DrillJSON.object(let fields) = tree, let body: DrillJSON = fields["template"] else {
            return Review.rejected(reasons: ["返事に `template` がありません。`{\"template\": 型, \"reason\": \"\"}` の形で返してください。"])
        }
        if case DrillJSON.null = body {
            var reason: String = ""
            if case DrillJSON.string(let text)? = fields["reason"] { reason = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            return Review.declined(reason: reason.isEmpty ? "型にできない(理由の記載なし)" : reason)
        }
        let encoder: JSONEncoder = JSONEncoder()
        encoder.outputFormatting = [JSONEncoder.OutputFormatting.withoutEscapingSlashes]
        guard let data: Data = try? encoder.encode(body) else {
            return Review.rejected(reasons: ["`template` を読めません。"])
        }
        let result: (template: DrillTemplate?, inspection: DrillInspection) = validator.inspect(json: String(decoding: data, as: UTF8.self))
        var reasons: [String] = result.inspection.issues.map { (issue: DrillIssue) -> String in issue.message }
        guard let template: DrillTemplate = result.template else {
            return Review.rejected(reasons: reasons)
        }
        if template.skillId != request.skillID {
            reasons.insert("`skill_id` が依頼した点(\(request.skillID))と違います: \(template.skillId)", at: 0)
        }
        guard reasons.isEmpty, let json: String = try? template.canonicalJSON() else {
            return Review.rejected(reasons: reasons.isEmpty ? ["型を保存する形にできません。"] : reasons)
        }
        return Review.accepted(json: json, inspection: result.inspection)
    }

    /// 点検に落ちた時に AI に返す文。
    static func retryMessage(reasons: [String]) -> String {
        let lines: String = reasons.map { (reason: String) -> String in "- " + reason }.joined(separator: "\n")
        return "端末の点検で、次の理由により型を保存できませんでした。\n\n\(lines)\n\n"
            + "理由に出ている式や問題は、実際に作った問題の例です。原因を型の側で直し、型の全体を同じ形(`{\"template\": 型, \"reason\": \"\"}`)でもう一度返してください。"
            + "書き直しはこの 1 回だけです。直しても型にできないと判断した時は、`template` を null にして理由を返してください。"
    }

    private struct InputSkill: Encodable {
        let id: String
        let name: String
        let kind: String
    }

    private struct InputPayload: Encodable {
        let skill: InputSkill
        let solved: [DrillSolvedExample]
    }
}

/// 1 つの点について、返事を受け取り、点検し、落ちたら 1 回だけ書き直させる流れ。
/// 2 回目も落ちたら、その点を対象から外す。
nonisolated struct DrillAuthoringSession: Sendable {
    /// AI に書かせる回数の上限(最初の 1 回と、書き直しの 1 回)。
    static let maximumAttempts: Int = 2

    let request: DrillAuthoringRequest
    let validator: DrillValidator
    /// 受け取った返事の数。
    private(set) var attempts: Int = 0
    /// 結論が出たか(出た後の返事は受け取らない)。
    private(set) var outcome: DrillAuthoringOutcome? = nil

    init(request: DrillAuthoringRequest, validator: DrillValidator = DrillValidator()) {
        self.request = request
        self.validator = validator
    }

    mutating func receive(reply: String) -> DrillAuthoringStep {
        if let outcome: DrillAuthoringOutcome = outcome { return DrillAuthoringStep.finished(outcome) }
        attempts += 1
        switch DrillAuthoring.review(reply: reply, request: request, validator: validator) {
        case DrillAuthoring.Review.accepted(let json, let inspection):
            return finish(DrillAuthoringOutcome.ready(json: json, numericallyChecked: inspection.numericallyChecked, problems: inspection.distinct))
        case DrillAuthoring.Review.declined(let reason):
            return finish(DrillAuthoringOutcome.excluded(reasons: [reason], declined: true))
        case DrillAuthoring.Review.rejected(let reasons):
            if attempts >= DrillAuthoringSession.maximumAttempts {
                return finish(DrillAuthoringOutcome.excluded(reasons: reasons, declined: false))
            }
            return DrillAuthoringStep.retry(message: DrillAuthoring.retryMessage(reasons: reasons))
        }
    }

    private mutating func finish(_ result: DrillAuthoringOutcome) -> DrillAuthoringStep {
        outcome = result
        return DrillAuthoringStep.finished(result)
    }
}
