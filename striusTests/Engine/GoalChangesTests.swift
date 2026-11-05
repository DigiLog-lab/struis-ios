import XCTest
@testable import strius

/// 目標の部分更新(`goal_changes`): 変更項目だけを送り、省略した項目は保存済みの値を引き継ぐ。合成した後の検証は従来と同じ。
final class GoalChangesTests: XCTestCase {
    private struct Base {
        var state: ProgressState
        var raw: EngineObject
        var reply: String
        var user: String
        var assistant: String
        var sources: [String: LearningProgress.SourceMessage]
        var now: Date
    }

    /// 学習の記録の検証ベクトルから、目標のある受理済みの状態と、その時の更新(共通の項目)を取る。
    private func base() throws -> Base {
        let vectors = try EngineVectors.load("learning_progress")
        let c = try XCTUnwrap(vectors["apply_update"]?.arrayValue?.compactMap(\.objectValue).first {
            $0["expect"]?["ok"]?.boolValue == true && ($0["expect"]?["after"]?["goals"]?.objectValue?.count ?? 0) > 0
                && ($0["raw"]?["goals"]?.arrayValue?.count ?? 0) > 0
        })
        var sources: [String: LearningProgress.SourceMessage] = [:]
        for (key, item) in c["source_messages"]?.objectValue?.pairs ?? [] {
            sources[key] = (role: item["role"]?.stringOrEmpty ?? "", plainText: item["plain_text"]?.stringOrEmpty ?? "")
        }
        let before = try ProgressState(json: c["before"]!)
        let now = EnginePyTime.parseISO(c["now"]!.stringOrEmpty)!
        let after = try LearningProgress.applyUpdate(before: before, raw: c["raw"]!, reply: c["reply"]!.stringOrEmpty,
                                                     userMessageID: c["user_message_id"]!.stringOrEmpty,
                                                     assistantMessageID: c["assistant_message_id"]!.stringOrEmpty, sourceMessages: sources, now: now)
        var raw = c["raw"]!.objectValue!
        raw["base_revision"] = .integer(after.revision)
        raw["goals"] = .array([])
        raw["problems"] = .array([])
        raw["attempts"] = .array([])
        return Base(state: after, raw: raw, reply: c["reply"]!.stringOrEmpty, user: c["user_message_id"]!.stringOrEmpty,
                    assistant: c["assistant_message_id"]!.stringOrEmpty, sources: sources, now: now)
    }

    private func apply(_ base: Base, _ raw: EngineObject) throws -> ProgressState {
        try LearningProgress.applyUpdate(before: base.state, raw: .object(raw), reply: base.reply, userMessageID: base.user,
                                         assistantMessageID: base.assistant, sourceMessages: base.sources, now: base.now)
    }

    func testPartialChangeMatchesTheFullGoal() throws {
        let base = try base()
        let goal = base.state.goals.values[0]
        // 従来の形: 目標の全体を、次の行動だけ変えて送り直す。
        var full = goal.json.objectValue!
        for key in ["started_at", "history_goal_id", "stagnation_since_sequence"] { full[key] = nil }
        full["next_action"] = .string("次は符号の確認から")
        var fullRaw = base.raw
        fullRaw["goals"] = .array([.object(full)])
        // 部分更新: 変える項目だけ。
        var partialRaw = base.raw
        partialRaw["goal_changes"] = .array([.object(EngineObject([("id", .string(goal.id)), ("next_action", .string("次は符号の確認から"))]))])
        let expected = try apply(base, fullRaw)
        let merged = try apply(base, partialRaw)
        XCTAssertEqual(merged, expected)
        XCTAssertEqual(merged.goals[goal.id]?.nextAction, "次は符号の確認から")
        XCTAssertEqual(merged.goals[goal.id]?.evaluation, goal.evaluation)
        XCTAssertEqual(merged.goals[goal.id]?.loop, goal.loop)
        XCTAssertEqual(merged.goals[goal.id]?.evidence, goal.evidence)
    }

