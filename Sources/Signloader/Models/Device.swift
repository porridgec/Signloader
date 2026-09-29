import Foundation

struct Device: Identifiable, Hashable, Sendable {
    let udid: String
    let name: String
    let productName: String
    let productType: String
    let productVersion: String

    var id: String { udid }

    var displayName: String { name.isEmpty ? productType : name }

    var subtitle: String {
        [productName, productVersion].filter { !$0.isEmpty }.joined(separator: " · ")
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
