import XCTest
@testable import strius

/// 指示文・schema・Skill はすべてアプリに同梱する。
final class TimelineAssetTests: XCTestCase {
    func testEveryBundledAssetShipsWithTheApp() throws {
        for name in BundledAssets.names {
            let data = try XCTUnwrap(BundledAssets.main.data(name), "\(name) が同梱されていない")
            XCTAssertFalse(data.isEmpty, name)
            if name.hasPrefix("schema:") {
                let value = try XCTUnwrap(LedgerJSON.parse(String(decoding: data, as: UTF8.self)), "\(name) が JSON として読めない")
                XCTAssertEqual(value["type"]?.stringValue, "object", name)
                XCTAssertEqual(value["additionalProperties"]?.boolValue, false, name)
            }
        }
    }

    func testNoBundledAssetNamesTheRetiredRuntime() throws {
        for name in BundledAssets.names {
            let data: Data = try XCTUnwrap(BundledAssets.main.data(name), name)
            let text: String = String(decoding: data, as: UTF8.self).lowercased()
            for retired in ["codex", "gpt-", "openai", "chatgpt"] {
                XCTAssertFalse(text.contains(retired), "\(name) に \(retired) が残っている")
            }
        }
    }

    func testReadsTheBundledCopyAndHashesIt() async throws {
        let cache = AssetCache()
        let text = try await cache.text("prompt:timeline_instructions")
        XCTAssertTrue(text.contains("次の5枚"))
        let ref = try await cache.ref("prompt:timeline_instructions")
        let data = try XCTUnwrap(BundledAssets.main.data("prompt:timeline_instructions"))
        XCTAssertEqual(ref.sha256, AssetCache.sha256Hex(data))
        let schema = try await cache.json("schema:timeline_batch")
        XCTAssertNotNil(schema["properties"]?["cards"])
        // 表に無い名前は読めない。
        do {
            _ = try await cache.text("prompt:unknown")
            XCTFail("prompt:unknown は同梱していない")
        } catch AssetError.missing {}
    }

    func testTheProtocolAndWorkspaceFilesAreBundled() async throws {
        let cache = AssetCache()
        let developer = try await cache.text("prompt:developer")
        XCTAssertTrue(developer.contains("STRUIS_TURN_PROTOCOL_V2"), "受け答えの決まりは指示文の側にある")
        // 質問画面は学習の話に絞る。つらい気持ちはこの決まりの対象にしない(#77)。
        XCTAssertTrue(developer.contains("「ここでは勉強のことだけお手伝いできます。」"))
        XCTAssertTrue(developer.contains("This rule does not apply when the learner writes about distress"))
        let reference = try await ChatTurns.developerRef(assets: cache)
        XCTAssertTrue(reference.append?.contains("Progress update_schema") == true)
        for name in ["prompt:base", "prompt:agents", "prompt:luna_child", "prompt:delegate_py", "prompt:tutor_memory_py",
                     "prompt:reply_lint_py", "skill:struis_document"] {
            let body = try await cache.text(name)
            XCTAssertFalse(body.isEmpty, name)
        }
    }

    func testTimelineModelAliases() async throws {
        let cache = AssetCache()
        let claude = await cache.model(TimelineModels.role)
        XCTAssertEqual(claude.model, "claude-sonnet-5-5")
        XCTAssertEqual(claude.provider, .anthropic)
        let graph = await cache.model(TimelineModels.graphRole)
        XCTAssertEqual(graph.model, "claude-opus-5-5")
        // 質問・下調べは Claude の既定。
        let astra = await cache.model("astra")
        XCTAssertEqual(astra.model, ClaudeModels.astraModel)
        XCTAssertEqual(astra.provider, .anthropic)
        let luna = await cache.model("luna")
        XCTAssertEqual(luna.model, ClaudeModels.lunaModel)
    }

    func testTheChosenTimelineModelAppliesToTheTimelineOnly() async throws {
        let haiku = AssetCache(timelineClaudeModel: { "claude-haiku-5-5" })
        let model = await haiku.model(TimelineModels.role)
        XCTAssertEqual(model.model, "claude-haiku-5-5")
        XCTAssertEqual(model.provider, .anthropic)
        // 知識グラフは設定の対象外。
        let graph = await haiku.model(TimelineModels.graphRole)
        XCTAssertEqual(graph.model, "claude-opus-5-5")
    }

    func testTimelineModelPreferenceDefaultsToSonnetAndIgnoresUnknownValues() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: TimelineModelPreference.defaultsKey)
        defer { defaults.set(saved, forKey: TimelineModelPreference.defaultsKey) }
        defaults.removeObject(forKey: TimelineModelPreference.defaultsKey)
        XCTAssertEqual(TimelineModelPreference.current, "claude-sonnet-5-5")
        TimelineModelPreference.current = "claude-haiku-5-5"
        XCTAssertEqual(TimelineModelPreference.current, "claude-haiku-5-5")
        defaults.set("claude-opus-5-5", forKey: TimelineModelPreference.defaultsKey)
        XCTAssertEqual(TimelineModelPreference.current, "claude-sonnet-5-5")
    }
}
