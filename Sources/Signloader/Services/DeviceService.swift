import Foundation

/// Wraps libimobiledevice (`idevice_id` / `ideviceinfo` / `ideviceinstaller`).
struct DeviceService: Sendable {
    let ideviceID = "/opt/homebrew/bin/idevice_id"
    let ideviceInfo = "/opt/homebrew/bin/ideviceinfo"
    let ideviceInstaller = "/opt/homebrew/bin/ideviceinstaller"

    static let shared = DeviceService()

    var isAvailable: Bool {
        Shell.locate("ideviceinstaller") != nil && Shell.locate("idevice_id") != nil
    }

    func listDevices() async throws -> [Device] {
        let output = try await Shell.run("idevice_id", ["-l"]).stdout
        let udids = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isHexDigit || $0 == "-" } }

        guard !udids.isEmpty else { return [] }

        return await withTaskGroup(of: Device.self) { group in
            for udid in udids {
                group.addTask { await self.info(for: udid) }
            }
            var devices: [Device] = []
            for await device in group { devices.append(device) }
            return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func info(for udid: String) async -> Device {
        var device = Device(udid: udid, name: "", productName: "", productType: "", productVersion: "")
        guard let data = try? await Shell.data("ideviceinfo", ["-u", udid, "-x"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else { return device }

        device = Device(
            udid: udid,
            name: dict["DeviceName"] as? String ?? "",
            productName: dict["ProductName"] as? String ?? "",
            productType: dict["ProductType"] as? String ?? "",
            productVersion: dict["ProductVersion"] as? String ?? ""
        )
        return device
    }

    func installedApps(udid: String) async throws -> [InstalledApp] {
        let result = try await Shell.run(
            "ideviceinstaller", ["-u", udid, "list", "--user", "--xml"]
        )
        guard let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let array = plist as? [[String: Any]] else { return [] }

        return array.compactMap { entry in
            guard let bundleID = entry["CFBundleIdentifier"] as? String else { return nil }
            let name = (entry["CFBundleDisplayName"] as? String)
                ?? (entry["CFBundleName"] as? String)
                ?? bundleID
            return InstalledApp(
                bundleID: bundleID,
                name: name,
                version: entry["CFBundleVersion"] as? String ?? "",
                shortVersion: entry["CFBundleShortVersionString"] as? String ?? "",
                signer: entry["SignerIdentity"] as? String ?? "",
                applicationType: entry["ApplicationType"] as? String ?? "",
                path: entry["Path"] as? String ?? ""
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func install(udid: String, ipa: URL, onLine: @escaping @Sendable ([String]) -> Void) async throws {
        try await Shell.run(
            "ideviceinstaller", ["-u", udid, "install", ipa.path],
            onLine: onLine
        )
    }

    func uninstall(udid: String, bundleID: String, onLine: @escaping @Sendable ([String]) -> Void) async throws {
        try await Shell.run(
            "ideviceinstaller", ["-u", udid, "uninstall", bundleID],
            onLine: onLine
        )
    }

    /// Re-export the profiles currently installed on the phone.
    func exportProfiles(udid: String, to directory: URL, onLine: @escaping @Sendable ([String]) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await Shell.run(
            "ideviceprovision", ["-u", udid, "copy", directory.path],
            onLine: onLine
        )
    }
}
