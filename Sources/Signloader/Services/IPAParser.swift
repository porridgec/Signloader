import Foundation

enum IPAError: LocalizedError {
    case notFound(String)
    case emptyArchive
    case noAppBundle
    case unreadableInfoPlist
    case noBundleIdentifier

    var errorDescription: String? {
        switch self {
        case .notFound(let p): return "找不到文件：\(p)"
        case .emptyArchive: return "IPA 是空文件或不是有效的 zip。"
        case .noAppBundle: return "IPA 里没有 Payload/*.app 目录，可能不是 iOS App 包。"
        case .unreadableInfoPlist: return "无法读取 Payload/*.app/Info.plist。"
        case .noBundleIdentifier: return "Info.plist 里缺少 CFBundleIdentifier。"
        }
    }
}

/// Reads an IPA without unpacking it: the zip central directory gives us the
/// layout, and `unzip -p` streams the single files we care about.
enum IPAParser {
    private static let fm = FileManager.default

    static func parse(url: URL) async throws -> IPAInfo {
        guard fm.fileExists(atPath: url.path) else { throw IPAError.notFound(url.path) }

        let entries = try await Shell.run("/usr/bin/unzip", ["-Z1", url.path]).stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let infoPlistEntry = entries.first(where: { isAppInfoPlist($0) }) else {
            if entries.isEmpty { throw IPAError.emptyArchive }
            throw IPAError.noAppBundle
        }
        let appPath = String(infoPlistEntry.dropLast("Info.plist".count))  // keeps the trailing "/"
        let bundleName = URL(fileURLWithPath: appPath).lastPathComponent
            .replacingOccurrences(of: ".app", with: "")

        let infoData = try await Shell.data("/usr/bin/unzip", ["-p", url.path, infoPlistEntry])
        guard let plist = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil),
              let info = plist as? [String: Any] else { throw IPAError.unreadableInfoPlist }

        guard let bundleID = (info["CFBundleIdentifier"] as? String), !bundleID.isEmpty else {
            throw IPAError.noBundleIdentifier
        }

        let appName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? bundleName
        let shortVersion = info["CFBundleShortVersionString"] as? String ?? ""
        let buildVersion = info["CFBundleVersion"] as? String ?? ""
        let executable = info["CFBundleExecutable"] as? String ?? bundleName
        let minimumOS = info["MinimumOSVersion"] as? String ?? ""

        // Only direct children of PlugIns/ — these apps nest .appex inside
        // .appex, and walking the whole tree double counts every one.
        let rawExtensions = entries
            .compactMap { entry -> String? in

                let prefix = appPath + "PlugIns/"
                guard entry.hasPrefix(prefix) else { return nil }
                let tail = entry.dropFirst(prefix.count)
                guard let slash = tail.firstIndex(of: "/") else { return nil }
                return String(tail[tail.startIndex..<slash])
            }
            .filter { $0.hasSuffix(".appex") || $0.hasSuffix(".app") || $0.hasSuffix(".framework") }
        let extensions = uniquedSorted(rawExtensions)

        let watchApp = entries
            .filter { $0.hasPrefix(appPath + "Watch/") }
            .compactMap { entry -> String? in
                guard entry.hasSuffix(".app/Info.plist") else { return nil }
                return URL(fileURLWithPath: entry).deletingLastPathComponent().lastPathComponent
            }
            .first

        let hasSwift = entries.contains { $0.hasSuffix(".dylib") && $0.contains("Frameworks/") }

        let iconData = await extractIcon(ipaURL: url, appPath: appPath, info: info, entries: Set(entries))

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0

