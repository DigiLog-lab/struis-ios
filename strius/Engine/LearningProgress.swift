import Foundation

// Port of backend/src/struis/services/learning_progress.py (pure logic only;
// load_state / source_messages_for_update / mirror_state read the database or the
// workspace and are the caller's job on device).
//
// Every ValueError message raised explicitly by Python is reproduced byte-for-byte
// because the repair loop feeds it back to the model.  pydantic validation
// failures raise `LearningProgressError` as well, with a descriptive (not
// identical) message.

typealias LearningProgressError = EngineError

// MARK: - Validation helpers (pydantic `extra="forbid"` + Field constraints, lax mode)

nonisolated enum EngineValidate {
    static func object(_ value: EngineJSON, _ path: String) throws -> EngineObject {
        guard let object = value.objectValue else { throw EngineError("\(path): Input should be a valid dictionary") }
        return object
    }

    static func forbidExtra(_ object: EngineObject, allowed: Set<String>, _ path: String) throws {
        for key in object.keys where !allowed.contains(key) {
            throw EngineError("\(path).\(key): Extra inputs are not permitted")
        }
    }

    static func required(_ object: EngineObject, _ key: String, _ path: String) throws -> EngineJSON {
        guard let value = object[key] else { throw EngineError("\(path).\(key): Field required") }
        return value
    }

    static func string(_ value: EngineJSON, _ path: String, min: Int = 0, max: Int? = nil, pattern: NSRegularExpression? = nil) throws -> String {
        guard let text = value.stringValue else { throw EngineError("\(path): Input should be a valid string") }
        let length = EnginePyText.length(text)
        if length < min { throw EngineError("\(path): String should have at least \(min) character") }
        if let max, length > max { throw EngineError("\(path): String should have at most \(max) characters") }
        if let pattern {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if pattern.firstMatch(in: text, options: [], range: range) == nil {
                throw EngineError("\(path): String should match pattern '\(pattern.pattern)'")
            }
        }
        return text
    }

    static func optionalString(_ value: EngineJSON?, _ path: String, min: Int = 0, max: Int? = nil, pattern: NSRegularExpression? = nil) throws -> String? {
        guard let value, !value.isNull else { return nil }
        return try string(value, path, min: min, max: max, pattern: pattern)
    }

    static func int(_ value: EngineJSON, _ path: String, ge: Int? = nil, le: Int? = nil) throws -> Int {
        let number: Int
        switch value {
        case .integer(let i): number = i
        case .bool(let b): number = b ? 1 : 0
        case .number(let d):
            guard d == d.rounded(), abs(d) < 9e15 else { throw EngineError("\(path): Input should be a valid integer, got a number with a fractional part") }
            number = Int(d)
        case .string(let s):
            guard let parsed = Int(EnginePyText.strip(s)) else { throw EngineError("\(path): Input should be a valid integer") }
            number = parsed
        default: throw EngineError("\(path): Input should be a valid integer")
        }
        if let ge, number < ge { throw EngineError("\(path): Input should be greater than or equal to \(ge)") }
        if let le, number > le { throw EngineError("\(path): Input should be less than or equal to \(le)") }
        return number
    }

    static func double(_ value: EngineJSON, _ path: String, ge: Double? = nil, le: Double? = nil) throws -> Double {
        let number: Double
        switch value {
        case .integer(let i): number = Double(i)
        case .number(let d): number = d
        case .bool(let b): number = b ? 1 : 0
        case .string(let s):
            guard let parsed = Double(EnginePyText.strip(s)) else { throw EngineError("\(path): Input should be a valid number") }
            number = parsed
        default: throw EngineError("\(path): Input should be a valid number")
        }
        if number.isNaN || number.isInfinite { throw EngineError("\(path): Input should be a finite number") }
        if let ge, number < ge { throw EngineError("\(path): Input should be greater than or equal to \(ge)") }
        if let le, number > le { throw EngineError("\(path): Input should be less than or equal to \(le)") }
        return number
    }

    static func bool(_ value: EngineJSON, _ path: String) throws -> Bool {
        switch value {
        case .bool(let b): return b
        case .integer(let i) where i == 0 || i == 1: return i == 1
        case .number(let d) where d == 0 || d == 1: return d == 1
        case .string(let s):
            switch s.lowercased() {
            case "true", "1", "yes", "y", "on", "t": return true
            case "false", "0", "no", "n", "off", "f": return false
            default: break
            }
        default: break
        }
        throw EngineError("\(path): Input should be a valid boolean")
    }

    static func literal(_ value: EngineJSON, _ path: String, _ allowed: [String]) throws -> String {
        guard let text = value.stringValue, allowed.contains(text) else {
            throw EngineError("\(path): Input should be \(allowed.map { "'\($0)'" }.joined(separator: ", "))")
        }
        return text
    }

    static func literalNumber(_ value: EngineJSON, _ path: String, _ expected: Double) throws {
        let actual: Double?
        switch value {
        case .integer(let i): actual = Double(i)
        case .number(let d): actual = d
        case .bool(let b): actual = b ? 1 : 0
        default: actual = nil
        }
        guard actual == expected else { throw EngineError("\(path): Input should be \(expected)") }
    }

    static func uuid(_ value: EngineJSON, _ path: String) throws -> String {
        guard let text = value.stringValue, let parsed = UUID(uuidString: text) else {
            throw EngineError("\(path): Input should be a valid UUID")
        }
        return parsed.uuidString.lowercased()
    }

    static func array(_ value: EngineJSON?, _ path: String, min: Int = 0, max: Int? = nil) throws -> [EngineJSON] {
        guard let value else { return [] }
        guard let items = value.arrayValue else { throw EngineError("\(path): Input should be a valid list") }
        if items.count < min { throw EngineError("\(path): List should have at least \(min) item") }
        if let max, items.count > max { throw EngineError("\(path): List should have at most \(max) items") }
        return items
    }

    static let identifierPattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_-]{1,100}$")

    static func identifier(_ value: EngineJSON, _ path: String) throws -> String {
        try string(value, path, pattern: identifierPattern)
    }

    static func text(_ value: EngineJSON, _ path: String) throws -> String {
        try string(value, path, min: 1, max: 2000)
    }
}

// MARK: - Models

nonisolated struct GoalEvidence: Codable, Equatable, Hashable {
    var messageID: String
    var kind: String
    var summary: String
    var quote: String

    enum CodingKeys: String, CodingKey { case messageID = "message_id", kind, summary, quote }

    init(messageID: String, kind: String, summary: String, quote: String) {
        self.messageID = messageID; self.kind = kind; self.summary = summary; self.quote = quote
    }

    init(validating value: EngineJSON, path: String) throws {
        let o = try EngineValidate.object(value, path)
        try EngineValidate.forbidExtra(o, allowed: ["message_id", "kind", "summary", "quote"], path)
        messageID = try EngineValidate.uuid(try EngineValidate.required(o, "message_id", path), "\(path).message_id")
        kind = try EngineValidate.literal(try EngineValidate.required(o, "kind", path), "\(path).kind", ["learner", "model"])
        summary = try EngineValidate.text(try EngineValidate.required(o, "summary", path), "\(path).summary")
        quote = try EngineValidate.text(try EngineValidate.required(o, "quote", path), "\(path).quote")
    }

    init(state value: EngineJSON) throws {
        let o = try EngineValidate.object(value, "evidence")
        messageID = o["message_id"]?.stringValue ?? ""
        kind = o["kind"]?.stringValue ?? ""
        summary = o["summary"]?.stringValue ?? ""
        quote = o["quote"]?.stringValue ?? ""
    }

    var json: EngineJSON {
        .object(EngineObject([("message_id", .string(messageID)), ("kind", .string(kind)),
                                 ("summary", .string(summary)), ("quote", .string(quote))]))
    }
}

nonisolated struct Evaluation: Codable, Equatable {
    var n: Int
    var targetScope: String
    var scoringUnit: String
    var difficulty: String
    var assistance: String = "independent_first"
    var threshold: Double = 0.8

    enum CodingKeys: String, CodingKey {
        case n, targetScope = "target_scope", scoringUnit = "scoring_unit", difficulty, assistance, threshold
    }

    init(n: Int, targetScope: String, scoringUnit: String, difficulty: String) {
        self.n = n; self.targetScope = targetScope; self.scoringUnit = scoringUnit; self.difficulty = difficulty
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = try c.decode(Int.self, forKey: .n)
        targetScope = try c.decode(String.self, forKey: .targetScope)
        scoringUnit = try c.decode(String.self, forKey: .scoringUnit)
        difficulty = try c.decode(String.self, forKey: .difficulty)
        assistance = try c.decodeIfPresent(String.self, forKey: .assistance) ?? "independent_first"
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.8
    }

    init(validating value: EngineJSON, path: String) throws {
        let o = try EngineValidate.object(value, path)
        try EngineValidate.forbidExtra(o, allowed: ["n", "target_scope", "scoring_unit", "difficulty", "assistance", "threshold"], path)
        n = try EngineValidate.int(try EngineValidate.required(o, "n", path), "\(path).n", ge: 1, le: 100)
        targetScope = try EngineValidate.text(try EngineValidate.required(o, "target_scope", path), "\(path).target_scope")
        scoringUnit = try EngineValidate.text(try EngineValidate.required(o, "scoring_unit", path), "\(path).scoring_unit")
        difficulty = try EngineValidate.text(try EngineValidate.required(o, "difficulty", path), "\(path).difficulty")
        if let value = o["assistance"] { assistance = try EngineValidate.literal(value, "\(path).assistance", ["independent_first"]) }
        if let value = o["threshold"] { try EngineValidate.literalNumber(value, "\(path).threshold", 0.8) }
    }

    init(state value: EngineJSON) throws {
        let o = try EngineValidate.object(value, "evaluation")
        n = o["n"]?.intValue ?? 1
        targetScope = o["target_scope"]?.stringValue ?? ""
        scoringUnit = o["scoring_unit"]?.stringValue ?? ""
        difficulty = o["difficulty"]?.stringValue ?? ""
        assistance = o["assistance"]?.stringValue ?? "independent_first"
        threshold = o["threshold"]?.doubleValue ?? 0.8
    }

    var json: EngineJSON {
        .object(EngineObject([("n", .integer(n)), ("target_scope", .string(targetScope)), ("scoring_unit", .string(scoringUnit)),
                                 ("difficulty", .string(difficulty)), ("assistance", .string(assistance)), ("threshold", .number(threshold))]))
    }
}

