import Foundation
import XCTest
#if canImport(StruisEngine)
@testable import StruisEngine
#else
@testable import strius
#endif

final class TurnProgressVectorTests: XCTestCase {
    static let vectors: EngineJSON = { try! EngineVectors.load("turn_progress") }()

    private func cases(_ key: String) -> [EngineObject] {
        Self.vectors[key]?.arrayValue?.compactMap(\.objectValue) ?? []
    }

    func testCommandActivityLabels() {
        let expected = cases("command_activity_labels")[0]
        XCTAssertEqual(expected.count, TurnProgress.commandActivityLabels.count)
        for (key, value) in expected.pairs { XCTAssertEqual(TurnProgress.commandActivityLabels[key], value.stringValue, key) }
    }

    func testProgressLabelsFromPlanVectors() {
        for c in cases("progress_labels_from_plan") {
            XCTAssertEqual(TurnProgress.progressLabelsFromPlan(c["params"]!), c["expect"]!.arrayValue!.map(\.stringOrEmpty), c["name"]!.stringOrEmpty)
        }
    }

    func testProgressActivityFromItemVectors() {
        for c in cases("progress_activity_from_item") {
            let name = c["name"]!.stringOrEmpty
            let (label, metadata) = TurnProgress.progressActivityFromItem(c["item"]!)
            let expect = c["expect"]!
            XCTAssertEqual(label, expect["label"]?.stringValue, name)
            EngineVectors.assertEqual(metadata?.json ?? .null, expect["metadata"] ?? .null, name + " metadata")
            XCTAssertEqual(TurnProgress.progressLabelFromItem(c["item"]!), label, name)
            if let object = c["item"]!.objectValue {
                EngineVectors.assertEqual(TurnProgress.commandFromItem(object) ?? .null, expect["command"] ?? .null, name + " command")
            }
        }
    }

    func testShlexSplitVectors() {
        for c in cases("shlex_split") {
            let input = c["input"]!
            if let text = input.stringValue {
                let expect = c["expect"]!
                do {
                    let parts = try TurnProgress.shlexSplit(text)
                    XCTAssertEqual(expect["ok"]?.boolValue, true, text)
                    XCTAssertEqual(parts, expect["parts"]?.arrayValue?.map(\.stringOrEmpty), text)
                } catch {
                    XCTAssertEqual(expect["ok"]?.boolValue, false, "\(text): \(error)")
                }
            }
            XCTAssertEqual(TurnProgress.commandParts(input), c["command_parts"]!.arrayValue!.map(\.stringOrEmpty), input.serialized())
        }
    }

    func testStringLabelVectors() {
        for c in cases("activity_label_from_text") {
            XCTAssertEqual(TurnProgress.activityLabelFromText(c["input"]!.stringOrEmpty), c["expect"]!.stringOrEmpty, c["input"]!.stringOrEmpty)
        }
        for c in cases("progress_label_from_agent_delta") {
            XCTAssertEqual(TurnProgress.progressLabelFromAgentDelta(c["input"]!.stringOrEmpty), c["expect"]!.stringOrEmpty, c["input"]!.stringOrEmpty)
        }
        for c in cases("progress_message_from_agent_text") {
            XCTAssertEqual(TurnProgress.progressMessageFromAgentText(c["input"]!.stringOrEmpty), c["expect"]!.stringOrEmpty, c["input"]!.stringOrEmpty)
        }
        for c in cases("progress_label") {
            XCTAssertEqual(TurnProgress.progressLabel(c["input"]!.stringOrEmpty), c["expect"]!.stringOrEmpty, c["input"]!.stringOrEmpty)
        }
    }

    func testExtractAgentTextVectors() {
        for c in cases("extract_agent_text_from_item") {
            let name = c["name"]!.stringOrEmpty
            XCTAssertEqual(AgentText.extractAgentTextFromItem(c["item"]!), c["expect"]!["text"]?.stringValue, name)
            XCTAssertEqual(AgentText.agentMessagePhase(c["item"]!), c["expect"]!["phase"]?.stringValue, name)
            var params = EngineObject()
            params["item"] = c["item"]!
            XCTAssertEqual(AgentText.extractAgentText(params: .object(params)), c["expect"]!["text"]?.stringValue, name)
        }
        for c in cases("agent_message_phase") {
            XCTAssertEqual(AgentText.agentMessagePhase(c["item"]!), c["expect"]!.stringOrEmpty, c["item"]!.serialized())
        }
    }

    func testNaturalLanguageVectors() {
        for c in cases("natural_language_from_agent_text") {
            XCTAssertEqual(AgentText.naturalLanguageFromAgentText(c["input"]!.stringOrEmpty), c["expect"]!.stringOrEmpty, c["name"]!.stringOrEmpty)
        }
        for c in cases("json_object_spans") {
            let spans = AgentText.jsonObjectSpans(c["input"]!.stringOrEmpty)
            let actual = EngineJSON.array(spans.map { .object(EngineObject([("start", .integer($0.start)), ("end", .integer($0.end)), ("object", .object($0.object))])) })
            EngineVectors.assertEqual(actual, c["expect"]!, c["input"]!.stringOrEmpty)
        }
        for c in cases("tolerant_structured_message") {
            XCTAssertEqual(AgentText.tolerantStructuredMessage(c["input"]!.stringOrEmpty), c["expect"]!.stringOrEmpty, c["input"]!.stringOrEmpty)
        }
        for c in cases("strip_jsonish_contract") {
            XCTAssertEqual(AgentText.stripJsonishContract(c["input"]!.stringOrEmpty), c["expect"]!.stringOrEmpty, c["input"]!.stringOrEmpty)
        }
        for c in cases("clean_agent_text") {
            XCTAssertEqual(AgentText.cleanAgentText(c["input"]!.stringOrEmpty), c["expect"]!.stringOrEmpty, c["input"]!.stringOrEmpty)
        }
        for c in cases("read_jsonish_string") {
            XCTAssertEqual(AgentText.readJsonishString(c["input"]!.stringOrEmpty, quoteIndex: c["quote_index"]!.intValue!), c["expect"]!.stringOrEmpty, c["input"]!.stringOrEmpty)
        }
    }
}
