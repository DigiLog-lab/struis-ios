import Foundation
@testable import strius

/// タイムラインのテストで使う行。
enum TimelineFixture {
    static let now = "2026-10-23T06:00:00.000000Z"

    static func card(_ id: String, kind: String = "solve", level: Int = 2, origin: String = "batch", status: String = "unused", position: Int = 0,
                     chain: (String, Int, Int)? = nil, skills: [String] = [], easier: Bool = true, createdAt: String = now, subunitID: String? = nil,
                     payload: [String: LedgerJSON] = [:]) -> TimelineCardRecord {
        var body = payload
        if easier, body["easier"] == nil {
            body["easier"] = .object(["level": .number(1), "prompt": .string("やさしい版"), "math": .string("y = (x-1)^2"), "question": .string(""),
                                      "answer_key": .string("(1, 0)"), "answer_expr": .string("(1, 0)"), "checkpoints": .array([])])
        }
        return TimelineCardRecord(
            id: id, batchId: "b", position: position, kind: kind, level: level, skills: skills, typeName: "型", prompt: "問題 \(id)", math: "y = x^2",
            question: "", answerKey: "0", answerExpr: "", checkpoints: [], commonMistakes: [], estimatedSeconds: 60,
            chain: chain.map { .object(["chain_id": .string($0.0), "position": .number(Double($0.1)), "total": .number(Double($0.2))]) },
            easierOf: nil, subunitId: subunitID, unitId: nil, payload: .object(body), origin: origin, status: status, createdAt: createdAt, updatedAt: createdAt
        )
    }

    static func attempt(_ id: String, card: String, verdict: String, counts: Bool = true, seconds: Double = 30, createdAt: String = now, skip: String? = nil) -> TimelineAttemptRecord {
        TimelineAttemptRecord(
            id: id, cardId: card, capturePath: nil, verdict: verdict, checkpointResults: .emptyArray, errors: .emptyArray, learnerAnswer: "",
            cause: "unknown", seconds: seconds, firstTry: true, assisted: false, skipReason: skip, keySuspect: false, countsForAccuracy: counts,
            feedback: "", createdAt: createdAt, gradedAt: createdAt
        )
    }

    static func skill(_ id: String, status: String = "practicing", attempts: Int = 0, dates: [String] = [], threshold: Int = 3) -> TimelineSkillRecord {
        TimelineSkillRecord(id: id, name: id, kind: "procedure", unitId: nil, status: status, correctDates: dates, masteryThreshold: threshold,
                            attempts: attempts, lastCorrectAt: nil, nextReviewAt: nil, reviewCount: 0, replacedBy: [], source: "initial",
                            createdAt: now, updatedAt: now)
    }

    static func draftJSON(kind: String = "solve", level: Int = 2, skills: [String] = [], checks: [[String: String]] = [["left": "2*x^2-8*x+3", "right": "2*(x-2)^2-5"]],
                          chain: [String: Any]? = nil, steps: [String] = ["y = 2x^2 - 8x + 3", "= 2(x^2 - 4x) + 3", "= 2(x - 2)^2 - 5", "最小値 -5"],
                          facts: [String: Any] = ["answer_value": -5, "vertex": [2, -5], "axis": 2]) -> [String: Any] {
        [
            "kind": kind, "level": level, "skills": skills, "type_name": "最大最小", "prompt": "最小値を求めなさい。", "math": "y = 2x^2 - 8x + 3",
            "question": "最小値は？", "answer_key": "-5", "answer_expr": "2*(x-2)^2-5", "checks": checks, "checkpoints": ["平方完成"], "common_mistakes": ["符号"],
            "steps": steps, "mistake_steps": [["step": 3, "wrong": "= 2(x - 2)^2 + 5"]], "estimated_seconds": 60, "chain": chain ?? NSNull(),
            "easier": ["level": 1, "prompt": "頂点は？", "math": "y = 2(x - 2)^2 - 5", "question": "", "answer_key": "(2, -5)", "answer_expr": "(2, -5)", "checkpoints": []],
            "subunit_id": NSNull(), "facts": facts, "compare": NSNull(), "reason": ["question": "なぜ？", "options": ["a", "b", "c"], "answer_index": 0],
            "howto": NSNull(), "diagnostic": NSNull(),
        ]
    }

    static func batchText(cards: [[String: Any]], rapid: Int = 3) -> String {
        let object: [String: Any] = [
            "reason": "テスト", "cards": cards,
            "rapid": (0..<rapid).map { ["skill": "", "prompt": "頂点は？", "math": "y = (x - \($0))^2", "answer_key": "(\($0), 0)", "answer_expr": "(\($0), 0)"] },
            "wanted_prerequisites": [], "graph_ops": [],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func batch(cards: [[String: Any]], rapid: Int = 3) throws -> TimelineCards.Batch {
        try TimelineCards.Batch.parse(batchText(cards: cards, rapid: rapid))
    }

    static func machine(now: String = now) -> TimelineMachine {
        var machine = TimelineMachine()
        var counter = 0
        machine.now = { now }
        machine.newID = { counter += 1; return "id-\(counter)" }
        machine.calendar = Calendar(identifier: .gregorian)
        machine.calendar.timeZone = TimeZone(identifier: "UTC")!
        return machine
    }
}
