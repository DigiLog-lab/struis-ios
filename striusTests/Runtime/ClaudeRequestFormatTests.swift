import XCTest
@testable import strius

/// Claude への要求の部品(tool 名の対応・出力の形の制約外し・画像・effort)と、ストリームから履歴の content を組み立てる部品。
/// 要求の全体の形は `ClaudeTurnRunnerTests` が模擬の Anthropic に届いた要求で確かめる。
final class ClaudeRequestFormatTests: XCTestCase {
    /// 端末の tool 定義(Responses の形)。namespace・freeform(文法つき)・Claude に対応の無い種類を含む。
    private let responsesTools: [[String: Any]] = [[
        "type": "namespace", "name": "struis", "description": "Native",
        "tools": [
            ["type": "function", "name": "exec_command", "description": "Run", "strict": false,
             "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]], "required": ["cmd"], "additionalProperties": false]],
        ],
    ], [
        "type": "custom", "name": "apply_patch", "description": "Patch",
        "format": ["type": "grammar", "syntax": "lark", "definition": "start: /.+/"],
    ], ["type": "web_search"]]

    // MARK: - Tools

    func testToolsAreFlattenedAndSortedByTheirClaudeNames() throws {
        let sorted: ClaudeToolNames = ClaudeToolNames(responsesTools: responsesTools, sorted: true)
        // 版 2 以降は名前の順に固定する(定義の並べ方が変わっても tools の先頭を変えない)。
        XCTAssertEqual(sorted.claudeTools.compactMap { $0["name"] as? String }, ["apply_patch", "struis__exec_command"])
        let unsorted: ClaudeToolNames = ClaudeToolNames(responsesTools: responsesTools)
        XCTAssertEqual(unsorted.claudeTools.compactMap { $0["name"] as? String }, ["struis__exec_command", "apply_patch"])
        let reversed: ClaudeToolNames = ClaudeToolNames(responsesTools: Array(responsesTools.reversed()), sorted: true)
        XCTAssertEqual(reversed.claudeTools.compactMap { $0["name"] as? String }, ["apply_patch", "struis__exec_command"])

        // Claude の名前から端末の tool に戻せる。
        let exec: ClaudeToolNames.Entry = try XCTUnwrap(sorted.entry(claudeName: "struis__exec_command"))
        XCTAssertEqual(exec.name, "exec_command")
        XCTAssertEqual(exec.namespace, "struis")
        XCTAssertFalse(exec.custom)
        let execTool: [String: Any] = try XCTUnwrap(sorted.claudeTools.last)
        XCTAssertEqual(execTool["description"] as? String, "Run")
        XCTAssertEqual(((execTool["input_schema"] as? [String: Any])?["required"] as? [String]), ["cmd"])

        // freeform の tool は、入力の文字列 1 つを受ける JSON の tool にし、文法を説明に足す。
        let patch: ClaudeToolNames.Entry = try XCTUnwrap(sorted.entry(claudeName: "apply_patch"))
        XCTAssertTrue(patch.custom)
        XCTAssertNil(patch.namespace)
        let patchTool: [String: Any] = try XCTUnwrap(sorted.claudeTools.first)
        XCTAssertEqual((patchTool["input_schema"] as? [String: Any])?["required"] as? [String], ["input"])
        let description: String = try XCTUnwrap(patchTool["description"] as? String)
        XCTAssertTrue(description.hasPrefix("Patch\n\nPut the whole tool input in the `input` string."), description)
        XCTAssertTrue(description.hasSuffix("(lark):\nstart: /.+/"), description)
        XCTAssertNil(sorted.entry(claudeName: "web_search"), "Claude に対応の無い種類は渡さない")
    }

    func testClaudeNamesKeepOnlyTheAllowedCharacters() {
        XCTAssertEqual(ClaudeToolNames.claudeName(name: "exec_command", namespace: "struis"), "struis__exec_command")
        XCTAssertEqual(ClaudeToolNames.claudeName(name: "read.file", namespace: nil), "read_file")
        XCTAssertEqual(ClaudeToolNames.claudeName(name: "日本-tool", namespace: nil), "__-tool")
        XCTAssertEqual(ClaudeToolNames.claudeName(name: String(repeating: "a", count: 200), namespace: nil).count, 128)
        // 同じ Claude の名前になる 2 つ目の定義は足さない。
        let duplicated: ClaudeToolNames = ClaudeToolNames(responsesTools: [
            ["type": "function", "name": "a.b", "description": "first"], ["type": "function", "name": "a_b", "description": "second"],
        ])
        XCTAssertEqual(duplicated.claudeTools.count, 1)
        XCTAssertEqual(duplicated.claudeTools.first?["description"] as? String, "first")
    }

    // MARK: - Output schema

    func testOutputSchemaDropsConstraintsClaudeRejects() throws {
        let schema: [String: Any] = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object", "required": ["items"],
            "properties": ["items": ["type": "array", "minItems": 1, "maxItems": 5,
                                     "items": ["type": "object", "properties": ["score": ["type": "integer", "minimum": 0, "maximum": 10]]]]],
            "$defs": ["note": ["type": "object", "properties": ["text": ["type": "string", "maxLength": 40, "enum": ["a", "b"]]]]],
        ]
        let sanitized: [String: Any] = try XCTUnwrap(ClaudeSchema.sanitize(schema) as? [String: Any])
        XCTAssertNil(sanitized["$schema"])
        XCTAssertEqual(sanitized["additionalProperties"] as? Bool, false)
        XCTAssertEqual(sanitized["required"] as? [String], ["items"])
        let items: [String: Any] = try XCTUnwrap((sanitized["properties"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertNil(items["minItems"])
        XCTAssertNil(items["maxItems"])
        XCTAssertNil(items["additionalProperties"], "object でない schema には足さない")
        let element: [String: Any] = try XCTUnwrap(items["items"] as? [String: Any])
        XCTAssertEqual(element["additionalProperties"] as? Bool, false)
        let score: [String: Any] = try XCTUnwrap((element["properties"] as? [String: Any])?["score"] as? [String: Any])
        XCTAssertNil(score["minimum"])
        XCTAssertNil(score["maximum"])
        XCTAssertEqual(score["type"] as? String, "integer")
        let note: [String: Any] = try XCTUnwrap((sanitized["$defs"] as? [String: Any])?["note"] as? [String: Any])
        XCTAssertEqual(note["additionalProperties"] as? Bool, false)
        let text: [String: Any] = try XCTUnwrap((note["properties"] as? [String: Any])?["text"] as? [String: Any])
        XCTAssertNil(text["maxLength"])
        XCTAssertEqual(text["enum"] as? [String], ["a", "b"], "値の列挙はそのまま")
    }

    // MARK: - Images and effort

    func testImageBlocksAcceptOnlySupportedTypesWithinTheLimit() throws {
        let png: [String: Any] = try XCTUnwrap(ClaudeRequestFormat.imageBlock("data:image/png;base64,iVBORw0KGgo="))
        XCTAssertEqual(png["type"] as? String, "image")
        let source: [String: Any] = try XCTUnwrap(png["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "iVBORw0KGgo=")
        let remote: [String: Any]? = ClaudeRequestFormat.imageBlock("https://example.invalid/a.png")?["source"] as? [String: Any]
        XCTAssertEqual(remote?["type"] as? String, "url")
        XCTAssertNil(ClaudeRequestFormat.imageBlock("data:image/tiff;base64,AAAA"))
        XCTAssertNil(ClaudeRequestFormat.imageBlock("data:image/png,raw"))
        XCTAssertNil(ClaudeRequestFormat.imageBlock("file:///tmp/a.png"))
        XCTAssertNil(ClaudeRequestFormat.imageBlock("data:image/jpeg;base64," + String(repeating: "A", count: 8), maxBytes: 5), "上限を超える画像は送らない")
        XCTAssertNotNil(ClaudeRequestFormat.imageBlock("data:image/jpeg;base64," + String(repeating: "A", count: 8), maxBytes: 6))
    }

    func testEffortMapsThePlanValuesToClaude() {
        XCTAssertEqual(ClaudeRequestFormat.effort("none"), "low")
        XCTAssertEqual(ClaudeRequestFormat.effort("minimal"), "low")
        XCTAssertEqual(ClaudeRequestFormat.effort("medium"), "medium")
        XCTAssertEqual(ClaudeRequestFormat.effort("xhigh"), "xhigh")
        XCTAssertEqual(ClaudeRequestFormat.effort("max"), "max")
        XCTAssertNil(ClaudeRequestFormat.effort(nil))
        XCTAssertNil(ClaudeRequestFormat.effort("unknown"))
    }

    // MARK: - Stream → 履歴

    private func block(_ index: Int, _ block: [String: Any]) -> [String: Any] { ["type": "content_block_start", "index": index, "content_block": block] }
    private func delta(_ index: Int, _ delta: [String: Any]) -> [String: Any] { ["type": "content_block_delta", "index": index, "delta": delta] }

    func testReaderKeepsSignedThinkingCommentaryAndToolInput() throws {
        let reader: ClaudeMessageReader = ClaudeMessageReader(itemPrefix: "item")
        let events: [[String: Any]] = [
            ["type": "message_start", "message": ["id": "msg_1", "model": "claude-opus-5-5"]],
            block(0, ["type": "thinking", "thinking": "", "signature": ""]),
            delta(0, ["type": "thinking_delta", "thinking": "Checking files"]),
            delta(0, ["type": "signature_delta", "signature": "SIG"]),
            ["type": "content_block_stop", "index": 0],
            block(1, ["type": "text", "text": ""]),
            delta(1, ["type": "text_delta", "text": "Let me look."]),
            block(2, ["type": "tool_use", "id": "toolu_9", "name": "struis__exec_command", "input": [String: Any]()]),
            delta(2, ["type": "input_json_delta", "partial_json": "{\"cmd\":"]),
            delta(2, ["type": "input_json_delta", "partial_json": "\"ls\"}"]),
            block(3, ["type": "server_tool_use", "id": "srv", "name": "web_search"]),
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"]],
        ]
        var outputs: [String] = []
        for event in events {
            for output in reader.consume(event) {
                switch output {
                case .thinking(let itemID, let text): outputs.append("thinking \(itemID) \(text)")
                case .text(let itemID, let text): outputs.append("text \(itemID) \(text)")
                }
            }
        }
        XCTAssertEqual(outputs, ["thinking item-0 Checking files", "text item-1 Let me look."])
        let content: [[String: Any]] = reader.content
        XCTAssertEqual(content.map { $0["type"] as? String }, ["thinking", "text", "tool_use"], "履歴に戻さないブロックは入れない")
        XCTAssertEqual(content[0]["signature"] as? String, "SIG")
        XCTAssertEqual(content[0]["thinking"] as? String, "Checking files")
        let use: [String: Any] = try XCTUnwrap(reader.toolUses.first)
        XCTAssertEqual(use["id"] as? String, "toolu_9")
        XCTAssertEqual(use["name"] as? String, "struis__exec_command")
        XCTAssertEqual((use["input"] as? [String: Any])?["cmd"] as? String, "ls")
        XCTAssertEqual(reader.commentary, ["Let me look."])
    }

    func testFinalAnswerKeepsEveryTextBlockInOrder() {
        let reader: ClaudeMessageReader = ClaudeMessageReader()
        _ = reader.consume(block(0, ["type": "text", "text": "説明の本文"]))
        _ = reader.consume(block(1, ["type": "text", "text": "<struis_progress_update>{}</struis_progress_update>"]))
        XCTAssertEqual(reader.finalText, "説明の本文\n\n<struis_progress_update>{}</struis_progress_update>")
    }

    func testPartialResultKeepsItsItems() {
        let event: TurnProgressEvent = TurnProgressEvent(kind: .partialResult(done: 1, total: nil), label: "", progressID: nil,
                                                         allowDuplicate: true, items: ["問題 1"])
        XCTAssertEqual(event.items, ["問題 1"])
    }

    func testToolIsStoppedAndReportedAsTimedOutWhenTheDeadlinePasses() async {
        let deadline: TurnDeadline = TurnDeadline(limitSeconds: 0)
        deadline.start()
        let stop: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation) = AsyncStream<Void>.makeStream()
        let continuation: AsyncStream<Void>.Continuation = stop.continuation
        do {
            let _: Int = try await ClaudeTurn.watchingDeadline(deadline, onExpire: { continuation.finish() }) {
                for await _ in stop.stream {}
                throw TurnRuntimeError.interrupted
            }
            XCTFail("期限を過ぎた道具は止まる")
        } catch {
            XCTAssertEqual(error as? TurnRuntimeError, .timeout(ClaudeTurnRunner.deadlineDetail))
        }
    }

    func testFinalAnswerIsTheLastTextAndUnansweredToolCallsAreMergedBeforeTheNextInput() {
        let reader: ClaudeMessageReader = ClaudeMessageReader()
        _ = reader.consume(block(0, ["type": "redacted_thinking", "data": "opaque"]))
        _ = reader.consume(block(1, ["type": "text", "text": "{\"ok\":"]))
        _ = reader.consume(delta(1, ["type": "text_delta", "text": "true}"]))
        XCTAssertEqual(reader.finalText, "{\"ok\":true}")
        XCTAssertTrue(reader.toolUses.isEmpty)
        XCTAssertEqual(reader.content.first?["data"] as? String, "opaque")

        // 同じ役割が続いたら 1 つにまとめ、user では tool_result を先頭に置く。
        let merged: [[String: Any]] = ClaudeTurn.alternating([
            ["role": "user", "content": [["type": "text", "text": "grade"]]],
            ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_1", "name": "x", "input": [String: Any]()]]],
            ["role": "user", "content": [["type": "text", "text": "stop"]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "interrupted", "is_error": true]]],
            ["role": "assistant", "content": [[String: Any]]()],
        ])
        XCTAssertEqual(merged.map { $0["role"] as? String }, ["user", "assistant", "user"], "空の発話は落とす")
        let last: [[String: Any]] = merged.last?["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(last.map { $0["type"] as? String }, ["tool_result", "text"])
        XCTAssertEqual(last.last?["text"] as? String, "stop")
    }
}
