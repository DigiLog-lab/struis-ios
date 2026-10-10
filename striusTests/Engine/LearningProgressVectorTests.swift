import Foundation
import XCTest
#if canImport(StruisEngine)
@testable import StruisEngine
#else
@testable import strius
#endif

final class LearningProgressVectorTests: XCTestCase {
    static let vectors: EngineJSON = { try! EngineVectors.load("learning_progress") }()

    private func cases(_ key: String) -> [EngineObject] {
        Self.vectors[key]?.arrayValue?.compactMap(\.objectValue) ?? []
    }

    private func sources(_ value: EngineJSON?) -> [String: LearningProgress.SourceMessage] {
        var result: [String: LearningProgress.SourceMessage] = [:]
        for (key, item) in value?.objectValue?.pairs ?? [] {
            result[key] = (role: item["role"]?.stringOrEmpty ?? "", plainText: item["plain_text"]?.stringOrEmpty ?? "")
        }
        return result
    }

    func testApplyUpdateVectors() throws {
        let all = cases("apply_update")
        XCTAssertGreaterThan(all.count, 100)
        for c in all {
            let name = c["name"]!.stringOrEmpty
            let before = try ProgressState(json: c["before"]!)
            let now = EnginePyTime.parseISO(c["now"]!.stringOrEmpty)!
            let expect = c["expect"]!.objectValue!
            do {
                let after = try LearningProgress.applyUpdate(
                    before: before, raw: c["raw"]!, reply: c["reply"]!.stringOrEmpty,
                    userMessageID: c["user_message_id"]!.stringOrEmpty, assistantMessageID: c["assistant_message_id"]!.stringOrEmpty,
                    sourceMessages: sources(c["source_messages"]), now: now)
                if expect["ok"]?.boolValue == true {
                    EngineVectors.assertEqual(after.json, expect["after"]!, name)
                    // Round trip through the order-preserving JSON path.
                    let reloaded = try ProgressState(json: try EngineJSON.parse(after.json.serialized()))
                    XCTAssertEqual(reloaded, after, "\(name) round trip")
                } else {
                    XCTFail("\(name): expected failure \(expect["error"]?.stringOrEmpty ?? "(validation)") but succeeded")
                }
            } catch let error as EngineError {
                if expect["ok"]?.boolValue == true {
                    XCTFail("\(name): unexpected error \(error.message)")
                } else if let message = expect["error"]?.stringValue {
                    XCTAssertEqual(error.message, message, name)
                } else {
                    XCTAssertEqual(expect["validation"]?.boolValue, true, name)
                }
            }
        }
    }

    func testScoreWindowVectors() throws {
        for c in cases("score_window") {
            let state = try ProgressState(json: c["state"]!)
            let result = try LearningProgress.scoreWindow(state: state, goalID: c["goal_id"]!.stringOrEmpty)
            EngineVectors.assertEqual(result.json, c["expect"]!, c["name"]!.stringOrEmpty)
        }
    }

    func testLoopStatsVectors() throws {
        for c in cases("loop_stats") {
            let state = try ProgressState(json: c["state"]!)
            let now = EnginePyTime.parseISO(c["now"]!.stringOrEmpty)!
            let result = try LearningProgress.loopStats(state: state, goalID: c["goal_id"]!.stringOrEmpty, now: now)
            EngineVectors.assertEqual(result.json, c["expect"]!, c["name"]!.stringOrEmpty)
        }
    }

    func testContextForTurnVectors() throws {
        for c in cases("context_for_turn") {
            let state = try ProgressState(json: c["state"]!)
            let now = EnginePyTime.parseISO(c["now"]!.stringOrEmpty)!
            let result = try LearningProgress.contextForTurnValue(state: state, now: now)
            EngineVectors.assertEqual(result, c["expect"]!, c["name"]!.stringOrEmpty)
            // The [String: Any] surface carries the same content.
            let bridged = EngineJSON(any: try LearningProgress.contextForTurn(state: state, now: now))
            EngineVectors.assertEqual(bridged, c["expect"]!, c["name"]!.stringOrEmpty + " (bridged)")
        }
    }

    func testPublicTraceVectors() throws {
        for c in cases("public_trace") {
            let result = try LearningProgress.publicTraceValue(trace: c["trace"]!, messageID: c["message_id"]!.stringOrEmpty)
            EngineVectors.assertEqual(result, c["expect"]!, c["name"]!.stringOrEmpty)
        }
    }

