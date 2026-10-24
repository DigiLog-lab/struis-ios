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
        /// 実行先。nil は OpenAI(従来の配信と互換)。
        var provider: ModelProvider? = nil
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
    /// アプリに同梱した prompt・schema(配信の manifest に無い時に使う)。
    nonisolated let bundled: BundledAssets
    private var manifest: DeliveryManifest?
    private var memory: [String: String] = [:]

    init(root: URL = StruisPaths.assets, lenient: Bool = false, bundled: BundledAssets = .main) {
        self.root = root
        self.lenient = lenient
        self.bundled = bundled
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

    /// 役割(`astra` / `luna` / `timeline` / `timeline_graph`)のモデル。`provider` を省くと設定画面で選んだ実行先を使う。
    func model(_ role: String, provider: ModelProvider = ModelProviderPreference.current) -> DeliveryManifest.Model {
        if let fallback = TimelineModels.fallback(role: role, provider: provider) {
            // タイムラインは別名で指す(配信の manifest に別名があればそれ、無ければ同梱の既定)。
            var model = manifest?.models[provider.manifestKey(role: role)] ?? fallback
            model.provider = provider == .anthropic ? .anthropic : nil
            return model
        }
        switch provider {
        case .openai:
            if var model = manifest?.models[role] {
                model.provider = nil
                return model
            }
            return role == "luna"
                ? DeliveryManifest.Model(model: CodexModels.lunaModel, effort: CodexModels.lunaEffort)
                : DeliveryManifest.Model(model: CodexModels.astraModel, effort: CodexModels.astraEffort)
        case .anthropic:
            var model = manifest?.models[provider.manifestKey(role: role)] ?? (role == "luna"
                ? DeliveryManifest.Model(model: ClaudeModels.lunaModel, effort: ClaudeModels.lunaEffort)
                : DeliveryManifest.Model(model: ClaudeModels.astraModel, effort: ClaudeModels.astraEffort))
            model.provider = .anthropic
            return model
        }
    }

    /// Reference for a plan: the current sha256 of a named asset. 配信に無い名前は同梱版を使う(sha256 は同梱ファイルから計算)。
    func ref(_ name: String, append: String? = nil) throws -> TurnPlan.AssetRef {
        guard let entry = manifest?.assets[name] else {
            if let bundled = bundled.data(name) { return TurnPlan.AssetRef(asset: name, sha256: Self.sha256Hex(bundled), append: append) }
            if lenient { return TurnPlan.AssetRef(asset: name, sha256: "unavailable", append: append) }
            throw DeliveryError.notCached(name)
        }
        return TurnPlan.AssetRef(asset: name, sha256: entry.sha256, append: append)
    }

    func text(_ name: String) throws -> String {
        if let cached = memory[name] { return cached }
        guard let entry = manifest?.assets[name] else {
            // 配信の manifest に無ければ同梱版。サーバーへ移す時は同じファイルを配信に載せれば、配信版が優先される。
            if let bundled = bundled.data(name), let text = String(data: bundled, encoding: .utf8) {
                memory[name] = text
                return text
            }
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

/// アプリに同梱した prompt・schema・Skill(Issue #46)。配信と同じ名前(`prompt:` / `schema:` / `skill:`)で引く。
/// 同梱分は `DeliveryManifest.assetNames`(必須の一覧)に入れない: 入れるとサーバーが対応するまで `refresh` が
/// `manifestMissing` で失敗し、配信の更新が全部止まる。
nonisolated struct BundledAssets: Sendable {
    /// 同梱ファイルの置き場(アプリの `Prompts/`)。
    let root: URL?

    static let main = BundledAssets(root: Bundle.main.url(forResource: "Prompts", withExtension: nil))

    /// 名前と同梱ファイルの対応表。
    static let files: [String: String] = [
        "prompt:timeline_shared": "timeline_shared.md",
        "prompt:timeline_instructions": "timeline_instructions.md",
        "prompt:timeline_grading_instructions": "timeline_grading_instructions.md",
        "prompt:timeline_graph_instructions": "timeline_graph_instructions.md",
        "prompt:timeline_decompose_instructions": "timeline_decompose_instructions.md",
        "prompt:timeline_misconceptions_instructions": "timeline_misconceptions_instructions.md",
        "prompt:timeline_review_instructions": "timeline_review_instructions.md",
        "schema:timeline_batch": "timeline_batch.json",
        "schema:timeline_grading": "timeline_grading.json",
        "schema:timeline_graph": "timeline_graph.json",
        "schema:timeline_decompose": "timeline_decompose.json",
        "schema:timeline_misconceptions": "timeline_misconceptions.json",
        "schema:timeline_review": "timeline_review.json",
        "skill:timeline_query": "skills/timeline-query/SKILL.md",
    ]

    static var names: [String] { files.keys.sorted() }

    func url(_ name: String) -> URL? {
        guard let root, let relative = Self.files[name] else { return nil }
        return root.appendingPathComponent(relative)
    }

    func data(_ name: String) -> Data? {
        url(name).flatMap { try? Data(contentsOf: $0) }
    }
}

/// タイムラインのモデルの別名(Issue #46)。配信の manifest に別名(`timeline` / `claude:timeline` など)があればそちら。
/// 実行先が OpenAI の時は astra の別名ではなく GPT-6.1 Sol を使う(2026-10-23 の指示)。
nonisolated enum TimelineModels {
    /// 次の5枚と採点。
    static let role = "timeline"
    /// 知識グラフを作る・見直す上位モデル。
    static let graphRole = "timeline_graph"
    static let openAIModel = "gpt-6.1-sol"

    static func fallback(role: String, provider: ModelProvider) -> DeliveryManifest.Model? {
        switch (role, provider) {
        case (Self.role, .anthropic): DeliveryManifest.Model(model: "claude-sonnet-5-5", effort: "low")
        case (Self.graphRole, .anthropic): DeliveryManifest.Model(model: "claude-opus-5-5", effort: "medium")
        case (Self.role, .openai): DeliveryManifest.Model(model: openAIModel, effort: "low")
        case (Self.graphRole, .openai): DeliveryManifest.Model(model: openAIModel, effort: "medium")
        default: nil
        }
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
