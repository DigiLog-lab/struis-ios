import Foundation
import Security

/// Ledger IDs are UUIDv7 (design §4.1): time-ordered, generated on the device, and
/// still valid `UUID` strings for the existing DTOs.
nonisolated enum LedgerID {
    /// A lowercase UUIDv7 string: 48-bit Unix milliseconds, version 7, RFC 4122 variant, random rest.
    static func make(date: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let millis = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        for index in 0..<6 {
            bytes[index] = UInt8((millis >> (8 * (5 - index))) & 0xff)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }
}
