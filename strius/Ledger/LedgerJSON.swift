import Foundation
import GRDB

/// A Codable JSON tree used for ledger columns that hold free-form JSON
/// (`overview`, `metadata`, `verdicts`, …) and for event payloads.
nonisolated indirect enum LedgerJSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LedgerJSON])
    case object([String: LedgerJSON])

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let value = try? single.decode([LedgerJSON].self) {
            self = .array(value)
        } else if let value = try? single.decode([String: LedgerJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: single, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null: try single.encodeNil()
        case .bool(let value): try single.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { try single.encode(Int64(value)) } else { try single.encode(value) }
        case .string(let value): try single.encode(value)
        case .array(let value): try single.encode(value)
        case .object(let value): try single.encode(value)
        }
    }

    // MARK: - Bridging with Foundation JSON objects

    init(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let value as LedgerJSON: self = value
        case let value as Bool where Self.isBool(any): self = .bool(value)
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map(LedgerJSON.init(any:)))
        case let value as [String: Any]: self = .object(value.mapValues(LedgerJSON.init(any:)))
        case let value as Date: self = .string(LedgerClock.iso(value))
        case let value as UUID: self = .string(value.uuidString.lowercased())
        default: self = .string(String(describing: any))
        }
    }

    private static func isBool(_ any: Any) -> Bool {
        guard let number = any as? NSNumber else { return any is Bool }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value as Any
        case .string(let value): value
        case .array(let value): value.map(\.any)
        case .object(let value): value.mapValues(\.any)
        }
    }

    var objectValue: [String: LedgerJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [LedgerJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        doubleValue.map { Int($0) }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    subscript(key: String) -> LedgerJSON? {
        objectValue?[key]
    }

    static let emptyObject = LedgerJSON.object([:])
    static let emptyArray = LedgerJSON.array([])

    /// Canonical JSON text (sorted keys, no escaped slashes).
    var canonicalText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    static func parse(_ text: String) -> LedgerJSON? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LedgerJSON.self, from: data)
    }
}

/// GRDBのJSON列はSQLiteのTEXTとして保存する。`Codable`だけに任せると、
/// レコードの射影保存時にJSONツリーが単一値として扱われ、オブジェクトや配列が
/// 正しく復元できないため、台帳で使うJSON型自身に明示的な変換を持たせる。
extension LedgerJSON: DatabaseValueConvertible {
    var databaseValue: DatabaseValue { canonicalText.databaseValue }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> LedgerJSON? {
        guard case .string(let text) = dbValue.storage else { return nil }
        return parse(text)
    }
}

/// UTC timestamps in the same text form Python's `datetime.isoformat()` uses
/// (`2026-09-18T01:02:03.123456+00:00`), so rows and vectors compare equal.
nonisolated enum LedgerClock {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func iso(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.down)
        let micros = Int(((seconds - whole) * 1_000_000).rounded())
        let base = plainFormatter.string(from: Date(timeIntervalSince1970: whole))  // yyyy-MM-ddTHH:mm:ssZ
        let stem = String(base.dropLast())  // strip Z
        return String(format: "%@.%06d+00:00", stem, micros)
    }

    static func parse(_ text: String) -> Date? {
        if let date = formatter.date(from: text) { return date }
        if let date = plainFormatter.date(from: text) { return date }
        // Python isoformat without fractional seconds: 2026-09-18T01:02:03+00:00
        let normalized = text.replacingOccurrences(of: "+00:00", with: "Z")
        if let date = formatter.date(from: normalized) { return date }
        return plainFormatter.date(from: normalized)
    }

    static func now() -> String { iso(Date()) }

    /// The `iso` text one microsecond after `text` (also `iso` form). Keeps a local write the newest
    /// version of its row when another device's clock ran ahead (Issue #51).
    static func after(_ text: String) -> String {
        guard let dot = text.firstIndex(of: "."), let whole = plainFormatter.date(from: String(text[..<dot]) + "Z"),
              let fraction = Int(text[text.index(after: dot)...].prefix(6)) else { return iso(Date()) }
        var seconds = whole
        var micros = fraction + 1
        if micros >= 1_000_000 { micros -= 1_000_000; seconds = seconds.addingTimeInterval(1) }
        return String(format: "%@.%06d+00:00", String(plainFormatter.string(from: seconds).dropLast()), micros)
    }
}
