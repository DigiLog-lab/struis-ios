import XCTest
@testable import strius

/// 「ChatGPT でサインイン」(内部の配布だけ)の部品: Messages の履歴 → Responses の要求、Responses のイベント → Messages の
/// イベント、サインインの URL・戻り先の読み取り・トークンの応答。実際の OpenAI には送らない。
final class ResponsesTranslationTests: XCTestCase {
    private let tools = ClaudeToolNames(responsesTools: [[
        "type": "namespace", "name": "struis", "description": "Native",
        "tools": [["type": "function", "name": "exec_command", "description": "Run",
                   "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]], "required": ["cmd"]]]],
    ], ClaudeTurn.viewImageTool], sorted: true)

    // MARK: - 要求

    func testBodyCarriesInstructionsToolsAndReasoning() throws {
        let body = ResponsesRequest.body(
            model: "gpt-test", effort: "medium",
            system: [["type": "text", "text": "base", "cache_control": ["type": "ephemeral"]], ["type": "text", "text": "developer"]],
            messages: [["role": "user", "content": [["type": "text", "text": "hi"]]]], tools: tools
        )
        XCTAssertEqual(body["model"] as? String, "gpt-test")
        XCTAssertEqual(body["instructions"] as? String, "base\n\ndeveloper")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertNil(body["cache_control"])
        // 道具は namespace にまとめる。namespace の無い view_image は struis_core に入れる。
        let groups = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(groups.compactMap { $0["name"] as? String }.sorted(), ["struis", "struis_core"])
        let core = try XCTUnwrap(groups.first { $0["name"] as? String == "struis_core" })
        let viewImage = try XCTUnwrap((core["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(viewImage["name"] as? String, "view_image")
        XCTAssertEqual(viewImage["strict"] as? Bool, false)

        let withoutReasoning = ResponsesRequest.body(model: "m", effort: "high", system: [], messages: [], tools: tools, includeReasoning: false)
        XCTAssertNil(withoutReasoning["reasoning"])
        XCTAssertEqual(ResponsesRequest.reasoningEffort("max"), "xhigh")
        XCTAssertEqual(ResponsesRequest.reasoningEffort("minimal"), "low")
    }

    func testHistoryBecomesResponsesItems() throws {
        let messages: [[String: Any]] = [
            ["role": "user", "content": [
                ["type": "text", "text": "解いて"],
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "QUJD"]],
            ]],
            ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "secret", "signature": "sig"],
                ["type": "text", "text": "見ます"],
                ["type": "tool_use", "id": "toolu_1", "name": "struis__exec_command", "input": ["cmd": "ls"]],
                ["type": "tool_use", "id": "toolu_2", "name": "view_image", "input": ["path": "a.png"]],
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_1", "content": "a.png", "is_error": false],
                ["type": "tool_result", "tool_use_id": "toolu_2", "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "UE5H"]],
                ]],
                ["type": "text", "text": "続けて"],
            ]],
        ]
        let items = ResponsesRequest.input(messages, tools: tools)
        XCTAssertEqual(items.compactMap { $0["type"] as? String },
                       ["message", "message", "function_call", "function_call", "function_call_output", "function_call_output", "message"])
        // 最初の発話: 文字と画像。
        let first = try XCTUnwrap(items[0]["content"] as? [[String: Any]])
        XCTAssertEqual(first[1]["image_url"] as? String, "data:image/jpeg;base64,QUJD")
        // thinking は送らない。
        let assistant = try XCTUnwrap(items[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistant.count, 1)
        XCTAssertEqual(assistant[0]["type"] as? String, "output_text")
        // 道具の呼び出しは端末の名前と namespace に戻す。
        XCTAssertEqual(items[2]["name"] as? String, "exec_command")
        XCTAssertEqual(items[2]["namespace"] as? String, "struis")
        XCTAssertEqual(items[2]["call_id"] as? String, "toolu_1")
        XCTAssertEqual(items[2]["arguments"] as? String, "{\"cmd\":\"ls\"}")
        XCTAssertEqual(items[3]["namespace"] as? String, ResponsesRequest.coreNamespace)
        // 道具の結果の画像は、続く user の発話で渡す。
        XCTAssertEqual(items[4]["output"] as? String, "a.png")
        XCTAssertTrue((items[5]["output"] as? String)?.contains("1 image(s)") == true)
        let last = try XCTUnwrap(items[6]["content"] as? [[String: Any]])
        XCTAssertEqual(last.compactMap { $0["type"] as? String }, ["input_image", "input_text"])
    }

