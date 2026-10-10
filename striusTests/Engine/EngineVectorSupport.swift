import Foundation
import XCTest
#if canImport(StruisEngine)
@testable import StruisEngine
#else
@testable import strius
#endif

/// Loads engine vectors from the test bundle (app target) or relative to this file (SwiftPM).
nonisolated enum EngineVectors {
    static func load(_ name: String) throws -> EngineJSON {
        let data = try loadData(name)
        return try EngineJSON.parse(data)
    }

    static func loadData(_ name: String) throws -> Data {
        if let url = Bundle(for: EngineVectorBundleMarker.self).url(forResource: name, withExtension: "json", subdirectory: "engine-vectors")
            ?? Bundle(for: EngineVectorBundleMarker.self).url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        let here = URL(fileURLWithPath: #filePath)
        let fallback = here.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/engine-vectors/\(name).json")
        return try Data(contentsOf: fallback)
    }

    /// Canonical text: sorted keys, integers without fraction, booleans distinct from numbers.
    static func canonical(_ value: EngineJSON) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .integer(let i): return String(i)
        case .number(let d):
            if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
            return "\(d)"
        case .string(let s): return EngineJSON.string(s).serialized()
        case .array(let items): return "[" + items.map(canonical).joined(separator: ",") + "]"
        case .object(let object):
            return "{" + object.keys.sorted().map { EngineJSON.string($0).serialized() + ":" + canonical(object[$0]!) }.joined(separator: ",") + "}"
        }
    }

    static func assertEqual(_ actual: EngineJSON, _ expected: EngineJSON, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let a = canonical(actual), e = canonical(expected)
        if a != e {
            XCTFail("\(label)\n  expected: \(e.prefix(1500))\n  actual:   \(a.prefix(1500))", file: file, line: line)
        }
    }
}

final class EngineVectorBundleMarker: NSObject {}

nonisolated extension EngineJSON {
    var stringOrEmpty: String { stringValue ?? "" }
}
