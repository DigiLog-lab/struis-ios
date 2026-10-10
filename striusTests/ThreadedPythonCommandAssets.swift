// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit

/// Only four fixed entries override the same frozen, validated foundation map.
nonisolated struct ThreadedPythonCommandAssets: Sendable {
    let files: [String: Data]
    init(bundle: Bundle) throws {
        let base = try ThreadedPythonFoundationAssets(bundle: bundle)
        guard let root = bundle.url(forResource: "ThreadedPythonCommandTestOverlay", withExtension: nil) else { throw Self.invalid() }
        func read(_ name: String, maximum: Int) throws -> Data {
            let url = root.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, (1...maximum).contains(size) else { throw Self.invalid() }
            return try Data(contentsOf: url)
        }
        let bytes = try read("overlay-manifest.json", maximum: 8192)
        guard Self.digest(bytes) == "a201704550aecb439fb9d5fee36fb7b2e2ebc82dc47b1237e4de94cc08a362ae",
              let manifest = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              manifest["base_runtime_manifest_sha256"] as? String == "560ff976255773573e69ec9eac6832fd993ada286e963307639e0710536d8ce2",
              manifest["runtime_profile"] as? String == "sync-proxy-no-jspi",
              let changes = manifest["runtime_closure_changes"] as? [String], changes.isEmpty,
              let entries = manifest["overlay_files"] as? [String: [String: Any]],
              Set(entries.keys) == Set(["main.js", "worker.js", "stdio.js", "hyotan_runner.py"]) else { throw Self.invalid() }
        var map = base.files; var total = 0
        for (name, entry) in entries {
            guard let count = entry["bytes"] as? Int, (1...16384).contains(count), let hash = entry["sha256"] as? String else { throw Self.invalid() }
            let data = try read(name, maximum: count); total += data.count
            guard total <= 32768, data.count == count, Self.digest(data) == hash else { throw Self.invalid() }
            map[name] = data
        }
        files = map
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func invalid() -> NSError { NSError(domain: "ThreadedPythonCommandAssets", code: 1) }
}
