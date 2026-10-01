import Foundation

/// Canonical locations, shared by the GUI and the CLI so both agree on where
/// things live. Centralised here because the CLI has no AppModel and must not
/// depend on GUI types.
enum SignloaderPaths {
    static let defaultKitPath = "~/.signloader/kit"
    static let defaultOutputDirectory = "~/Desktop/Signed"

    static var defaultKitPathExpanded: String {
        expanded(defaultKitPath)
    }

    static func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Kit directory resolution, shared by GUI and CLI so both see the same kit.
    ///
    /// Precedence: explicit override → `SIGNLOADER_KIT` env (agents / CI) → the
    /// GUI's saved setting (UserDefaults domain `dev.local.signloader`, which a
    /// copied CLI binary reads by suite name since it has no bundle) → default.
    static func resolveKitPath(_ override: String? = nil) -> String {
        if let override, !override.isEmpty { return expanded(override) }
        if let env = ProcessInfo.processInfo.environment["SIGNLOADER_KIT"], !env.isEmpty {
            return expanded(env)
        }
        if let saved = UserDefaults(suiteName: "dev.local.signloader")?.string(forKey: "kitPath"),
           !saved.isEmpty {
            return expanded(saved)
        }
        return expanded(defaultKitPath)
    }
}

/// External tools the app shells out to, with presence checking for `doctor`
/// and the GUI's availability banner.
enum Toolchain {
    static let required = [
        "zsign", "idevice_id", "ideviceinfo", "ideviceinstaller",
        "ideviceprovision", "unzip", "ditto", "security", "openssl",
    ]

    static func missing() -> [String] {
        required.filter { Shell.locate($0) == nil }
    }
}