    // MARK: - イベント

    func testEventsBecomeMessagesEventsTheReadersUnderstand() throws {
        let events = ResponsesEventTranslator(tools: tools)
        let status = ClaudeStreamStatus()
        let reader = ClaudeMessageReader(keepsThinking: false)
        let stream: [[String: Any]] = [
            ["type": "response.created", "response": ["id": "resp_1", "model": "gpt-test"]],
            ["type": "response.reasoning_summary_text.delta", "output_index": 0, "summary_index": 0, "delta": "考え中"],
            ["type": "response.output_text.delta", "output_index": 1, "content_index": 0, "delta": "答えは"],
            ["type": "response.output_text.delta", "output_index": 1, "content_index": 0, "delta": " 2 です"],
            ["type": "response.output_item.done", "output_index": 2, "item": [
                "type": "function_call", "call_id": "call_9", "name": "exec_command", "namespace": "struis", "arguments": "{\"cmd\":\"pwd\"}",
            ]],
            ["type": "response.completed", "response": ["id": "resp_1", "usage": [
                "input_tokens": 100, "input_tokens_details": ["cached_tokens": 40], "output_tokens": 7, "output_tokens_details": ["reasoning_tokens": 3],
            ]]],
        ]
        var thinking = ""
        for event in stream {
            for translated in events.translate(event) {
                status.consume(translated)
                for output in reader.consume(translated) {
                    if case .thinking(_, let delta) = output { thinking += delta }
                }
            }
        }
        XCTAssertTrue(status.isFinished)
        XCTAssertEqual(status.messageID, "resp_1")
        XCTAssertEqual(status.model, "gpt-test")
        XCTAssertEqual(status.stopReason, "tool_use")
        XCTAssertEqual(status.rawUsage["input_tokens"] as? Int, 60)
        XCTAssertEqual(status.rawUsage["cache_read_input_tokens"] as? Int, 40)
        XCTAssertEqual(status.rawUsage["output_tokens"] as? Int, 7)
        XCTAssertEqual(thinking, "考え中")
        // 履歴には thinking を残さず、text と tool_use だけ。
        XCTAssertEqual(reader.content.compactMap { $0["type"] as? String }, ["text", "tool_use"])
        XCTAssertEqual(reader.finalText, "答えは 2 です")
        let use = try XCTUnwrap(reader.toolUses.first)
        XCTAssertEqual(use["id"] as? String, "call_9")
        XCTAssertEqual(use["name"] as? String, "struis__exec_command")
        XCTAssertEqual((use["input"] as? [String: Any])?["cmd"] as? String, "pwd")
    }

