// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit

/// Separate fixed test runtime. The manifest itself is pinned by checked-in policy.
nonisolated struct ThreadedPythonFoundationAssets: Sendable {
    let files: [String: Data]
    init(bundle: Bundle) throws {
        guard let root = bundle.url(forResource: "ThreadedPythonFoundationTestAssets", withExtension: nil),
              let policyURL = bundle.url(forResource: "threaded-foundation-policy", withExtension: "json"),
              let policy = try JSONSerialization.jsonObject(with: Data(contentsOf: policyURL)) as? [String: Any],
              policy["manifest_sha256"] as? String == "560ff976255773573e69ec9eac6832fd993ada286e963307639e0710536d8ce2",
              let allowed = policy["files"] as? [String] else { throw Self.invalid() }
        let manifestBytes = try Self.regular(root.appendingPathComponent("manifest.json"), maximum: 1_048_576)
        guard Self.digest(manifestBytes) == "560ff976255773573e69ec9eac6832fd993ada286e963307639e0710536d8ce2",
              let manifest = try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any],
              manifest["format_version"] as? Int == 2,
              manifest["runtime_family"] as? String == "vanilla-cpython-pthread-cli",
              manifest["python_version"] as? String == "3.14.2",
              manifest["runtime_profile"] as? String == "sync-proxy-no-jspi",
              manifest["requires_jspi"] as? Bool == false, manifest["optional_cpython_jspi_io"] as? Bool == false,
              manifest["emscripten_asyncify"] as? Int == 0, manifest["trusted_native_preload"] as? Bool == true,
              manifest["pthread_cleanup"] as? Bool == true,
              manifest["custom_abi"] as? String == "pyemscripten_2026_99_wasm32",
              manifest["test_only"] as? Bool == true, manifest["production_enabled"] as? Bool == false,
              let memory = manifest["logical_memory"] as? [String: Any],
              memory["initial_bytes"] as? Int == 20_971_520, memory["maximum_pages"] as? Int == 65_536,
              memory["shared"] as? Bool == true, memory["physical_4GiB_verified"] as? Bool == false,
              let entries = manifest["files"] as? [String: [String: Any]],
              Set(entries.keys) == Set(allowed), allowed.count == Set(allowed).count else { throw Self.invalid() }
        var map: [String: Data] = [:]; var total = 0
        for name in allowed {
            guard !name.isEmpty, name.utf8.count <= 512,
                  name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !name.contains("\\"), !name.contains("%"), !name.contains("\0"),
                  let entry = entries[name], let count = entry["bytes"] as? Int,
                  (1...67_108_864).contains(count), let expected = entry["sha256"] as? String else { throw Self.invalid() }
            var url = root
            let components = name.split(separator: "/")
            for component in components.dropLast() {
                url.appendPathComponent(String(component))
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw Self.invalid() }
            }
            url.appendPathComponent(String(components.last!))
            let bytes = try Self.regular(url, maximum: count)
            total += bytes.count
            guard total <= 268_435_456, bytes.count == count, Self.digest(bytes) == expected else { throw Self.invalid() }
            map[name] = bytes
        }
        guard let inventoryBytes = map["inventory.json"],
              let inventory = try JSONSerialization.jsonObject(with: inventoryBytes) as? [String: Any],
              inventory["custom_abi"] as? String == "pyemscripten_2026_99_wasm32" else { throw Self.invalid() }
        for group in ["files", "native"] {
            guard let items = inventory[group] as? [[String: Any]] else { throw Self.invalid() }
            for item in items {
                guard let url = item["url"] as? String, url.hasPrefix("./"),
                      let bytes = map[String(url.dropFirst(2))], Self.digest(bytes) == item["sha256"] as? String else { throw Self.invalid() }
            }
        }
        let closure = "provenance/vanilla/closure-inspection/runtime-closure-audit.json"
        guard let audit = map[closure], Self.digest(audit) == manifest["closure_audit_sha256"] as? String else { throw Self.invalid() }
        guard let profileBytes = map["provenance/vanilla/no-jspi/profile.json"],
              let profile = try JSONSerialization.jsonObject(with: profileBytes) as? [String: Any],
              profile["profile"] as? String == "sync-proxy-no-jspi",
              profile["actual_compile_flag"] as? String == "-DHYOTAN_ENABLE_OPTIONAL_JSPI_IO=0",
              let source = map["provenance/vanilla/no-jspi/emscripten_syscalls_sync_profile.c"],
              Self.digest(source) == profile["source_patched_sha256"] as? String else { throw Self.invalid() }
        files = map
    }
    private static func regular(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximum else { throw invalid() }
        return try Data(contentsOf: url)
    }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func invalid() -> NSError { NSError(domain: "ThreadedPythonFoundationAssets", code: 1) }
}
