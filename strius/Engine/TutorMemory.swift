import Foundation
import Yams

// Port of backend/src/struis/services/tutor_memory.py: embedded update
// extraction, queueing, validation (`_shape_payload`), application to the
// canonical `tutor_desk` YAML files, manifest/snapshot helpers and the session
// staging.  `stage_tutor_memory_context` (legacy DB inputs) is intentionally not
// ported; `stageSession` writes the same `current/session.yaml` / `current/task.yaml`.
//
// YAML is written like `yaml.safe_dump(allow_unicode=True, sort_keys=False,
// default_flow_style=False)`: key order preserved, block style, strings that
// would resolve to another type single-quoted.

// MARK: - YAML bridge

nonisolated enum EngineYAML {
    /// Parses one YAML document into an order-preserving value (`yaml.safe_load`).
    static func load(_ text: String) throws -> EngineJSON {
        guard let node = try Yams.compose(yaml: text) else { return .null }
        return try value(from: node)
    }

    static func value(from node: Node) throws -> EngineJSON {
        switch node {
        case .scalar(let scalar):
            let tag = Resolver.default.resolveTag(of: node)
            let string = scalar.string
            if scalar.style != .plain && scalar.style != .any { return .string(string) }
            switch tag {
            case .null: return .null
            case .bool:
                if let value = node.bool { return .bool(value) }
                return .string(string)
            case .int:
                if let value = node.int { return .integer(value) }
                return .string(string)
            case .float:
                if let value = node.float { return .number(value) }
                return .string(string)
            default:
                return .string(string)
            }
        case .sequence(let sequence):
            return .array(try sequence.map { try value(from: $0) })
        case .mapping(let mapping):
            var object = EngineObject()
            for (key, item) in mapping {
                let keyText: String
                if case .scalar(let scalar) = key { keyText = scalar.string } else { keyText = try value(from: key).serialized() }
                object[keyText] = try value(from: item)
            }
            return .object(object)
        case .alias:
            throw EngineError("YAML aliases are not supported")
        }
    }

    /// `yaml.safe_dump(value, allow_unicode=True, sort_keys=False, default_flow_style=False)`.
    static func dump(_ value: EngineJSON) throws -> String {
        try Yams.serialize(node: node(from: value), allowUnicode: true)
    }

    static func node(from value: EngineJSON) -> Node {
        switch value {
        case .null: return .scalar(.init("null", Tag(.null), .plain))
        case .bool(let b): return .scalar(.init(b ? "true" : "false", Tag(.bool), .plain))
        case .integer(let i): return .scalar(.init(String(i), Tag(.int), .plain))
        case .number(let d): return .scalar(.init(pythonYAMLFloat(d), Tag(.float), .plain))
        case .string(let s): return .scalar(.init(s, Tag(.str), scalarStyle(for: s)))
        case .array(let items):
            return .sequence(.init(items.map(node(from:)), Tag(.seq), items.isEmpty ? .flow : .block))
        case .object(let object):
            let pairs = object.pairs.map { (Node.scalar(.init($0.0, Tag(.str), scalarStyle(for: $0.0))), node(from: $0.1)) }
            return .mapping(.init(pairs, Tag(.map), object.isEmpty ? .flow : .block))
        }
    }

    static func scalarStyle(for string: String) -> Node.Scalar.Style {
        if string.isEmpty { return .singleQuoted }
        if Resolver.default.resolveTag(of: .scalar(.init(string))) != .str { return .singleQuoted }
        if string.contains("\n") { return .doubleQuoted }
        return .any
    }

    /// PyYAML float representation (`repr`, with `.0` and `e-05` style exponents).
    static func pythonYAMLFloat(_ d: Double) -> String {
        if d.isNaN { return ".nan" }
        if d.isInfinite { return d > 0 ? ".inf" : "-.inf" }
        var text = EngineJSON.pythonFloatRepr(d)
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            var mantissa = String(text[..<e])
            if !mantissa.contains(".") { mantissa += ".0" }
            text = mantissa + text[e...]
        }
        return text
    }
}

// MARK: - SHA-256 (Foundation-only)

nonisolated enum EngineSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hexDigest(_ data: Data) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}

// MARK: - Tutor memory

