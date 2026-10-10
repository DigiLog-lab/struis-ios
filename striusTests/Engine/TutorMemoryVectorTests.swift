import Foundation
import XCTest
#if canImport(StruisEngine)
@testable import StruisEngine
#else
@testable import strius
#endif

final class TutorMemoryVectorTests: XCTestCase {
    static let vectors: EngineJSON = { try! EngineVectors.load("tutor_memory") }()
    static let uuidPattern = try! NSRegularExpression(pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-f]{32}")

    private func cases(_ key: String) -> [EngineObject] {
        Self.vectors[key]?.arrayValue?.compactMap(\.objectValue) ?? []
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("engine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeTree(_ root: URL, _ files: EngineObject) throws {
        for (relative, text) in files.pairs {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.stringOrEmpty.utf8).write(to: url)
        }
    }

    private func readTree(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            result[TutorMemory.relative(url, to: root)] = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
        return result
    }

    private func uuids(in text: String) -> Set<String> {
        let ns = text as NSString
        return Set(Self.uuidPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() })
    }

    /// Replaces generated ids (uuid4 claim/evidence/question ids, collision suffixes) with a placeholder.
    private func normalize(_ text: String, keep: Set<String>) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in Self.uuidPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let value = ns.substring(with: match.range)
            result += keep.contains(value.lowercased()) ? value : "<uuid>"
            cursor = match.range.location + match.range.length
        }
        return result + ns.substring(from: cursor)
    }

    private func canonicalFile(_ path: String, _ text: String, keep: Set<String>) throws -> String {
        if path.hasSuffix(".yaml") { return normalize(EngineVectors.canonical(try EngineYAML.load(text)), keep: keep) }
        return text
    }

    private func assertTreesEqual(actual: [String: String], expected: EngineObject, keep: Set<String>, _ label: String) throws {
        var actualGroups: [String: [String]] = [:]
        for (path, text) in actual { actualGroups[normalize(path, keep: keep), default: []].append(try canonicalFile(path, text, keep: keep)) }
        var expectedGroups: [String: [String]] = [:]
        for (path, text) in expected.pairs { expectedGroups[normalize(path, keep: keep), default: []].append(try canonicalFile(path, text.stringOrEmpty, keep: keep)) }
        XCTAssertEqual(Set(actualGroups.keys), Set(expectedGroups.keys), "\(label): file set")
        for (path, contents) in expectedGroups {
            XCTAssertEqual(actualGroups[path]?.sorted(), contents.sorted(), "\(label): \(path)")
        }
    }

    func testConstants() {
        let c = cases("constants")[0]
        XCTAssertEqual(c["MEMORY_SCHEMA_VERSION"]?.intValue, TutorMemory.memorySchemaVersion)
        XCTAssertEqual(c["MAX_QUEUE_FILES"]?.intValue, TutorMemory.maxQueueFiles)
        XCTAssertEqual(c["MAX_QUEUE_FILE_BYTES"]?.intValue, TutorMemory.maxQueueFileBytes)
        XCTAssertEqual(c["MAX_ITEMS_PER_SECTION"]?.intValue, TutorMemory.maxItemsPerSection)
        XCTAssertEqual(c["MAX_TEXT_LENGTH"]?.intValue, TutorMemory.maxTextLength)
        XCTAssertEqual(c["MAX_INJECTED_MEMORY_CHARS"]?.intValue, TutorMemory.maxInjectedMemoryChars)
        XCTAssertEqual(Set(c["ALLOWED_EVIDENCE_TYPES"]!.arrayValue!.map(\.stringOrEmpty)), TutorMemory.allowedEvidenceTypes)
        XCTAssertEqual(Set(c["ALLOWED_OBSERVATION_KINDS"]!.arrayValue!.map(\.stringOrEmpty)), TutorMemory.allowedObservationKinds)
        XCTAssertEqual(Set(c["ALLOWED_SKILL_DIMENSIONS"]!.arrayValue!.map(\.stringOrEmpty)), TutorMemory.allowedSkillDimensions)
        XCTAssertEqual(Set(c["ALLOWED_CLAIM_STATUSES"]!.arrayValue!.map(\.stringOrEmpty)), TutorMemory.allowedClaimStatuses)
        XCTAssertEqual(Set(c["ALLOWED_LEARNER_CATEGORIES"]!.arrayValue!.map(\.stringOrEmpty)), TutorMemory.allowedLearnerCategories)
    }

    func testShapePayloadVectors() {
        for c in cases("shape_payload") {
            let name = c["name"]!.stringOrEmpty
            let expected = c["expected"]!.objectValue!.pairs.map { ($0.0, $0.1.stringOrEmpty) }
            let expect = c["expect"]!.objectValue!
            do {
                let shaped = try TutorMemory.shapePayload(payload: c["payload"]!, expected: expected)
                XCTAssertEqual(expect["ok"]?.boolValue, true, "\(name): expected \(expect["error"]?.stringOrEmpty ?? "")")
                EngineVectors.assertEqual(.object(shaped), expect["shaped"] ?? .null, name)
            } catch let error as EngineError {
                XCTAssertEqual(expect["ok"]?.boolValue, false, "\(name): \(error.message)")
                XCTAssertEqual(error.message, expect["error"]?.stringValue, name)
            } catch {
                XCTFail("\(name): \(error)")
            }
        }
    }

    func testYAMLDumpRoundTrip() throws {
        for c in cases("yaml_dump") {
            let value = c["value"]!
            let dumped = try EngineYAML.dump(value)
            EngineVectors.assertEqual(try EngineYAML.load(dumped), value, "reload of Swift dump")
            EngineVectors.assertEqual(try EngineYAML.load(c["expect"]!.stringOrEmpty), value, "reload of Python dump")
        }
    }

    func testApplyQueueVectors() throws {
        for c in cases("apply_queue") {
            let name = c["name"]!.stringOrEmpty
            let workspace = try tempDir()
            let desk = workspace.appendingPathComponent("tutor_desk", isDirectory: true)
            try writeTree(workspace, c["files_before"]!.objectValue!)
            var keep = uuids(in: c["files_before"]!.serialized())
            for key in ["learner_id", "thread_id", "turn_run_id", "user_message_id"] { if let v = c[key]?.stringValue { keep.insert(v.lowercased()) } }
            let valid = Set(c["valid_refs"]!.arrayValue!.map { $0.arrayValue!.map(\.stringOrEmpty).joined(separator: "\u{0}") })
            let result = try TutorMemory.applyTutorMemoryQueue(
                queueDirectory: desk.appendingPathComponent("queue/memory", isDirectory: true), desk: desk, workspaceRootForRelativePaths: workspace,
                learnerID: c["learner_id"]!.stringOrEmpty, threadID: c["thread_id"]!.stringOrEmpty, turnRunID: c["turn_run_id"]!.stringOrEmpty,
                userMessageID: c["user_message_id"]?.stringValue, now: EnginePyTime.parseISO(c["now"]!.stringOrEmpty)!,
                isValidEvidenceRef: { valid.contains($0 + "\u{0}" + $1) })
            let expected = c["expect"]!["result"]!.objectValue!
            XCTAssertEqual(result.processedCount, expected["processed_count"]?.intValue, name)
            XCTAssertEqual(result.appliedCount, expected["applied_count"]?.intValue, name)
            XCTAssertEqual(result.rejectedCount, expected["rejected_count"]?.intValue, name)
            XCTAssertEqual(result.appliedFiles.map { normalize($0, keep: keep) }, expected["applied_files"]!.arrayValue!.map { normalize($0.stringOrEmpty, keep: keep) }, name)
            XCTAssertEqual(result.changedPaths.map { normalize($0, keep: keep) }, expected["changed_paths"]!.arrayValue!.map { normalize($0.stringOrEmpty, keep: keep) }, name)
            XCTAssertEqual(result.rejected.map { normalize($0.path, keep: keep) + " :: " + normalize($0.error, keep: keep) },
                           expected["rejected"]!.arrayValue!.map { normalize($0["path"]!.stringOrEmpty, keep: keep) + " :: " + normalize($0["error"]!.stringOrEmpty, keep: keep) }, name)
            XCTAssertEqual(result.beforeDigest == result.afterDigest, expected["before_digest"] == expected["after_digest"], "\(name): digest change")
            try assertTreesEqual(actual: try readTree(workspace), expected: c["expect"]!["files_after"]!.objectValue!, keep: keep, name)
            if name == "supersede_second" {
                let claims = try EngineYAML.load(String(decoding: try Data(contentsOf: desk.appendingPathComponent("skills/inferences.yaml")), as: UTF8.self))["claims"]!.arrayValue!
                XCTAssertEqual(claims.count, 2)
                XCTAssertEqual(claims[0]["lifecycle"]?.stringValue, "superseded")
                XCTAssertEqual(claims[0]["superseded_by"], claims[1]["claim_id"])
                XCTAssertEqual(claims[1]["supersedes"]?.arrayValue?.first, claims[0]["claim_id"])
                XCTAssertEqual(claims[1]["lifecycle"]?.stringValue, "active")
            }
        }
    }

    func testEnsureFilesVectors() throws {
        let c = cases("ensure_files")[0]
        let workspace = try tempDir()
        let desk = workspace.appendingPathComponent("tutor_desk", isDirectory: true)
        try TutorMemory.ensureTutorMemoryFiles(desk: desk, learnerID: c["learner_id"]!.stringOrEmpty)
        try assertTreesEqual(actual: try readTree(workspace), expected: c["expect"]!["files"]!.objectValue!, keep: [], "ensure_files")
        var dirs: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: desk, includingPropertiesForKeys: [.isDirectoryKey])! where (try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            dirs.append(TutorMemory.relative(url, to: workspace))
        }
        XCTAssertEqual(dirs.sorted(), c["expect"]!["dirs"]!.arrayValue!.map(\.stringOrEmpty))
        // Re-running keeps existing documents but rewrites the README.
        try Data("custom".utf8).write(to: desk.appendingPathComponent("learner/profile.yaml"))
        try TutorMemory.ensureTutorMemoryFiles(desk: desk, learnerID: "other")
        XCTAssertEqual(String(decoding: try Data(contentsOf: desk.appendingPathComponent("learner/profile.yaml")), as: UTF8.self), "custom")
    }

    func testRenderAndManifestVectors() throws {
        for c in cases("render_and_manifest") {
            let name = c["name"]!.stringOrEmpty
            let workspace = try tempDir()
            try writeTree(workspace, c["files"]!.objectValue!)
            let rendered = try TutorMemory.renderTutorMemoryContext(workspace: workspace)
            let expected = c["expect"]!["rendered"]!.stringOrEmpty
            func sections(_ text: String) -> [(String, String)] {
                var result: [(String, String)] = []
                for chunk in text.components(separatedBy: "--- ").dropFirst() {
                    let parts = chunk.components(separatedBy: " ---\n")
                    result.append((parts[0], parts.dropFirst().joined(separator: " ---\n")))
                }
                return result
            }
            let actualSections = sections(rendered), expectedSections = sections(expected)
            XCTAssertEqual(actualSections.map(\.0), expectedSections.map(\.0), name)
            for (a, e) in zip(actualSections, expectedSections) {
                if a.0 == "tutor_desk/plans/current.yaml" {
                    EngineVectors.assertEqual(try EngineYAML.load(a.1), try EngineYAML.load(e.1), "\(name): plans section")
                } else {
                    XCTAssertEqual(a.1, e.1, "\(name): section \(a.0)")
                }
            }
            if !expectedSections.contains(where: { $0.0 == "tutor_desk/plans/current.yaml" }) { XCTAssertEqual(rendered, expected, name) }
            let manifest = try TutorMemory.modelMemoryManifest(workspace: workspace)
            XCTAssertEqual(manifest.digest, c["expect"]!["manifest"]!["digest"]?.stringValue, name)
            EngineVectors.assertEqual(EngineJSON(any: manifest.files), c["expect"]!["manifest"]!["files"]!, name)
            let protected = TutorMemory.protectedMemoryPaths(workspace: workspace).map { TutorMemory.relative($0, to: workspace) }.sorted()
            XCTAssertEqual(protected, c["expect"]!["protected_paths"]!.arrayValue!.map(\.stringOrEmpty), name)
        }
    }

    func testSnapshotRestoreVector() throws {
        let c = cases("snapshot_restore")[0]
        let workspace = try tempDir()
        try writeTree(workspace, c["modified_files"]!.objectValue!)
        var snapshot: [String: Data] = [:]
        for (path, text) in c["snapshot"]!.objectValue!.pairs { snapshot[path] = Data(text.stringOrEmpty.utf8) }
        let changed = try TutorMemory.restoreProtectedMemorySnapshot(workspace: workspace, snapshot: snapshot)
        XCTAssertEqual(changed, c["expect"]!["changed"]!.arrayValue!.map(\.stringOrEmpty))
        let after = try readTree(workspace)
        XCTAssertEqual(EngineJSON(any: after), EngineJSON(any: c["expect"]!["files_after"]!.anyValue))
        let taken = try TutorMemory.protectedMemorySnapshot(workspace: workspace)
        XCTAssertEqual(taken, snapshot)
    }

    func testStageSessionAndQueueEmbeddedVectors() throws {
        let c = cases("stage_session")[0]
        let desk = try tempDir().appendingPathComponent("tutor_desk", isDirectory: true)
        try TutorMemory.stageSession(desk: desk, learnerID: c["learner_id"]!.stringOrEmpty, threadID: c["thread_id"]!.stringOrEmpty,
                                     turnRunID: c["turn_run_id"]!.stringOrEmpty, userMessageID: c["user_message_id"]?.stringValue,
                                     latestUserText: c["latest_user_text"]!.stringOrEmpty, stagedAt: EnginePyTime.parseISO(c["staged_at"]!.stringOrEmpty)!)
        let session = String(decoding: try Data(contentsOf: desk.appendingPathComponent("current/session.yaml")), as: UTF8.self)
        let task = String(decoding: try Data(contentsOf: desk.appendingPathComponent("current/task.yaml")), as: UTF8.self)
        EngineVectors.assertEqual(try EngineYAML.load(session), try EngineYAML.load(c["expect"]!["session"]!.stringOrEmpty), "session.yaml")
        EngineVectors.assertEqual(try EngineYAML.load(task), try EngineYAML.load(c["expect"]!["task"]!.stringOrEmpty), "task.yaml")

        let e = cases("queue_embedded")[0]
        let queued = try TutorMemory.queueEmbeddedMemoryUpdate(desk: desk, turnRunID: e["turn_run_id"]!.stringOrEmpty, payload: e["payload"]!.stringOrEmpty)
        XCTAssertEqual(TutorMemory.relative(queued.deletingLastPathComponent(), to: desk.deletingLastPathComponent()), e["expect"]!["relative_dir"]?.stringValue)
        XCTAssertTrue(queued.lastPathComponent.hasPrefix(e["expect"]!["name_prefix"]!.stringOrEmpty))
        XCTAssertTrue(queued.lastPathComponent.hasSuffix(".yaml"))
        XCTAssertEqual(String(decoding: try Data(contentsOf: queued), as: UTF8.self), e["expect"]!["content"]?.stringValue)
    }

    func testSHA256KnownAnswer() {
        XCTAssertEqual(EngineSHA256.hexDigest(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(EngineSHA256.hexDigest(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(EngineSHA256.hexDigest(Data(String(repeating: "a", count: 1000).utf8)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }
}