nonisolated struct Loop: Codable, Equatable {
    var enabled: Bool
    var unit: String
    var countBy: String = "graded_attempt"
    var repeatWhen: String
    var exitWhen: String
    var afterExit: String
    var stagnationAttempts: Int
    var maxAttempts: Int
    var maxMinutes: Int?
    var timeBasis: String = "server_elapsed"

    enum CodingKeys: String, CodingKey {
        case enabled, unit, countBy = "count_by", repeatWhen = "repeat_when", exitWhen = "exit_when", afterExit = "after_exit"
        case stagnationAttempts = "stagnation_attempts", maxAttempts = "max_attempts", maxMinutes = "max_minutes", timeBasis = "time_basis"
    }

    init(enabled: Bool, unit: String, repeatWhen: String, exitWhen: String, afterExit: String,
                stagnationAttempts: Int, maxAttempts: Int, maxMinutes: Int? = nil) {
        self.enabled = enabled; self.unit = unit; self.repeatWhen = repeatWhen; self.exitWhen = exitWhen
        self.afterExit = afterExit; self.stagnationAttempts = stagnationAttempts; self.maxAttempts = maxAttempts; self.maxMinutes = maxMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        unit = try c.decode(String.self, forKey: .unit)
        countBy = try c.decodeIfPresent(String.self, forKey: .countBy) ?? "graded_attempt"
        repeatWhen = try c.decode(String.self, forKey: .repeatWhen)
        exitWhen = try c.decode(String.self, forKey: .exitWhen)
        afterExit = try c.decode(String.self, forKey: .afterExit)
        stagnationAttempts = try c.decode(Int.self, forKey: .stagnationAttempts)
        maxAttempts = try c.decode(Int.self, forKey: .maxAttempts)
        maxMinutes = try c.decodeIfPresent(Int.self, forKey: .maxMinutes)
        timeBasis = try c.decodeIfPresent(String.self, forKey: .timeBasis) ?? "server_elapsed"
    }

    static let allowedKeys: Set<String> = ["enabled", "unit", "count_by", "repeat_when", "exit_when", "after_exit",
                                           "stagnation_attempts", "max_attempts", "max_minutes", "time_basis"]

    init(validating value: EngineJSON, path: String) throws {
        let o = try EngineValidate.object(value, path)
        try EngineValidate.forbidExtra(o, allowed: Loop.allowedKeys, path)
        enabled = try EngineValidate.bool(try EngineValidate.required(o, "enabled", path), "\(path).enabled")
        unit = try EngineValidate.text(try EngineValidate.required(o, "unit", path), "\(path).unit")
        if let value = o["count_by"] {
            countBy = try EngineValidate.literal(value, "\(path).count_by", ["graded_attempt", "independent_attempt", "child_completion", "model_action"])
        }
        repeatWhen = try EngineValidate.text(try EngineValidate.required(o, "repeat_when", path), "\(path).repeat_when")
        exitWhen = try EngineValidate.text(try EngineValidate.required(o, "exit_when", path), "\(path).exit_when")
        afterExit = try EngineValidate.text(try EngineValidate.required(o, "after_exit", path), "\(path).after_exit")
        stagnationAttempts = try EngineValidate.int(try EngineValidate.required(o, "stagnation_attempts", path), "\(path).stagnation_attempts", ge: 2, le: 100)
        maxAttempts = try EngineValidate.int(try EngineValidate.required(o, "max_attempts", path), "\(path).max_attempts", ge: 1, le: 1000)
        if let value = o["max_minutes"], !value.isNull {
            maxMinutes = try EngineValidate.int(value, "\(path).max_minutes", ge: 1, le: 1440)
        }
        if let value = o["time_basis"] { timeBasis = try EngineValidate.literal(value, "\(path).time_basis", ["server_elapsed"]) }
    }

    init(state value: EngineJSON) throws {
        // Python re-validates stored loops (`Loop.model_validate(old["loop"])`) before comparing,
        // which only fills defaults; stored loops always satisfy the constraints.
        try self.init(validating: value, path: "loop")
    }

    var json: EngineJSON {
        .object(EngineObject([
            ("enabled", .bool(enabled)), ("unit", .string(unit)), ("count_by", .string(countBy)), ("repeat_when", .string(repeatWhen)),
            ("exit_when", .string(exitWhen)), ("after_exit", .string(afterExit)), ("stagnation_attempts", .integer(stagnationAttempts)),
            ("max_attempts", .integer(maxAttempts)), ("max_minutes", maxMinutes.map { .integer($0) } ?? .null), ("time_basis", .string(timeBasis)),
        ]))
    }
}