    func testLimitFailureIsReadAsAnError() {
        let events = ResponsesEventTranslator(tools: tools)
        let status = ClaudeStreamStatus()
        for event in [
            ["type": "response.created", "response": ["id": "resp_2"]],
            ["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded", "message": "limit"]]],
        ] as [[String: Any]] {
            for translated in events.translate(event) { status.consume(translated) }
        }
        XCTAssertTrue(status.isFinished)
        XCTAssertEqual(status.errorType, "subscription_sharing_usage_limit_exceeded")
        XCTAssertTrue(events.isLimit)
        XCTAssertEqual(events.errorMessage, "limit")
    }

    func testIncompleteForOutputLimitStopsAsMaxTokens() {
        let events = ResponsesEventTranslator(tools: tools)
        let status = ClaudeStreamStatus()
        for event in [
            ["type": "response.output_text.delta", "output_index": 0, "content_index": 0, "delta": "途中"],
            ["type": "response.incomplete", "response": ["incomplete_details": ["reason": "max_output_tokens"]]],
        ] as [[String: Any]] {
            for translated in events.translate(event) { status.consume(translated) }
        }
        XCTAssertEqual(status.stopReason, "max_tokens")
    }

    // MARK: - サインイン

    func testAuthorizeURLRegistersOnFirstSignInOnly() throws {
        let first = ChatGPTSignIn.authorizeURL(clientID: nil, hostID: "urn:uuid:1", redirectURI: "http://127.0.0.1:1455/auth/callback",
                                               state: "s", nonce: "n", challenge: "c")
        let items = try XCTUnwrap(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems)
        let value = { (name: String) in items.first { $0.name == name }?.value }
        XCTAssertEqual(value("client_id"), "dynamic_agent_client")
        XCTAssertEqual(value("agent_name_hint"), "Struis")
        XCTAssertEqual(value("ext_agent_host_id"), "urn:uuid:1")
        XCTAssertEqual(value("redirect_uri"), "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(value("resource"), "https://api.openai.com/v1")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertTrue(value("scope")?.contains("chatgpt.tokens.use.direct") == true)

        let again = ChatGPTSignIn.authorizeURL(clientID: "oaiapp_x", hostID: "urn:uuid:1", redirectURI: "http://127.0.0.1:1456/auth/callback",
                                               state: "s", nonce: "n", challenge: "c")
        let againItems = try XCTUnwrap(URLComponents(url: again, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(againItems.first { $0.name == "client_id" }?.value, "oaiapp_x")
        XCTAssertNil(againItems.first { $0.name == "agent_name_hint" })
    }

    func testPKCEChallengeMatchesTheRFCExample() {
        // RFC 7636 付録 B の例。
        XCTAssertEqual(ChatGPTSignIn.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testCallbackIsReadFromTheRequestLine() {
        let callback = ChatGPTSignIn.Callback.parse(requestLine: "GET /auth/callback?code=abc&state=xyz&client_id=oaiapp_1&scope=openid HTTP/1.1")
        XCTAssertEqual(callback, ChatGPTSignIn.Callback(code: "abc", state: "xyz", clientID: "oaiapp_1", error: nil, errorDescription: nil))
        XCTAssertNil(ChatGPTSignIn.Callback.parse(requestLine: "GET /favicon.ico HTTP/1.1"))
        XCTAssertEqual(ChatGPTSignIn.Callback.parse(requestLine: "GET /auth/callback?error=access_denied HTTP/1.1")?.error, "access_denied")
    }

    func testTokenResponseNeedsThePlanScope() throws {
        let payload = Data("{\"email\":\"a@example.com\",\"name\":\"A\",\"nonce\":\"n\"}".utf8)
        let jwt = "e30." + ChatGPTSignIn.base64URL(payload) + ".sig"
        let now = Date(timeIntervalSince1970: 1_000)
        let credentials = try ChatGPTAccount.credentials(from: [
            "access_token": "at", "refresh_token": "rt", "expires_in": 3600, "id_token": jwt,
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
        ], clientID: "oaiapp_1", now: now)
        XCTAssertEqual(credentials.email, "a@example.com")
        XCTAssertEqual(credentials.name, "A")
        XCTAssertEqual(credentials.expiresAt, now.addingTimeInterval(3600))
        XCTAssertTrue(credentials.canUsePlan)

        // 更新の応答に無い値は前の記録から引き継ぐ。
        let refreshed = try ChatGPTAccount.credentials(from: ["access_token": "at2", "expires_in": 60], clientID: "oaiapp_1", previous: credentials, now: now)
        XCTAssertEqual(refreshed.refreshToken, "rt")
        XCTAssertEqual(refreshed.email, "a@example.com")

        XCTAssertThrowsError(try ChatGPTAccount.credentials(from: ["access_token": "at", "refresh_token": "rt", "scope": "openid email"], clientID: "c"))
    }

    func testModelsKeepOnlyListedOnes() {
        let data = Data("{\"models\":[{\"slug\":\"a\",\"display_name\":\"A\",\"visibility\":\"list\"},{\"slug\":\"b\",\"visibility\":\"hide\"}]}".utf8)
        XCTAssertEqual(ChatGPTAccount.models(from: data), [ChatGPTAccount.Model(slug: "a", displayName: "A")])
    }

    func testFormBodyEncodesReservedCharacters() {
        XCTAssertEqual(ChatGPTAccount.formBody(["redirect_uri": "http://127.0.0.1:1455/a", "a": "x y+z"]),
                       "a=x%20y%2Bz&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fa")
    }
}
