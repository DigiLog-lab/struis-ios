import Foundation

// Shared JSON and text helpers for the Engine ports (Foundation only).
//
// Python dicts preserve insertion order and that order is observable in several
// outputs (context_for_turn, public_trace, YAML documents), so the Engine keeps an
// order-preserving JSON value instead of `[String: Any]` where order matters.

/// Error type for every Engine validation failure. `message` is what Python raised.
nonisolated struct EngineError: Error, CustomStringConvertible, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// Order-preserving JSON object (Python dict semantics: overwrite keeps position).
nonisolated struct EngineObject: Equatable {
    private(set) var keys: [String] = []
    private var storage: [String: EngineJSON] = [:]

    init() {}
    init(_ pairs: [(String, EngineJSON)]) { for (k, v) in pairs { self[k] = v } }

    subscript(key: String) -> EngineJSON? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = newValue
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }
    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }
    var pairs: [(String, EngineJSON)] { keys.map { ($0, storage[$0]!) } }
    var values: [EngineJSON] { keys.map { storage[$0]! } }
    func contains(_ key: String) -> Bool { storage[key] != nil }
}

/// A JSON document value. Integers and floats are kept distinct so the serializer
/// mirrors Python (`1` vs `1.0`).
nonisolated indirect enum EngineJSON: Equatable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([EngineJSON])
    case object(EngineObject)

    var isNull: Bool { if case .null = self { return true } else { return false } }
    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var arrayValue: [EngineJSON]? { if case .array(let a) = self { return a } else { return nil } }
    var objectValue: EngineObject? { if case .object(let o) = self { return o } else { return nil } }
    var doubleValue: Double? {
        switch self {
        case .integer(let i): return Double(i)
        case .number(let d): return d
        default: return nil
        }
    }
    var intValue: Int? {
        switch self {
        case .integer(let i): return i
        case .number(let d): return d == d.rounded() && abs(d) < 9e15 ? Int(d) : nil
        default: return nil
        }
    }
    subscript(key: String) -> EngineJSON? { objectValue?[key] }

    /// Python truthiness.
    var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .integer(let i): return i != 0
        case .number(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    // MARK: Bridging to/from Foundation `Any`

    /// Builds a value from a Foundation JSON object (`[String: Any]`, `[Any]`, NSNumber, String, NSNull).
    /// Plain dictionaries have no order; their keys are emitted sorted for determinism.
    init(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let value as EngineJSON: self = value
        case let value as EngineObject: self = .object(value)
        case let value as String: self = .string(value)
        case let value as Bool where CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(): self = .bool(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool(value.boolValue); return }
            let type = String(cString: value.objCType)
            if type == "d" || type == "f" {
                let d = value.doubleValue
                self = .number(d)
            } else {
                self = .integer(value.intValue)
            }
        case let value as Int: self = .integer(value)
        case let value as Double: self = .number(value)
        case let value as [Any]: self = .array(value.map { EngineJSON(any: $0) })
        case let value as [String: Any]:
            var object = EngineObject()
            for key in value.keys.sorted() { object[key] = EngineJSON(any: value[key]!) }
            self = .object(object)
        case let value as [(String, Any)]:
            var object = EngineObject()
            for (key, item) in value { object[key] = EngineJSON(any: item) }
            self = .object(object)
        case let value as Optional<Any>:
            if let inner = value { self = EngineJSON(any: inner) } else { self = .null }
        default:
            self = .string(String(describing: any))
        }
    }

    /// Foundation representation (`[String: Any]` for objects, `NSNull` for null).
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .integer(let i): return i
        case .number(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o):
            var result: [String: Any] = [:]
            for (k, v) in o.pairs { result[k] = v.anyValue }
            return result
        }
    }

    // MARK: Parsing (order preserving; accepts what Python's json.loads accepts)

    static func parse(_ text: String) throws -> EngineJSON {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.scalars.count else { throw EngineError("Extra data at position \(parser.index)") }
        return value
    }

    static func parse(_ data: Data) throws -> EngineJSON {
        guard let text = String(data: data, encoding: .utf8) else { throw EngineError("invalid UTF-8") }
        return try parse(text)
    }

    nonisolated struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        mutating func skipWhitespace() {
            while index < scalars.count, [" ", "\t", "\n", "\r"].contains(scalars[index]) { index += 1 }
        }

        mutating func parseValue() throws -> EngineJSON {
            guard index < scalars.count else { throw EngineError("Expecting value at \(index)") }
            switch scalars[index] {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t": try expect("true"); return .bool(true)
            case "f": try expect("false"); return .bool(false)
            case "n": try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func expect(_ word: String) throws {
            for scalar in word.unicodeScalars {
                guard index < scalars.count, scalars[index] == scalar else { throw EngineError("Expecting value at \(index)") }
                index += 1
            }
        }

        mutating func parseObject() throws -> EngineJSON {
            index += 1
            var object = EngineObject()
            skipWhitespace()
            if index < scalars.count, scalars[index] == "}" { index += 1; return .object(object) }
            while true {
                skipWhitespace()
                guard index < scalars.count, scalars[index] == "\"" else { throw EngineError("Expecting property name enclosed in double quotes") }
                let key = try parseString()
                skipWhitespace()
                guard index < scalars.count, scalars[index] == ":" else { throw EngineError("Expecting ':' delimiter") }
                index += 1
                skipWhitespace()
                object[key] = try parseValue()
                skipWhitespace()
                guard index < scalars.count else { throw EngineError("Expecting ',' delimiter") }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "}" { index += 1; return .object(object) }
                throw EngineError("Expecting ',' delimiter")
            }
        }

        mutating func parseArray() throws -> EngineJSON {
            index += 1
            var items: [EngineJSON] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "]" { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue())
                skipWhitespace()
                guard index < scalars.count else { throw EngineError("Expecting ',' delimiter") }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "]" { index += 1; return .array(items) }
                throw EngineError("Expecting ',' delimiter")
            }
        }

        mutating func parseString() throws -> String {
            index += 1
            var result = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "\"" { index += 1; return String(result) }
                if scalar == "\\" {
                    index += 1
                    guard index < scalars.count else { break }
                    let escape = scalars[index]
                    index += 1
                    switch escape {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    case "b": result.append("\u{08}")
                    case "f": result.append("\u{0C}")
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "u":
                        var code = try parseHex4()
                        if (0xD800...0xDBFF).contains(code), index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
                            let save = index
                            index += 2
                            let low = try parseHex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                index = save
                            }
                        }
                        result.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default: throw EngineError("Invalid \\escape")
                    }
                    continue
                }
                if scalar.value < 0x20 { throw EngineError("Invalid control character") }
                result.append(scalar)
                index += 1
            }
            throw EngineError("Unterminated string")
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= scalars.count else { throw EngineError("Invalid \\uXXXX escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard scalars[index].isASCII, let digit = UInt32(String(scalars[index]), radix: 16) else {
                    throw EngineError("Invalid \\uXXXX escape")
                }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        mutating func parseNumber() throws -> EngineJSON {
            let start = index
            var isFloat = false
            if index < scalars.count, scalars[index] == "-" { index += 1 }
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar.properties.numericType != nil && scalar.value < 128 { index += 1; continue }
                if scalar == "." || scalar == "e" || scalar == "E" { isFloat = true; index += 1; continue }
                if (scalar == "+" || scalar == "-") && index > start && (scalars[index - 1] == "e" || scalars[index - 1] == "E") { index += 1; continue }
                break
            }
            let text = String(String.UnicodeScalarView(scalars[start..<index]))
            guard !text.isEmpty, text != "-" else { throw EngineError("Expecting value at \(index)") }
            if !isFloat, let int = Int(text) { return .integer(int) }
            guard let double = Double(text) else { throw EngineError("Expecting value at \(index)") }
            return .number(double)
        }
    }

    // MARK: Serialization

    /// Serializes like Python `json.dumps(..., ensure_ascii=False)`.
    /// `compact` uses orjson / `separators=(",", ":")`; otherwise `", "` and `": "`.
    func serialized(compact: Bool = false) -> String {
        var out = ""
        write(into: &out, compact: compact)
        return out
    }

    private func write(into out: inout String, compact: Bool) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .integer(let i): out += String(i)
        case .number(let d): out += EngineJSON.pythonFloatRepr(d)
        case .string(let s): EngineJSON.writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += compact ? "," : ", " }
                item.write(into: &out, compact: compact)
            }
            out += "]"
        case .object(let object):
            out += "{"
            for (i, (key, value)) in object.pairs.enumerated() {
                if i > 0 { out += compact ? "," : ", " }
                EngineJSON.writeString(key, into: &out)
                out += compact ? ":" : ": "
                value.write(into: &out, compact: compact)
            }
            out += "}"
        }
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// Python `repr(float)`: shortest round-trip, always with a decimal point or exponent.
    static func pythonFloatRepr(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        var text = "\(d)"
        if text.contains("e") {
            // Swift: 1e-09 -> Python: 1e-09 ; Swift: 1e+16 -> Python: 1e+16
            return text
        }
        if !text.contains(".") { text += ".0" }
        return text
    }
}