nonisolated struct Goal: Codable, Equatable {
    var id: String
    var parentID: String?
    var title: String
    var outcome: String
    var learnerAction: String
    var modelAction: String
    var completionCondition: String
    var kind: String
    var status: String
    var nextAction: String
    var childOrder: [String] = []
    var branchCondition: String = ""
    var evidence: [GoalEvidence] = []
    var loop: Loop
    var evaluation: Evaluation?
    var exitReason: String?
    var replacesID: String?
    // Server-owned fields (present in stored state, forbidden in updates).
    var startedAt: String = ""
    var historyGoalID: String?
    var stagnationSinceSequence: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, parentID = "parent_id", title, outcome, learnerAction = "learner_action", modelAction = "model_action"
        case completionCondition = "completion_condition", kind, status, nextAction = "next_action", childOrder = "child_order"
        case branchCondition = "branch_condition", evidence, loop, evaluation, exitReason = "exit_reason", replacesID = "replaces_id"
        case startedAt = "started_at", historyGoalID = "history_goal_id", stagnationSinceSequence = "stagnation_since_sequence"
    }

    static let updateKeys: Set<String> = ["id", "parent_id", "title", "outcome", "learner_action", "model_action", "completion_condition",
                                          "kind", "status", "next_action", "child_order", "branch_condition", "evidence", "loop",
                                          "evaluation", "exit_reason", "replaces_id"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        title = try c.decode(String.self, forKey: .title)
        outcome = try c.decode(String.self, forKey: .outcome)
        learnerAction = try c.decode(String.self, forKey: .learnerAction)
        modelAction = try c.decode(String.self, forKey: .modelAction)
        completionCondition = try c.decode(String.self, forKey: .completionCondition)
        kind = try c.decode(String.self, forKey: .kind)
        status = try c.decode(String.self, forKey: .status)
        nextAction = try c.decode(String.self, forKey: .nextAction)
        childOrder = try c.decodeIfPresent([String].self, forKey: .childOrder) ?? []
        branchCondition = try c.decodeIfPresent(String.self, forKey: .branchCondition) ?? ""
        evidence = try c.decodeIfPresent([GoalEvidence].self, forKey: .evidence) ?? []
        loop = try c.decode(Loop.self, forKey: .loop)
        evaluation = try c.decodeIfPresent(Evaluation.self, forKey: .evaluation)
        exitReason = try c.decodeIfPresent(String.self, forKey: .exitReason)
        replacesID = try c.decodeIfPresent(String.self, forKey: .replacesID)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
        historyGoalID = try c.decodeIfPresent(String.self, forKey: .historyGoalID)
        stagnationSinceSequence = try c.decodeIfPresent(Int.self, forKey: .stagnationSinceSequence) ?? 0
    }

    /// pydantic `Goal.model_validate` (update payload; server-owned keys are extra and rejected).
    init(validating value: EngineJSON, path: String) throws {
        let o = try EngineValidate.object(value, path)
        try EngineValidate.forbidExtra(o, allowed: Goal.updateKeys, path)
        id = try EngineValidate.identifier(try EngineValidate.required(o, "id", path), "\(path).id")
        let parent = try EngineValidate.required(o, "parent_id", path)
        parentID = try EngineValidate.optionalString(parent, "\(path).parent_id", pattern: EngineValidate.identifierPattern)
        title = try EngineValidate.text(try EngineValidate.required(o, "title", path), "\(path).title")
        outcome = try EngineValidate.text(try EngineValidate.required(o, "outcome", path), "\(path).outcome")
        learnerAction = try EngineValidate.text(try EngineValidate.required(o, "learner_action", path), "\(path).learner_action")
        modelAction = try EngineValidate.text(try EngineValidate.required(o, "model_action", path), "\(path).model_action")
        completionCondition = try EngineValidate.text(try EngineValidate.required(o, "completion_condition", path), "\(path).completion_condition")
        kind = try EngineValidate.literal(try EngineValidate.required(o, "kind", path), "\(path).kind", ["model", "learner"])
        status = try EngineValidate.literal(try EngineValidate.required(o, "status", path), "\(path).status", ["pending", "active", "completed", "paused"])
        nextAction = try EngineValidate.text(try EngineValidate.required(o, "next_action", path), "\(path).next_action")
        childOrder = try EngineValidate.array(o["child_order"], "\(path).child_order").enumerated().map {
            try EngineValidate.identifier($0.element, "\(path).child_order[\($0.offset)]")
        }
        if let value = o["branch_condition"] { branchCondition = try EngineValidate.string(value, "\(path).branch_condition", max: 2000) }
        evidence = try EngineValidate.array(o["evidence"], "\(path).evidence").enumerated().map {
            try GoalEvidence(validating: $0.element, path: "\(path).evidence[\($0.offset)]")
        }
        loop = try Loop(validating: try EngineValidate.required(o, "loop", path), path: "\(path).loop")
        if let value = o["evaluation"], !value.isNull { evaluation = try Evaluation(validating: value, path: "\(path).evaluation") }
        if let value = o["exit_reason"], !value.isNull {
            exitReason = try EngineValidate.literal(value, "\(path).exit_reason", ["achieved", "stagnation", "attempt_limit", "time_limit", "interrupted", "goal_changed"])
        }
        replacesID = try EngineValidate.optionalString(o["replaces_id"], "\(path).replaces_id", pattern: EngineValidate.identifierPattern)
    }

    /// Lenient load of a stored goal (state JSON).
    init(state value: EngineJSON) throws {
        let o = try EngineValidate.object(value, "goal")
        id = o["id"]?.stringValue ?? ""
        parentID = o["parent_id"]?.stringValue
        title = o["title"]?.stringValue ?? ""
        outcome = o["outcome"]?.stringValue ?? ""
        learnerAction = o["learner_action"]?.stringValue ?? ""
        modelAction = o["model_action"]?.stringValue ?? ""
        completionCondition = o["completion_condition"]?.stringValue ?? ""
        kind = o["kind"]?.stringValue ?? ""
        status = o["status"]?.stringValue ?? ""
        nextAction = o["next_action"]?.stringValue ?? ""
        childOrder = (o["child_order"]?.arrayValue ?? []).compactMap(\.stringValue)
        branchCondition = o["branch_condition"]?.stringValue ?? ""
        evidence = try (o["evidence"]?.arrayValue ?? []).map { try GoalEvidence(state: $0) }
        guard let loopValue = o["loop"] else { throw EngineError("goal.loop: Field required") }
        loop = try Loop(state: loopValue)
        if let value = o["evaluation"], !value.isNull { evaluation = try Evaluation(state: value) }
        exitReason = o["exit_reason"]?.stringValue
        replacesID = o["replaces_id"]?.stringValue
        startedAt = o["started_at"]?.stringValue ?? ""
        historyGoalID = o["history_goal_id"]?.stringValue
        stagnationSinceSequence = o["stagnation_since_sequence"]?.intValue ?? 0
    }

    /// `goal.get("history_goal_id", goal["id"])`
    var historyScope: String { historyGoalID ?? id }

    /// JSON as stored by Python after `apply_update` (model fields + server-owned fields).
    var json: EngineJSON {
        .object(EngineObject([
            ("id", .string(id)), ("parent_id", parentID.map { .string($0) } ?? .null), ("title", .string(title)),
            ("outcome", .string(outcome)), ("learner_action", .string(learnerAction)), ("model_action", .string(modelAction)),
            ("completion_condition", .string(completionCondition)), ("kind", .string(kind)), ("status", .string(status)),
            ("next_action", .string(nextAction)), ("child_order", .array(childOrder.map { .string($0) })),
            ("branch_condition", .string(branchCondition)), ("evidence", .array(evidence.map(\.json))), ("loop", loop.json),
            ("evaluation", evaluation?.json ?? .null), ("exit_reason", exitReason.map { .string($0) } ?? .null),
            ("replaces_id", replacesID.map { .string($0) } ?? .null), ("started_at", .string(startedAt)),
            ("history_goal_id", .string(historyScope)), ("stagnation_since_sequence", .integer(stagnationSinceSequence)),
        ]))
    }
}

nonisolated struct Problem: Codable, Equatable {
    var id: String
    var goalID: String
    var prompt: String
    var independent: Bool
    /// Server-owned: the assistant message that delivered the problem.
    var messageID: String = ""

    enum CodingKeys: String, CodingKey { case id, goalID = "goal_id", prompt, independent, messageID = "message_id" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        goalID = try c.decode(String.self, forKey: .goalID)
        prompt = try c.decode(String.self, forKey: .prompt)
        independent = try c.decode(Bool.self, forKey: .independent)
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID) ?? ""
    }

    init(validating value: EngineJSON, path: String) throws {
        let o = try EngineValidate.object(value, path)
        try EngineValidate.forbidExtra(o, allowed: ["id", "goal_id", "prompt", "independent"], path)
        id = try EngineValidate.identifier(try EngineValidate.required(o, "id", path), "\(path).id")
        goalID = try EngineValidate.identifier(try EngineValidate.required(o, "goal_id", path), "\(path).goal_id")
        prompt = try EngineValidate.text(try EngineValidate.required(o, "prompt", path), "\(path).prompt")
        independent = try EngineValidate.bool(try EngineValidate.required(o, "independent", path), "\(path).independent")
    }

    init(state value: EngineJSON) throws {
        let o = try EngineValidate.object(value, "problem")
        id = o["id"]?.stringValue ?? ""
        goalID = o["goal_id"]?.stringValue ?? ""
        prompt = o["prompt"]?.stringValue ?? ""
        independent = o["independent"]?.boolValue ?? false
        messageID = o["message_id"]?.stringValue ?? ""
    }

    /// The update-visible fields (what `problem_model.model_dump()` contains).
    func sameServedFields(as other: Problem) -> Bool {
        id == other.id && goalID == other.goalID && prompt == other.prompt && independent == other.independent
    }

    var json: EngineJSON {
        .object(EngineObject([("id", .string(id)), ("goal_id", .string(goalID)), ("prompt", .string(prompt)),
                                 ("independent", .bool(independent)), ("message_id", .string(messageID))]))
    }
}

nonisolated struct Attempt: Codable, Equatable {
    var problemID: String
    var submissionID: String
    var score: Double
    var assisted: Bool
    var feedback: String
    var errorTag: String = ""
    var correctionReason: String?
    /// Server-owned ordering number.
    var sequence: Int = 0

    enum CodingKeys: String, CodingKey {
        case problemID = "problem_id", submissionID = "submission_id", score, assisted, feedback, errorTag = "error_tag"
        case correctionReason = "correction_reason", sequence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        problemID = try c.decode(String.self, forKey: .problemID)
        submissionID = try c.decode(String.self, forKey: .submissionID)
        score = try c.decode(Double.self, forKey: .score)
        assisted = try c.decode(Bool.self, forKey: .assisted)
        feedback = try c.decode(String.self, forKey: .feedback)
        errorTag = try c.decodeIfPresent(String.self, forKey: .errorTag) ?? ""
        correctionReason = try c.decodeIfPresent(String.self, forKey: .correctionReason)
        sequence = try c.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
    }

    init(validating value: EngineJSON, path: String) throws {
        let o = try EngineValidate.object(value, path)
        try EngineValidate.forbidExtra(o, allowed: ["problem_id", "submission_id", "score", "assisted", "feedback", "error_tag", "correction_reason"], path)
        problemID = try EngineValidate.identifier(try EngineValidate.required(o, "problem_id", path), "\(path).problem_id")
        submissionID = try EngineValidate.uuid(try EngineValidate.required(o, "submission_id", path), "\(path).submission_id")
        score = try EngineValidate.double(try EngineValidate.required(o, "score", path), "\(path).score", ge: 0, le: 1)
        assisted = try EngineValidate.bool(try EngineValidate.required(o, "assisted", path), "\(path).assisted")
        feedback = try EngineValidate.text(try EngineValidate.required(o, "feedback", path), "\(path).feedback")
        if let value = o["error_tag"] { errorTag = try EngineValidate.string(value, "\(path).error_tag", max: 100) }
        correctionReason = try EngineValidate.optionalString(o["correction_reason"], "\(path).correction_reason", max: 2000)
    }

    init(state value: EngineJSON) throws {
        let o = try EngineValidate.object(value, "attempt")
        problemID = o["problem_id"]?.stringValue ?? ""
        submissionID = o["submission_id"]?.stringValue ?? ""
        score = o["score"]?.doubleValue ?? 0
        assisted = o["assisted"]?.boolValue ?? false
        feedback = o["feedback"]?.stringValue ?? ""
        errorTag = o["error_tag"]?.stringValue ?? ""
        correctionReason = o["correction_reason"]?.stringValue
        sequence = o["sequence"]?.intValue ?? 0
    }

    var json: EngineJSON {
        .object(EngineObject([
            ("problem_id", .string(problemID)), ("submission_id", .string(submissionID)), ("score", .number(score)),
            ("assisted", .bool(assisted)), ("feedback", .string(feedback)), ("error_tag", .string(errorTag)),
            ("correction_reason", correctionReason.map { .string($0) } ?? .null), ("sequence", .integer(sequence)),
        ]))
    }
}

