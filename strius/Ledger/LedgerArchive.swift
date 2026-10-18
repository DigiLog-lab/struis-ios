import Compression
import Foundation
import GRDB

/// 台帳の書き出し / 取り込み (design §4.3)。`ledger_events` 全件と、画像 (`captures/`、
/// 質問の添付 `attachments/`)、記憶 (`memory/`) を 1 つの zip にまとめる。取り込みは空の台帳にだけ
/// 許し、イベントを再生して射影を作る。サーバーが無くても端末を乗り換えられる。
nonisolated enum LedgerArchive {
    static let formatVersion = 1

    struct Manifest: Codable, Sendable {
        var formatVersion: Int
        var deviceID: String
        var createdAt: String
        var eventCount: Int

        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case deviceID = "device_id"
            case createdAt = "created_at"
            case eventCount = "event_count"
        }
    }

    /// One exported event as stored on the source device. On import the events are re-appended
    /// under the new device's `device_id` and `seq`; the original pair stays in the file for reference.
    struct ExportedEvent: Codable, Sendable {
        var seq: Int64
        var deviceID: String
        var kind: String
        var entity: String
        var entityID: String
        var payload: String
        var createdAt: String

        enum CodingKeys: String, CodingKey {
            case seq, kind, entity, payload
            case deviceID = "device_id"
            case entityID = "entity_id"
            case createdAt = "created_at"
        }
    }

    /// Directories under `StruisPaths.root` carried in the archive. `diagnostics` holds app-side records
    /// (`math_fallback.jsonl`: formulas SwiftMath could not parse, Issue #28) so an exported ledger shows them.
    static let fileRoots = ["captures", "attachments", "memory", "diagnostics"]

    static func fileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "struis-ledger-\(formatter.string(from: date)).zip"
    }

    /// Write the archive to a temporary file and return its URL.
    static func export(ledger: Ledger, root: URL = StruisPaths.root, to directory: URL = FileManager.default.temporaryDirectory) async throws -> URL {
        return try await ledger.exportArchive(root: root, to: directory)
    }

    static func exportSnapshot(stored: [StoredLedgerEvent], deviceID: String, root: URL, directory: URL) throws -> URL {
        let events = stored.compactMap { row -> ExportedEvent? in
            guard let seq = row.seq else { return nil }
            return ExportedEvent(seq: seq, deviceID: row.deviceId, kind: row.kind, entity: row.entity, entityID: row.entityId, payload: row.payload, createdAt: row.createdAt)
        }
        let manifest = Manifest(formatVersion: formatVersion, deviceID: deviceID, createdAt: LedgerClock.now(), eventCount: events.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var writer = ZipWriter()
        writer.add(path: "manifest.json", data: try encoder.encode(manifest))
        writer.add(path: "ledger_events.json", data: try encoder.encode(events))
        let manager = FileManager.default
        for name in fileRoots {
            let base = root.appendingPathComponent(name, isDirectory: true)
            guard let enumerator = manager.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let relative = url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1)
                writer.add(path: "\(name)/\(relative)", data: try Data(contentsOf: url))
            }
        }
        let target = directory.appendingPathComponent(fileName())
        try? manager.removeItem(at: target)
        try writer.finish().write(to: target, options: .atomic)
        return target
    }

    struct ImportJournal: Codable, Sendable {
        var id: String
        var changes: [UnitDeletion.Change]
    }

    static func importJournalURL(_ root: URL) -> URL { root.appendingPathComponent("archive-import.json") }

    static func recoverImport(queue: DatabaseQueue, root: URL) throws {
        let url = importJournalURL(root)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let journal = try JSONDecoder().decode(ImportJournal.self, from: Data(contentsOf: url))
        let committed = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM ledger_meta WHERE key='archive_import_id'") == journal.id
        }
        for change in journal.changes.reversed() { try UnitDeletion.write(change, restoring: !committed) }
        try FileManager.default.removeItem(at: url)
    }

    /// Files and events are committed together; interrupted imports recover before ledger reads.
    @discardableResult
    static func importArchive(from url: URL, into ledger: Ledger, root: URL = StruisPaths.root) async throws -> Manifest {
        guard try await ledger.eventCount() == 0 else { throw LedgerError.conflict("取り込みは空の台帳にだけできます") }
        let entries = try ZipReader.entries(of: Data(contentsOf: url))
        guard let manifestData = entries["manifest.json"], let eventsData = entries["ledger_events.json"] else {
            throw LedgerError.invalid("Struis の台帳ファイルではありません")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.formatVersion <= formatVersion else { throw LedgerError.invalid("新しい版の台帳ファイルです。アプリを更新してください") }
        guard manifest.formatVersion == formatVersion else { throw LedgerError.invalid("未対応の台帳ファイルです") }
        let exported = try JSONDecoder().decode([ExportedEvent].self, from: eventsData).sorted { $0.seq < $1.seq }
        guard manifest.eventCount == exported.count,
              exported.allSatisfy({ $0.seq > 0 }),
              Set(exported.map(\.seq)).count == exported.count else {
            throw LedgerError.invalid("台帳の記録件数または順序が壊れています")
        }
        var events: [LedgerEvent] = []
        for row in exported {
            guard let entity = LedgerEntity(rawValue: row.entity), let payload = LedgerJSON.parse(row.payload) else {
                throw LedgerError.invalid("読めないイベントがあります (seq \(row.seq))")
            }
            events.append(LedgerEvent(kind: row.kind, entity: entity, entityID: row.entityID, payload: payload))
        }
        var files: [String: Data] = [:]
        for (path, data) in entries where fileRoots.contains(where: { path.hasPrefix($0 + "/") }) {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { throw LedgerError.invalid("不正なパス: \(path)") }
            files[path] = data
        }
        try await ledger.importArchive(events: events, files: files, root: root)
        return manifest
    }
}

