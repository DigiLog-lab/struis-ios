import GRDB
import XCTest
@testable import strius

/// 台帳 (design §4) の受け入れ: すべての変更が `ledger_events` を通ること、`rebuild()` で
/// 射影が同一に戻ること、export → 空台帳へ import → rebuild で同一になること。
final class LedgerTests: XCTestCase {
    private func makeLedger() throws -> Ledger {
        try Ledger.inMemory()
    }

    func testEventsRebuildProjectionsIdentically() async throws {
        let ledger = try makeLedger()
        try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let unitID = machine.createUnit(
                title: "二次関数", outcome: "基本が解ける", source: "consult",
                subunits: [.init(title: "頂点", n: 3), .init(title: "平行移動", n: 4)], firstStage: 3
            )
            let subunitID = machine.orderedSubunits(unitID: unitID)[0].id
            let spec = try machine.nextSetSpec(subunitID: subunitID)
            let setID = machine.insertGeneratingSet(subunitID: subunitID, spec: spec)
            let ids = machine.addProblems(subunitID: subunitID, problems: [.init(prompt: "y=x^2-2x+1")], source: "generated")
            machine.fillSet(setID: setID, problemIDs: ids)
            _ = try machine.createCapture(id: "cap-1", imagePath: "cap-1.jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, subunitID: nil, setID: setID)
            return (machine.events, ())
        }
        let count = try await ledger.eventCount()
        XCTAssertGreaterThanOrEqual(count, 6)
        let before = try await ledger.projectionDigest()
        try await ledger.rebuild()
        let after = try await ledger.projectionDigest()
        XCTAssertEqual(before, after)
        XCTAssertFalse(before.isEmpty)
    }

    func testExportImportRebuildMatches() async throws {
        let source = try makeLedger()
        try await source.commit { db in
            var machine = try WorkbookMachine(loading: db)
            machine.createUnit(title: "英作文", outcome: "", source: "capture", subunits: [.init(title: "言い換え", n: 2)], firstStage: 4)
            return (machine.events, ())
        }
        let events = try await source.events()
        let target = try makeLedger()
        try await target.importEvents(events.compactMap(\.event))
        let sourceDigest = try await source.projectionDigest()
        try await target.rebuild()
        let targetDigest = try await target.projectionDigest()
        XCTAssertEqual(sourceDigest, targetDigest)
    }

