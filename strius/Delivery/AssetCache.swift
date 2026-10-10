import CryptoKit
import Foundation
import OSLog

private let deliveryLog = Logger(subsystem: "com.digiloglab.strius", category: "delivery")

/// Delivered prompts, schemas and model settings (design §5). Every asset is
/// verified by sha256 and cached under `Application Support/struis/assets/`.
/// Turns never fetch: they read the cache, and the manifest is refreshed at
/// launch and from Settings.
nonisolated struct DeliveryManifest: Codable, Hashable, Sendable {
    nonisolated struct Model: Codable, Hashable, Sendable {
        var model: String
        var effort: String
    }

    nonisolated struct Asset: Codable, Hashable, Sendable {
        var sha256: String
        var bytes: Int
        var updatedAt: String
    }

    var codexVersion: String
    /// Legacy Linux clients consume this field. Native builds do not compare it to a native version.
    var rootfsMinVersion: Int
    var models: [String: Model]
    var assets: [String: Asset]
    var fetchedAt: String?

    static let assetNames: [String] = [
        "prompt:base", "prompt:developer", "prompt:agents", "prompt:luna_child", "prompt:delegate_py",
        "prompt:tutor_memory_py", "prompt:reply_lint_py", "prompt:grading_instructions", "prompt:set_instructions",
        "prompt:unit_instructions", "schema:workbook_grading", "schema:workbook_set", "schema:workbook_unit",
        "schema:luna_lookup", "schema:progress_update", "skill:struis_document",
    ]
}

nonisolated enum DeliveryError: Error, LocalizedError, Sendable {
    case notCached(String)
    case checksum(String)
    case manifestMissing

    var errorDescription: String? {
        switch self {
        case .notCached(let name): "配信データ \(name) がまだ端末にありません。設定から更新してください"
        case .checksum(let name): "配信データ \(name) が壊れています"
        case .manifestMissing: "配信データが未取得です"
        }
    }
}

/// Where assets come from.
protocol AssetSource: Sendable {
    func fetchManifest() async throws -> DeliveryManifest
    func fetchAsset(_ name: String) async throws -> Data
}

