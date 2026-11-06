import Security
import XCTest
@testable import strius

/// 利用枠の端末の ID は、バックアップから別の端末へ移さない(2 台が同じ ID になると、使用額が合計されず上書きし合う)。
final class KeychainValueStoreTests: XCTestCase {
    private var service: String = ""

    override func setUp() {
        service = "com.digiloglab.strius.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        let store = KeychainStore(service: service)
        store.delete(UsageMeter.deviceKey)
        store.delete("usage.week.2026-11-02")
    }

    private func accessible(_ account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        let attributes = try XCTUnwrap(item as? [String: Any])
        return try XCTUnwrap(attributes[kSecAttrAccessible as String] as? String)
    }

    func testTheDeviceIDStaysOnThisDeviceAndOtherValuesKeepTheirAccessibility() throws {
        let store = KeychainValueStore(keychain: KeychainStore(service: service))
        store.set("device-1", UsageMeter.deviceKey)
        store.set("0.25", "usage.week.2026-11-02")
        XCTAssertEqual(store.string(UsageMeter.deviceKey), "device-1")
        XCTAssertEqual(try accessible(UsageMeter.deviceKey), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(try accessible("usage.week.2026-11-02"), kSecAttrAccessibleAfterFirstUnlock as String,
                       "使用額は今までどおり(入れ直しても戻らない)")
    }
}