    func testGradingUpdatesStageAndAttemptsThroughEvents() async throws {
        let ledger = try makeLedger()
        let (setID, context): (String, WorkbookMachine.GradingContext) = try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let unitID = machine.createUnit(title: "二次関数", outcome: "", source: "consult", subunits: [.init(title: "頂点", n: 2)], firstStage: 3)
            let subunitID = machine.orderedSubunits(unitID: unitID)[0].id
            let setID = machine.insertGeneratingSet(subunitID: subunitID, spec: try machine.nextSetSpec(subunitID: subunitID))
            let ids = machine.addProblems(subunitID: subunitID, problems: [.init(prompt: "例題")], source: "generated")
            machine.fillSet(setID: setID, problemIDs: ids)
            _ = try machine.createCapture(id: "cap-2", imagePath: "cap-2.jpg", contentType: "image/jpeg", sha256: "0", byteCount: 1, subunitID: nil, setID: setID)
            let context = machine.gradingContext(capture: machine.captures["cap-2"]!)
            return (machine.events, (setID, context))
        }
        let problemID = context.subunits[0]["problems"]!.arrayValue![0]["id"]!.stringValue!
        let graded = WorkbookMachine.GradingResult(
            readable: true,
            items: [.init(label: "問1", promptText: "例題", matchedProblemId: problemID, verdict: "correct", errorTag: "", note: "正しい")],
            candidates: [], newSubunit: nil, note: ""
        )
        let _: Void = try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let outcome = try machine.applyGradingResult(captureID: "cap-2", graded: graded, context: context)
            XCTAssertEqual(outcome.status, "graded")
            return (machine.events, ())
        }
        let (stage, attempts, set) = try await ledger.read { db in
            let machine = try WorkbookMachine(loading: db)
            let subunit = machine.orderedSubunits()[0]
            return (subunit.stage, machine.attemptsOf(subunitID: subunit.id).count, machine.sets[setID]!)
        }
        XCTAssertEqual(stage, 4, "自力例題 ○ → 練習")
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(set.status, "graded")
        let kinds = try await ledger.events().map(\.kind)
        XCTAssertTrue(kinds.contains("attempt.recorded"))
        XCTAssertTrue(kinds.contains("subunit.stage_set"))
        XCTAssertTrue(kinds.contains("capture.graded"))
    }

    func testLedgerIDsAreUUIDv7() throws {
        let earlier = LedgerID.make(date: Date(timeIntervalSince1970: 1_700_000_000))
        let later = LedgerID.make(date: Date(timeIntervalSince1970: 1_700_000_001))
        for id in [earlier, later] {
            XCTAssertNotNil(UUID(uuidString: id))
            XCTAssertEqual(Array(id)[14], "7", "version nibble")
            XCTAssertTrue("89ab".contains(Array(id)[19]), "RFC 4122 variant")
        }
        XCTAssertLessThan(earlier, later, "time-ordered")
    }

    /// design §4.3: 書き出し → 空の台帳へ取り込み → 射影と画像・記憶が同じになる。
    func testArchiveExportImportRoundTrip() async throws {
        let source = try makeLedger()
        try await source.commit { db in
            var machine = try WorkbookMachine(loading: db)
            machine.createUnit(title: "三角比", outcome: "", source: "consult", subunits: [.init(title: "sin", n: 2)], firstStage: 3)
            return (machine.events, ())
        }
        let (thread, event) = ChatRepository.createThread(title: "質問")
        try await source.append([event])
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("archive-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceRoot.appendingPathComponent("captures"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot.appendingPathComponent("memory/current"), withIntermediateDirectories: true)
        try Data([0xff, 0xd8, 0x01]).write(to: sourceRoot.appendingPathComponent("captures/cap-1.jpg"))
        try Data("schema_version: 1\n".utf8).write(to: sourceRoot.appendingPathComponent("memory/current/session.yaml"))

        let archive = try await LedgerArchive.export(ledger: source, root: sourceRoot, to: sourceRoot)
        XCTAssertTrue(archive.lastPathComponent.hasPrefix("struis-ledger-"))

        let target = try makeLedger()
        let targetRoot = FileManager.default.temporaryDirectory.appendingPathComponent("archive-dst-\(UUID().uuidString)")
        let manifest = try await LedgerArchive.importArchive(from: archive, into: target, root: targetRoot)
        let sourceCount = try await source.eventCount()
        XCTAssertEqual(manifest.eventCount, sourceCount)
        let sourceDigest = try await source.projectionDigest()
        let targetDigest = try await target.projectionDigest()
        XCTAssertEqual(sourceDigest, targetDigest)
        XCTAssertEqual(try Data(contentsOf: targetRoot.appendingPathComponent("captures/cap-1.jpg")), Data([0xff, 0xd8, 0x01]))
        XCTAssertEqual(try String(contentsOf: targetRoot.appendingPathComponent("memory/current/session.yaml"), encoding: .utf8), "schema_version: 1\n")
        let threads = try await target.read { db in try ChatRepository.threads(db).map(\.id) }
        XCTAssertEqual(threads, [thread.id])

        // 取り込みは空の台帳だけ。
        do {
            try await LedgerArchive.importArchive(from: archive, into: target, root: targetRoot)
            XCTFail("空でない台帳に取り込めてしまった")
        } catch {}
    }

    func testUsageReportDropsContentKeys() {
        let executions: [LedgerJSON] = [.object([
            "execution_id": .string("e1"), "requested_model": .string("gpt-6-astra"), "text": .string("秘密"),
            "usage": .object(["input_tokens": .number(10), "final_text": .string("x")]),
            "files": .array([.string("a")]),
        ])]
        let cleaned = UsageReporter.sanitized(executions)
        let object = cleaned[0].objectValue!
        XCTAssertNil(object["text"])
        XCTAssertNil(object["files"])
        XCTAssertNil(object["usage"]?.objectValue?["final_text"])
        XCTAssertEqual(object["requested_model"]?.stringValue, "gpt-6-astra")
    }

    func testUsageReportRejectsInvalidStatisticValues() {
        let cleaned = UsageReporter.sanitized([.object([
            "requested_model": .string("gpt-6\n"), "actual_model": .object(["text": .string("secret")]),
            "status": .string("secret"), "task_type": .string("secret"), "elapsed_ms": .number(-1),
            "usage": .object(["inputTokens": .bool(true), "outputTokens": .number(0.5),
                              "total": .object(["totalTokens": .number(13), "text": .string("secret")])]),
        ])])
        XCTAssertEqual(cleaned, [.object(["usage": .object(["total": .object(["totalTokens": .number(13)])])])])
    }

    func testArchiveRejectsTruncatedAndOutOfBoundsZipEntries() throws {
        var writer = ZipWriter()
        writer.add(path: "manifest.json", data: Data("{}".utf8))
        let valid = writer.finish()
        XCTAssertEqual(try ZipReader.entries(of: valid)["manifest.json"], Data("{}".utf8))
        for length in 0..<valid.count {
            XCTAssertThrowsError(try ZipReader.entries(of: Data(valid.prefix(length))), "length=\(length)")
        }
        let central = 30 + "manifest.json".utf8.count + 2
        // Filename/extra/comment lengths and local header offsets used to be read before bounds checks.
        for (offset, width) in [(central + 28, 2), (central + 30, 2), (central + 32, 2),
                                (central + 42, 4), (26, 2), (28, 2)] {
            var malformed = valid
            for index in offset..<(offset + width) { malformed[index] = 0xff }
            XCTAssertThrowsError(try ZipReader.entries(of: malformed), "offset=\(offset)")
        }
        var mismatch = valid
        mismatch[central + 24] = 3 // CRC still matches the stored two bytes, but the size does not.
        XCTAssertThrowsError(try ZipReader.entries(of: mismatch))
    }

    func testArchiveRejectsDuplicateZipPaths() {
        var writer = ZipWriter()
        writer.add(path: "manifest.json", data: Data("first".utf8))
        writer.add(path: "manifest.json", data: Data("second".utf8))
        XCTAssertThrowsError(try ZipReader.entries(of: writer.finish()))
    }

    func testArchivePreservesClassicZipMaximumEntryCount() throws {
        var writer = ZipWriter()
        for index in 0..<Int(UInt16.max) {
            writer.add(path: "captures/\(index).jpg", data: Data())
        }
        let entries = try ZipReader.entries(of: writer.finish())
        XCTAssertEqual(entries.count, Int(UInt16.max))
    }

    func testArchiveRejectsInvalidManifestAndDuplicateSequenceBeforeWritingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeLedger()
        let (_, event) = ChatRepository.createThread(title: "質問")
        try await source.append([event])
        let sourceEvents = try await source.events()
        let stored = try XCTUnwrap(sourceEvents.first)
        let exported = LedgerArchive.ExportedEvent(seq: 1, deviceID: source.deviceID, kind: stored.kind,
            entity: stored.entity, entityID: stored.entityId, payload: stored.payload, createdAt: stored.createdAt)
        for (version, count, events) in [(0, 1, [exported]), (1, 2, [exported]), (1, 2, [exported, exported])] {
            let manifest = LedgerArchive.Manifest(formatVersion: version, deviceID: source.deviceID,
                createdAt: LedgerClock.now(), eventCount: count)
            var writer = ZipWriter()
            writer.add(path: "manifest.json", data: try JSONEncoder().encode(manifest))
            writer.add(path: "ledger_events.json", data: try JSONEncoder().encode(events))
            writer.add(path: "captures/should-not-exist.jpg", data: Data([1]))
            let archive = root.appendingPathComponent("invalid.zip")
            try writer.finish().write(to: archive)
            let target = try makeLedger()
            do {
                try await LedgerArchive.importArchive(from: archive, into: target, root: root)
                XCTFail("壊れた台帳を取り込めてしまった")
            } catch {}
            let count = try await target.eventCount()
            XCTAssertEqual(count, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("captures/should-not-exist.jpg").path))
        }
    }

    @MainActor
    func testTurnCoordinatorPersistsGradedCaptureSummary() async throws {
        let ledger = try makeLedger()
        let captureID = "cap-coordinator"
        try await ledger.commit { db in
            var machine = try WorkbookMachine(loading: db)
            let unitID = machine.createUnit(
                title: "二次関数", outcome: "", source: "consult",
                subunits: [.init(title: "頂点", n: 1)], firstStage: 3
            )
            let subunitID = machine.orderedSubunits(unitID: unitID)[0].id
            let setID = machine.insertGeneratingSet(
                subunitID: subunitID,
                spec: try machine.nextSetSpec(subunitID: subunitID)
            )
            let problemID = machine.addProblems(
                subunitID: subunitID,
                problems: [.init(prompt: "例題")],
                source: "generated"
            )[0]
            machine.fillSet(setID: setID, problemIDs: [problemID])
            _ = try machine.createCapture(
                id: captureID, imagePath: "\(captureID).jpg", contentType: "image/jpeg",
                sha256: "0", byteCount: 1, subunitID: nil, setID: setID
            )
            return (machine.events, ())
        }

        let turns = TurnCoordinator(
            ledger: ledger,
            assets: AssetCache(lenient: true),
            runner: MockTurnRunner()
        )
        await turns.startGrading(captureID: captureID)

        var capture: WorkbookCaptureRecord?
        for _ in 0..<100 {
            capture = try await ledger.read { db in try WorkbookCaptureRecord.fetchOne(db, key: captureID) }
            if capture?.status != "identifying" { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let result = try XCTUnwrap(capture)
        XCTAssertEqual(result.status, "graded")
        XCTAssertEqual(result.summary["result"]?["correct"]?.intValue, 1)
        XCTAssertEqual(result.summary["result"]?["total"]?.intValue, 1)
        XCTAssertEqual(result.summary["outcome"]?.stringValue, "stage_advanced")
    }
}