        return IPAInfo(
            url: url,
            appPath: appPath,
            appName: appName,
            bundleID: bundleID,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            executable: executable,
            minimumOS: minimumOS,
            fileSize: size,
            entryCount: entries.count,
            appExtensionNames: extensions,
            watchAppName: watchApp,
            hasSwiftDylibs: hasSwift,
            iconData: iconData
        )
    }

    /// Deduplicated, deterministic ordering.
    private static func uniquedSorted(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private static func isAppInfoPlist(_ entry: String) -> Bool {
        guard entry.hasPrefix("Payload/"), entry.hasSuffix(".app/Info.plist") else { return false }
        let body = entry.dropFirst("Payload/".count).dropLast(".app/Info.plist".count)
        return !body.contains("/")
    }

    // MARK: Icon

    private static func extractIcon(
        ipaURL: URL,
        appPath: String,
        info: [String: Any],
        entries: Set<String>
    ) async -> Data? {
        var candidates: [String] = []

        func iconNames(from container: Any) {
            guard let dict = container as? [String: Any] else { return }
            if let files = dict["CFBundleIconFiles"] as? [String] {
                for name in files { candidates.append("\(name).png") }
            }
        }

        if let icons = info["CFBundleIcons"] as? [String: Any] {
            if let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                iconNames(from: primary)
                if let files = primary["CFBundleIconFiles"] as? [String] {
                    for name in files {
                        candidates.append("\(name)@2x.png")
                        candidates.append("\(name)@3x.png")
                        candidates.append("\(name)~ipad.png")
                    }
                }
            }
            for (key, value) in icons {
                if let dict = value as? [String: Any], key != "CFBundlePrimaryIcon" {
                    iconNames(from: dict)
                }
            }
        }
        if let ipadIcons = info["CFBundleIcons~ipad"] as? [String: Any] {
            if let primary = ipadIcons["CFBundlePrimaryIcon"] as? [String: Any] {
                iconNames(from: primary)
            }
        }
        iconNames(from: info)

        candidates += [
            "AppIcon60x60@2x.png",
            "AppIcon76x76@2x~ipad.png",
            "AppIcon60x60@3x.png",
            "Icon-60@2x.png",
            "Icon-76@2x~ipad.png",
            "Icon.png",
            "icon.png",
        ]

        // Prefer the largest declared icon by trying the 3x/2x variants first.
        let ordered = candidates.sorted { lhs, rhs in
            rank(lhs) < rank(rhs)
        }

        for candidate in ordered {
            let entry = appPath + candidate
            guard entries.contains(entry) else { continue }
            if let data = try? await Shell.data("/usr/bin/unzip", ["-p", ipaURL.path, entry]),
               data.count > 512 {
                return data
            }
        }
        return nil
    }

    private static func rank(_ name: String) -> Int {
        if name.contains("@3x") { return 0 }
        if name.contains("@2x") { return 1 }
        if name.hasSuffix(".png") && !name.contains("~") { return 3 }
        return 4
    }

    // MARK: Verification

    struct Verification: Sendable {
        var hasCodeSignature = false
        var hasEmbeddedProfile = false
        var embeddedProfileName: String?
        var embeddedAppIdentifier: String?
        var matchesProfile = false
        var signedAt: Date?
    }

    /// Cheap post-sign sanity check: the archive must carry a code signature and
    /// an embedded profile whose application-identifier equals the one we asked for.
    static func verify(signedIPA: URL, expectedAppIdentifier: String?) async -> Verification {
        var result = Verification()
        guard let entries = try? await Shell.run("/usr/bin/unzip", ["-Z1", signedIPA.path]).stdout
            .split(separator: "\n").map(String.init) else { return result }

        result.hasCodeSignature = entries.contains { $0.contains("Payload/") && $0.hasSuffix("_CodeSignature/CodeResources") }
        guard let profileEntry = entries.first(where: { $0.contains("Payload/") && $0.hasSuffix("embedded.mobileprovision") }) else {
            return result
        }
        result.hasEmbeddedProfile = true
        guard let data = try? await Shell.data("/usr/bin/unzip", ["-p", signedIPA.path, profileEntry]) else { return result }

        let temp = fm.temporaryDirectory.appendingPathComponent("signloader-verify-\(UUID().uuidString).mobileprovision")
        defer { try? fm.removeItem(at: temp) }
        guard (try? data.write(to: temp, options: .atomic)) != nil else { return result }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        guard let xml = try? await Shell.data("/usr/bin/security", ["cms", "-D", "-i", temp.path]),
              let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil),
              let dict = plist as? [String: Any] else { return result }

        result.embeddedProfileName = dict["Name"] as? String
        result.signedAt = dict["CreationDate"] as? Date
        let entitlements = dict["Entitlements"] as? [String: Any]
        result.embeddedAppIdentifier = entitlements?["application-identifier"] as? String
        if let expected = expectedAppIdentifier {
            result.matchesProfile = result.embeddedAppIdentifier == expected
        } else {
            result.matchesProfile = false
        }
        return result
    }
}
