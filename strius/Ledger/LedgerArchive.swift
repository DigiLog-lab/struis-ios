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
        /// 期間を指定した・写真を除いた書き出し(調べる用)。true のファイルは取り込めない(途中からの記録では台帳を作り直せない)。
        /// 「すべて」の書き出しでは書かない(前の版のファイルと同じ形)。
        var partial: Bool? = nil
        /// 期間の始まり(この時刻以降に記録された出来事だけを入れた)。
        var since: String? = nil
        /// 答案の写真・質問の添付・記憶を入れたか。
        var includesFiles: Bool? = nil

        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case deviceID = "device_id"
            case createdAt = "created_at"
            case eventCount = "event_count"
            case partial
            case since
            case includesFiles = "includes_files"
        }
    }

    /// 書き出す範囲(設定の「書き出す」で選ぶ)。
    struct Scope: Sendable, Equatable {
        /// この時刻以降に記録された出来事だけ(nil はすべて)。
        var since: Date?
        /// 答案の写真・質問の添付・記憶を入れる(`diagnostics` はいつも入れる)。
        var includesFiles: Bool

        /// 端末の乗り換えに使える、すべての書き出し。
        static let everything = Scope(since: nil, includesFiles: true)

        /// 取り込みに使えない(調べる用の)書き出しか。
        var isPartial: Bool { since != nil || !includesFiles }
    }

    /// 設定で選べる期間。
    enum Period: String, CaseIterable, Identifiable, Sendable {
        case today
        case threeDays
        case sevenDays
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: return "今日"
            case .threeDays: return "直近3日"
            case .sevenDays: return "直近7日"
            case .all: return "すべて"
            }
        }

        /// 期間の始まり(端末の暦で、今日を含めて数えた日の 0 時)。「すべて」は nil。
        func since(now: Date = Date(), calendar: Calendar = .current) -> Date? {
            let days: Int
            switch self {
            case .today: days = 1
            case .threeDays: days = 3
            case .sevenDays: days = 7
            case .all: return nil
            }
            let today: Date = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        }

        /// ファイル名に付ける印(「すべて」は付けない)。
        var fileSuffix: String? {
            switch self {
            case .today: return "today"
            case .threeDays: return "3days"
            case .sevenDays: return "7days"
            case .all: return nil
            }
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

    static func fileName(date: Date = Date(), suffix: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let tail: String = suffix.map { "-" + $0 } ?? ""
        return "struis-ledger-\(formatter.string(from: date))\(tail).zip"
    }

    /// Write the archive to a temporary file and return its URL.
    /// - Parameters:
    ///   - scope: 書き出す範囲。既定はすべて(取り込みに使える)。
    ///   - suffix: ファイル名に付ける印(期間の名前)。
    static func export(ledger: Ledger, root: URL = StruisPaths.root, to directory: URL = FileManager.default.temporaryDirectory,
                       scope: Scope = .everything, suffix: String? = nil) async throws -> URL {
        return try await ledger.exportArchive(root: root, to: directory, scope: scope, suffix: suffix)
    }

    /// 書き出す出来事。期間を指定した時は、ターンの行(`turns`)は同じターンの最後の 1 件だけにする:
    /// ターンは待機・実行中・段階ごと・完了のたびに、AI に渡したプラン(その日の記録の全文を含む)ごと行を書き直すので、
    /// 1 回のターンで同じ記録が何回も複製される。最後の 1 件の実行記録に、途中の段階の時刻はすべて残っている。
    static func exportedEvents(_ stored: [StoredLedgerEvent], scope: Scope) -> [ExportedEvent] {
        var rows: [StoredLedgerEvent] = stored
        if let since = scope.since {
            let start: String = LedgerClock.iso(since)
            rows = rows.filter { $0.createdAt >= start }
            var lastTurnEvent: [String: Int64] = [:]
            for row in rows where row.entity == LedgerEntity.turns.rawValue {
                guard let seq = row.seq else { continue }
                lastTurnEvent[row.entityId] = max(lastTurnEvent[row.entityId] ?? seq, seq)
            }
            rows = rows.filter { row in row.entity != LedgerEntity.turns.rawValue || row.seq == lastTurnEvent[row.entityId] }
        }
        return rows.compactMap { row -> ExportedEvent? in
            guard let seq = row.seq else { return nil }
            return ExportedEvent(seq: seq, deviceID: row.deviceId, kind: row.kind, entity: row.entity, entityID: row.entityId, payload: row.payload, createdAt: row.createdAt)
        }
    }

    static func exportSnapshot(stored: [StoredLedgerEvent], deviceID: String, root: URL, directory: URL,
                               scope: Scope = .everything, suffix: String? = nil) throws -> URL {
        let events: [ExportedEvent] = exportedEvents(stored, scope: scope)
        var manifest = Manifest(formatVersion: formatVersion, deviceID: deviceID, createdAt: LedgerClock.now(), eventCount: events.count)
        if scope.isPartial {
            manifest.partial = true
            manifest.since = scope.since.map(LedgerClock.iso)
            manifest.includesFiles = scope.includesFiles
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manager = FileManager.default
        let target: URL = directory.appendingPathComponent(fileName(suffix: suffix))
        // 書きかけのファイルに書いてから置き換える(写真を全部メモリに載せず、1 つずつファイルへ書く)。
        let partialTarget: URL = directory.appendingPathComponent(target.lastPathComponent + ".part")
        try? manager.removeItem(at: partialTarget)
        guard manager.createFile(atPath: partialTarget.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle: FileHandle = try FileHandle(forWritingTo: partialTarget)
        do {
            var writer = ZipFileWriter(handle: handle)
            try writer.add(path: "manifest.json", data: try encoder.encode(manifest))
            try writer.add(path: "ledger_events.json", data: try encoder.encode(events))
            for name in fileRoots where scope.includesFiles || name == "diagnostics" {
                let base = root.appendingPathComponent(name, isDirectory: true)
                let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
                guard let enumerator = manager.enumerator(at: base, includingPropertiesForKeys: keys) else { continue }
                for case let url as URL in enumerator {
                    let values = try url.resourceValues(forKeys: Set(keys))
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    // 期間を指定した時の写真・添付・記憶は、その期間に書かれたものだけ(`diagnostics` は追記のファイルなので丸ごと)。
                    if let since = scope.since, name != "diagnostics", let modified = values.contentModificationDate, modified < since { continue }
                    let relative = url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1)
                    try writer.add(path: "\(name)/\(relative)", data: try Data(contentsOf: url))
                }
            }
            try writer.finish()
            try handle.close()
        } catch {
            try? handle.close()
            try? manager.removeItem(at: partialTarget)
            throw error
        }
        try? manager.removeItem(at: target)
        try manager.moveItem(at: partialTarget, to: target)
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
        guard manifest.partial != true else {
            throw LedgerError.invalid("期間を指定した・写真を除いた書き出しは調べる用なので、取り込めません。「すべて」で書き出したファイルを選んでください")
        }
        guard manifest.formatVersion <= formatVersion else { throw LedgerError.invalid("新しい版の台帳ファイルです。アプリを更新してください") }
        guard manifest.formatVersion == formatVersion else { throw LedgerError.invalid("未対応の台帳ファイルです") }
        let exported = try JSONDecoder().decode([ExportedEvent].self, from: eventsData).sorted { $0.seq < $1.seq }
        guard manifest.eventCount == exported.count,
              exported.allSatisfy({ $0.seq > 0 }),
              Set(exported.map(\.seq)).count == exported.count else {
            throw LedgerError.invalid("台帳の記録件数または順序が壊れています")
        }
        var events: [LedgerEvent] = []
        // Re-append in last-writer-wins order (Issue #51): an event taken in from another device can be
        // older than a local event stored before it.
        for row in exported.sorted(by: { ($0.createdAt, $0.deviceID, $0.seq) < ($1.createdAt, $1.deviceID, $1.seq) }) {
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
        let headers = Self.headers(path: path, data: data, offset: UInt32(body.count))
        body.append(headers.local)
        body.append(data)
        central.append(headers.central)
        count += 1
    }

    /// 1 つの項目の、ローカルヘッダと目次の行(圧縮なし)。
    static func headers(path: String, data: Data, offset: UInt32) -> (local: Data, central: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
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

        var central = Data()
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
        return (local, central)
    }

    func finish() -> Data {
        var out = body
        out.append(Self.end(central: central, centralOffset: UInt32(body.count), count: count))
        return out
    }

    /// 目次と終端の記録。
    static func end(central: Data, centralOffset: UInt32, count: UInt16) -> Data {
        var out = central
        out.append(le32: 0x0605_4b50)
        out.append(le16: 0); out.append(le16: 0)
        out.append(le16: count); out.append(le16: count)
        out.append(le32: UInt32(central.count))
        out.append(le32: centralOffset)
        out.append(le16: 0)
        return out
    }
}

/// 項目をファイルへ順に書く zip(書き出しで、写真を全部メモリに載せない)。形式は `ZipWriter` と同じ。
nonisolated struct ZipFileWriter {
    private let handle: FileHandle
    private var central = Data()
    private var count: UInt16 = 0
    private var offset: UInt32 = 0

    init(handle: FileHandle) {
        self.handle = handle
    }

    mutating func add(path: String, data: Data) throws {
        guard count < UInt16.max else { throw LedgerError.invalid("zip に入れる項目が多すぎます") }
        let headers = ZipWriter.headers(path: path, data: data, offset: offset)
        let written: UInt64 = UInt64(offset) + UInt64(headers.local.count) + UInt64(data.count)
        guard written <= UInt64(UInt32.max) else { throw LedgerError.invalid("zip が大きすぎます(4GB を超えます)") }
        try handle.write(contentsOf: headers.local)
        try handle.write(contentsOf: data)
        offset = UInt32(written)
        central.append(headers.central)
        count += 1
    }

    func finish() throws {
        try handle.write(contentsOf: ZipWriter.end(central: central, centralOffset: offset, count: count))
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
