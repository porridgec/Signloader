import Foundation

struct Device: Identifiable, Hashable, Sendable {
    /// How the device is reachable. Commands differ per transport: libimobiledevice
    /// tools need an explicit `-n` for network devices, otherwise they only look
    /// at USB.
    enum Transport: String, Hashable, Sendable, CaseIterable {
        case usb
        case network

        var label: String { self == .network ? "Wi-Fi" : "USB" }

        var symbol: String { self == .network ? "wifi" : "cable.connector" }

        /// libimobiledevice's `-n` flag, applied to every per-device invocation.
        var arguments: [String] { self == .network ? ["-n"] : [] }
    }

    let udid: String
    let name: String
    let productName: String
    let productType: String
    let productVersion: String
    let transport: Transport

    var id: String { udid }

    var displayName: String { name.isEmpty ? productType : name }

    var subtitle: String {
        [productName, productVersion, transport.label]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var shortUDID: String {
        String(udid.prefix(8))
    }
}

struct InstalledApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let version: String
    let shortVersion: String
    let signer: String
    let applicationType: String
    let path: String

    var id: String { bundleID }

    var versionLabel: String {
        if !shortVersion.isEmpty, !version.isEmpty, shortVersion != version {
            return "\(shortVersion) (\(version))"
        }
        return shortVersion.isEmpty ? version : shortVersion
    }
}
