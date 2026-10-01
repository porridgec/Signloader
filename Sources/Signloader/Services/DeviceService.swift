import Foundation

/// Wraps libimobiledevice (`idevice_id` / `ideviceinfo` / `ideviceinstaller` /
/// `ideviceprovision`).
///
/// Devices are reachable over USB or Wi-Fi. libimobiledevice's tools list and
/// address them separately: `idevice_id -l` only sees USB, `-n` only sees
/// network devices, and every per-device command needs `-n` appended to talk to
/// a Wi-Fi device. A device that shows up in both lists is treated as USB —
/// faster and more reliable for the multi-hundred-megabyte transfers signing
/// produces.
struct DeviceService: Sendable {
    static let shared = DeviceService()

    var isAvailable: Bool {
        Shell.locate("ideviceinstaller") != nil && Shell.locate("idevice_id") != nil
    }

    // MARK: Discovery

    private func udids(for arguments: [String]) async throws -> [String] {
        let output = try await Shell.run("idevice_id", arguments).stdout
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isHexDigit || $0 == "-" } }
    }

    func listDevices() async throws -> [Device] {
        let usb = try await udids(for: ["-l"])
        // Fails harmlessly when no network devices are discoverable.
        let network = (try? await udids(for: ["-n"])) ?? []

        var entries: [(udid: String, transport: Device.Transport)] = []
        var seen = Set<String>()
        for udid in usb where !seen.contains(udid) {
            seen.insert(udid)
            entries.append((udid, .usb))
        }
        for udid in network where !seen.contains(udid) {
            seen.insert(udid)
            entries.append((udid, .network))
        }
        guard !entries.isEmpty else { return [] }

        return await withTaskGroup(of: Device.self) { group in
            for entry in entries {
                group.addTask { await self.info(for: entry.udid, transport: entry.transport) }
            }
            var devices: [Device] = []
            for await device in group { devices.append(device) }
            // USB first, then by name — `install auto` picks the head of this.
            return devices.sorted {
                if $0.transport != $1.transport { return $0.transport == .usb }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    private func info(for udid: String, transport: Device.Transport) async -> Device {
        // -x returns a plist with everything we need in one call. Wi-Fi devices
        // are flaky on first contact (mDNS discovery races the lockdown
        // handshake), so give it one retry before degrading to a bare UDID row.
        for attempt in 0...1 {
            if let device = await queryInfo(for: udid, transport: transport) {
                return device
            }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        // Keep the UDID visible even when the query fails, so the transport
        // the list reported is still actionable.
        return Device(
            udid: udid, name: "", productName: "", productType: "",
            productVersion: "", transport: transport
        )
    }

    private func queryInfo(for udid: String, transport: Device.Transport) async -> Device? {
        guard let data = try? await Shell.data(
            "ideviceinfo",
            ["-u", udid] + transport.arguments + ["-x"]
        ), let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dict = plist as? [String: Any],
            // A truncated handshake returns an (almost) empty dict; treat that
            // as a miss so the retry path can kick in.
            !dict.isEmpty
        else { return nil }
        return Device(
            udid: udid,
            name: dict["DeviceName"] as? String ?? "",
            productName: dict["ProductName"] as? String ?? "",
            productType: dict["ProductType"] as? String ?? "",
            productVersion: dict["ProductVersion"] as? String ?? "",
            transport: transport
        )
    }

    // MARK: Apps

    func installedApps(udid: String, transport: Device.Transport = .usb) async throws -> [InstalledApp] {
        let result = try await Shell.run(
            "ideviceinstaller",
            ["-u", udid] + transport.arguments + ["list", "--user", "--xml"]
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

    func install(
        udid: String,
        transport: Device.Transport = .usb,
        ipa: URL,
        onLine: @escaping @Sendable ([String]) -> Void
    ) async throws {
        try await Shell.run(
            "ideviceinstaller",
            ["-u", udid] + transport.arguments + ["install", ipa.path],
            onLine: onLine
        )
    }

    func uninstall(
        udid: String,
        transport: Device.Transport = .usb,
        bundleID: String,
        onLine: @escaping @Sendable ([String]) -> Void
    ) async throws {
        try await Shell.run(
            "ideviceinstaller",
            ["-u", udid] + transport.arguments + ["uninstall", bundleID],
            onLine: onLine
        )
    }

    /// Re-export the profiles currently installed on the phone.
    func exportProfiles(
        udid: String,
        transport: Device.Transport = .usb,
        to directory: URL,
        onLine: @escaping @Sendable ([String]) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await Shell.run(
            "ideviceprovision",
            ["-u", udid] + transport.arguments + ["copy", directory.path],
            onLine: onLine
        )
    }
}
