import XCTest
@testable import strius

/// 台帳の書き出しの期間指定(2026-10-31): 期間の出来事だけ・ターンは最後の 1 件だけ・写真を除ける・取り込みには使えない。
final class LedgerArchiveScopeTests: XCTestCase {
    private func stored(_ seq: Int64, entity: LedgerEntity, id: String, at createdAt: String) -> StoredLedgerEvent {
        StoredLedgerEvent(seq: seq, deviceId: "d", event: LedgerEvent(kind: "\(entity.rawValue).k", entity: entity, entityID: id, payload: .emptyObject),
                          createdAt: createdAt)
    }

    private func temporaryRoot(_ name: String) throws -> URL {
        let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testPeriodKeepsOnlyItsEventsAndTheLastEventOfEachTurn() {
        let since: Date = Date(timeIntervalSince1970: 1_793_404_800) // 2026-10-31T00:00:00Z
        let rows: [StoredLedgerEvent] = [
            stored(1, entity: .workbookUnits, id: "u", at: "2026-10-30T10:00:00.000000+00:00"),
            stored(2, entity: .turns, id: "t1", at: "2026-10-31T01:00:00.000000+00:00"),
            stored(3, entity: .turns, id: "t1", at: "2026-10-31T01:00:01.000000+00:00"),
            stored(4, entity: .timelineCards, id: "c", at: "2026-10-31T01:00:02.000000+00:00"),
            stored(5, entity: .turns, id: "t1", at: "2026-10-31T01:00:03.000000+00:00"),
            stored(6, entity: .turns, id: "t2", at: "2026-10-31T01:00:04.000000+00:00"),
        ]
        let partial = LedgerArchive.exportedEvents(rows, scope: LedgerArchive.Scope(since: since, includesFiles: false))
        XCTAssertEqual(partial.map(\.seq), [4, 5, 6], "前の日の出来事は入れず、ターンは最後の 1 件だけ")
        let everything = LedgerArchive.exportedEvents(rows, scope: .everything)
        XCTAssertEqual(everything.map(\.seq), [1, 2, 3, 4, 5, 6], "すべての書き出しは今まで通り全件")
    }

    func testPeriodStartsAtMidnightCountingToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let now: Date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9, minute: 13)))
        XCTAssertEqual(LedgerArchive.Period.today.since(now: now, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 10, day: 31)))
        XCTAssertEqual(LedgerArchive.Period.threeDays.since(now: now, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 10, day: 29)))
        XCTAssertNil(LedgerArchive.Period.all.since(now: now, calendar: calendar))
    }

    func testPartialArchiveLeavesOutFilesAndCannotBeImported() async throws {
        let source: Ledger = try Ledger.inMemory()
        try await source.commit { db in
            var machine = try WorkbookMachine(loading: db)
            machine.createUnit(title: "三角比", outcome: "", source: "consult", subunits: [.init(title: "sin", n: 2)], firstStage: 3)
            return (machine.events, ())
        }
        let root: URL = try temporaryRoot("archive-scope")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("captures"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("diagnostics"), withIntermediateDirectories: true)
        try Data([0xff, 0xd8]).write(to: root.appendingPathComponent("captures/cap.jpg"))
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("diagnostics/math_fallback.jsonl"))

        let scope = LedgerArchive.Scope(since: Date(timeIntervalSinceNow: -3600), includesFiles: false)
        let archive: URL = try await LedgerArchive.export(ledger: source, root: root, to: root, scope: scope, suffix: "today")
        XCTAssertTrue(archive.lastPathComponent.hasSuffix("-today.zip"))
        let entries: [String: Data] = try ZipReader.entries(of: Data(contentsOf: archive))
        XCTAssertNil(entries["captures/cap.jpg"], "写真を除いた")
        XCTAssertNotNil(entries["diagnostics/math_fallback.jsonl"], "診断の記録はいつも入れる")
        let manifest = try JSONDecoder().decode(LedgerArchive.Manifest.self, from: try XCTUnwrap(entries["manifest.json"]))
        XCTAssertEqual(manifest.partial, true)
        XCTAssertEqual(manifest.includesFiles, false)
        XCTAssertGreaterThan(manifest.eventCount, 0, "直前に作った単元の出来事は期間に入る")

        let target: Ledger = try Ledger.inMemory()
        do {
            _ = try await LedgerArchive.importArchive(from: archive, into: target, root: try temporaryRoot("archive-scope-dst"))
            XCTFail("期間を指定した書き出しを取り込めてしまった")
        } catch {}
        let imported: Int = try await target.eventCount()
        XCTAssertEqual(imported, 0)
    }

    func testFullArchiveManifestKeepsThePreviousShape() async throws {
        let source: Ledger = try Ledger.inMemory()
        let root: URL = try temporaryRoot("archive-full")
        let archive: URL = try await LedgerArchive.export(ledger: source, root: root, to: root)
        let entries: [String: Data] = try ZipReader.entries(of: Data(contentsOf: archive))
        let object = try JSONSerialization.jsonObject(with: try XCTUnwrap(entries["manifest.json"])) as? [String: Any]
        XCTAssertNil(object?["partial"], "すべての書き出しには期間の印を書かない")
        XCTAssertFalse(archive.lastPathComponent.contains("today"))
    }

    func testFileWriterProducesTheSameZipAsTheMemoryWriter() throws {
        let root: URL = try temporaryRoot("zip-file")
        let url: URL = root.appendingPathComponent("a.zip")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle: FileHandle = try FileHandle(forWritingTo: url)
        var fileWriter = ZipFileWriter(handle: handle)
        try fileWriter.add(path: "manifest.json", data: Data("{}".utf8))
        try fileWriter.add(path: "captures/x.jpg", data: Data([1, 2, 3]))
        try fileWriter.finish()
        try handle.close()
        var memoryWriter = ZipWriter()
        memoryWriter.add(path: "manifest.json", data: Data("{}".utf8))
        memoryWriter.add(path: "captures/x.jpg", data: Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: url), memoryWriter.finish())
        XCTAssertEqual(try ZipReader.entries(of: Data(contentsOf: url))["captures/x.jpg"], Data([1, 2, 3]))
    }
}
