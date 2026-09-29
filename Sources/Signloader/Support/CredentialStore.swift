import Foundation

/// Legacy password storage used while the app was ad-hoc signed: a 0600 file
/// at `~/.signloader/credentials`. Kept only as a migration source — `PasswordStore`
/// imports and deletes it the first time it runs with working Keychain access.
///
/// For context, none of these produce a prompt-free Keychain item readable by an
/// ad-hoc signed binary (whose cdhash changes every build):
/// - `SecAccessCreate` with a `nil` or empty trusted list — still prompts
/// - `security add-generic-password -A` — a foreign reader still blocks ~10 s
enum CredentialStore {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".signloader/credentials")
    }

    static func read() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func write(_ value: String) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Remove-then-create so the mode is set at creation rather than fixed
        // up afterwards; an atomic rewrite would briefly leave a 0644 file.
        try? fm.removeItem(at: url)
        _ = fm.createFile(
            atPath: url.path,
            contents: Data(value.utf8),
            attributes: [.posixPermissions: 0o600]
        )
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
