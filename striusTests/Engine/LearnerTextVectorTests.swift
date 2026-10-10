import Foundation
import XCTest
#if canImport(StruisEngine)
@testable import StruisEngine
#else
@testable import strius
#endif

final class LearnerTextVectorTests: XCTestCase {
    static let vectors: EngineJSON = { try! EngineVectors.load("learner_text") }()

    private func cases(_ key: String) -> [EngineObject] {
        Self.vectors[key]?.arrayValue?.compactMap(\.objectValue) ?? []
    }

    private func threadRow(_ value: EngineJSON) -> ThreadRow {
        ThreadRow(id: value["id"]!.stringOrEmpty, title: value["title"]?.stringValue,
                  source: value["source"]?.stringValue ?? "user", latestPreview: value["latest_preview"]?.stringValue ?? "",
                  lastMessageAt: value["last_message_at"]?.stringValue.flatMap { EnginePyTime.parseISO($0) },
                  recentContext: value["recent_context"]?.stringValue ?? "")
    }

    private func messageRow(_ value: EngineJSON) -> MessageRow {
        MessageRow(threadID: value["thread_id"]!.stringOrEmpty, threadTitle: value["thread_title"]?.stringValue,
                   role: value["role"]?.stringValue, plainText: value["plain_text"]?.stringValue ?? "",
                   createdAt: EnginePyTime.parseISO(value["created_at"]!.stringOrEmpty)!)
    }

    func testConstants() {
        let c = cases("constants")[0]
        XCTAssertEqual(c["MAX_CONTEXT_TEXT_CHARS"]?.intValue, LearnerText.maxContextTextChars)
        XCTAssertEqual(c["MAX_CONTEXT_MESSAGE_CHARS"]?.intValue, LearnerText.maxContextMessageChars)
        XCTAssertEqual(c["MAX_CONTEXT_PREVIEW_CHARS"]?.intValue, LearnerText.maxContextPreviewChars)
        XCTAssertEqual(c["MAX_CONTEXT_THREADS_WITH_HISTORY"]?.intValue, LearnerText.maxContextThreadsWithHistory)
        XCTAssertEqual(c["RECENT_CONTEXT_SNIPPET_CHARS"]?.intValue, LearnerText.recentContextSnippetChars)
        XCTAssertEqual(c["ASTRA_MODEL"]?.stringValue, CodexModels.astraModel)
        XCTAssertEqual(c["ASTRA_EFFORT"]?.stringValue, CodexModels.astraEffort)
        XCTAssertEqual(c["LUNA_MODEL"]?.stringValue, CodexModels.lunaModel)
        XCTAssertEqual(c["LUNA_EFFORT"]?.stringValue, CodexModels.lunaEffort)
        XCTAssertEqual(c["LEARNER_FACING_SANITIZER_FALLBACK"]?.stringValue, LearnerText.learnerFacingSanitizerFallback)
    }

    func testSanitizeVectors() {
        for c in cases("sanitize") {
            XCTAssertEqual(LearnerText.sanitizeLearnerFacingText(c["input"]!.stringOrEmpty), c["expect"]!.stringOrEmpty, c["name"]!.stringOrEmpty)
        }
    }

    func testExtractWorkbookBlockVectors() {
        for c in cases("extract_workbook_blocks") {
            let name = c["name"]!.stringOrEmpty
            let result = LearnerText.extractWorkbookBlockValues(c["input"]!.stringOrEmpty)
            let expect = c["expect"]!
            XCTAssertEqual(result.text, expect["text"]?.stringValue, name)
            EngineVectors.assertEqual(result.proposal ?? .null, expect["proposal"] ?? .null, name + " proposal")
            EngineVectors.assertEqual(result.hint ?? .null, expect["hint"] ?? .null, name + " hint")
            let bridged = LearnerText.extractWorkbookBlocks(c["input"]!.stringOrEmpty)
            XCTAssertEqual(bridged.text, result.text, name)
            XCTAssertEqual(bridged.proposal == nil, result.proposal == nil, name)
        }
    }

