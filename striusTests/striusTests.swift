//
//  striusTests.swift
//  striusTests
//
//  Created by 宮氏朋愛 on 2026/04/17.
//

import Foundation
import Testing
@testable import strius

struct striusTests {

    @Test func assistantTextReadabilityAddsLineBreaksToDenseReply() {
        let raw = "OKです。前にやっていた物理だと、候補は「斜方投射・速度の成分」と「物理学A 第4回の力・作用反作用」です。まずどちらからテスト対策しますか？選んでくれた方で、確認問題を1問出します。"

        let formatted = ChatTextReadability.formatAssistantText(raw)

        #expect(
            formatted == """
            OKです。
            前にやっていた物理だと、候補は「斜方投射・速度の成分」と「物理学A 第4回の力・作用反作用」です。
            まずどちらからテスト対策しますか？
            選んでくれた方で、確認問題を1問出します。
            """
        )
    }

    @Test func assistantTextReadabilityPreservesExplicitLineBreaks() {
        let raw = "OKです。\\nまずは斜方投射からいきましょう。"

        let formatted = ChatTextReadability.formatAssistantText(raw)

        #expect(
            formatted == """
            OKです。
            まずは斜方投射からいきましょう。
            """
        )
    }

    @Test func assetCacheFetchesMissingDeliveryAssetsAndBecomesReady() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("struis-delivery-test-\(UUID().uuidString)", isDirectory: true)
        let source = TestAssetSource()
        let cache = AssetCache(root: root)

        let manifest = try await cache.refresh(from: source)
        #expect(manifest.assets.count == DeliveryManifest.assetNames.count)
        #expect(await cache.isReady)

        let reference = try await cache.ref("prompt:base")
        #expect(reference.sha256 == manifest.assets["prompt:base"]?.sha256)
        let prompt = try await cache.text("prompt:base")
        #expect(prompt == "prompt:base")

        try? FileManager.default.removeItem(at: root)
    }

    @Test func deliveryAssetNameIsEscapedExactlyOnce() {
        let path = ServerAssetSource.assetPath("prompt:base")
        let url = URL(string: "http://127.0.0.1:4041")!.appendingPathComponent(path)

        #expect(url.absoluteString == "http://127.0.0.1:4041/v1/device-runtime/assets/prompt:base")
        #expect(!url.absoluteString.contains("%253A"))
    }

    @Test func assetCacheRejectsManifestMissingRequiredAsset() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("struis-delivery-incomplete-\(UUID().uuidString)", isDirectory: true)
        let cache = AssetCache(root: root)

        do {
            _ = try await cache.refresh(from: TestAssetSource(missing: "prompt:base"))
            Issue.record("Incomplete delivery manifest was accepted")
        } catch DeliveryError.manifestMissing {
            // Expected: turns must remain disabled until every required asset is present.
        }
        #expect(!(await cache.isReady))

        try? FileManager.default.removeItem(at: root)
    }

}

private struct TestAssetSource: AssetSource, Sendable {
    let manifest: DeliveryManifest
    let bodies: [String: Data]

    init(missing: String? = nil) {
        var bodies: [String: Data] = [:]
        for name in DeliveryManifest.assetNames {
            if name == missing { continue }
            bodies[name] = Data(name.utf8)
        }
        self.bodies = bodies
        self.manifest = DeliveryManifest(
            codexVersion: "test",
            rootfsMinVersion: 1,
            models: [:],
            assets: Dictionary(uniqueKeysWithValues: bodies.map { name, data in
                (
                    name,
                    DeliveryManifest.Asset(
                        sha256: AssetCache.sha256Hex(data),
                        bytes: data.count,
                        updatedAt: "test"
                    )
                )
            }),
            fetchedAt: nil
        )
    }

    func fetchManifest() async throws -> DeliveryManifest {
        manifest
    }

    func fetchAsset(_ name: String) async throws -> Data {
        guard let data = bodies[name] else {
            throw DeliveryError.notCached(name)
        }
        return data
    }
}