actor AssetCache {
    nonisolated let root: URL
    /// DEBUG: placeholders instead of errors when nothing was delivered (mock turns).
    nonisolated let lenient: Bool
    private var manifest: DeliveryManifest?
    private var memory: [String: String] = [:]

    init(root: URL = StruisPaths.assets, lenient: Bool = false) {
        self.root = root
        self.lenient = lenient
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")) {
            manifest = try? Self.decoder.decode(DeliveryManifest.self, from: data)
        }
    }

    nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    var currentManifest: DeliveryManifest? { manifest }

    var isReady: Bool {
        guard let manifest else { return false }
        return hasAllRequiredAssets(manifest)
    }

    func model(_ role: String) -> DeliveryManifest.Model {
        if let model = manifest?.models[role] { return model }
        return role == "luna"
            ? DeliveryManifest.Model(model: CodexModels.lunaModel, effort: CodexModels.lunaEffort)
            : DeliveryManifest.Model(model: CodexModels.astraModel, effort: CodexModels.astraEffort)
    }

    /// Reference for a plan: the current sha256 of a named asset.
    func ref(_ name: String, append: String? = nil) throws -> TurnPlan.AssetRef {
        guard let entry = manifest?.assets[name] else {
            if lenient { return TurnPlan.AssetRef(asset: name, sha256: "unavailable", append: append) }
            throw DeliveryError.notCached(name)
        }
        return TurnPlan.AssetRef(asset: name, sha256: entry.sha256, append: append)
    }

    func text(_ name: String) throws -> String {
        if let cached = memory[name] { return cached }
        guard let entry = manifest?.assets[name] else {
            if lenient { return "" }
            throw DeliveryError.notCached(name)
        }
        let url = fileURL(name, sha256: entry.sha256)
        guard let data = try? Data(contentsOf: url) else { throw DeliveryError.notCached(name) }
        guard Self.sha256Hex(data) == entry.sha256 else { throw DeliveryError.checksum(name) }
        guard let text = String(data: data, encoding: .utf8) else { throw DeliveryError.checksum(name) }
        memory[name] = text
        return text
    }

    func text(_ ref: TurnPlan.AssetRef) throws -> String {
        var body = try text(ref.asset)
        if let append = ref.append, !append.isEmpty { body += "\n\n" + append }
        return body
    }

    func json(_ name: String) throws -> LedgerJSON {
        let body = try text(name)
        if body.isEmpty, lenient { return .object(["type": .string("object")]) }
        guard let value = LedgerJSON.parse(body) else { throw DeliveryError.checksum(name) }
        return value
    }

    /// Fetch the manifest and every asset whose sha256 is not cached yet.
    @discardableResult
    func refresh(from source: any AssetSource) async throws -> DeliveryManifest {
        var fetched = try await source.fetchManifest()
        guard DeliveryManifest.assetNames.allSatisfy({ fetched.assets[$0] != nil }) else {
            throw DeliveryError.manifestMissing
        }
        for (name, entry) in fetched.assets {
            let url = fileURL(name, sha256: entry.sha256)
            if let cached = try? Data(contentsOf: url), Self.sha256Hex(cached) == entry.sha256 {
                continue
            }
            let data = try await source.fetchAsset(name)
            guard Self.sha256Hex(data) == entry.sha256 else { throw DeliveryError.checksum(name) }
            try data.write(to: url, options: .atomic)
            deliveryLog.info("cached asset \(name, privacy: .public) (\(data.count) bytes)")
        }
        guard hasAllRequiredAssets(fetched) else { throw DeliveryError.manifestMissing }
        fetched.fetchedAt = LedgerClock.now()
        manifest = fetched
        memory.removeAll()
        try Self.encoder.encode(fetched).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        pruneStale(keeping: fetched)
        return fetched
    }

    private func hasAllRequiredAssets(_ manifest: DeliveryManifest) -> Bool {
        DeliveryManifest.assetNames.allSatisfy { name in
            guard let entry = manifest.assets[name],
                  let data = try? Data(contentsOf: fileURL(name, sha256: entry.sha256))
            else { return false }
            return Self.sha256Hex(data) == entry.sha256
        }
    }

    private func pruneStale(keeping manifest: DeliveryManifest) {
        let keep = Set(manifest.assets.map { fileURL($0.key, sha256: $0.value.sha256).lastPathComponent })
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent != "manifest.json" && !keep.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    nonisolated private func fileURL(_ name: String, sha256: String) -> URL {
        root.appendingPathComponent(name.replacingOccurrences(of: ":", with: "-") + "-" + sha256.prefix(16))
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Delivery GETs use either the build's app key or the learner's Bearer token.
@MainActor
struct ServerAssetSource: AssetSource {
    let client: APIClient

    nonisolated init(client: APIClient) {
        self.client = client
    }

    func fetchManifest() async throws -> DeliveryManifest {
        try await client.send(Self.endpoint(path: "/v1/device-runtime/manifest"))
    }

    func fetchAsset(_ name: String) async throws -> Data {
        // APIClient appends the endpoint path as a URL path component, which
        // performs the required escaping. Pre-escaping here turns `:` into
        // `%253A` and makes every named delivery asset return 404.
        return try await client.fetchData(Self.endpoint(path: Self.assetPath(name))).data
    }

    static func endpoint(path: String) -> APIEndpoint {
        var endpoint = APIEndpoint(method: .get, path: path, requiresAuth: Auth0Config.authenticationRequired)
        if !Auth0Config.authenticationRequired { endpoint.deliveryAppKey = ServerConfig.deliveryAppKey }
        return endpoint
    }

    nonisolated static func assetPath(_ name: String) -> String {
        "/v1/device-runtime/assets/\(name)"
    }
}

#if DEBUG
/// Development source: read the prompt files straight from a checkout
/// (`STRUIS_DEVICE_ASSETS_DIR=<repo>/backend/coach`) so the simulator can run
/// turns without a server. Mirrors `backend/src/struis/services/device_assets.py`.
nonisolated struct LocalDirectoryAssetSource: AssetSource {
    let root: URL

    static var fromEnvironment: LocalDirectoryAssetSource? {
        guard let path = ProcessInfo.processInfo.environment["STRUIS_DEVICE_ASSETS_DIR"], !path.isEmpty else { return nil }
        return LocalDirectoryAssetSource(root: URL(fileURLWithPath: path))
    }

    static let files: [String: String] = [
        "prompt:base": "app_server/base_instructions.md",
        "prompt:developer": "app_server/developer_instructions.md",
        "prompt:agents": "app_server/AGENTS.md",
        "prompt:luna_child": "app_server/luna_child_instructions.md",
        "prompt:delegate_py": "app_server/delegate.py",
        "prompt:tutor_memory_py": "app_server/struis_tutor_memory.py",
        "prompt:reply_lint_py": "app_server/struis_reply_lint.py",
        "prompt:grading_instructions": "app_server/grading_instructions.md",
        "prompt:set_instructions": "app_server/set_instructions.md",
        "prompt:unit_instructions": "app_server/unit_instructions.md",
        "schema:workbook_grading": "device_runtime/schemas/workbook_grading.json",
        "schema:workbook_set": "device_runtime/schemas/workbook_set.json",
        "schema:workbook_unit": "device_runtime/schemas/workbook_unit.json",
        "schema:luna_lookup": "device_runtime/schemas/luna_lookup.json",
        "schema:progress_update": "device_runtime/schemas/progress_update.json",
        "skill:struis_document": "app_server/skills/struis-document/SKILL.md",
    ]

    func fetchManifest() async throws -> DeliveryManifest {
        var assets: [String: DeliveryManifest.Asset] = [:]
        for (name, relative) in Self.files {
            let data = try Data(contentsOf: root.appendingPathComponent(relative))
            assets[name] = DeliveryManifest.Asset(sha256: AssetCache.sha256Hex(data), bytes: data.count, updatedAt: "local")
        }
        return DeliveryManifest(
            codexVersion: "0.153.4", rootfsMinVersion: 1,
            models: [
                "astra": DeliveryManifest.Model(model: CodexModels.astraModel, effort: CodexModels.astraEffort),
                "luna": DeliveryManifest.Model(model: CodexModels.lunaModel, effort: CodexModels.lunaEffort),
            ],
            assets: assets, fetchedAt: nil
        )
    }

    func fetchAsset(_ name: String) async throws -> Data {
        guard let relative = Self.files[name] else { throw DeliveryError.notCached(name) }
        return try Data(contentsOf: root.appendingPathComponent(relative))
    }
}
#endif
