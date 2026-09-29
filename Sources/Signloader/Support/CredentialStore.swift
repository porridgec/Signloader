import Foundation

/// Password storage on disk (`~/.signloader/credentials`, mode 0600).
///
/// Deliberately not the Keychain. This app is ad-hoc signed and rebuilt often,
/// and a Keychain item's access control is bound to the code signature of the
/// binary that wrote it — so every rebuild re-triggers an authorization prompt.
/// None of the documented ways to create a "trust all applications" item works
/// on current macOS:
///
/// - `SecAccessCreate` with a `nil` or empty trusted list still prompts
///   (verified: cross-process read blocks)
/// - `security add-generic-password -A` still prompts — a foreign process
///   reading the item blocked for 10 s waiting on SecurityAgent
///
/// A 0600 file under the user's home is what comparable local tools use. It is
/// readable by any process running as this user — which is the same trust
/// boundary the Keychain item ended up with anyway, minus the prompts.
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