nonisolated enum TutorMemory {
    typealias JSONObject = [String: Any]

    static let memorySchemaVersion = 1
    static let maxQueueFiles = 5
    static let maxQueueFileBytes = 64 * 1024
    static let maxItemsPerSection = 20
    static let maxTextLength = 1200
    static let maxInjectedMemoryChars = 24_000
    static let memoryUpdateOpen = "<struis_memory_update>"
    static let memoryUpdateClose = "</struis_memory_update>"

    static let allowedEvidenceTypes: Set<String> = ["attempt", "chat_message", "observation", "study_progress_event"]
    static let allowedObservationKinds: Set<String> = ["learner_report", "performance", "preference", "goal", "correction", "context"]
    static let allowedSkillDimensions: Set<String> = [
        "conceptual_understanding", "method_selection", "first_step_independence", "procedural_execution", "accuracy", "fluency",
        "hint_dependence", "transfer", "self_correction", "delayed_retention",
    ]
    static let allowedClaimStatuses: Set<String> = ["tentative", "supported"]
    static let allowedLearnerCategories: Set<String> = ["profile", "active_goal", "preference"]

    static let memoryUpdatePattern = try! NSRegularExpression(pattern: "<struis_memory_update>\\s*(.*?)\\s*</struis_memory_update>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    static let unclosedPattern = try! NSRegularExpression(pattern: "<struis_memory_update>.*$", options: [.caseInsensitive, .dotMatchesLineSeparators])
    static let strayTagPattern = try! NSRegularExpression(pattern: "</?struis_memory_update>", options: [.caseInsensitive])

    static let fm = FileManager.default

    // MARK: extraction & queueing

    /// `extract_embedded_memory_update(text) -> (visible, payload, error)`.
    static func extractEmbeddedMemoryUpdate(_ text: String) -> (visible: String, payload: String?, error: String?) {
        let ns = text as NSString
        let matches = memoryUpdatePattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var visible = memoryUpdatePattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        visible = unclosedPattern.stringByReplacingMatches(in: visible, range: NSRange(location: 0, length: (visible as NSString).length), withTemplate: "")
        visible = EnginePyText.strip(strayTagPattern.stringByReplacingMatches(in: visible, range: NSRange(location: 0, length: (visible as NSString).length), withTemplate: ""))
        if matches.isEmpty { return (visible, nil, nil) }
        if matches.count != 1 { return (visible, nil, "multiple embedded memory updates were emitted") }
        let payload = EnginePyText.strip(ns.substring(with: matches[0].range(at: 1)))
        if payload.isEmpty { return (visible, nil, "embedded memory update was empty") }
        if payload.utf8.count > maxQueueFileBytes { return (visible, nil, "embedded memory update was too large") }
        return (visible, payload, nil)
    }

    /// `queue_embedded_memory_update`: writes `queue/memory/<turn>-embedded-<hex>.yaml` under the desk.
    @discardableResult
    static func queueEmbeddedMemoryUpdate(desk: URL, turnRunID: String, payload: String) throws -> URL {
        let queue = desk.appendingPathComponent("queue/memory", isDirectory: true)
        try fm.createDirectory(at: queue, withIntermediateDirectories: true)
        let path = queue.appendingPathComponent("\(turnRunID)-embedded-\(uuidHex()).yaml")
        try Data((EnginePyText.rstrip(payload) + "\n").utf8).write(to: path)
        return path
    }

    static func uuidHex() -> String { UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") }
    static func uuidString() -> String { UUID().uuidString.lowercased() }

    // MARK: files

    static let readmeText = "# Tutor Desk memory\n\n"
        + "`current/`, `evidence/recent.yaml`, `skills/system.yaml`, and "
        + "`learner/dossier.yaml` are backend-owned observations.\n"
        + "`skills/inferences.yaml`, learner claims, plans, and model evidence are "
        + "durable conclusions that were accepted from evidence-backed updates.\n\n"
        + "Never edit canonical durable files directly. When new evidence would change "
        + "future teaching, create one YAML draft and run:\n\n"
        + "`python scripts/struis_tutor_memory.py submit --file <draft.yaml>`\n\n"
        + "The backend validates ownership, source IDs, evidence references, dimensions, "
        + "and supersession before applying it. Do not store hidden reasoning.\n"

    static func writeYAML(_ url: URL, _ value: EngineJSON) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(try EngineYAML.dump(value).utf8).write(to: url)
    }

    static func readYAMLMapping(_ url: URL, default defaultValue: EngineObject) throws -> EngineObject {
        guard fm.fileExists(atPath: url.path) else { return defaultValue }
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        return try EngineYAML.load(text).objectValue ?? defaultValue
    }

    static func writeYAMLIfMissing(_ url: URL, _ value: EngineJSON) throws {
        if !fm.fileExists(atPath: url.path) { try writeYAML(url, value) }
    }

    static func trim(_ value: String, limit: Int = maxTextLength) -> String {
        let text = EnginePyText.strip(value)
        return EnginePyText.length(text) <= limit ? text : EnginePyText.prefix(text, limit - 1) + "…"
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) || isSymlink(url) }

    static func relative(_ url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
    }

    /// Files under `root` (recursive), sorted by relative path like Python's sorted `rglob`.
    static func filesRecursive(_ root: URL, suffix: String? = nil) -> [URL] {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if let suffix, !url.lastPathComponent.hasSuffix(suffix) { continue }
            if isRegularFile(url) && !isSymlink(url) { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// `ensure_tutor_memory_files` (without the delivered `scripts/struis_tutor_memory.py`).
    @discardableResult
    static func ensureTutorMemoryFiles(desk: URL, learnerID: String) throws -> URL {
        for relative in ["learner", "goals", "current", "skills", "evidence/model", "interventions", "plans/archive", "review", "drafts",
                         "queue/memory/applied", "queue/memory/rejected"] {
            try fm.createDirectory(at: desk.appendingPathComponent(relative, isDirectory: true), withIntermediateDirectories: true)
        }
        try Data(readmeText.utf8).write(to: desk.appendingPathComponent("README.md"))
        let base: [(String, EngineJSON)] = [("schema_version", .integer(memorySchemaVersion)), ("learner_id", .string(learnerID)),
                                           ("prototype_user_id", .string(learnerID)), ("updated_at", .null)]
        func doc(_ extra: [(String, EngineJSON)]) -> EngineJSON { .object(EngineObject(base + extra)) }
        try writeYAMLIfMissing(desk.appendingPathComponent("learner/profile.yaml"), doc([("claims", .array([]))]))
        try writeYAMLIfMissing(desk.appendingPathComponent("learner/preferences.yaml"), doc([("claims", .array([]))]))
        try writeYAMLIfMissing(desk.appendingPathComponent("learner/open_questions.yaml"), doc([("questions", .array([]))]))
        try writeYAMLIfMissing(desk.appendingPathComponent("goals/current.yaml"), doc([("claims", .array([]))]))
        try writeYAMLIfMissing(desk.appendingPathComponent("skills/inferences.yaml"), doc([("claims", .array([]))]))
        try writeYAMLIfMissing(desk.appendingPathComponent("plans/current.yaml"),
                               doc([("plan", .null), ("note", .string("No evidence-backed next plan has been saved yet."))]))
        try writeYAMLIfMissing(desk.appendingPathComponent("review/schedule.yaml"),
                               doc([("items", .array([])), ("note", .string("Review timing remains unconfirmed."))]))
        return desk
    }

    /// `render_tutor_memory_context(workspace_path)`; `workspace` contains `tutor_desk/`.
    /// `only` limits the sections to these desk-relative paths; `excluding` drops them (reliability plan
    /// P1-3 sends the per-turn session record every turn and the durable rest only when it changed).
    static func renderTutorMemoryContext(workspace: URL, only: Set<String>? = nil, excluding: Set<String> = []) throws -> String {
        UnitDeletion.gate.lock(); defer { UnitDeletion.gate.unlock() }
        let desk = workspace.appendingPathComponent("tutor_desk", isDirectory: true)
        var paths = ["current/deletions.yaml", "current/session.yaml", "current/task.yaml", "goals/current.yaml", "learner/profile.yaml", "learner/preferences.yaml",
                     "learner/open_questions.yaml", "skills/inferences.yaml", "plans/current.yaml", "evidence/recent.yaml", "skills/system.yaml",
                     "learner/dossier.yaml"].filter { (only?.contains($0) ?? true) && !excluding.contains($0) }.map { desk.appendingPathComponent($0) }
        let interventions = desk.appendingPathComponent("interventions", isDirectory: true)
        if only == nil, exists(interventions) {
            let candidates = ((try? fm.contentsOfDirectory(at: interventions, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "yaml" }
                .sorted { $0.path > $1.path }
            paths.append(contentsOf: candidates.prefix(4))
        }
        let plansCurrent = desk.appendingPathComponent("plans/current.yaml")
        var sections: [String] = []
        var used = 0
        for path in paths {
            if !isRegularFile(path) || isSymlink(path) { continue }
            let relative = relative(path, to: workspace)
            let body: String
            if path.standardizedFileURL.path == plansCurrent.standardizedFileURL.path {
                var document = try readYAMLMapping(path, default: .init())
                document["learning_progress"] = nil
                body = EnginePyText.strip(EnginePyText.prefix(try EngineYAML.dump(.object(document)), 6000))
            } else {
                body = EnginePyText.strip(EnginePyText.prefix(String(decoding: try Data(contentsOf: path), as: UTF8.self), 6000))
            }
            var section = "--- \(relative) ---\n\(body)\n"
            let remaining = maxInjectedMemoryChars - used
            if remaining <= 0 { break }
            if EnginePyText.length(section) > remaining {
                section = EnginePyText.rstrip(EnginePyText.prefix(section, remaining)) + "\n[truncated]\n"
            }
            sections.append(section)
            used += EnginePyText.length(section)
        }
        return EnginePyText.strip(sections.joined(separator: "\n"))
    }

    struct MemoryManifest: Equatable {
        var digest: String
        var files: [String: String]
    }

    /// `model_memory_manifest(workspace_path)`.
    static func modelMemoryManifest(workspace: URL) throws -> MemoryManifest {
        let desk = workspace.appendingPathComponent("tutor_desk", isDirectory: true)
        var candidates: [URL] = []
        for relative in ["current/deletions.yaml", "learner/profile.yaml", "learner/preferences.yaml", "learner/open_questions.yaml", "goals/current.yaml",
                         "skills/inferences.yaml", "plans/current.yaml", "review/schedule.yaml"] {
            let path = desk.appendingPathComponent(relative)
            if isRegularFile(path) { candidates.append(path) }
        }
        for relative in ["evidence/model", "interventions", "plans/archive"] {
            let root = desk.appendingPathComponent(relative, isDirectory: true)
            if exists(root) { candidates.append(contentsOf: filesRecursive(root, suffix: ".yaml")) }
        }
        var files: [String: String] = [:]
        for path in Set(candidates.map(\.standardizedFileURL)).sorted(by: { $0.path < $1.path }) {
            files[relative(path, to: workspace)] = EngineSHA256.hexDigest(try Data(contentsOf: path))
        }
        let joined = files.keys.sorted().map { "\($0):\(files[$0]!)" }.joined(separator: "\n")
        return MemoryManifest(digest: EngineSHA256.hexDigest(Data(joined.utf8)), files: files)
    }

    /// `_protected_memory_paths`.
    static func protectedMemoryPaths(workspace: URL) -> Set<URL> {
        let desk = workspace.appendingPathComponent("tutor_desk", isDirectory: true)
        var paths = Set<URL>()
        for name in ["README.md", "student.md"] {
            let path = desk.appendingPathComponent(name)
            if isRegularFile(path) || isSymlink(path) { paths.insert(path.standardizedFileURL) }
        }
        for relative in ["current", "learner", "goals", "skills", "evidence", "interventions", "plans", "review"] {
            let root = desk.appendingPathComponent(relative, isDirectory: true)
            if isSymlink(root) {
                paths.insert(root.standardizedFileURL)
            } else if exists(root), let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: []) {
                for case let url as URL in enumerator where isRegularFile(url) || isSymlink(url) { paths.insert(url.standardizedFileURL) }
            }
        }
        return paths
    }

    /// `protected_memory_snapshot`: relative path -> bytes.
    static func protectedMemorySnapshot(workspace: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for path in protectedMemoryPaths(workspace: workspace).sorted(by: { $0.path < $1.path }) {
            if isSymlink(path) { throw EngineError("protected tutor memory path is a symlink: \(path.path)") }
            snapshot[relative(path, to: workspace)] = try Data(contentsOf: path)
        }
        return snapshot
    }

    /// `restore_protected_memory_snapshot`; returns the sorted list of changed relative paths.
    static func restoreProtectedMemorySnapshot(workspace: URL, snapshot: [String: Data]) throws -> [String] {
        var currentPaths: [String: URL] = [:]
        for path in protectedMemoryPaths(workspace: workspace) { currentPaths[relative(path, to: workspace)] = path }
        var changed = Set<String>()
        for (relative, path) in currentPaths {
            guard let expected = snapshot[relative] else {
                try fm.removeItem(at: path)
                changed.insert(relative)
                continue
            }
            if try isSymlink(path) || Data(contentsOf: path) != expected {
                try fm.removeItem(at: path)
                try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try expected.write(to: path)
                changed.insert(relative)
            }
        }
        for (relative, contents) in snapshot where currentPaths[relative] == nil {
            let path = workspace.appendingPathComponent(relative)
            let rootPath = workspace.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(rootPath) else {
                throw EngineError("protected tutor memory snapshot escapes workspace: \(relative)")
            }
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: path)
            changed.insert(relative)
        }
        return changed.sorted()
    }

    // MARK: validation (`_shape_payload`)

    /// Python `str(value or "")` for YAML scalars.
    static func pyStrOrEmpty(_ value: EngineJSON?) -> String {
        guard let value, value.isTruthy else { return "" }
        return TurnProgress.pyStr(value)
    }

    static func requireText(_ value: EngineJSON?, _ field: String, limit: Int = maxTextLength) throws -> String {
        let text = EnginePyText.strip(pyStrOrEmpty(value))
        if text.isEmpty { throw EngineError("\(field) is required") }
        if EnginePyText.length(text) > limit { throw EngineError("\(field) is too long") }
        return text
    }

    static func confidence(_ value: EngineJSON?, _ field: String) throws -> Double {
        let number: Double
        switch value {
        case .integer(let i)?: number = Double(i)
        case .number(let d)?: number = d
        case .bool(let b)?: number = b ? 1 : 0
        case .string(let s)?:
            guard let parsed = Double(EnginePyText.strip(s)) else { throw EngineError("\(field) must be a number") }
            number = parsed
        default: throw EngineError("\(field) must be a number")
        }
        if number < 0 || number > 1 { throw EngineError("\(field) must be between 0 and 1") }
        return (number * 1000).rounded(.toNearestOrEven) / 1000
    }

    static func items(_ payload: EngineObject, _ field: String) throws -> [EngineObject] {
        guard let value = payload[field], !value.isNull else { return [] }
        guard let list = value.arrayValue, list.count <= maxItemsPerSection else { throw EngineError("\(field) must be a short list") }
        let objects = list.compactMap(\.objectValue)
        if objects.count != list.count { throw EngineError("\(field) items must be mappings") }
        return objects
    }

    /// Python `uuid.UUID(str)` acceptance; returns the canonical lowercase hyphenated form.
    static func pyUUID(_ text: String) -> String? {
        var hex = text.replacingOccurrences(of: "urn:", with: "").replacingOccurrences(of: "uuid:", with: "")
        hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        let lower = hex.lowercased()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range -> String in
            let start = lower.index(lower.startIndex, offsetBy: range.lowerBound)
            let end = lower.index(lower.startIndex, offsetBy: range.upperBound)
            return String(lower[start..<end])
        }
        return parts.joined(separator: "-")
    }

    static func evidenceRefs(_ value: EngineJSON?, _ field: String) throws -> [EngineObject] {
        guard let list = value?.arrayValue, !list.isEmpty, list.count <= 12 else { throw EngineError("\(field) must contain evidence references") }
        var refs: [EngineObject] = []
        for item in list {
            guard let object = item.objectValue else { throw EngineError("\(field) contains an invalid reference") }
            let refType = EnginePyText.strip(pyStrOrEmpty(object["type"]))
            let refID = EnginePyText.strip(pyStrOrEmpty(object["id"]))
            if !allowedEvidenceTypes.contains(refType) { throw EngineError("\(field) contains an invalid evidence type") }
            if pyUUID(refID) == nil { throw EngineError("\(field) contains an invalid evidence id") }
            refs.append(EngineObject([("type", .string(refType)), ("id", .string(refID))]))
        }
        return refs
    }

    static func supersedes(_ value: EngineJSON?, _ field: String) throws -> [String] {
        guard let value, !value.isNull else { return [] }
        guard let list = value.arrayValue, list.count <= 12 else { throw EngineError("\(field) must be a short list") }
        return try list.map {
            guard let id = pyUUID(TurnProgress.pyStr($0)) else { throw EngineError("\(field) contains an invalid claim id") }
            return id
        }
    }

    /// `_shape_payload(payload, expected=...)`. `expected` keys: learner_id, thread_id, turn_run_id, user_message_id.
    static func shapePayload(payload: EngineJSON, expected: [(String, String)]) throws -> EngineObject {
        guard let object = payload.objectValue else { throw EngineError("memory update must be a YAML mapping") }
        let allowed: Set<String> = ["schema_version", "source", "future_teaching_change", "observations", "skill_inferences", "learner_updates",
                                    "unknowns", "plan", "intervention"]
        let unexpected = object.keys.filter { !allowed.contains($0) }.sorted()
        if !unexpected.isEmpty {
            throw EngineError("unexpected keys: [\(unexpected.map { LearningProgress.pythonRepr($0) }.joined(separator: ", "))]")
        }
        guard let version = object["schema_version"], version.doubleValue == Double(memorySchemaVersion) || version == .bool(true) else {
            throw EngineError("schema_version must be 1")
        }
        guard let source = object["source"]?.objectValue else { throw EngineError("source is required") }
        for (key, value) in expected where pyStrOrEmpty(source[key]) != value {
            throw EngineError("source.\(key) does not match the active turn")
        }
        var shaped = EngineObject()
        shaped["schema_version"] = .integer(memorySchemaVersion)
        shaped["source"] = .object(EngineObject(expected.map { ($0.0, .string($0.1)) }))
        shaped["future_teaching_change"] = .string(try requireText(object["future_teaching_change"], "future_teaching_change"))
        var observations: [EngineJSON] = []
        for (index, item) in try items(object, "observations").enumerated() {
            let kind = EnginePyText.strip(pyStrOrEmpty(item["kind"]))
            if !allowedObservationKinds.contains(kind) { throw EngineError("observations[\(index)].kind is invalid") }
            observations.append(.object(EngineObject([
                ("kind", .string(kind)),
                ("summary", .string(try requireText(item["summary"], "observations[\(index)].summary"))),
                ("evidence_refs", .array(try evidenceRefs(item["evidence_refs"], "observations[\(index)].evidence_refs").map { .object($0) })),
            ])))
        }
        shaped["observations"] = .array(observations)
        var skills: [EngineJSON] = []
        for (index, item) in try items(object, "skill_inferences").enumerated() {
            let dimension = EnginePyText.strip(pyStrOrEmpty(item["dimension"]))
            let status = EnginePyText.strip(item["status"].map { $0.isTruthy ? TurnProgress.pyStr($0) : "tentative" } ?? "tentative")
            if !allowedSkillDimensions.contains(dimension) { throw EngineError("skill_inferences[\(index)].dimension is invalid") }
            if !allowedClaimStatuses.contains(status) { throw EngineError("skill_inferences[\(index)].status is invalid") }
            skills.append(.object(EngineObject([
                ("topic", .string(try requireText(item["topic"], "skill_inferences[\(index)].topic", limit: 240))),
                ("dimension", .string(dimension)),
                ("statement", .string(try requireText(item["statement"], "skill_inferences[\(index)].statement"))),
                ("confidence", .number(try confidence(item["confidence"], "skill_inferences[\(index)].confidence"))),
                ("status", .string(status)),
                ("evidence_refs", .array(try evidenceRefs(item["evidence_refs"], "skill_inferences[\(index)].evidence_refs").map { .object($0) })),
                ("supersedes", .array(try supersedes(item["supersedes"], "skill_inferences[\(index)].supersedes").map { .string($0) })),
            ])))
        }
        shaped["skill_inferences"] = .array(skills)
        var learnerUpdates: [EngineJSON] = []
        for (index, item) in try items(object, "learner_updates").enumerated() {
            let category = EnginePyText.strip(pyStrOrEmpty(item["category"]))
            let status = EnginePyText.strip(item["status"].map { $0.isTruthy ? TurnProgress.pyStr($0) : "tentative" } ?? "tentative")
            if !allowedLearnerCategories.contains(category) { throw EngineError("learner_updates[\(index)].category is invalid") }
            if !allowedClaimStatuses.contains(status) { throw EngineError("learner_updates[\(index)].status is invalid") }
            learnerUpdates.append(.object(EngineObject([
                ("category", .string(category)),
                ("statement", .string(try requireText(item["statement"], "learner_updates[\(index)].statement"))),
                ("confidence", .number(try confidence(item["confidence"], "learner_updates[\(index)].confidence"))),
                ("status", .string(status)),
                ("evidence_refs", .array(try evidenceRefs(item["evidence_refs"], "learner_updates[\(index)].evidence_refs").map { .object($0) })),
                ("supersedes", .array(try supersedes(item["supersedes"], "learner_updates[\(index)].supersedes").map { .string($0) })),
            ])))
        }
        shaped["learner_updates"] = .array(learnerUpdates)
        var unknowns: [EngineJSON] = []
        for (index, item) in try items(object, "unknowns").enumerated() {
            unknowns.append(.object(EngineObject([
                ("question", .string(try requireText(item["question"], "unknowns[\(index)].question"))),
                ("why_it_matters", .string(try requireText(item["why_it_matters"], "unknowns[\(index)].why_it_matters"))),
                ("evidence_refs", .array(try evidenceRefs(item["evidence_refs"], "unknowns[\(index)].evidence_refs").map { .object($0) })),
            ])))
        }
        shaped["unknowns"] = .array(unknowns)
        shaped["plan"] = .null
        shaped["intervention"] = .null
        for field in ["plan", "intervention"] {
            if let value = object[field], !value.isNull, value.objectValue == nil { throw EngineError("\(field) must be a mapping") }
        }
        if let plan = object["plan"]?.objectValue {
            shaped["plan"] = .object(EngineObject([
                ("next_action", .string(try requireText(plan["next_action"], "plan.next_action"))),
                ("why", .string(try requireText(plan["why"], "plan.why"))),
                ("success_signal", .string(try requireText(plan["success_signal"], "plan.success_signal"))),
                ("evidence_refs", .array(try evidenceRefs(plan["evidence_refs"], "plan.evidence_refs").map { .object($0) })),
            ]))
        }
        if let intervention = object["intervention"]?.objectValue {
            shaped["intervention"] = .object(EngineObject([
                ("action", .string(try requireText(intervention["action"], "intervention.action"))),
                ("learner_response", .string(try requireText(intervention["learner_response"], "intervention.learner_response"))),
                ("outcome", .string(try requireText(intervention["outcome"], "intervention.outcome"))),
                ("evidence_refs", .array(try evidenceRefs(intervention["evidence_refs"], "intervention.evidence_refs").map { .object($0) })),
            ]))
        }
        let hasEntries = !observations.isEmpty || !skills.isEmpty || !learnerUpdates.isEmpty || !unknowns.isEmpty
            || shaped["plan"]!.isTruthy || shaped["intervention"]!.isTruthy
        if !hasEntries { throw EngineError("memory update has no entries") }
        return shaped
    }

    static func shapePayload(payload: Any, expected: [String: String]) throws -> JSONObject {
        let ordered = ["learner_id", "thread_id", "turn_run_id", "user_message_id"].compactMap { key in expected[key].map { (key, $0) } }
        return try shapePayload(payload: EngineJSON(any: payload), expected: ordered).pairs.reduce(into: [:]) { $0[$1.0] = $1.1.anyValue }
    }

    static func refGroups(_ payload: EngineObject) -> [[EngineObject]] {
        var groups: [[EngineObject]] = []
        for field in ["observations", "skill_inferences", "learner_updates", "unknowns"] {
            for item in payload[field]?.arrayValue ?? [] {
                groups.append((item["evidence_refs"]?.arrayValue ?? []).compactMap(\.objectValue))
            }
        }
        for field in ["plan", "intervention"] {
            if let item = payload[field], item.isTruthy {
                groups.append((item["evidence_refs"]?.arrayValue ?? []).compactMap(\.objectValue))
            }
        }
        return groups
    }

    // MARK: application

    static func claimDocument(_ url: URL, learnerID: String) throws -> EngineObject {
        try readYAMLMapping(url, default: EngineObject([("schema_version", .integer(memorySchemaVersion)), ("learner_id", .string(learnerID)),
                                                          ("updated_at", .null), ("claims", .array([]))]))
    }

    static func claimIndex(_ claims: [EngineJSON]) -> [String: Int] {
        var byID: [String: Int] = [:]
        for (index, claim) in claims.enumerated() {
            if let object = claim.objectValue, let id = object["claim_id"], id.isTruthy { byID[TurnProgress.pyStr(id)] = index }
        }
        return byID
    }

    static func validateSupersedes(_ document: EngineObject, _ items: [EngineJSON]) throws {
        let claims = document["claims"]?.arrayValue ?? []
        let byID = claimIndex(claims)
        for item in items {
            for claimID in (item["supersedes"]?.arrayValue ?? []).map({ TurnProgress.pyStr($0) }) {
                guard let index = byID[claimID] else { throw EngineError("superseded claim does not exist: \(claimID)") }
                if claims[index]["lifecycle"] == .string("superseded") { throw EngineError("claim is already superseded: \(claimID)") }
            }
        }
    }

    static func mergeClaims(_ document: inout EngineObject, _ items: [EngineJSON], now: String) throws {
        var claims = document["claims"]?.arrayValue ?? []
        var byID = claimIndex(claims)
        for item in items {
            let supersedes = (item["supersedes"]?.arrayValue ?? []).map { TurnProgress.pyStr($0) }
            for claimID in supersedes {
                guard let index = byID[claimID] else { throw EngineError("superseded claim does not exist: \(claimID)") }
                if claims[index]["lifecycle"] == .string("superseded") { throw EngineError("claim is already superseded: \(claimID)") }
            }
            let newID = uuidString()
            for claimID in supersedes {
                var prior = claims[byID[claimID]!].objectValue!
                prior["lifecycle"] = .string("superseded")
                prior["superseded_by"] = .string(newID)
                prior["superseded_at"] = .string(now)
                claims[byID[claimID]!] = .object(prior)
            }
            var saved = EngineObject([("claim_id", .string(newID))])
            for (key, value) in item.objectValue?.pairs ?? [] where key != "supersedes" { saved[key] = value }
            saved["supersedes"] = .array(supersedes.map { .string($0) })
            saved["lifecycle"] = .string("active")
            saved["created_at"] = .string(now)
            claims.append(.object(saved))
            byID[newID] = claims.count - 1
        }
        document["claims"] = .array(claims)
        document["updated_at"] = .string(now)
    }

    static func archivePlan(desk: URL, document: EngineObject, now: Date) throws {
        guard let plan = document["plan"], plan.isTruthy else { return }
        try writeYAML(desk.appendingPathComponent("plans/archive/\(EnginePyTime.compactStamp(now)).yaml"), .object(document))
    }

    /// `_apply_shaped_payload`; returns sorted relative paths (relative to the desk's parent, e.g. `tutor_desk/skills/inferences.yaml`).
    static func applyShapedPayload(desk: URL, learnerID: String, payload: EngineObject, now: Date = Date()) throws -> [String] {
        try ensureTutorMemoryFiles(desk: desk, learnerID: learnerID)
        let workspace = desk.deletingLastPathComponent()
        let nowText = EnginePyTime.isoformat(now)
        var changed = Set<String>()
        let skillPath = desk.appendingPathComponent("skills/inferences.yaml")
        var skillDoc = try claimDocument(skillPath, learnerID: learnerID)
        let categoryPaths: [(String, URL)] = [("profile", desk.appendingPathComponent("learner/profile.yaml")),
                                              ("preference", desk.appendingPathComponent("learner/preferences.yaml")),
                                              ("active_goal", desk.appendingPathComponent("goals/current.yaml"))]
        var categoryDocuments: [String: EngineObject] = [:]
        for (category, path) in categoryPaths { categoryDocuments[category] = try claimDocument(path, learnerID: learnerID) }
        let skillItems = payload["skill_inferences"]?.arrayValue ?? []
        let learnerItems = payload["learner_updates"]?.arrayValue ?? []
        try validateSupersedes(skillDoc, skillItems)
        for (category, _) in categoryPaths {
            try validateSupersedes(categoryDocuments[category]!, learnerItems.filter { $0["category"] == .string(category) })
        }
        if !skillItems.isEmpty {
            try mergeClaims(&skillDoc, skillItems, now: nowText)
            try writeYAML(skillPath, .object(skillDoc))
            changed.insert(relative(skillPath, to: workspace))
        }
        for (category, path) in categoryPaths {
            let updates = learnerItems.filter { $0["category"] == .string(category) }
            if updates.isEmpty { continue }
            var document = categoryDocuments[category]!
            try mergeClaims(&document, updates, now: nowText)
            try writeYAML(path, .object(document))
            changed.insert(relative(path, to: workspace))
        }
        let unknowns = payload["unknowns"]?.arrayValue ?? []
        if !unknowns.isEmpty {
            let path = desk.appendingPathComponent("learner/open_questions.yaml")
            var document = try readYAMLMapping(path, default: EngineObject([("schema_version", .integer(memorySchemaVersion)), ("learner_id", .string(learnerID)),
                                                                              ("updated_at", .null), ("questions", .array([]))]))
            var questions = document["questions"]?.arrayValue ?? []
            for item in unknowns {
                var question = EngineObject([("question_id", .string(uuidString()))])
                for (key, value) in item.objectValue?.pairs ?? [] { question[key] = value }
                question["status"] = .string("open")
                question["created_at"] = .string(nowText)
                questions.append(.object(question))
            }
            document["questions"] = .array(questions)
            document["updated_at"] = .string(nowText)
            try writeYAML(path, .object(document))
            changed.insert(relative(path, to: workspace))
        }
        let month = EnginePyTime.yearMonth(now)
        for observation in payload["observations"]?.arrayValue ?? [] {
            let id = uuidString()
            let path = desk.appendingPathComponent("evidence/model/\(month)/\(id).yaml")
            var document = EngineObject([("schema_version", .integer(memorySchemaVersion)), ("evidence_id", .string(id)), ("learner_id", .string(learnerID)),
                                            ("observed_at", .string(nowText)), ("source", payload["source"] ?? .null)])
            for (key, value) in observation.objectValue?.pairs ?? [] { document[key] = value }
            try writeYAML(path, .object(document))
            changed.insert(relative(path, to: workspace))
        }
        if let intervention = payload["intervention"], intervention.isTruthy {
            let stamp = EnginePyTime.compactStamp(now)
            let path = desk.appendingPathComponent("interventions/\(stamp).yaml")
            var document = EngineObject([("schema_version", .integer(memorySchemaVersion)), ("intervention_id", .string(stamp)), ("learner_id", .string(learnerID)),
                                            ("recorded_at", .string(nowText)), ("source", payload["source"] ?? .null)])
            for (key, value) in intervention.objectValue?.pairs ?? [] { document[key] = value }
            try writeYAML(path, .object(document))
            changed.insert(relative(path, to: workspace))
        }
        if let plan = payload["plan"], plan.isTruthy {
            let path = desk.appendingPathComponent("plans/current.yaml")
            let previous = try readYAMLMapping(path, default: .init())
            try archivePlan(desk: desk, document: previous, now: now)
            var document = EngineObject([("schema_version", .integer(memorySchemaVersion)), ("learner_id", .string(learnerID)), ("updated_at", .string(nowText)),
                                            ("future_teaching_change", payload["future_teaching_change"] ?? .null), ("source", payload["source"] ?? .null),
                                            ("plan", plan)])
            if let progress = previous["learning_progress"] { document["learning_progress"] = progress }
            try writeYAML(path, .object(document))
            changed.insert(relative(path, to: workspace))
        }
        return changed.sorted()
    }

    static func moveQueueFile(_ path: URL, to destination: URL) throws -> URL {
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var target = destination.appendingPathComponent(path.lastPathComponent)
        if exists(target) {
            let stem = path.deletingPathExtension().lastPathComponent
            let suffix = path.pathExtension.isEmpty ? "" : ".\(path.pathExtension)"
            target = destination.appendingPathComponent("\(stem)-\(uuidHex())\(suffix)")
        }
        try fm.moveItem(at: path, to: target)
        return target
    }

    static func pythonTupleListRepr(_ refs: [(String, String)]) -> String {
        "[" + refs.map { "(\(LearningProgress.pythonRepr($0.0)), \(LearningProgress.pythonRepr($0.1)))" }.joined(separator: ", ") + "]"
    }

    struct QueueResult: Equatable {
        var processedCount: Int
        var appliedCount: Int
        var rejectedCount: Int
        var appliedFiles: [String]
        var rejected: [(path: String, error: String)]
        var beforeDigest: String
        var afterDigest: String
        var changedPaths: [String]

        static func == (lhs: QueueResult, rhs: QueueResult) -> Bool { lhs.json == rhs.json }

        var json: EngineJSON {
            .object(EngineObject([
                ("processed_count", .integer(processedCount)), ("applied_count", .integer(appliedCount)), ("rejected_count", .integer(rejectedCount)),
                ("applied_files", .array(appliedFiles.map { .string($0) })),
                ("rejected", .array(rejected.map { .object(EngineObject([("path", .string($0.path)), ("error", .string($0.error))])) })),
                ("before_digest", .string(beforeDigest)), ("after_digest", .string(afterDigest)),
                ("changed_paths", .array(changedPaths.map { .string($0) })),
            ]))
        }

        var jsonObject: JSONObject { json.anyValue as! JSONObject }
    }

    /// `apply_tutor_memory_queue`. `isValidEvidenceRef` replaces the database ownership lookup.
    static func applyTutorMemoryQueue(queueDirectory: URL, desk: URL, workspaceRootForRelativePaths workspace: URL, learnerID: String,
                                             threadID: String, turnRunID: String, userMessageID: String?, now: Date = Date(),
                                             isValidEvidenceRef: (_ type: String, _ id: String) -> Bool) throws -> QueueResult {
        try ensureTutorMemoryFiles(desk: desk, learnerID: learnerID)
        let before = try modelMemoryManifest(workspace: workspace)
        let queue = queueDirectory
        let paths = ((try? fm.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "yaml" && isRegularFile($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(maxQueueFiles)
        var appliedFiles: [String] = []
        var rejected: [(path: String, error: String)] = []
        var changedPaths = Set<String>()
        let expected: [(String, String)] = [("learner_id", learnerID), ("thread_id", threadID), ("turn_run_id", turnRunID), ("user_message_id", userMessageID ?? "")]
        for path in paths {
            do {
                let data = try Data(contentsOf: path)
                if data.count > maxQueueFileBytes { throw EngineError("memory update is too large") }
                let shaped = try shapePayload(payload: try EngineYAML.load(String(decoding: data, as: UTF8.self)), expected: expected)
                let groups = refGroups(shaped)
                var requested: [(String, String)] = []
                var seen = Set<String>()
                for ref in groups.flatMap({ $0 }) {
                    let pair = (ref["type"]?.stringValue ?? "", ref["id"]?.stringValue ?? "")
                    if seen.insert(pair.0 + "\u{0}" + pair.1).inserted { requested.append(pair) }
                }
                let invalid = requested.filter { !isValidEvidenceRef($0.0, $0.1) }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
                if !invalid.isEmpty { throw EngineError("evidence references are not owned or do not exist: \(pythonTupleListRepr(invalid))") }
                let currentRef = ("chat_message", userMessageID ?? "None")
                guard let userMessageID, requested.contains(where: { $0 == currentRef }) else {
                    throw EngineError("the current learner message must support the update")
                }
                for group in groups where !group.contains(where: { $0["type"]?.stringValue == "chat_message" && $0["id"]?.stringValue == userMessageID }) {
                    throw EngineError("each memory entry must cite the current learner message")
                }
                changedPaths.formUnion(try applyShapedPayload(desk: desk, learnerID: learnerID, payload: shaped, now: now))
                let moved = try moveQueueFile(path, to: queue.appendingPathComponent("applied", isDirectory: true))
                appliedFiles.append(relative(moved, to: workspace))
            } catch {
                let message = (error as? EngineError)?.message ?? String(describing: error)
                let moved = try moveQueueFile(path, to: queue.appendingPathComponent("rejected", isDirectory: true))
                let errorPath = moved.deletingPathExtension().appendingPathExtension("error.yaml")
                try writeYAML(errorPath, .object(EngineObject([
                    ("schema_version", .integer(memorySchemaVersion)), ("rejected_at", .string(EnginePyTime.isoformat(now))),
                    ("error", .string(trim(message, limit: 1000))), ("source_file", .string(relative(moved, to: workspace))),
                ])))
                rejected.append((relative(moved, to: workspace), trim(message, limit: 1000)))
            }
        }
        let after = try modelMemoryManifest(workspace: workspace)
        for key in Set(before.files.keys).union(after.files.keys) where before.files[key] != after.files[key] { changedPaths.insert(key) }
        return QueueResult(processedCount: paths.count, appliedCount: appliedFiles.count, rejectedCount: rejected.count, appliedFiles: appliedFiles,
                           rejected: rejected, beforeDigest: before.digest, afterDigest: after.digest, changedPaths: changedPaths.sorted())
    }

    // MARK: session staging (replacement for stage_tutor_memory_context)

    /// Writes `current/session.yaml` exactly like Python and `current/task.yaml` with an empty `study_contexts` list.
    static func stageSession(desk: URL, learnerID: String, threadID: String, turnRunID: String, userMessageID: String?,
                                    latestUserText: String, stagedAt: Date = Date()) throws {
        UnitDeletion.gate.lock(); defer { UnitDeletion.gate.unlock() }
        let staged = EnginePyTime.isoformat(stagedAt)
        try writeYAML(desk.appendingPathComponent("current/session.yaml"), .object(EngineObject([
            ("schema_version", .integer(memorySchemaVersion)), ("backend_owned", .bool(true)), ("learner_id", .string(learnerID)),
            ("thread_id", .string(threadID)), ("turn_run_id", .string(turnRunID)),
            ("user_message_id", userMessageID.map { .string($0) } ?? .null), ("staged_at", .string(staged)),
            ("latest_learner_message", .string(trim(latestUserText, limit: 3000))),
            ("memory_update_policy", .string("Submit an update only when this turn adds evidence that changes future teaching.")),
        ])))
        try writeYAML(desk.appendingPathComponent("current/task.yaml"), .object(EngineObject([
            ("schema_version", .integer(memorySchemaVersion)), ("backend_owned", .bool(true)), ("staged_at", .string(staged)),
            ("study_contexts", .array([])),
        ])))
    }
}
