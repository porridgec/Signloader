import Foundation
import Security

/// Minimal Keychain wrapper for the p12 password.
///
/// This only works without repeated prompts when the app is signed with a
/// stable identity (see `sign_app` in build.sh): an item's ACL matches the
/// app's *designated requirement*, which for a real certificate is anchored on
/// the certificate — identical across rebuilds. An ad-hoc signature's DR is
/// the binary's cdhash, which changes on every build, so every rebuild would
/// re-prompt. Ad-hoc builds should use `SIGNLOADER_P12_PASSWORD` instead.
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
        // In-place update keeps the existing ACL (which already trusts this
        // app's stable designated requirement).
        if SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return
        }
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
