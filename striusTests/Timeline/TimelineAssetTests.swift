import XCTest
@testable import strius

/// Issue #46「プロンプトとスキーマは、このリポに埋め込む」: 配信に無い名前は同梱版を使い、配信にあれば配信版が優先される。
final class TimelineAssetTests: XCTestCase {
    private func emptyRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-assets-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

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

    func testBundledAssetsAreNotRequiredByTheManifest() {
        // 必須の一覧に入れると、サーバーが対応するまで refresh が manifestMissing で失敗し、配信の更新が全部止まる。
        XCTAssertTrue(Set(DeliveryManifest.assetNames).isDisjoint(with: BundledAssets.names))
    }

    func testFallsBackToTheBundledCopyAndHashesIt() async throws {
        let cache = AssetCache(root: emptyRoot())
        let text = try await cache.text("prompt:timeline_instructions")
        XCTAssertTrue(text.contains("次の5枚"))
        let ref = try await cache.ref("prompt:timeline_instructions")
        let data = try XCTUnwrap(BundledAssets.main.data("prompt:timeline_instructions"))
        XCTAssertEqual(ref.sha256, AssetCache.sha256Hex(data))
        let schema = try await cache.json("schema:timeline_batch")
        XCTAssertNotNil(schema["properties"]?["cards"])
        // 同梱に無い名前は今まで通り未取得。
        do {
            _ = try await cache.text("prompt:base")
            XCTFail("prompt:base は同梱しない")
        } catch DeliveryError.notCached {}
    }

    func testDeliveredCopyWins() async throws {
        let root = emptyRoot()
        let body = Data("配信版の指示".utf8)
        let sha = AssetCache.sha256Hex(body)
        try body.write(to: root.appendingPathComponent("prompt-timeline_instructions-" + sha.prefix(16)))
        var assets: [String: DeliveryManifest.Asset] = [:]
        assets["prompt:timeline_instructions"] = DeliveryManifest.Asset(sha256: sha, bytes: body.count, updatedAt: "now")
        let manifest = DeliveryManifest(codexVersion: "0", rootfsMinVersion: 1, models: [:], assets: assets, fetchedAt: nil)
        try AssetCache.encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        let cache = AssetCache(root: root)
        let text = try await cache.text("prompt:timeline_instructions")
        XCTAssertEqual(text, "配信版の指示")
        let ref = try await cache.ref("prompt:timeline_instructions")
        XCTAssertEqual(ref.sha256, sha)
    }

    func testTimelineModelAliases() async throws {
        let cache = AssetCache(root: emptyRoot())
        let claude = await cache.model(TimelineModels.role, provider: .anthropic)
        XCTAssertEqual(claude.model, "claude-sonnet-5-5")
        XCTAssertEqual(claude.provider, .anthropic)
        let graph = await cache.model(TimelineModels.graphRole, provider: .anthropic)
        XCTAssertEqual(graph.model, "claude-opus-5-5")
        // 実行先が OpenAI の時は astra ではなく GPT-6.1 Sol。
        let openai = await cache.model(TimelineModels.role, provider: .openai)
        XCTAssertEqual(openai.model, "gpt-6.1-sol")
        XCTAssertNil(openai.provider)
        let openaiGraph = await cache.model(TimelineModels.graphRole, provider: .openai)
        XCTAssertEqual(openaiGraph.model, "gpt-6.1-sol")
    }

    func testManifestAliasOverridesTheTimelineModel() async throws {
        let root = emptyRoot()
        let manifest = DeliveryManifest(codexVersion: "0", rootfsMinVersion: 1, models: [
            "claude:timeline": DeliveryManifest.Model(model: "claude-opus-5-5", effort: "medium"),
            "timeline": DeliveryManifest.Model(model: "gpt-6.2", effort: "low"),
        ], assets: [:], fetchedAt: nil)
        try AssetCache.encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        let cache = AssetCache(root: root)
        // OpenAI は配信の別名のまま。
        let openai = await cache.model(TimelineModels.role, provider: .openai)
        XCTAssertEqual(openai.model, "gpt-6.2")
        // Claude は設定で選んだモデル(既定は Sonnet 5.5)が manifest の `claude:timeline` より優先する。
        let haiku = AssetCache(root: root, timelineClaudeModel: { "claude-haiku-5-5" })
        let model = await haiku.model(TimelineModels.role, provider: .anthropic)
        XCTAssertEqual(model.model, "claude-haiku-5-5")
        XCTAssertEqual(model.provider, .anthropic)
        // 知識グラフは設定の対象外。
        let graph = await haiku.model(TimelineModels.graphRole, provider: .anthropic)
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
