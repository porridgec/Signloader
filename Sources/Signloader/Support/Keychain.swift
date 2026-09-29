import Foundation
import Security

/// Minimal Keychain wrapper for the p12 password.
///
/// The password never goes into UserDefaults or source control. Items are
/// scoped to this device and only readable while unlocked.
enum Keychain {
    private static let service = "app.signloader.p12-password"
    private static let account = "default"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            // Never synced to iCloud, not readable from the lock screen.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
