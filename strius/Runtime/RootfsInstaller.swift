import Compression
import CryptoKit
import Foundation
import SQLite3

/// The bundled guest rootfs (`rootfs-v<N>.tar.gz`, built by `Runtime/rootfs/build.py`).
nonisolated struct RootfsManifest: Sendable, Equatable {
    let version: Int
    let archiveName: String
    let sha256: String
    let codexVersion: String
    let alpineVersion: String

    static func bundled(in bundle: Bundle = .main) throws -> RootfsManifest {
        guard let url = bundle.url(forResource: "rootfs-manifest", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["version"] as? Int,
              let archive = plist["archive"] as? String,
              let sha256 = plist["sha256"] as? String
        else { throw RootfsInstallerError.manifestMissing }
        return RootfsManifest(
            version: version, archiveName: archive, sha256: sha256,
            codexVersion: plist["codex"] as? String ?? "", alpineVersion: plist["alpine"] as? String ?? ""
        )
    }

    func archiveURL(in bundle: Bundle = .main) throws -> URL {
        let name = (archiveName as NSString).deletingPathExtension  // rootfs-v1.tar
        let base = (name as NSString).deletingPathExtension          // rootfs-v1
        guard let url = bundle.url(forResource: base, withExtension: "tar.gz") else {
            throw RootfsInstallerError.archiveMissing(archiveName)
        }
        return url
    }
}

nonisolated enum RootfsInstallerError: Error, LocalizedError, Sendable {
    case manifestMissing
    case archiveMissing(String)
    case checksumMismatch(expected: String, actual: String)
    case corruptArchive(String)
    case sqlite(String)
    case posix(String, Int32)

    var errorDescription: String? {
        switch self {
        case .manifestMissing: "同梱された実行環境の情報が見つかりません"
        case .archiveMissing(let name): "同梱された実行環境 \(name) が見つかりません"
        case .checksumMismatch: "同梱された実行環境が壊れています"
        case .corruptArchive(let detail): "実行環境の展開に失敗しました (\(detail))"
        case .sqlite(let detail): "実行環境の索引を作れませんでした (\(detail))"
        case .posix(let what, let code): "実行環境の展開に失敗しました (\(what): \(code))"
        }
    }
}

/// Expands a GNU tar.gz into an iSH fakefs v3 (`meta.db` + `data/`), the on-disk
/// format that `HyotanRuntime.bootRoot:` mounts as `/`.
///
/// Format (from hyotan `tools/fakefs.c` / `fs/fake-db.h`):
///   meta(id, db_inode)         — db_inode 0 makes the runtime rebuild inode numbers on first mount
///   stats(inode PK, stat BLOB) — 16 bytes little-endian: mode, uid, gid, rdev
///   paths(path BLOB PK, inode) — "/usr/bin/sh" style keys, "" for the root
/// Symlinks are regular host files whose contents are the link target; hardlinks share an inode.
nonisolated enum RootfsInstaller {
    struct Progress: Sendable {
        let fraction: Double
        let entries: Int
    }

    /// Verify the archive against the manifest and expand it into `destination`.
    /// `destination` must not exist; a `.installing` sibling is used and renamed at the end.
    static func install(
        manifest: RootfsManifest,
        archive: URL,
        destination: URL,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) throws {
        let actual = try sha256Hex(of: archive)
        guard actual == manifest.sha256 else {
            throw RootfsInstallerError.checksumMismatch(expected: manifest.sha256, actual: actual)
        }
        let fileManager = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".installing", isDirectory: true)
        if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let dataRoot = staging.appendingPathComponent("data", isDirectory: true)
        try fileManager.createDirectory(at: dataRoot, withIntermediateDirectories: true)

        let totalBytes = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init) ?? 1
        let db = try FakeFSDatabase(path: staging.appendingPathComponent("meta.db").path)
        defer { db.close() }
        try db.begin()
        var entries = 0
        var rootSeen = false
        let reader = try GzipTarReader(url: archive)
        var longName: String?
        var longLink: String?
        while let header = try reader.nextHeader() {
            var name = longName ?? header.name
            var linkName = longLink ?? header.linkName
            longName = nil
            longLink = nil
            switch header.type {
            case "L":  // GNU long name
                longName = try reader.readString(size: header.size)
                continue
            case "K":  // GNU long link
                longLink = try reader.readString(size: header.size)
                continue
            case "g", "x":  // pax headers: not produced by build.py; skip payload
                try reader.skip(size: header.size)
                continue
            default:
                break
            }
            name = normalize(name)
            if name.isEmpty { rootSeen = true }
            let hostPath = name.isEmpty ? dataRoot.path : dataRoot.path + "/" + name
            let key = name.isEmpty ? "" : "/" + name
            try makeParents(of: hostPath, under: dataRoot.path, db: db)
            switch header.type {
            case "5":
                if mkdir(hostPath, 0o755) != 0, errno != EEXIST {
                    throw RootfsInstallerError.posix("mkdir \(name)", errno)
                }
                try db.insert(path: key, mode: UInt32(S_IFDIR) | (header.mode & 0o7777), uid: header.uid, gid: header.gid)
            case "2":
                linkName = normalizeLinkTarget(linkName)
                try writeFile(at: hostPath, name: name) { fd in
                    var bytes = Array(linkName.utf8)
                    let written = write(fd, &bytes, bytes.count)
                    if written != bytes.count { throw RootfsInstallerError.posix("symlink \(name)", errno) }
                }
                try db.insert(path: key, mode: UInt32(S_IFLNK) | 0o777, uid: header.uid, gid: header.gid)
            case "1":
                let target = normalize(linkName)
                let targetPath = dataRoot.path + "/" + target
                unlink(hostPath)
                if link(targetPath, hostPath) != 0 { throw RootfsInstallerError.posix("link \(name)", errno) }
                try db.insertHardlink(path: key, target: "/" + target)
            case "0", "\0", "7":
                try writeFile(at: hostPath, name: name) { fd in
                    try reader.copy(size: header.size, to: fd)
                }
                try db.insert(path: key, mode: UInt32(S_IFREG) | (header.mode & 0o7777), uid: header.uid, gid: header.gid)
            case "3", "4", "6":
                try reader.skip(size: header.size)  // device nodes are created by the runtime at boot
            default:
                try reader.skip(size: header.size)
            }
            entries += 1
            if entries % 200 == 0 {
                progress(Progress(fraction: min(0.99, reader.consumedCompressedBytes / totalBytes), entries: entries))
            }
        }
        if !rootSeen {
            try db.insert(path: "", mode: UInt32(S_IFDIR) | 0o755, uid: 0, gid: 0)
        }
        try db.commit()
        db.close()
        progress(Progress(fraction: 1, entries: entries))

        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path
        )
        var excluded = staging
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let marker = ["version": manifest.version, "sha256": manifest.sha256, "entries": entries] as [String: Any]
        let markerData = try JSONSerialization.data(withJSONObject: marker)
        try markerData.write(to: staging.appendingPathComponent("installed.json"))
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: staging, to: destination)
    }

    static func isInstalled(at destination: URL, manifest: RootfsManifest) -> Bool {
        let marker = destination.appendingPathComponent("installed.json")
        guard let data = try? Data(contentsOf: marker),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == manifest.version,
              object["sha256"] as? String == manifest.sha256
        else { return false }
        return FileManager.default.fileExists(atPath: destination.appendingPathComponent("meta.db").path)
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private static var createdDirectories = Set<String>()

    private static func makeParents(of hostPath: String, under root: String, db: FakeFSDatabase) throws {
        let relative = hostPath.hasPrefix(root + "/") ? String(hostPath.dropFirst(root.count + 1)) : ""
        var components = relative.split(separator: "/").map(String.init)
        guard components.count > 1 else { return }
        components.removeLast()
        var current = root
        var key = ""
        for component in components {
            current += "/" + component
            key += "/" + component
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: current, isDirectory: &isDirectory) {
                continue
            }
            if mkdir(current, 0o755) != 0, errno != EEXIST {
                throw RootfsInstallerError.posix("mkdir -p \(key)", errno)
            }
            try db.insert(path: key, mode: UInt32(S_IFDIR) | 0o755, uid: 0, gid: 0)
        }
    }

    private static func writeFile(at hostPath: String, name: String, body: (Int32) throws -> Void) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDirectory), isDirectory.boolValue {
            throw RootfsInstallerError.corruptArchive("file replaces directory: \(name)")
        }
        unlink(hostPath)
        let fd = open(hostPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw RootfsInstallerError.posix("open \(name)", errno) }
        defer { close(fd) }
        try body(fd)
    }

    static func normalize(_ raw: String) -> String {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        // The build script never emits "..", and the runtime must not be pointed outside data/.
        return parts.filter { $0 != ".." }.joined(separator: "/")
    }

    private static func normalizeLinkTarget(_ raw: String) -> String {
        raw.isEmpty ? "." : raw
    }
}