// MARK: - Codable bridge (JSONEncoder preserves call order; JSONDecoder does not preserve key order)

nonisolated extension EngineJSON: Codable {
    nonisolated struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicKey.self) {
            var object = EngineObject()
            for key in keyed.allKeys { object[key.stringValue] = try keyed.decode(EngineJSON.self, forKey: key) }
            self = .object(object)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var items: [EngineJSON] = []
            while !unkeyed.isAtEnd { items.append(try unkeyed.decode(EngineJSON.self)) }
            self = .array(items)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let b = try? single.decode(Bool.self) { self = .bool(b); return }
        if let i = try? single.decode(Int.self) { self = .integer(i); return }
        if let d = try? single.decode(Double.self) { self = .number(d); return }
        self = .string(try single.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let b): var c = encoder.singleValueContainer(); try c.encode(b)
        case .integer(let i): var c = encoder.singleValueContainer(); try c.encode(i)
        case .number(let d): var c = encoder.singleValueContainer(); try c.encode(d)
        case .string(let s): var c = encoder.singleValueContainer(); try c.encode(s)
        case .array(let items): var c = encoder.unkeyedContainer(); for item in items { try c.encode(item) }
        case .object(let object):
            var c = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in object.pairs { try c.encode(value, forKey: DynamicKey(key)) }
        }
    }
}

