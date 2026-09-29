import AppKit
import Foundation

struct IPAInfo: Identifiable, Sendable {
    var id: String { url.path }

    let url: URL
    /// e.g. `Payload/MyApp.app`
    let appPath: String
    let appName: String
    let bundleID: String
    let shortVersion: String
    let buildVersion: String
    let executable: String
    let minimumOS: String
    let fileSize: Int64
    let entryCount: Int
    let appExtensionNames: [String]
    let watchAppName: String?
    let hasSwiftDylibs: Bool

    /// Best-effort app icon, decoded from the archive.
    let iconData: Data?

    var displayName: String {
        appName.isEmpty ? (url.deletingPathExtension().lastPathComponent) : appName
    }

    var versionLabel: String {
        shortVersion.isEmpty ? buildVersion : (buildVersion.isEmpty ? shortVersion : "\(shortVersion) (\(buildVersion))")
    }

    /// Past ~500 MB zsign's zip step is known to blow up; offer the safe pipeline.
    var recommendsSafeMode: Bool { fileSize > 500 * 1024 * 1024 }

    var icon: NSImage? {
        guard let iconData else { return nil }
        return NSImage(data: iconData)
    }

    /// Apps like 薄荷健康 ship ~50 app extensions; show a few and count the rest.
    var extensionSummary: String {
        guard !appExtensionNames.isEmpty else { return "" }
        let names = appExtensionNames.map { ($0 as NSString).deletingPathExtension }
        let head = names.prefix(3).joined(separator: "、")
        return names.count > 3 ? "\(head) 等 \(names.count) 个" : head
    }

    static let placeholder = IPAInfo(
        url: URL(fileURLWithPath: "/"),
        appPath: "",
        appName: "",
        bundleID: "",
        shortVersion: "",
        buildVersion: "",
        executable: "",
        minimumOS: "",
        fileSize: 0,
        entryCount: 0,
        appExtensionNames: [],
        watchAppName: nil,
        hasSwiftDylibs: false,
        iconData: nil
    )
}
