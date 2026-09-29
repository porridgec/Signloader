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
        // A plain in-place update keeps the item's existing ACL. If the item was
        // created with `security add-generic-password -A` (any app may access),
        // saving from here preserves that; see README for why you'd want to.
        if SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return
        }
        // Only when the item is missing or its ACL doesn't cover this binary do
        // we replace it. Note the recreated item trusts just this binary — with
        // an ad-hoc signature that means a prompt after the next rebuild; the
        // `-A` seed in the README avoids that entirely.
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