/// `meta.db` writer.
nonisolated final class FakeFSDatabase {
    private var db: OpaquePointer?
    private var insertStat: OpaquePointer?
    private var insertPath: OpaquePointer?
    private var insertHardlink: OpaquePointer?

    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle else {
            throw RootfsInstallerError.sqlite("open")
        }
        db = handle
        try exec("pragma journal_mode=wal")
        try exec(
            """
            create table meta (id integer unique default 0, db_inode integer);
            insert into meta (db_inode) values (0);
            create table stats (inode integer primary key, stat blob);
            create table paths (path blob primary key, inode integer references stats(inode));
            create index inode_to_path on paths (inode, path);
            pragma user_version=3;
            """
        )
        insertStat = try prepare("insert into stats (stat) values (?)")
        insertPath = try prepare("insert or replace into paths values (?, ?)")
        insertHardlink = try prepare("insert or replace into paths values (?, (select inode from paths where path = ? limit 1))")
    }

    func begin() throws { try exec("begin") }
    func commit() throws { try exec("commit") }

    func insert(path: String, mode: UInt32, uid: UInt32, gid: UInt32, rdev: UInt32 = 0) throws {
        guard let db, let insertStat, let insertPath else { throw RootfsInstallerError.sqlite("closed") }
        var blob = [UInt8]()
        blob.reserveCapacity(16)
        for value in [mode, uid, gid, rdev] {
            blob.append(UInt8(value & 0xff))
            blob.append(UInt8((value >> 8) & 0xff))
            blob.append(UInt8((value >> 16) & 0xff))
            blob.append(UInt8((value >> 24) & 0xff))
        }
        sqlite3_bind_blob(insertStat, 1, blob, 16, transient)
        guard sqlite3_step(insertStat) == SQLITE_DONE else { throw RootfsInstallerError.sqlite(message()) }
        sqlite3_reset(insertStat)
        let inode = sqlite3_last_insert_rowid(db)
        let key = Array(path.utf8)
        sqlite3_bind_blob(insertPath, 1, key, Int32(key.count), transient)
        sqlite3_bind_int64(insertPath, 2, inode)
        guard sqlite3_step(insertPath) == SQLITE_DONE else { throw RootfsInstallerError.sqlite(message()) }
        sqlite3_reset(insertPath)
    }

    func insertHardlink(path: String, target: String) throws {
        guard let insertHardlink else { throw RootfsInstallerError.sqlite("closed") }
        let key = Array(path.utf8)
        let targetKey = Array(target.utf8)
        sqlite3_bind_blob(insertHardlink, 1, key, Int32(key.count), transient)
        sqlite3_bind_blob(insertHardlink, 2, targetKey, Int32(targetKey.count), transient)
        guard sqlite3_step(insertHardlink) == SQLITE_DONE else { throw RootfsInstallerError.sqlite(message()) }
        sqlite3_reset(insertHardlink)
    }

    func close() {
        for statement in [insertStat, insertPath, insertHardlink] where statement != nil {
            sqlite3_finalize(statement)
        }
        insertStat = nil
        insertPath = nil
        insertHardlink = nil
        if let db { sqlite3_close(db) }
        db = nil
    }

    private var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw RootfsInstallerError.sqlite("closed") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let text = error.map { String(cString: $0) } ?? "exec"
            sqlite3_free(error)
            throw RootfsInstallerError.sqlite(text)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw RootfsInstallerError.sqlite("closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RootfsInstallerError.sqlite(message())
        }
        return statement
    }

    private func message() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite"
    }
}

