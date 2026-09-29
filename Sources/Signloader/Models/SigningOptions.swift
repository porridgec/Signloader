import Foundation

struct SigningOptions: Sendable, Equatable, Codable {
    /// `unzip → zsign folder → ditto` instead of letting zsign re-zip the IPA.
    /// Slower but avoids the known zip explosion on very large apps.
    var safeMode: Bool = false
    /// 0 = store only (fastest, biggest), 9 = maximum compression.
    var zipLevel: Int = 9
    var overrideBundleID: String = ""
    var overrideAppName: String = ""
    var removeAppExtensions: Bool = false
    var removeWatchApp: Bool = false
    /// zsign `-R` deletes `embedded.mobileprovision` *after* signing, which
    /// breaks installation. Off by default; only useful when you deliberately
    /// want a profile-less archive.
    var stripEmbeddedProfile: Bool = false
    var installAfterSigning: Bool = true
    var uninstallBeforeInstall: Bool = false
}
