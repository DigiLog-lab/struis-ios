import CoreGraphics
import Foundation
import Testing
@testable import strius

@MainActor
struct DTODecodingTests {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    @Test func decodeAppleExchangeResponse() throws {
        let json = """
        {
          "access_token": "jwt.token.value",
          "refresh_token": "refresh-xyz",
          "user_id": "11111111-2222-3333-4444-555555555555",
          "trial_started_at": "2026-04-17T12:00:00Z",
          "trial_ends_at": "2026-05-01T12:00:00Z"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(AppleExchangeResponse.self, from: json)
        #expect(response.accessToken == "jwt.token.value")
        #expect(response.refreshToken == "refresh-xyz")
        #expect(response.userId.uuidString == "11111111-2222-3333-4444-555555555555")
    }

    @Test func decodeBootstrapResponse() throws {
        let json = """
        {
          "user": {
            "id": "11111111-2222-3333-4444-555555555555",
            "display_name": "朋愛",
            "email": "t@example.com"
          },
          "trial": {
            "started_at": "2026-04-17T12:00:00Z",
            "ends_at": "2026-05-01T12:00:00Z"
          },
          "streak": { "count": 3, "last_solved_on": "2026-04-16" },
          "threads": [
            {
              "id": "22222222-0000-0000-0000-000000000000",
              "title": "三角比の復習",
              "latest_preview": "余弦定理のところを…",
              "last_message_at": "2026-04-17T09:30:00Z"
            }
          ],
          "unread_proposals": 2,
          "latest_re_evaluation": null
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(BootstrapResponse.self, from: json)
        #expect(response.user.displayName == "朋愛")
        #expect(response.streak.count == 3)
        #expect(response.threads.count == 1)
        #expect(response.threads.first?.title == "三角比の復習")
    }

    @Test func decodeChatMessage() throws {
        let json = """
        {
          "id": "33333333-0000-0000-0000-000000000000",
          "role": "assistant",
          "status": "completed",
          "plain_text": "今日はここから始めましょう。",
          "blocks": [{"kind": "text", "payload": {"text": "今日はここから始めましょう。"}}],
          "metadata": null,
          "created_at": "2026-04-17T10:00:00Z",
          "completed_at": "2026-04-17T10:00:04Z"
        }
        """.data(using: .utf8)!

        let message = try decoder.decode(ChatMessage.self, from: json)
        #expect(message.role == .assistant)
        #expect(message.status == .completed)
        #expect(message.plainText == "今日はここから始めましょう。")
        #expect(message.blocks.count == 1)
        #expect(message.blocks.first?.kind == "text")
    }