// MARK: - Minimal zip (store on write; store + deflate on read)

nonisolated struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count: UInt16 = 0

    mutating func add(path: String, data: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        let offset = UInt32(body.count)
        var local = Data()
        local.append(le32: 0x0403_4b50)
        local.append(le16: 20)          // version needed
        local.append(le16: 0x0800)      // UTF-8 names
        local.append(le16: 0)           // stored
        local.append(le16: 0); local.append(le16: 0x21)  // time / date (1980-01-01)
        local.append(le32: crc)
        local.append(le32: UInt32(data.count))
        local.append(le32: UInt32(data.count))
        local.append(le16: UInt16(name.count))
        local.append(le16: 0)
        local.append(name)
        body.append(local)
        body.append(data)

        central.append(le32: 0x0201_4b50)
        central.append(le16: 20); central.append(le16: 20)
        central.append(le16: 0x0800); central.append(le16: 0)
        central.append(le16: 0); central.append(le16: 0x21)
        central.append(le32: crc)
        central.append(le32: UInt32(data.count)); central.append(le32: UInt32(data.count))
        central.append(le16: UInt16(name.count))
        central.append(le16: 0); central.append(le16: 0); central.append(le16: 0); central.append(le16: 0)
        central.append(le32: 0)
        central.append(le32: offset)
        central.append(name)
        count += 1
    }

    func finish() -> Data {
        var out = body
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32: 0x0605_4b50)
        out.append(le16: 0); out.append(le16: 0)
        out.append(le16: count); out.append(le16: count)
        out.append(le32: UInt32(central.count))
        out.append(le32: centralOffset)
        out.append(le16: 0)
        return out
    }
}

nonisolated enum ZipReader {
    static func entries(of data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard bytes.count >= 22 else { throw LedgerError.invalid("zip が短すぎます") }
        var end = bytes.count - 22
        let earliestEnd = max(0, bytes.count - 22 - Int(UInt16.max))
        while end >= earliestEnd {
            if u32(end) == 0x0605_4b50, end + 22 + u16(end + 20) == bytes.count { break }
            end -= 1
        }
        guard end >= earliestEnd else { throw LedgerError.invalid("zip の終端が見つかりません") }
        let total = u16(end + 10)
        var cursor = u32(end + 16)
        let centralStart = cursor
        let centralEnd = cursor + u32(end + 12)
        guard u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == total,
              centralEnd == end else {
            throw LedgerError.invalid("zip の目次が壊れています")
        }
        var result: [String: Data] = [:]
        var names = Set<String>()
        for _ in 0..<total {
            guard cursor + 46 <= centralEnd, u32(cursor) == 0x0201_4b50 else { throw LedgerError.invalid("zip の目次が壊れています") }
            let flags = u16(cursor + 8)
            let method = u16(cursor + 10)
            let crc = UInt32(u32(cursor + 16))
            let compressed = u32(cursor + 20)
            let size = u32(cursor + 24)
            let nameLength = u16(cursor + 28), extraLength = u16(cursor + 30), commentLength = u16(cursor + 32)
            let localOffset = u32(cursor + 42)
            let nextCursor = cursor + 46 + nameLength + extraLength + commentLength
            guard nextCursor <= centralEnd, nameLength > 0,
                  let name = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8),
                  names.insert(name).inserted,
                  flags & 0x0041 == 0, u16(cursor + 34) == 0,
                  localOffset + 30 <= centralStart, u32(localOffset) == 0x0403_4b50 else {
                throw LedgerError.invalid("zip の項目が壊れています")
            }
            let localNameLength = u16(localOffset + 26)
            let dataStart = localOffset + 30 + localNameLength + u16(localOffset + 28)
            guard dataStart <= centralStart, dataStart + compressed <= centralStart,
                  u16(localOffset + 6) == flags, u16(localOffset + 8) == method,
                  localNameLength == nameLength,
                  bytes[(localOffset + 30)..<(localOffset + 30 + localNameLength)] == bytes[(cursor + 46)..<(cursor + 46 + nameLength)] else {
                throw LedgerError.invalid("zip のデータが足りないか、目次と一致しません")
            }
            cursor = nextCursor
            guard !name.hasSuffix("/") else { continue }
            let raw = Data(bytes[dataStart..<(dataStart + compressed)])
            let content: Data
            switch method {
            case 0: content = raw
            case 8: content = try inflate(raw, size: size)
            default: throw LedgerError.invalid("未対応の圧縮形式 (\(method))")
            }
            guard content.count == size, CRC32.checksum(content) == crc else { throw LedgerError.invalid("zip の検査値が合いません: \(name)") }
            result[name] = content
        }
        guard cursor == centralEnd else { throw LedgerError.invalid("zip の目次の件数が合いません") }
        return result
    }

    private static func inflate(_ data: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        guard !data.isEmpty else { throw LedgerError.invalid("zip の圧縮データがありません") }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_decode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, size,
                    input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw LedgerError.invalid("zip の展開に失敗しました") }
        return output
    }
}

nonisolated enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