// MARK: - Python-compatible text helpers

nonisolated enum EnginePyText {
    /// Python `str.isspace()` for a scalar (close enough: Unicode White_Space plus the ASCII separators).
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return true }
        return (0x1C...0x1F).contains(scalar.value)
    }

    /// Python `str.strip()`.
    static func strip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, isSpace(scalars[start]) { start += 1 }
        while end > start, isSpace(scalars[end - 1]) { end -= 1 }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    static func rstrip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var end = scalars.count
        while end > 0, isSpace(scalars[end - 1]) { end -= 1 }
        return String(String.UnicodeScalarView(scalars[0..<end]))
    }

    /// Python `str.strip(chars)`.
    static func strip(_ text: String, chars: String) -> String {
        let set = Set(chars.unicodeScalars)
        let scalars = Array(text.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, set.contains(scalars[start]) { start += 1 }
        while end > start, set.contains(scalars[end - 1]) { end -= 1 }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    /// Python `str.split()` (whitespace runs).
    static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isSpace(scalar) {
                if !current.isEmpty { parts.append(String(current)); current = .init() }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { parts.append(String(current)) }
        return parts
    }

    /// `"".join(text.split())`
    static func compact(_ text: String) -> String { split(text).joined() }

    /// `" ".join(text.split())`
    static func normalizeSpaces(_ text: String) -> String { split(text).joined(separator: " ") }

    /// Python `len(str)` (code points).
    static func length(_ text: String) -> Int { text.unicodeScalars.count }

    /// Python `text[:limit]` (code points).
    static func prefix(_ text: String, _ limit: Int) -> String {
        if limit <= 0 { return "" }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
    }

    /// Python `text[start:]` (code points).
    static func suffix(_ text: String, from start: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.dropFirst(max(0, start))))
    }

    /// Python `a in b` (code point substring, no canonical equivalence).
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        if needle.isEmpty { return true }
        return haystack.range(of: needle, options: .literal) != nil
    }

    /// Python `text.count(sub)` (non-overlapping).
    static func count(_ haystack: String, _ needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: .literal, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }

    /// Python `text.find(sub, start)` in code point offsets (-1 when absent).
    static func find(_ scalars: [Unicode.Scalar], _ needle: [Unicode.Scalar], from start: Int = 0) -> Int {
        if needle.isEmpty { return min(start, scalars.count) }
        var i = max(0, start)
        while i + needle.count <= scalars.count {
            if scalars[i] == needle[0] {
                var j = 1
                while j < needle.count, scalars[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return -1
    }

    static func lowercased(_ text: String) -> String { text.lowercased() }

    /// Python `.replace(old, new)`.
    static func replace(_ text: String, _ old: String, _ new: String) -> String {
        text.replacingOccurrences(of: old, with: new, options: .literal)
    }
}

// MARK: - Python datetime.isoformat() compatibility

nonisolated enum EnginePyTime {
    static let utc = TimeZone(identifier: "UTC")!

    /// `datetime.isoformat()` of an aware UTC datetime: microseconds only when non-zero, `+00:00` suffix.
    static func isoformat(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.down)
        var micro = Int(((seconds - whole) * 1_000_000).rounded())
        var base = Date(timeIntervalSince1970: whole)
        if micro >= 1_000_000 { micro -= 1_000_000; base = base.addingTimeInterval(1) }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: base)
        var text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        if micro != 0 { text += String(format: ".%06d", micro) }
        return text + "+00:00"
    }

    /// `(to - from).total_seconds()` with Python's microsecond resolution.
    static func totalSeconds(from start: Date, to end: Date) -> Double {
        ((end.timeIntervalSince1970 - start.timeIntervalSince1970) * 1_000_000).rounded() / 1_000_000
    }

    /// `datetime.strftime("%Y%m%dT%H%M%S%fZ")`.
    static func compactStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.down)
        let micro = min(999_999, Int(((seconds - whole) * 1_000_000).rounded()))
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: whole))
        return String(format: "%04d%02d%02dT%02d%02d%02d%06dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, micro)
    }

    /// `strftime("%Y-%m")`.
    static func yearMonth(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }

    /// `datetime.fromisoformat` for the formats the backend emits (with/without fraction, `+00:00`, `Z`, naive = UTC).
    static func parseISO(_ text: String) -> Date? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 19 else { return nil }
        func int(_ range: Range<Int>) -> Int? { Int(String(String.UnicodeScalarView(scalars[range]))) }
        guard let year = int(0..<4), let month = int(5..<7), let day = int(8..<10),
              let hour = int(11..<13), let minute = int(14..<16), let second = int(17..<19) else { return nil }
        var index = 19
        var fraction = 0.0
        if index < scalars.count, scalars[index] == "." {
            index += 1
            let start = index
            while index < scalars.count, scalars[index].properties.numericType != nil, scalars[index].value < 128 { index += 1 }
            let digits = String(String.UnicodeScalarView(scalars[start..<index]))
            if let value = Double("0." + digits) { fraction = value }
        }
        var offsetSeconds = 0
        if index < scalars.count {
            let sign = scalars[index]
            if sign == "Z" || sign == "z" {
                index += 1
            } else if sign == "+" || sign == "-" {
                let rest = String(String.UnicodeScalarView(scalars[(index + 1)...])).replacingOccurrences(of: ":", with: "")
                guard rest.count >= 4, let hours = Int(rest.prefix(2)), let minutes = Int(rest.dropFirst(2).prefix(2)) else { return nil }
                offsetSeconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
                index = scalars.count
            } else {
                return nil
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        guard let base = calendar.date(from: components) else { return nil }
        return base.addingTimeInterval(fraction - Double(offsetSeconds))
    }
}