    @Test func decodeChatMessageWithStringifiedJSONFields() throws {
        let json = #"""
        {
          "id": "33333333-0000-0000-0000-000000000000",
          "role": "assistant",
          "status": "completed",
          "plain_text": "今日はここから始めましょう。",
          "blocks": "[{\"kind\":\"text\",\"payload\":{\"text\":\"今日はここから始めましょう。\"}}]",
          "metadata": "{\"workflow_run_id\":\"55555555-0000-0000-0000-000000000000\"}",
          "created_at": "2026-04-17T10:00:00Z",
          "completed_at": "2026-04-17T10:00:04Z"
        }
        """#.data(using: .utf8)!

        let message = try decoder.decode(ChatMessage.self, from: json)
        #expect(message.blocks.count == 1)
        #expect(message.blocks.first?.payload.value["text"]?.stringValue == "今日はここから始めましょう。")
        #expect(message.metadata?.value["workflow_run_id"]?.stringValue == "55555555-0000-0000-0000-000000000000")
    }

    @Test func decodeCodexCreateMessageResponse() throws {
        let json = """
        {
          "user_message_id": "11111111-0000-0000-0000-000000000000",
          "assistant_message_id": "22222222-0000-0000-0000-000000000000",
          "workflow_run_id": null,
          "codex_turn_run_id": "33333333-0000-0000-0000-000000000000",
          "handled_as": "codex_app_server"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(CreateMessageResponse.self, from: json)
        #expect(response.workflowRunId == nil)
        #expect(response.codexTurnRunId?.uuidString == "33333333-0000-0000-0000-000000000000")
        #expect(response.handledAs == "codex_app_server")
    }

    @Test func decodeChatBranchAnchor() throws {
        let json = """
        {
          "id": "44444444-0000-0000-0000-000000000001",
          "stem_thread_id": "11111111-0000-0000-0000-000000000001",
          "thread_id": "22222222-0000-0000-0000-000000000001",
          "anchor_message_id": "33333333-0000-0000-0000-000000000001",
          "first_question_preview": "この符号が変わる理由は？",
          "status": "active",
          "merge_pending": false,
          "created_at": "2026-07-28T01:00:00Z",
          "updated_at": "2026-07-28T01:01:00Z"
        }
        """.data(using: .utf8)!

        let branch = try decoder.decode(ChatBranchSummary.self, from: json)
        #expect(branch.anchorMessageId?.uuidString == "33333333-0000-0000-0000-000000000001")
        #expect(branch.firstQuestionPreview == "この符号が変わる理由は？")
    }

    @Test func decodeEmptyResponseFromCreateMessagePayload() throws {
        let json = """
        {
          "user_message_id": "11111111-0000-0000-0000-000000000000",
          "assistant_message_id": "22222222-0000-0000-0000-000000000000",
          "workflow_run_id": null,
          "codex_turn_run_id": "33333333-0000-0000-0000-000000000000",
          "handled_as": "codex_app_server"
        }
        """.data(using: .utf8)!

        _ = try decoder.decode(EmptyResponse.self, from: json)
    }

    @Test func decodeCodexAccount() throws {
        let json = """
        {
          "id": "codex-account-1",
          "status": "connected",
          "auth_mode": "chatgpt",
          "plan_type": "pro",
          "account_email": "codex@example.com",
          "rate_limit_resets_at": "2026-04-17T12:00:00Z",
          "last_synced_at": "2026-04-17T10:00:00Z",
          "error": null,
          "loginId": null,
          "verificationUrl": null,
          "userCode": null
        }
        """.data(using: .utf8)!

        let account = try decoder.decode(CodexAccount.self, from: json)
        #expect(account.status == .connected)
        #expect(account.authMode == "chatgpt")
        #expect(account.planType == "pro")
        #expect(account.accountEmail == "codex@example.com")
        #expect(account.isConnected)
    }

    @Test func decodeCodexPromptVersions() throws {
        let json = """
        {
          "base": {
            "family": "education-base-e017e93a-v1",
            "sha256": "0123456789abcdef",
            "version": "education-base-e017e93a-v1+sha256:0123456789ab",
            "updated_at": "2026-09-01"
          },
          "developer_instructions": {
            "family": "education-developer-v1",
            "sha256": "abcdef0123456789",
            "version": "education-developer-v1+sha256:abcdef012345",
            "updated_at": "2026-09-01"
          },
          "agents": {
            "family": "struis-app-server-agents",
            "sha256": "fedcba9876543210",
            "version": "struis-app-server-agents+sha256:fedcba987654",
            "updated_at": "2026-07-20"
          }
        }
        """.data(using: .utf8)!

        let versions = try decoder.decode(CodexPromptVersions.self, from: json)
        #expect(versions.base.family == "education-base-e017e93a-v1")
        #expect(versions.base.updatedAt == "2026-09-01")
        #expect(versions.developerInstructions.version.contains("abcdef012345"))
        #expect(versions.agents.version.contains("fedcba987654"))
        #expect(versions.agents.updatedAt == "2026-07-20")
    }

    @Test func decodeTextAttemptView() throws {
        let json = #"""
        {
          "schema_version": 1,
          "attempt_id": "44444444-0000-0000-0000-000000000001",
          "source_message_id": "33333333-0000-0000-0000-000000000000",
          "thread_id": "22222222-0000-0000-0000-000000000000",
          "status": "completed",
          "result": "needs_revision",
          "input_mode": "text",
          "content": {
            "kind": "text",
            "text": "AB = \\begin{pmatrix}-5 & 9 \\\\ 4 & -3\\end{pmatrix}",
            "assets": [],
            "steps": []
          },
          "annotations": [
            {"step_id": null, "status": "needs_revision", "text": "下の行を確認しましょう。", "anchor": null}
          ],
          "created_at": "2026-07-14T01:00:00Z",
          "completed_at": "2026-07-14T01:00:04Z"
        }
        """#.data(using: .utf8)!

        let attempt = try decoder.decode(AttemptViewV1.self, from: json)
        #expect(attempt.schemaVersion == 1)
        #expect(attempt.inputMode == "text")
        #expect(attempt.content?.kind == "text")
        #expect(attempt.content?.text?.contains("pmatrix") == true)
        #expect(attempt.annotations.first?.text == "下の行を確認しましょう。")
        #expect(attempt.hasRenderableContent)
    }

    @Test func decodeAssetAttemptViewAndNormalizedAnchor() throws {
        let json = """
        {
          "schema_version": 1,
          "attempt_id": "44444444-0000-0000-0000-000000000002",
          "status": "completed",
          "input_mode": "mixed",
          "content": {
            "kind": "asset",
            "assets": [
              {
                "id": "image-1",
                "asset_path": "attempts/user/answer.jpg",
                "filename": "answer.jpg",
                "content_type": "image/jpeg",
                "bytes": 12000,
                "page": 1
              },
              {
                "id": "pdf-1",
                "asset_path": "attempts/user/notes.pdf",
                "filename": "notes.pdf",
                "content_type": "application/pdf",
                "bytes": 42000,
                "page": null
              }
            ],
            "steps": []
          },
          "annotations": [
            {
              "step_id": "step-2",
              "status": "incorrect",
              "text": "符号を確認してください。",
              "anchor": {
                "asset_id": "image-1",
                "asset_path": "attempts/user/answer.jpg",
                "page": 1,
                "x": 0.1,
                "y": 0.2,
                "width": 0.3,
                "height": 0.15
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let attempt = try decoder.decode(AttemptViewV1.self, from: json)
        #expect(attempt.schemaVersion == 1)
        #expect(attempt.content?.assets.count == 2)
        #expect(attempt.content?.assets[0].isImage == true)
        #expect(attempt.content?.assets[1].isPDF == true)
        #expect(attempt.annotations[0].anchor?.normalizedRect == CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.15))
        #expect(attempt.hasRenderableContent)
    }

    @Test func pdfPageProjectionUsesImagePath() {
        let asset = AttemptAssetV1(
            id: "pdf-page-2",
            assetPath: "attempts/user/notes.pdf",
            filename: "notes.pdf",
            contentType: "image/png",
            bytes: 32000,
            page: 2
        )

        #expect(asset.isImage)
        #expect(!asset.isPDF)
        #expect(APIEndpoint.asset(relativePath: asset.assetPath!, page: asset.page).queryItems == [
            URLQueryItem(name: "page", value: "2"),
        ])
    }

    @Test func decodeRealtimeEvent() {
        let completed = RealtimeEvent.decode(
            from: #"{"type":"thread.message.completed","data":{"thread_id":"22222222-0000-0000-0000-000000000000","message_id":"33333333-0000-0000-0000-000000000000"}}"#
        )
        if case .threadMessageCompleted(let threadID, let messageID) = completed {
            #expect(threadID.uuidString == "22222222-0000-0000-0000-000000000000")
            #expect(messageID.uuidString == "33333333-0000-0000-0000-000000000000")
        } else {
            Issue.record("Expected threadMessageCompleted, got \(String(describing: completed))")
        }

        #expect(RealtimeEvent.decode(from: "pong") == .pong)

        let attempt = RealtimeEvent.decode(
            from: #"{"type":"attempt.updated","data":{"thread_id":"22222222-0000-0000-0000-000000000000","attempt_id":"44444444-0000-0000-0000-000000000002"}}"#
        )
        if case .attemptUpdated(let threadID, let attemptID) = attempt {
            #expect(threadID?.uuidString == "22222222-0000-0000-0000-000000000000")
            #expect(attemptID.uuidString == "44444444-0000-0000-0000-000000000002")
        } else {
            Issue.record("Expected attemptUpdated, got \(String(describing: attempt))")
        }

        let unknown = RealtimeEvent.decode(
            from: #"{"type":"legacy.event","data":{"id":"44444444-0000-0000-0000-000000000000"}}"#
        )
        if case .unknown(let type) = unknown {
            #expect(type == "legacy.event")
        } else {
            Issue.record("Expected unknown, got \(String(describing: unknown))")
        }
    }
}