    func testExtractEmbeddedMemoryUpdateVectors() {
        for c in cases("extract_embedded_memory_update") {
            let name = c["name"]!.stringOrEmpty
            let result = TutorMemory.extractEmbeddedMemoryUpdate(c["input"]!.stringOrEmpty)
            let expect = c["expect"]!
            XCTAssertEqual(result.visible, expect["visible"]?.stringValue, name)
            XCTAssertEqual(result.payload, expect["payload"]?.stringValue, name)
            XCTAssertEqual(result.error, expect["error"]?.stringValue, name)
        }
    }

    func testRenderRecentThreadHistoryVectors() {
        for c in cases("render_recent_thread_history") {
            let rendered = LearnerText.renderRecentThreadHistory(
                currentThreadID: c["current_thread_id"]!.stringOrEmpty,
                threadRows: c["thread_rows"]!.arrayValue!.map(threadRow),
                messageRows: c["message_rows"]!.arrayValue!.map(messageRow),
                latestUserText: c["latest_user_text"]?.stringValue ?? "",
                crossThreadContextEnabled: c["cross_thread_context_enabled"]?.boolValue ?? true)
            XCTAssertEqual(rendered, c["expect"]!.stringOrEmpty, c["name"]!.stringOrEmpty)
        }
    }

    func testSelectContextThreadRowVectors() {
        for c in cases("select_context_thread_rows") {
            let result = LearnerText.selectContextThreadRows(currentThreadID: c["current_thread_id"]!.stringOrEmpty,
                                                             latestUserText: c["latest_user_text"]!.stringOrEmpty,
                                                             threadRows: c["thread_rows"]!.arrayValue!.map(threadRow))
            let expect = c["expect"]!
            XCTAssertEqual(result.rows.map(\.id), expect["ids"]!.arrayValue!.map(\.stringOrEmpty), c["name"]!.stringOrEmpty)
            XCTAssertEqual(result.crossThreadEnabled, expect["cross_thread"]?.boolValue, c["name"]!.stringOrEmpty)
        }
    }

    func testContextRelevanceScoreVectors() {
        for c in cases("context_relevance_score") {
            let score = LearnerText.contextRelevanceScore(latestUserText: c["latest_user_text"]!.stringOrEmpty, row: threadRow(c["row"]!),
                                                          anchorTime: c["anchor_time"]?.stringValue.flatMap { EnginePyTime.parseISO($0) })
            XCTAssertEqual(score, c["expect"]?.intValue, c["name"]!.stringOrEmpty)
        }
    }

    func testInjectedItemTextVectors() {
        for c in cases("injected_item_text") {
            let staged: StagedContext? = c["staged"]?.objectValue.map {
                StagedContext(tutorDeskManifestRelativePath: $0["tutor_desk_manifest_relative_path"]?.stringValue,
                              markdownRelativePath: $0["markdown_relative_path"]?.stringValue,
                              tutorMemoryContext: $0["tutor_memory_context"]?.stringValue)
            }
            XCTAssertEqual(LearnerText.struisContextInjectedItemText(staged: staged), c["expect"]!.stringOrEmpty, c["name"]!.stringOrEmpty)
        }
    }

    func testWorkbookCurrentViewTurnInputVectors() throws {
        for c in cases("workbook_current_view_turn_input") {
            let name = c["name"]!.stringOrEmpty
            let expected = c["expect"]!.stringOrEmpty
            let actual = LearnerText.workbookCurrentViewTurnInput(view: c["view"]!, learnerText: c["learner_text"]!.stringOrEmpty)
            // Key order follows the view object; compare the JSON payload structurally and the framing textually.
            func split(_ text: String) -> (String, String) {
                let open = "<struis_current_view>\n", close = "\n</struis_current_view>\n"
                let body = text.dropFirst(open.count)
                let end = body.range(of: close)!
                return (String(body[..<end.lowerBound]), String(body[end.upperBound...]))
            }
            XCTAssertTrue(actual.hasPrefix("<struis_current_view>\n"), name)
            let (actualJSON, actualRest) = split(actual)
            let (expectedJSON, expectedRest) = split(expected)
            EngineVectors.assertEqual(try EngineJSON.parse(actualJSON), try EngineJSON.parse(expectedJSON), name)
            XCTAssertEqual(actualRest, expectedRest, name)
            XCTAssertEqual(actual, expected, name + " (exact, order-preserving view)")
        }
    }
}