    func testExtractUpdateVectors() throws {
        for c in cases("extract_update") {
            let name = c["name"]!.stringOrEmpty
            let expect = c["expect"]!.objectValue!
            do {
                let (visible, raw) = try LearningProgress.extractUpdateValue(c["text"]!.stringOrEmpty)
                XCTAssertEqual(expect["ok"]?.boolValue, true, name)
                XCTAssertEqual(visible, expect["visible"]?.stringValue, name)
                EngineVectors.assertEqual(raw, expect["raw"] ?? .null, name)
            } catch let error as EngineError {
                XCTAssertEqual(expect["ok"]?.boolValue, false, "\(name): \(error.message)")
                if let message = expect["error"]?.stringValue { XCTAssertEqual(error.message, message, name) }
                else { XCTAssertEqual(expect["json_error"]?.boolValue, true, name) }
            }
        }
    }

    func testTurnContractVectors() throws {
        for c in cases("turn_contract") {
            let name = c["name"]!.stringOrEmpty
            let state = try ProgressState(json: c["state"]!)
            let now = EnginePyTime.parseISO(c["now"]!.stringOrEmpty)!
            let text = try LearningProgress.turnContract(state: state, assistantMessageID: c["assistant_message_id"]!.stringOrEmpty,
                                                         updateSchema: c["update_schema"]!, now: now)
            let expected = c["expect"]!.stringOrEmpty
            XCTAssertTrue(text.hasPrefix(LearningProgress.contractText), name)
            XCTAssertTrue(expected.hasPrefix(LearningProgress.contractText), name)
            let actualJSON = try EngineJSON.parse(String(text.dropFirst(LearningProgress.contractText.count)))
            let expectedJSON = try EngineJSON.parse(String(expected.dropFirst(LearningProgress.contractText.count)))
            EngineVectors.assertEqual(actualJSON, expectedJSON, name)
        }
    }

    func testCheckTreeVectors() throws {
        for c in cases("check_tree") {
            let name = c["name"]!.stringOrEmpty
            let state = try ProgressState(json: c["state"]!)
            let expect = c["expect"]!.objectValue!
            do {
                try LearningProgress.checkTree(state: state)
                XCTAssertEqual(expect["ok"]?.boolValue, true, name)
            } catch let error as EngineError {
                XCTAssertEqual(error.message, expect["error"]?.stringValue, name)
            }
        }
    }

    func testEmptyStateMatchesPython() {
        let expected = try! EngineJSON.parse(#"{"schema_version": 1, "revision": 0, "goals": {}, "problems": {}, "attempts": {}, "current_goal_id": null, "disposition": "not_learning", "next_action": "", "waiting_for": null, "wait_reason": "", "waiting_problem_id": null, "return_stack": [], "events": {}}"#)
        EngineVectors.assertEqual(LearningProgress.emptyState().json, expected, "empty_state")
    }

    func testNaNScoreIsRejected() {
        var raw = EngineObject()
        raw["schema_version"] = .integer(1); raw["base_revision"] = .integer(0); raw["current_goal_id"] = .null
        raw["disposition"] = .string("continue"); raw["next_action"] = .string("x"); raw["reply_quotes"] = .array([.string("r")])
        raw["attempts"] = .array([.object(EngineObject([("problem_id", .string("p")), ("submission_id", .string(UUID().uuidString)),
                                                            ("score", .number(.nan)), ("assisted", .bool(false)), ("feedback", .string("f"))]))])
        XCTAssertThrowsError(try LearningProgress.applyUpdate(before: .init(), raw: .object(raw), reply: "r", userMessageID: UUID().uuidString,
                                                              assistantMessageID: UUID().uuidString, sourceMessages: [:]))
    }

    func testStateCodableRoundTrip() throws {
        let c = cases("apply_update").first { $0["expect"]?["ok"]?.boolValue == true && ($0["expect"]?["after"]?["goals"]?.objectValue?.count ?? 0) > 0 }!
        let state = try ProgressState(json: c["expect"]!["after"]!)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ProgressState.self, from: data)
        XCTAssertEqual(decoded.revision, state.revision)
        XCTAssertEqual(Set(decoded.goals.keys), Set(state.goals.keys))
        XCTAssertEqual(decoded.goals[state.goals.keys[0]], state.goals[state.goals.keys[0]])
    }
}