/// Streaming gunzip + tar header parser over a file. Only the subset written by
/// `build.py` (GNU format, ustar headers, 'L'/'K' long names) is required, but
/// pax headers are skipped gracefully.
nonisolated final class GzipTarReader {
    struct Header {
        let name: String
        let mode: UInt32
        let uid: UInt32
        let gid: UInt32
        let size: Int
        let type: Character
        let linkName: String
    }

    private let handle: FileHandle
    private var stream: compression_stream
    private var compressedBuffer = Data()
    private var compressedOffset = 0
    private var decoded = Data()
    private var decodedOffset = 0
    private var finished = false
    private(set) var consumedCompressedBytes: Double = 0
    private let inputChunk = 512 * 1024
    private let outputChunk = 1024 * 1024
    private let outputScratch: UnsafeMutablePointer<UInt8>

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw RootfsInstallerError.corruptArchive("zlib init")
        }
        outputScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: outputChunk)
        try skipGzipHeader()
    }

    deinit {
        compression_stream_destroy(&stream)
        outputScratch.deallocate()
        try? handle.close()
    }

    // MARK: gzip framing

    private func skipGzipHeader() throws {
        guard let head = try handle.read(upToCount: 10), head.count == 10, head[0] == 0x1f, head[1] == 0x8b, head[2] == 8 else {
            throw RootfsInstallerError.corruptArchive("gzip header")
        }
        let flags = head[3]
        consumedCompressedBytes = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard let lengthBytes = try handle.read(upToCount: 2), lengthBytes.count == 2 else { throw RootfsInstallerError.corruptArchive("gzip extra") }
            let length = Int(lengthBytes[0]) | (Int(lengthBytes[1]) << 8)
            _ = try handle.read(upToCount: length)
            consumedCompressedBytes += Double(2 + length)
        }
        if flags & 0x08 != 0 { try skipZeroTerminated() }  // FNAME
        if flags & 0x10 != 0 { try skipZeroTerminated() }  // FCOMMENT
        if flags & 0x02 != 0 { _ = try handle.read(upToCount: 2); consumedCompressedBytes += 2 }  // FHCRC
    }

    private func skipZeroTerminated() throws {
        while let byte = try handle.read(upToCount: 1), byte.count == 1 {
            consumedCompressedBytes += 1
            if byte[0] == 0 { return }
        }
        throw RootfsInstallerError.corruptArchive("gzip name")
    }

    // MARK: decompression

    /// Fill `decoded` with at least `count` unread bytes when possible.
    private func ensureDecoded(_ count: Int) throws {
        while decoded.count - decodedOffset < count, !finished {
            try decodeMore()
        }
    }

    private func decodeMore() throws {
        if decodedOffset > 0 {
            decoded.removeSubrange(0..<decodedOffset)
            decodedOffset = 0
        }
        if compressedOffset >= compressedBuffer.count {
            compressedBuffer = try handle.read(upToCount: inputChunk) ?? Data()
            compressedOffset = 0
            consumedCompressedBytes += Double(compressedBuffer.count)
        }
        let flags = compressedBuffer.isEmpty ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        try compressedBuffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_ptr = base + compressedOffset
            stream.src_size = compressedBuffer.count - compressedOffset
            stream.dst_ptr = outputScratch
            stream.dst_size = outputChunk
            let status = compression_stream_process(&stream, flags)
            let produced = outputChunk - stream.dst_size
            let consumed = (compressedBuffer.count - compressedOffset) - stream.src_size
            compressedOffset += consumed
            if produced > 0 { decoded.append(outputScratch, count: produced) }
            switch status {
            case COMPRESSION_STATUS_END:
                finished = true
            case COMPRESSION_STATUS_ERROR:
                throw RootfsInstallerError.corruptArchive("deflate")
            default:
                if compressedBuffer.isEmpty, produced == 0 { finished = true }
            }
        }
    }

    private func take(_ count: Int) throws -> Data {
        try ensureDecoded(count)
        guard decoded.count - decodedOffset >= count else {
            throw RootfsInstallerError.corruptArchive("unexpected end of archive")
        }
        let slice = decoded.subdata(in: decodedOffset..<(decodedOffset + count))
        decodedOffset += count
        return slice
    }

    // MARK: tar

    func nextHeader() throws -> Header? {
        try ensureDecoded(512)
        if decoded.count - decodedOffset < 512 { return nil }
        let block = try take(512)
        if block.allSatisfy({ $0 == 0 }) { return nil }  // end-of-archive marker
        func field(_ range: Range<Int>) -> String {
            let bytes = block.subdata(in: range)
            let trimmed = bytes.prefix { $0 != 0 }
            return String(decoding: trimmed, as: UTF8.self)
        }
        func number(_ range: Range<Int>) -> UInt64 {
            let bytes = block.subdata(in: range)
            if let first = bytes.first, first & 0x80 != 0 {  // GNU base-256
                var value: UInt64 = 0
                for (index, byte) in bytes.enumerated() {
                    value = (value << 8) | UInt64(index == 0 ? (byte & 0x7f) : byte)
                }
                return value
            }
            var value: UInt64 = 0
            for byte in bytes {
                if byte == 0 || byte == 0x20 { if value == 0 { continue } else { break } }
                guard byte >= 0x30, byte <= 0x37 else { break }
                value = value * 8 + UInt64(byte - 0x30)
            }
            return value
        }
        let magic = field(257..<263)
        var name = field(0..<100)
        if magic.hasPrefix("ustar") {
            let prefix = field(345..<500)
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        let typeByte = block[156]
        let type = typeByte == 0 ? Character("\0") : Character(UnicodeScalar(typeByte))
        return Header(
            name: name, mode: UInt32(number(100..<108)), uid: UInt32(number(108..<116)), gid: UInt32(number(116..<124)),
            size: Int(number(124..<136)), type: type, linkName: field(157..<257)
        )
    }

    private func padded(_ size: Int) -> Int {
        (size + 511) / 512 * 512
    }

    func readString(size: Int) throws -> String {
        let data = try take(padded(size)).prefix(size)
        let trimmed = data.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    func skip(size: Int) throws {
        var remaining = padded(size)
        while remaining > 0 {
            let step = min(remaining, outputChunk)
            _ = try take(step)
            remaining -= step
        }
    }

    func copy(size: Int, to fd: Int32) throws {
        var remaining = size
        while remaining > 0 {
            let step = min(remaining, outputChunk)
            let chunk = try take(step)
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw RootfsInstallerError.posix("write", errno)
                    }
                    offset += written
                }
            }
            remaining -= step
        }
        let padding = padded(size) - size
        if padding > 0 { _ = try take(padding) }
    }
}