nonisolated struct ProgressEvent: Codable, Equatable {
    var kind: String
    var goalID: String
    var messageID: String

    enum CodingKeys: String, CodingKey { case kind, goalID = "goal_id", messageID = "message_id" }

    init(kind: String, goalID: String, messageID: String) { self.kind = kind; self.goalID = goalID; self.messageID = messageID }

    init(state value: EngineJSON) throws {
        let o = try EngineValidate.object(value, "event")
        kind = o["kind"]?.stringValue ?? ""
        goalID = o["goal_id"]?.stringValue ?? ""
        messageID = o["message_id"]?.stringValue ?? ""
    }

    var json: EngineJSON {
        .object(EngineObject([("kind", .string(kind)), ("goal_id", .string(goalID)), ("message_id", .string(messageID))]))
    }
}

nonisolated struct ProgressUpdate: Codable, Equatable {
    var schemaVersion: Int
    var baseRevision: Int
    var goals: [Goal]
    var problems: [Problem]
    var attempts: [Attempt]
    var currentGoalID: String?
    var disposition: String
    var nextAction: String
    var waitingFor: String?
    var waitReason: String
    var waitingProblemID: String?
    var returnStack: [String]
    var replyQuotes: [String]
    var policyChangeReason: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", baseRevision = "base_revision", goals, problems, attempts
        case currentGoalID = "current_goal_id", disposition, nextAction = "next_action", waitingFor = "waiting_for"
        case waitReason = "wait_reason", waitingProblemID = "waiting_problem_id", returnStack = "return_stack"
        case replyQuotes = "reply_quotes", policyChangeReason = "policy_change_reason"
    }

    static let allowedKeys: Set<String> = ["schema_version", "base_revision", "goals", "problems", "attempts", "current_goal_id",
                                           "disposition", "next_action", "waiting_for", "wait_reason", "waiting_problem_id",
                                           "return_stack", "reply_quotes", "policy_change_reason"]

    /// pydantic `ProgressUpdate.model_validate(raw)`.
    init(validating raw: EngineJSON) throws {
        let path = "ProgressUpdate"
        let o = try EngineValidate.object(raw, path)
        try EngineValidate.forbidExtra(o, allowed: ProgressUpdate.allowedKeys, path)
        try EngineValidate.literalNumber(try EngineValidate.required(o, "schema_version", path), "\(path).schema_version", 1)
        schemaVersion = 1
        baseRevision = try EngineValidate.int(try EngineValidate.required(o, "base_revision", path), "\(path).base_revision", ge: 0)
        goals = try EngineValidate.array(o["goals"], "\(path).goals", max: 40).enumerated().map { try Goal(validating: $0.element, path: "\(path).goals[\($0.offset)]") }
        problems = try EngineValidate.array(o["problems"], "\(path).problems", max: 10).enumerated().map { try Problem(validating: $0.element, path: "\(path).problems[\($0.offset)]") }
        attempts = try EngineValidate.array(o["attempts"], "\(path).attempts", max: 10).enumerated().map { try Attempt(validating: $0.element, path: "\(path).attempts[\($0.offset)]") }
        currentGoalID = try EngineValidate.optionalString(try EngineValidate.required(o, "current_goal_id", path), "\(path).current_goal_id", pattern: EngineValidate.identifierPattern)
        disposition = try EngineValidate.literal(try EngineValidate.required(o, "disposition", path), "\(path).disposition", ["waiting", "continue", "completed", "paused", "not_learning"])
        nextAction = try EngineValidate.string(try EngineValidate.required(o, "next_action", path), "\(path).next_action", max: 2000)
        if let value = o["waiting_for"], !value.isNull {
            waitingFor = try EngineValidate.literal(value, "\(path).waiting_for", ["answer", "choice", "reading"])
        }
        waitReason = try o["wait_reason"].map { try EngineValidate.string($0, "\(path).wait_reason", max: 2000) } ?? ""
        waitingProblemID = try EngineValidate.optionalString(o["waiting_problem_id"], "\(path).waiting_problem_id", pattern: EngineValidate.identifierPattern)
        returnStack = try EngineValidate.array(o["return_stack"], "\(path).return_stack").enumerated().map { try EngineValidate.identifier($0.element, "\(path).return_stack[\($0.offset)]") }
        guard let quotes = o["reply_quotes"] else { throw EngineError("\(path).reply_quotes: Field required") }
        replyQuotes = try EngineValidate.array(quotes, "\(path).reply_quotes", min: 1, max: 30).enumerated().map { try EngineValidate.text($0.element, "\(path).reply_quotes[\($0.offset)]") }
        policyChangeReason = try EngineValidate.optionalString(o["policy_change_reason"], "\(path).policy_change_reason", max: 2000)
    }

    init(validating raw: [String: Any]) throws {
        try self.init(validating: EngineJSON(any: raw))
    }
}

/// Insertion-ordered map with Python dict semantics (overwrite keeps position).
nonisolated struct EngineOrderedMap<Value: Codable & Equatable>: Codable, Equatable {
    private(set) var keys: [String] = []
    private var storage: [String: Value] = [:]

    init() {}

    subscript(key: String) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = newValue
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }
    var count: Int { keys.count }
    var values: [Value] { keys.map { storage[$0]! } }
    var pairs: [(String, Value)] { keys.map { ($0, storage[$0]!) } }
    func contains(_ key: String) -> Bool { storage[key] != nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: EngineJSON.DynamicKey.self)
        for key in c.allKeys { self[key.stringValue] = try c.decode(Value.self, forKey: key) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineJSON.DynamicKey.self)
        for (key, value) in pairs { try c.encode(value, forKey: EngineJSON.DynamicKey(key)) }
    }
}

nonisolated struct ProgressState: Codable, Equatable {
    var schemaVersion: Int = 1
    var revision: Int = 0
    var goals = EngineOrderedMap<Goal>()
    var problems = EngineOrderedMap<Problem>()
    var attempts = EngineOrderedMap<Attempt>()
    var currentGoalID: String?
    var disposition: String = "not_learning"
    var nextAction: String = ""
    var waitingFor: String?
    var waitReason: String = ""
    var waitingProblemID: String?
    var returnStack: [String] = []
    var events = EngineOrderedMap<ProgressEvent>()
    var lastMessageID: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", revision, goals, problems, attempts, currentGoalID = "current_goal_id", disposition
        case nextAction = "next_action", waitingFor = "waiting_for", waitReason = "wait_reason", waitingProblemID = "waiting_problem_id"
        case returnStack = "return_stack", events, lastMessageID = "last_message_id"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        goals = try c.decodeIfPresent(EngineOrderedMap<Goal>.self, forKey: .goals) ?? .init()
        problems = try c.decodeIfPresent(EngineOrderedMap<Problem>.self, forKey: .problems) ?? .init()
        attempts = try c.decodeIfPresent(EngineOrderedMap<Attempt>.self, forKey: .attempts) ?? .init()
        currentGoalID = try c.decodeIfPresent(String.self, forKey: .currentGoalID)
        disposition = try c.decodeIfPresent(String.self, forKey: .disposition) ?? "not_learning"
        nextAction = try c.decodeIfPresent(String.self, forKey: .nextAction) ?? ""
        waitingFor = try c.decodeIfPresent(String.self, forKey: .waitingFor)
        waitReason = try c.decodeIfPresent(String.self, forKey: .waitReason) ?? ""
        waitingProblemID = try c.decodeIfPresent(String.self, forKey: .waitingProblemID)
        returnStack = try c.decodeIfPresent([String].self, forKey: .returnStack) ?? []
        events = try c.decodeIfPresent(EngineOrderedMap<ProgressEvent>.self, forKey: .events) ?? .init()
        lastMessageID = try c.decodeIfPresent(String.self, forKey: .lastMessageID)
    }

    /// Order-preserving load (use this instead of JSONDecoder when Python-compatible ordering matters).
    init(json value: EngineJSON) throws {
        let o = try EngineValidate.object(value, "state")
        schemaVersion = o["schema_version"]?.intValue ?? 1
        revision = o["revision"]?.intValue ?? 0
        for (key, item) in (o["goals"]?.objectValue ?? .init()).pairs { goals[key] = try Goal(state: item) }
        for (key, item) in (o["problems"]?.objectValue ?? .init()).pairs { problems[key] = try Problem(state: item) }
        for (key, item) in (o["attempts"]?.objectValue ?? .init()).pairs { attempts[key] = try Attempt(state: item) }
        currentGoalID = o["current_goal_id"]?.stringValue
        disposition = o["disposition"]?.stringValue ?? "not_learning"
        nextAction = o["next_action"]?.stringValue ?? ""
        waitingFor = o["waiting_for"]?.stringValue
        waitReason = o["wait_reason"]?.stringValue ?? ""
        waitingProblemID = o["waiting_problem_id"]?.stringValue
        returnStack = (o["return_stack"]?.arrayValue ?? []).compactMap(\.stringValue)
        for (key, item) in (o["events"]?.objectValue ?? .init()).pairs { events[key] = try ProgressEvent(state: item) }
        lastMessageID = o["last_message_id"]?.stringValue
    }

    init(jsonData: Data) throws { try self.init(json: try EngineJSON.parse(jsonData)) }

    /// Python dict layout (`empty_state()` key order, `last_message_id` only once set).
    var json: EngineJSON {
        var object = EngineObject()
        object["schema_version"] = .integer(schemaVersion)
        object["revision"] = .integer(revision)
        object["goals"] = .object(EngineObject(goals.pairs.map { ($0.0, $0.1.json) }))
        object["problems"] = .object(EngineObject(problems.pairs.map { ($0.0, $0.1.json) }))
        object["attempts"] = .object(EngineObject(attempts.pairs.map { ($0.0, $0.1.json) }))
        object["current_goal_id"] = currentGoalID.map { .string($0) } ?? .null
        object["disposition"] = .string(disposition)
        object["next_action"] = .string(nextAction)
        object["waiting_for"] = waitingFor.map { .string($0) } ?? .null
        object["wait_reason"] = .string(waitReason)
        object["waiting_problem_id"] = waitingProblemID.map { .string($0) } ?? .null
        object["return_stack"] = .array(returnStack.map { .string($0) })
        object["events"] = .object(EngineObject(events.pairs.map { ($0.0, $0.1.json) }))
        if let lastMessageID { object["last_message_id"] = .string(lastMessageID) }
        return .object(object)
    }

    var jsonData: Data { Data(json.serialized().utf8) }
}