    func testPartialChangeKeepsTheExistingValidation() throws {
        let base = try base()
        let goal = base.state.goals.values[0]
        func change(_ pairs: [(String, EngineJSON)]) -> EngineObject {
            var raw = base.raw
            raw["policy_change_reason"] = nil
            raw["goal_changes"] = .array([.object(EngineObject([("id", .string(goal.id))] + pairs))])
            return raw
        }
        // 評価の基準を変えるには理由が要る(全体の更新と同じ)。
        XCTAssertThrowsError(try apply(base, change([("completion_condition", .string("別の条件"))]))) { error in
            XCTAssertEqual((error as? EngineError)?.message, "changing evaluation or loop policy requires an explicit reason")
        }
        // 親子関係は変えられない。
        XCTAssertThrowsError(try apply(base, change([("parent_id", .string("other"))]))) { error in
            XCTAssertTrue((error as? EngineError)?.message.contains("Extra inputs are not permitted") == true)
        }
        // 無い目標は部分更新できない。
        var unknown = base.raw
        unknown["goal_changes"] = .array([.object(EngineObject([("id", .string("no_such_goal")), ("status", .string("active"))]))])
        XCTAssertThrowsError(try apply(base, unknown)) { error in
            XCTAssertTrue((error as? EngineError)?.message.contains("existing goal") == true)
        }
        // 同じ目標を全体と部分の両方で送ると重複。
        var both = change([("next_action", .string("x"))])
        var full = goal.json.objectValue!
        for key in ["started_at", "history_goal_id", "stagnation_since_sequence"] { full[key] = nil }
        both["goals"] = .array([.object(full)])
        XCTAssertThrowsError(try apply(base, both)) { error in
            XCTAssertEqual((error as? EngineError)?.message, "update contains duplicate records")
        }
    }

    /// 前のターンの根拠(model と learner)を持つ目標に、根拠を足さない `goal_changes` を送る。チャットのターンは
    /// `ChatTurns.referencedMessageIDs` が集めた id の本文だけを台帳から読むので、合成された保存済みの根拠の id も
    /// 集めないと `model evidence must refer to an owned assistant reply` で落ちる(例題の 2 回目の答えで起きた)。
    func testGoalChangesLoadTheStoredEvidenceOfTheChangedGoal() throws {
        var base = try base()
        // 前のターン: 返事(model)と学習者の答え(learner)を根拠に持つ目標。
        let priorUser: String = "a0000000-0000-4000-8000-0000000000a1"
        var goal: Goal = base.state.goals.values[0]
        goal.evidence = [
            GoalEvidence(messageID: base.assistant, kind: "model", summary: "理由を説明した", quote: "操作の理由を説明しました"),
            GoalEvidence(messageID: priorUser, kind: "learner", summary: "第5項を答えた", quote: "a_5 = 162"),
        ]
        base.state.goals[goal.id] = goal
        let stored: [String: LearningProgress.SourceMessage] = [
            base.assistant: (role: "assistant", plainText: base.reply),
            priorUser: (role: "user", plainText: "a_5 = 2·3^4 = a_5 = 162"),
        ]
        // 今のターン: 根拠を足さずに次の行動だけ変える。
        var raw = base.raw
        raw["goal_changes"] = .array([.object(EngineObject([("id", .string(goal.id)), ("next_action", .string("類題へ進む"))]))])
        let json: JSONObject = try XCTUnwrap(EngineJSON.object(raw).anyValue as? JSONObject)
        let ids: Set<String> = ChatTurns.referencedMessageIDs(json, before: base.state)
        XCTAssertTrue(Set(stored.keys).isSubset(of: ids), "missing: \(Set(stored.keys).subtracting(ids).sorted())")
        // 台帳から読むのと同じく、集めた id の本文だけを渡す。
        let loaded: [String: LearningProgress.SourceMessage] = stored.filter { ids.contains($0.key) }
        let next: ProgressState = try LearningProgress.applyUpdate(
            before: base.state, raw: .object(raw), reply: base.reply, userMessageID: "a0000000-0000-4000-8000-0000000000b1",
            assistantMessageID: "a0000000-0000-4000-8000-0000000000b2", sourceMessages: loaded, now: base.now
        )
        XCTAssertEqual(next.goals[goal.id]?.nextAction, "類題へ進む")
        XCTAssertEqual(next.goals[goal.id]?.evidence, goal.evidence)
    }

    func testUpdatesWithoutGoalChangesAreUntouched() throws {
        let raw = EngineJSON.object(EngineObject([("schema_version", .integer(1)), ("goals", .array([]))]))
        XCTAssertEqual(try LearningProgress.expandGoalChanges(raw, before: .init()), raw)
    }
}
