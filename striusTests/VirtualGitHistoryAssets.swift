// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
@testable import strius

/// Independent compiled allowlist. No caller-selected filenames or stock inventory changes.
nonisolated struct VirtualGitHistoryAssets: Sendable {
    static let pins: [String: (String, Int)] = [
        "loader.js": ("bb8654977d5d50dcabafde26e95739ec7cb6a4f9167a1f25487e0780bd7671f0", 1463),
        "packages.zip": ("2fae1c45e4b7f6894b8792d95c9c7286615b3d38262e421161701a485589dfb1", 830309),
        "hyotan_history.py": ("5f5ccdc16b450ed610631a271e027d5ad581e46a40eb3fc5c4a4eb25c48d4502", 5801),
        "hyotan_virtual_git.py": ("21b77679e1697d3d35daa52c68e206c021fe300b580e235a276feabf5bab6b64", 486),
        "Licenses/Dulwich.txt": ("e17db6e0f06d3a70a9a6a6e4e1b85c6dfaa2c7d0154147c798435e333f4b366d", 29573),
        "Licenses/urllib3.txt": ("130e3a64d5fdd5d096a752694634a7d9df284469de86e5732100268041e3d686", 1093),
    ]
    let files: [String: Data]
    init(bundle: Bundle) throws {
        guard let root = bundle.url(forResource: "VirtualPythonGitTestAssets", withExtension: nil),
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any],
              manifest["format_version"] as? Int == 1,
              manifest["packages"] as? [String: String] == ["dulwich": "1.2.15", "urllib3": "2.8.0"],
              manifest["selected_licenses"] as? [String: String] == ["dulwich": "Apache-2.0", "urllib3": "MIT"],
              let entries = manifest["files"] as? [String: [String: Any]], Set(entries.keys) == Set(Self.pins.keys)
        else { throw NSError(domain: "VirtualGitHistoryAssets", code: 1) }
        var loaded: [String: Data] = [:]
        for (name, (sha, count)) in Self.pins {
            guard entries[name]?["sha256"] as? String == sha, entries[name]?["bytes"] as? Int == count else { throw NSError(domain: "VirtualGitHistoryAssets", code: 2) }
            let path = root.appendingPathComponent(name)
            let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == count else { throw NSError(domain: "VirtualGitHistoryAssets", code: 3) }
            let data = try Data(contentsOf: path)
            guard data.count == count, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha else { throw NSError(domain: "VirtualGitHistoryAssets", code: 4) }
            loaded["git/" + name] = data
        }
        files = loaded
    }
}