nonisolated struct ScoreWindow: Equatable {
    var count: Int
    var score: Double?
    var passed: Bool
    var submissionIDs: [String]

    var json: EngineJSON {
        .object(EngineObject([("count", .integer(count)), ("score", score.map { .number($0) } ?? .null),
                                 ("passed", .bool(passed)), ("submission_ids", .array(submissionIDs.map { .string($0) }))]))
    }
}

nonisolated struct LoopStats: Equatable {
    var totalAttempts: Int
    var totalIterations: Int
    var stalled: Bool
    var elapsedSeconds: Double
    var attemptLimitReached: Bool
    var timeLimitReached: Bool

    var json: EngineJSON {
        .object(EngineObject([("total_attempts", .integer(totalAttempts)), ("total_iterations", .integer(totalIterations)),
                                 ("stalled", .bool(stalled)), ("elapsed_seconds", .number(elapsedSeconds)),
                                 ("attempt_limit_reached", .bool(attemptLimitReached)), ("time_limit_reached", .bool(timeLimitReached))]))
    }
}

// MARK: - Engine

nonisolated enum LearningProgress {
    typealias JSONObject = [String: Any]
    typealias SourceMessage = (role: String, plainText: String)

    static let open = "<struis_progress_update>"
    static let close = "</struis_progress_update>"

    static func emptyState() -> ProgressState { ProgressState() }

    // MARK: extract_update

    static func extractUpdate(_ text: String) throws -> (visible: String, raw: JSONObject) {
        let (visible, value) = try extractUpdateValue(text)
        guard let object = value.objectValue else {
            // Python returns whatever json.loads produced; callers always pass a dict to apply_update.
            throw EngineError("progress update must be a JSON object")
        }
        return (visible, object.pairs.reduce(into: [:]) { $0[$1.0] = $1.1.anyValue })
    }

    /// Same as `extractUpdate` but keeps the parsed value (order-preserving).
    static func extractUpdateValue(_ text: String) throws -> (visible: String, raw: EngineJSON) {
        let scalars = Array(text.unicodeScalars)
        let openScalars = Array(open.unicodeScalars)
        let closeScalars = Array(close.unicodeScalars)
        let openCount = EnginePyText.count(text, open)
        let closeCount = EnginePyText.count(text, close)
        let start = EnginePyText.find(scalars, openScalars)
        let end = start < 0 ? -1 : EnginePyText.find(scalars, closeScalars, from: start + openScalars.count)
        guard openCount == 1, closeCount == 1, start >= 0, end >= 0 else {
            throw EngineError("exactly one complete progress update is required")
        }
        let raw = EnginePyText.strip(String(String.UnicodeScalarView(scalars[(start + openScalars.count)..<end])))
        if raw.utf8.count > 128 * 1024 { throw EngineError("progress update is too large") }
        let visible = EnginePyText.strip(String(String.UnicodeScalarView(scalars[0..<start])) + String(String.UnicodeScalarView(scalars[(end + closeScalars.count)...])))
        do {
            return (visible, try EngineJSON.parse(raw))
        } catch {
            // Most rejected rounds were `Invalid \escape` from LaTeX in quotes (B8). Repair only that
            // by rule and parse again; anything else is still rejected.
            let repaired = repairInvalidEscapes(raw)
            guard repaired != raw, let value = try? EngineJSON.parse(repaired) else { throw error }
            return (visible, value)
        }
    }

    /// Inside JSON strings, a backslash not starting a valid escape (`\"` `\\` `\/` `\b` `\f` `\n`
    /// `\r` `\t` `\uXXXX`) becomes a literal backslash (`\\`). Text outside strings is unchanged.
    static func repairInvalidEscapes(_ raw: String) -> String {
        let scalars = Array(raw.unicodeScalars)
        var out = String.UnicodeScalarView()
        var inString = false
        var index = 0
        func isHex(_ s: Unicode.Scalar) -> Bool { ("0"..."9").contains(s) || ("a"..."f").contains(s) || ("A"..."F").contains(s) }
        while index < scalars.count {
            let scalar = scalars[index]
            if !inString {
                if scalar == "\"" { inString = true }
                out.append(scalar)
                index += 1
                continue
            }
            if scalar == "\"" {
                inString = false
                out.append(scalar)
                index += 1
                continue
            }
            if scalar == "\\" {
                let next = index + 1 < scalars.count ? scalars[index + 1] : nil
                let valid: Bool
                switch next {
                case "\"", "\\", "/", "b", "f", "n", "r", "t":
                    valid = true
                case "u":
                    valid = index + 5 < scalars.count && scalars[(index + 2)...(index + 5)].allSatisfy(isHex)
                default:
                    valid = false
                }
                if valid, let next {
                    out.append(scalar)
                    out.append(next)
                    index += 2
                } else {
                    out.append("\\")
                    out.append("\\")
                    index += 1
                }
                continue
            }
            out.append(scalar)
            index += 1
        }
        return String(out)
    }

    // MARK: helpers

    static func requireQuote(_ quote: String, in body: String, field: String) throws {
        if EnginePyText.contains(body, quote) { return }
        let strippedQuote = EnginePyText.replace(EnginePyText.replace(quote, "\n", ""), "\r", "")
        let strippedBody = EnginePyText.replace(EnginePyText.replace(body, "\n", ""), "\r", "")
        if EnginePyText.contains(strippedBody, strippedQuote) { return }
        // The quote is the delivered text with only spacing, width, Markdown or math delimiters
        // differing (B8 `reply quote is absent`): accept it. A quote with other words still fails.
        let looseQuote = looseQuoteForm(quote)
        if !looseQuote.isEmpty, looseQuoteForm(body).contains(looseQuote) { return }
        throw EngineError("\(field) quote is absent from delivered reply/source: \(pythonRepr(quote))")
    }

    /// Compatibility form for quote matching: NFKC (full/half width), no whitespace, no Markdown
    /// emphasis or code marks, no math delimiters (`$`, `\(` `\)` `\[` `\]`), unified quotes.
    static func looseQuoteForm(_ text: String) -> String {
        var value = text.precomposedStringWithCompatibilityMapping
        for delimiter in ["\\(", "\\)", "\\[", "\\]"] { value = value.replacingOccurrences(of: delimiter, with: "") }
        let dropped: Set<Character> = ["*", "_", "`", "$", "「", "」", "『", "』", "\"", "'", "“", "”", "‘", "’"]
        return String(value.filter { !$0.isWhitespace && !dropped.contains($0) })
    }

    /// Python `repr(str)`.
    static func pythonRepr(_ text: String) -> String {
        let useDouble = text.contains("'") && !text.contains("\"")
        let quote: Character = useDouble ? "\"" : "'"
        var out = String(quote)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "'" where !useDouble: out += "\\'"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02x", scalar.value)
                } else if !scalar.properties.isPrintableForRepr {
                    out += scalar.value > 0xFFFF ? String(format: "\\U%08x", scalar.value) : (scalar.value > 0xFF ? String(format: "\\u%04x", scalar.value) : String(format: "\\x%02x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append(quote)
        return out
    }

    static func ancestry(_ state: ProgressState, _ goalID: String?) throws -> [Goal] {
        var result: [Goal] = []
        var seen = Set<String>()
        var current = goalID
        while let gid = current, !gid.isEmpty {
            guard !seen.contains(gid), let goal = state.goals[gid] else {
                throw EngineError("goal tree contains a cycle or missing parent")
            }
            seen.insert(gid)
            result.append(goal)
            current = goal.parentID
        }
        return result
    }

    static func goalAttempts(_ state: ProgressState, _ goalID: String) throws -> [Attempt] {
        guard let goal = state.goals[goalID] else { throw EngineError("KeyError: \(goalID)") }
        let scope = goal.historyScope
        var result: [Attempt] = []
        for attempt in state.attempts.values {
            guard let problem = state.problems[attempt.problemID] else { throw EngineError("KeyError: \(attempt.problemID)") }
            let parents = try ancestry(state, problem.goalID)
            if parents.contains(where: { $0.historyScope == scope }) { result.append(attempt) }
        }
        return result.enumerated().sorted { ($0.element.sequence, $0.offset) < ($1.element.sequence, $1.offset) }.map(\.element)
    }

    static func scoreWindow(state: ProgressState, goalID: String) throws -> ScoreWindow {
        guard let goal = state.goals[goalID] else { throw EngineError("KeyError: \(goalID)") }
        guard let policy = goal.evaluation else { return ScoreWindow(count: 0, score: nil, passed: false, submissionIDs: []) }
        var seen = Set<String>()
        var eligible: [Attempt] = []
        for attempt in try goalAttempts(state, goalID) {
            let pid = attempt.problemID
            let first = !seen.contains(pid)
            seen.insert(pid)
            if first, !attempt.assisted, state.problems[pid]?.independent == true { eligible.append(attempt) }
        }
        let window = Array(eligible.suffix(policy.n))
        let score: Double? = window.isEmpty ? nil : window.map(\.score).reduce(0, +) / Double(window.count)
        let passed = window.count == policy.n && score != nil && score! >= 0.8 - 1e-9
        return ScoreWindow(count: window.count, score: score, passed: passed, submissionIDs: window.map(\.submissionID))
    }

    static func loopStats(state: ProgressState, goalID: String, now: Date = Date()) throws -> LoopStats {
        guard let goal = state.goals[goalID] else { throw EngineError("KeyError: \(goalID)") }
        let policy = goal.loop
        let trials = try goalAttempts(state, goalID)
        let stagnationTrials = trials.filter { $0.sequence > goal.stagnationSinceSequence }
        let tail = Array(stagnationTrials.suffix(policy.stagnationAttempts))
        let stalled = tail.count == policy.stagnationAttempts && !tail[0].errorTag.isEmpty
            && tail.allSatisfy { $0.errorTag == tail[0].errorTag } && tail.allSatisfy { $0.score <= tail[0].score }
        guard let startedAt = EnginePyTime.parseISO(goal.startedAt) else { throw EngineError("Invalid isoformat string: \(pythonRepr(goal.startedAt))") }
        let elapsed = max(0, EnginePyTime.totalSeconds(from: startedAt, to: now))
        var iterations = trials.count
        if policy.countBy == "independent_attempt" {
            var seen = Set<String>()
            iterations = 0
            for trial in trials {
                let pid = trial.problemID
                if !seen.contains(pid), !trial.assisted, state.problems[pid]?.independent == true { iterations += 1 }
                seen.insert(pid)
            }
        } else if policy.countBy != "graded_attempt" {
            let scope = goal.historyScope
            let eventKind = policy.countBy == "child_completion" ? "completion" : "model_action"
            iterations = 0
            for event in state.events.values {
                guard event.kind == eventKind else { continue }
                let chain = try ancestry(state, event.goalID)
                let considered = eventKind == "completion" ? Array(chain.dropFirst()) : chain
                if considered.contains(where: { $0.historyScope == scope }) { iterations += 1 }
            }
        }
        let timeLimit = policy.maxMinutes.map { $0 > 0 && elapsed >= Double($0) * 60 } ?? false
        return LoopStats(totalAttempts: trials.count, totalIterations: iterations, stalled: stalled, elapsedSeconds: elapsed,
                         attemptLimitReached: iterations >= policy.maxAttempts, timeLimitReached: timeLimit)
    }

    static func checkTree(state: ProgressState) throws {
        for goal in state.goals.values {
            _ = try ancestry(state, goal.id)
            let children = Set(state.goals.values.filter { $0.parentID == goal.id }.map(\.id))
            if Set(goal.childOrder) != children || goal.childOrder.count != children.count {
                throw EngineError("child_order must name every child exactly once")
            }
        }
        for gid in state.returnStack where !state.goals.contains(gid) {
            throw EngineError("return goal does not exist")
        }
        if let current = state.currentGoalID, !current.isEmpty { _ = try ancestry(state, current) }
    }

    // MARK: apply_update

    static func applyUpdate(before: ProgressState, raw: JSONObject, reply: String, userMessageID: String,
                                   assistantMessageID: String, sourceMessages: [String: SourceMessage], now: Date = Date()) throws -> ProgressState {
        try applyUpdate(before: before, raw: EngineJSON(any: raw), reply: reply, userMessageID: userMessageID,
                        assistantMessageID: assistantMessageID, sourceMessages: sourceMessages, now: now)
    }

    static func applyUpdate(before: ProgressState, raw: EngineJSON, reply: String, userMessageID: String,
                                   assistantMessageID: String, sourceMessages: [String: SourceMessage], now: Date = Date()) throws -> ProgressState {
        let update = try ProgressUpdate(validating: raw)
        let assistantID = UUID(uuidString: assistantMessageID)?.uuidString.lowercased() ?? assistantMessageID
        let userID = UUID(uuidString: userMessageID)?.uuidString.lowercased() ?? userMessageID
        let goalKeys = update.goals.map(\.id)
        let problemKeys = update.problems.map(\.id)
        let attemptKeys = update.attempts.map { "\($0.problemID)\u{0}\($0.submissionID)" }
        for keys in [goalKeys, problemKeys, attemptKeys] where keys.count != Set(keys).count {
            throw EngineError("update contains duplicate records")
        }
        if update.baseRevision != before.revision { throw EngineError("stale progress revision") }
        for quote in update.replyQuotes { try requireQuote(quote, in: reply, field: "reply") }
        let currentTime = now
        var state = before
        if update.disposition == "not_learning" {
            if !update.goals.isEmpty || !update.problems.isEmpty || !update.attempts.isEmpty {
                throw EngineError("non-learning reply cannot modify learning records")
            }
            state.revision += 1
            state.lastMessageID = assistantID
            return state
        }
        for var goal in update.goals {
            let old = before.goals[goal.id]
            if let old {
                if goal.parentID != old.parentID || goal.replacesID != old.replacesID || goal.kind != old.kind {
                    throw EngineError("existing goal ancestry cannot change")
                }
                if (goal.evaluation != old.evaluation || goal.loop != old.loop || goal.outcome != old.outcome
                    || goal.completionCondition != old.completionCondition) && !(update.policyChangeReason ?? "").isTruthyString {
                    throw EngineError("changing evaluation or loop policy requires an explicit reason")
                }
                goal.startedAt = old.startedAt
                goal.historyGoalID = old.historyScope
                goal.stagnationSinceSequence = old.stagnationSinceSequence
                let previousRefs = Set(old.evidence.map { EvidenceRef($0) })
                let newRefs = Set(goal.evidence.map { EvidenceRef($0) })
                if !previousRefs.isSubset(of: newRefs) { throw EngineError("goal evidence cannot be discarded") }
            } else {
                let replacement = goal.replacesID.flatMap { before.goals[$0] }
                if goal.replacesID != nil, replacement == nil { throw EngineError("replacement goal does not exist") }
                if let replacement {
                    if replacement.parentID != goal.parentID || replacement.kind != goal.kind {
                        throw EngineError("replacement must preserve its parent and kind")
                    }
                    if state.goals.values.contains(where: { $0.replacesID == goal.replacesID }) {
                        throw EngineError("replace the latest replacement rather than branching replacement history")
                    }
                    if (goal.evaluation != replacement.evaluation || goal.loop != replacement.loop || goal.outcome != replacement.outcome
                        || goal.completionCondition != replacement.completionCondition) && !(update.policyChangeReason ?? "").isTruthyString {
                        throw EngineError("changing replacement evaluation or loop policy requires an explicit reason")
                    }
                }
                goal.startedAt = replacement?.startedAt ?? EnginePyTime.isoformat(currentTime)
                goal.historyGoalID = replacement?.historyScope ?? goal.id
                goal.stagnationSinceSequence = replacement?.stagnationSinceSequence ?? 0
            }
            let prior = old ?? goal.replacesID.flatMap { before.goals[$0] }
            if let prior, prior.status == "paused", prior.exitReason == "stagnation", goal.status == "active" {
                if !goal.evidence.contains(where: { $0.kind == "model" && $0.messageID == assistantID }) {
                    throw EngineError("resuming after stagnation requires delivered support or a revised approach")
                }
                goal.stagnationSinceSequence = before.attempts.values.map(\.sequence).max() ?? 0
            }
            for evidence in goal.evidence {
                let body: String
                if evidence.kind == "model" {
                    if evidence.messageID == assistantID {
                        body = reply
                    } else {
                        guard let source = sourceMessages[evidence.messageID], source.role == "assistant" else {
                            throw EngineError("model evidence must refer to an owned assistant reply")
                        }
                        body = source.plainText
                    }
                } else {
                    guard let source = sourceMessages[evidence.messageID], source.role == "user" else {
                        throw EngineError("learner evidence must refer to an owned user message")
                    }
                    body = source.plainText
                }
                try requireQuote(evidence.quote, in: body, field: "evidence")
            }
            state.goals[goal.id] = goal
            if goal.status == "completed", old == nil || old?.status != "completed" {
                state.events["completion:\(goal.id):\(assistantID)"] = ProgressEvent(kind: "completion", goalID: goal.id, messageID: assistantID)
            }
            if goal.evidence.contains(where: { $0.kind == "model" && $0.messageID == assistantID }) {
                state.events["model:\(goal.id):\(assistantID)"] = ProgressEvent(kind: "model_action", goalID: goal.id, messageID: assistantID)
            }
        }
        for var problem in update.problems {
            let old = state.problems[problem.id]
            if let old, !old.sameServedFields(as: problem) {
                throw EngineError("served problem is immutable; create a new problem for a new trial")
            }
            if !state.goals.contains(problem.goalID) { throw EngineError("problem goal does not exist") }
            if old == nil { try requireQuote(problem.prompt, in: reply, field: "new problem") }
            if old == nil, problem.independent, state.problems.values.contains(where: { $0.prompt == problem.prompt }) {
                throw EngineError("repeated problem cannot be a fresh independent trial")
            }
            problem.messageID = old?.messageID ?? assistantID
            state.problems[problem.id] = problem
        }
        for var attempt in update.attempts {
            guard let problem = before.problems[attempt.problemID], problem.messageID != assistantID else {
                throw EngineError("cannot grade a problem that was not previously delivered")
            }
            guard let source = sourceMessages[attempt.submissionID], source.role == "user" else {
                throw EngineError("submission must be an owned learner message")
            }
            let key = attempt.submissionID + ":" + attempt.problemID
            if let old = before.attempts[key] {
                if (attempt.score != old.score || attempt.assisted != old.assisted || attempt.feedback != old.feedback
                    || attempt.errorTag != old.errorTag) && !(attempt.correctionReason ?? "").isTruthyString {
                    throw EngineError("grading correction requires a reason")
                }
                attempt.sequence = old.sequence
            } else {
                if attempt.submissionID != userID { throw EngineError("new trial must cite the current submission") }
                if before.waitingProblemID != attempt.problemID { throw EngineError("submission does not match the awaited problem") }
                attempt.sequence = state.attempts.count + 1
            }
            try requireQuote(attempt.feedback, in: reply, field: "assessment")
            state.attempts[key] = attempt
        }
        state.currentGoalID = update.currentGoalID
        state.disposition = update.disposition
        state.nextAction = update.nextAction
        state.waitingFor = update.waitingFor
        state.waitReason = update.waitReason
        state.waitingProblemID = update.waitingProblemID
        state.returnStack = update.returnStack
        try checkTree(state: state)
        if update.disposition == "waiting" {
            if !(update.waitingFor ?? "").isTruthyString || !update.waitReason.isTruthyString || !update.nextAction.isTruthyString {
                throw EngineError("waiting requires a delivered learner action and waiting reason")
            }
            try requireQuote(update.nextAction, in: reply, field: "delivered learner action")
            if update.waitingFor == "answer", !(update.waitingProblemID.map { state.problems.contains($0) } ?? false) {
                throw EngineError("answer waiting requires a served problem")
            }
        } else if (update.waitingFor ?? "").isTruthyString || (update.waitingProblemID ?? "").isTruthyString {
            throw EngineError("non-waiting state cannot await an answer")
        }
        if update.disposition == "waiting" || update.disposition == "continue" {
            let focus = update.currentGoalID.flatMap { state.goals[$0] }
            guard let focus, focus.status == "active", focus.childOrder.isEmpty else {
                throw EngineError("active progress must point to an active smallest goal")
            }
        }
        for goal in state.goals.values {
            if goal.status == "completed" {
                if goal.exitReason != "achieved" || goal.evidence.isEmpty {
                    throw EngineError("completion requires achieved exit and evidence")
                }
                if goal.kind == "learner" {
                    if !goal.evidence.contains(where: { $0.kind == "learner" }) {
                        throw EngineError("learner completion requires learner evidence")
                    }
                    if goal.evaluation != nil, try !scoreWindow(state: state, goalID: goal.id).passed {
                        throw EngineError("completion does not meet the fixed score window")
                    }
                }
                let replaced = Set(state.goals.values.compactMap { $0.replacesID.flatMap { $0.isEmpty ? nil : $0 } })
                for gid in goal.childOrder where !replaced.contains(gid) {
                    if state.goals[gid]?.status != "completed" { throw EngineError("parent cannot complete with unfinished children") }
                }
            } else if goal.exitReason == "achieved" {
                throw EngineError("achieved exit must complete its goal")
            }
            if goal.status == "paused", !(goal.exitReason ?? "").isTruthyString {
                throw EngineError("paused goal requires an explicit exit reason")
            }
            if goal.loop.enabled, goal.status == "active" {
                let stats = try loopStats(state: state, goalID: goal.id, now: currentTime)
                if stats.attemptLimitReached || stats.stalled || stats.timeLimitReached {
                    throw EngineError("loop limit or stagnation requires a paused goal and explicit exit reason")
                }
            }
        }
        if update.disposition == "completed" {
            let focus = update.currentGoalID.flatMap { state.goals[$0] }
            guard let focus, focus.status == "completed", !(focus.parentID ?? "").isTruthyString else {
                throw EngineError("learning completion requires a completed root goal")
            }
        }
        if let reason = update.policyChangeReason, reason.isTruthyString {
            try requireQuote(reason, in: reply, field: "policy change must be disclosed")
        }
        state.revision += 1
        state.lastMessageID = assistantID
        return state
    }

    nonisolated struct EvidenceRef: Hashable {
        let messageID: String, kind: String, quote: String
        init(_ e: GoalEvidence) { messageID = e.messageID; kind = e.kind; quote = e.quote }
    }

    // MARK: context_for_turn

    static func contextForTurn(state: ProgressState, now: Date = Date()) throws -> JSONObject {
        try contextForTurnValue(state: state, now: now).anyValue as! JSONObject
    }

    static func contextForTurnValue(state: ProgressState, now: Date = Date()) throws -> EngineJSON {
        let chain = try ancestry(state, state.currentGoalID)
        var required = Set(chain.map(\.id)).union(state.returnStack)
        for gid in Array(required) {
            required.formUnion(try ancestry(state, gid).map(\.id))
            required.formUnion(state.goals[gid]?.childOrder ?? [])
        }
        let goals = state.goals.pairs.filter { required.contains($0.0) }.map(\.1)
        var result = EngineObject()
        for (key, value) in state.json.objectValue!.pairs where !["goals", "attempts", "problems", "events"].contains(key) {
            result[key] = value
        }
        result["goals"] = .array(goals.map(\.json))
        result["root_goals"] = .array(state.goals.values.filter { !($0.parentID ?? "").isTruthyString }.map {
            .object(EngineObject([("id", .string($0.id)), ("title", .string($0.title)), ("status", .string($0.status))]))
        })
        var problemIDs = Set<String>()
        if let waiting = state.waitingProblemID, !waiting.isEmpty { problemIDs.insert(waiting) }
        for gid in state.returnStack {
            var returnProblems: [Problem] = []
            for problem in state.problems.values where try ancestry(state, problem.goalID).contains(where: { $0.id == gid }) {
                returnProblems.append(problem)
            }
            if let last = returnProblems.last { problemIDs.insert(last.id) }
        }
        var trials: [Attempt] = []
        for goal in chain {
            let relevant = try goalAttempts(state, goal.id)
            let count = max(goal.loop.stagnationAttempts, goal.evaluation?.n ?? 1)
            trials.append(contentsOf: relevant.suffix(count))
            let scored = Set(try scoreWindow(state: state, goalID: goal.id).submissionIDs)
            trials.append(contentsOf: relevant.filter { scored.contains($0.submissionID) })
        }
        var dedup = EngineOrderedMap<Attempt>()
        for trial in trials { dedup[trial.submissionID + "\u{0}" + trial.problemID] = trial }
        trials = dedup.values
        problemIDs.formUnion(trials.map(\.problemID))
        result["attempts"] = .array(trials.map(\.json))
        result["problems"] = .array(state.problems.pairs.filter { problemIDs.contains($0.0) }.map(\.1.json))
        var evaluations = EngineObject()
        for goal in chain where goal.evaluation != nil { evaluations[goal.id] = try scoreWindow(state: state, goalID: goal.id).json }
        result["evaluations"] = .object(evaluations)
        var loops = EngineObject()
        for goal in chain where goal.loop.enabled { loops[goal.id] = try loopStats(state: state, goalID: goal.id, now: now).json }
        result["loop_stats"] = .object(loops)
        return .object(result)
    }

    // MARK: turn_contract

    static let contractText =
        "\nStruis progress contract: append exactly one <struis_progress_update> JSON block after the reply. "
        + "It is separate from the learner-memory block. Never expose either block. "
        + "Use not_learning for a direct non-learning request, preserving the ongoing goal. "
        + "Send only changed goals/problems/attempts, but complete objects for changed goals. "
        + "Create only the goals needed for the current work and their ancestors; do not pre-generate an entire curriculum or all future problems. "
        + "Internal started_at/history_goal_id/stagnation_since_sequence/sequence/message_id are server-owned; do not echo them into update objects. "
        + "The progress block is valid JSON: escape every literal backslash as two backslashes. Prefer short plain Japanese text for quotes, avoiding LaTeX in JSON when possible. "
        + "Use reply_quotes and evidence quotes copied verbatim from actual delivered text/source. "
        + "For new model-work evidence use assistant_message_id below. Choose fixed evaluation and loop policies before practice; "
        + "n is per problem type, 80% of the last n independent first attempts. "
        + "When stalled or over the limit, pause the loop and return to the parent for revision, preserving history. "
        + "After stagnation, resuming the paused goal requires new model evidence for delivered support or a revised approach. The server then evaluates new stagnation from that resumption while preserving total attempts and time limits. "
        + "Count stagnation as the configured consecutive attempts with the same nonempty error_tag and no score improvement. "
        + "loop.count_by selects graded_attempt (all scored submissions including assisted corrections), independent_attempt (only first unassisted submissions to independent problems), child_completion, or model_action; unit explains what one iteration means. "
        + "If the stated limit is independent attempts, use independent_attempt. Never describe graded_attempt as excluding assisted corrections. "
        + "model_action counts one evidenced execution of a goal per delivered reply, child_completion counts completed descendants. "
        + "Time limits, if used, measure server wall-clock time since goal creation, not learner active time. "
        + "A replacement must use replaces_id to retain history. Waiting requires next_action verbatim in the reply. "
        + "Continue your own explanation/example/evaluation until a real learner action is needed; do not only promise the next move.\n"

    /// `turn_contract`. `updateSchema` is the delivered `ProgressUpdate.model_json_schema()` asset.
    static func turnContract(state: ProgressState, assistantMessageID: String, updateSchema: JSONObject, now: Date = Date()) throws -> String {
        try turnContract(state: state, assistantMessageID: assistantMessageID, updateSchema: EngineJSON(any: updateSchema), now: now)
    }

    static func turnContract(state: ProgressState, assistantMessageID: String, updateSchema: EngineJSON, now: Date = Date()) throws -> String {
        let payload = EngineObject([
            ("assistant_message_id", .string(assistantMessageID)),
            ("progress", try contextForTurnValue(state: state, now: now)),
            ("update_schema", updateSchema),
        ])
        return contractText + EngineJSON.object(payload).serialized()
    }

    /// The per-turn part of the contract when the developer instructions carry the contract text and
    /// the update schema (reliability plan P1-3): the reply's message id and the current progress.
    static func turnProgressContext(state: ProgressState, assistantMessageID: String, now: Date = Date()) throws -> String {
        let payload = EngineObject([
            ("assistant_message_id", .string(assistantMessageID)),
            ("progress", try contextForTurnValue(state: state, now: now)),
        ])
        return "\nStruis progress context (contract and update_schema: developer instructions):\n" + EngineJSON.object(payload).serialized()
    }

    // MARK: public_trace

    static func summary(_ state: ProgressState) throws -> EngineObject {
        let chain = try ancestry(state, state.currentGoalID)
        return EngineObject([
            ("current_goal", chain.last.map { .string($0.title) } ?? .null),
            ("current_stage", chain.first.map { .string($0.title) } ?? .null),
            ("next_action", state.nextAction.isEmpty ? .null : .string(state.nextAction)),
            ("wait_reason", state.waitReason.isEmpty ? .null : .string(state.waitReason)),
        ])
    }

    /// `public_trace(trace, message_id)`. `trace` keys: before_state, after_state, save_status, public_issues.
    static func publicTrace(trace: JSONObject, messageID: String) throws -> JSONObject {
        try publicTraceValue(trace: EngineJSON(any: trace), messageID: messageID).anyValue as! JSONObject
    }

    static func publicTraceValue(trace: EngineJSON, messageID: String) throws -> EngineJSON {
        let traceObject = trace.objectValue ?? .init()
        let before = try traceObject["before_state"].flatMap { $0.isTruthy ? $0 : nil }.map { try ProgressState(json: $0) } ?? emptyState()
        let after = try traceObject["after_state"].flatMap { $0.isTruthy ? $0 : nil }.map { try ProgressState(json: $0) } ?? before
        let chain = try ancestry(after, after.currentGoalID)
        let completed = after.goals.pairs.filter { $0.1.status == "completed" && before.goals[$0.0]?.status != "completed" }.map(\.1.title)
        var evidence: [(String, String)] = []
        for goal in chain {
            for e in goal.evidence {
                evidence.append((e.messageID, (e.kind == "learner" ? "学習者の取り組み: " : "説明・出題: ") + e.summary))
            }
        }
        let trials = try chain.last.map { try goalAttempts(after, $0.id) } ?? []
        for t in trials { evidence.append((t.submissionID, "学習者の解答: " + t.feedback)) }
        var seen = Set<String>()
        evidence = evidence.filter { seen.insert($0.0 + "\u{0}" + $0.1).inserted }
        var newSubmissions = Set<String>()
        for (key, t) in after.attempts.pairs where before.attempts[key] != t { newSubmissions.insert(t.submissionID) }
        let highlighted = newSubmissions.union([messageID])
        evidence = evidence.enumerated().sorted {
            let a = highlighted.contains($0.element.0) ? 1 : 0
            let b = highlighted.contains($1.element.0) ? 1 : 0
            return (a, $0.offset) < (b, $1.offset)
        }.map(\.element)
        var conditions: [String] = []
        for goal in chain {
            if let p = goal.evaluation {
                let score = try scoreWindow(state: after, goalID: goal.id)
                let scoreText = score.score.map { "得点率\(String(format: "%.0f", $0 * 100))%。" } ?? ""
                let required = Int((Double(p.n) * 0.8).rounded(.up))
                conditions.append("\(p.targetScope): \(p.scoringUnit)、初回・支援なしの直近\(p.n)問で80%以上 (二値採点なら\(required)問正解)。対象\(score.count)問。\(scoreText)")
            }
            if goal.loop.enabled {
                let p = goal.loop
                let units = ["graded_attempt": "支援付き訂正を含む採点", "independent_attempt": "初回・支援なしの解答",
                             "child_completion": "子ゴールの完了", "model_action": "説明・出題などの実行"]
                guard let unit = units[p.countBy] else { throw EngineError("KeyError: \(p.countBy)") }
                var text = "\(goal.title): 同じ誤りが改善せず\(p.stagnationAttempts)回続いたら見直し。\(unit)を1回として上限\(p.maxAttempts)回。"
                if let minutes = p.maxMinutes, minutes != 0 { text += "開始から\(minutes)分 (経過時間)。" }
                conditions.append(text)
            }
            if let exit = goal.exitReason, !exit.isEmpty {
                let reasons = ["achieved": "達成", "stagnation": "停滞による見直し", "attempt_limit": "回数の上限",
                               "time_limit": "時間の上限", "interrupted": "中断", "goal_changed": "目標変更"]
                guard let reason = reasons[exit] else { throw EngineError("KeyError: \(exit)") }
                conditions.append("\(goal.title): \(reason)")
            }
        }
        var summaryAfter = try summary(after)
        summaryAfter["completed_actions"] = .array(completed.map { .string($0) })
        let ancestors = Array(chain.dropFirst()).reversed().map {
            EngineJSON.object(EngineObject([("id", .string($0.id)), ("title", .string($0.title)), ("status", .string($0.status))]))
        }
        let trialRows = trials.map {
            EngineJSON.object(EngineObject([("problem_id", .string($0.problemID)), ("submission_id", .string($0.submissionID)),
                                              ("score", .number($0.score)), ("assisted", .bool($0.assisted)), ("feedback", .string($0.feedback))]))
        }
        return .object(EngineObject([
            ("schema_version", .integer(1)), ("message_id", .string(messageID)), ("revision", .integer(after.revision)),
            ("save_status", traceObject["save_status"] ?? .string("not_recorded")),
            ("summary", .object(summaryAfter)),
            ("ancestors", .array(ancestors)),
            ("evidence", .array(evidence.map { .object(EngineObject([("message_id", .string($0.0)), ("summary", .string($0.1))])) })),
            ("trials", .array(trialRows)),
            ("before", .object(try summary(before))), ("after", .object(try summary(after))),
            ("conditions", .array(conditions.map { .string($0) })),
            ("issues", traceObject["public_issues"] ?? .array([])),
        ]))
    }
}

nonisolated extension String {
    /// Python truthiness of a str.
    var isTruthyString: Bool { !isEmpty }
}

nonisolated extension Unicode.Scalar.Properties {
    /// Approximation of Python's `str.isprintable()` used by `repr`.
    var isPrintableForRepr: Bool {
        switch generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator: return false
        case .spaceSeparator: return true
        default: return true
        }
    }
}
