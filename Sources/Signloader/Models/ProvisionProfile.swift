import Foundation

/// A parsed `.mobileprovision` decoded out of the signing kit.
struct ProvisionProfile: Identifiable, Hashable, Sendable {
    enum MatchKind: String, Sendable {
        case exact
        case teamSuffixed
        case wildcard
        case none

        var label: String {
            switch self {
            case .exact: return "完全匹配"
            case .teamSuffixed: return "团队后缀"
            case .wildcard: return "通配符"
            case .none: return "不匹配"
            }
        }
    }

    let id: String
    let url: URL
    let uuid: String
    let name: String
    let teamID: String
    /// `Entitlements.application-identifier`, e.g. `TEAMID.com.example.app.TEAMID`
    let appIdentifier: String
    /// app identifier with the team prefix stripped.
    let bundleID: String
    let expiration: Date
    let creation: Date
    let certificateCount: Int
    let deviceCount: Int
    /// How many byte-identical copies of this profile exist in the kit.
    let duplicateCount: Int
    let isXcodeManaged: Bool

    var isWildcard: Bool { bundleID == "*" }

    var isExpired: Bool { expiration < Date() }

    var daysRemaining: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: expiration).day ?? 0
    }

    var expiryLabel: String {
        if isExpired { return "已过期" }
        let days = daysRemaining
        if days < 30 { return "\(days) 天后过期" }
        if days < 365 { return "\(days / 30) 个月后过期" }
        return "\(days / 365) 年后过期"
    }

    /// Short, human readable version of the profile's app id.
    var displayBundleID: String { bundleID }

    func matchKind(for ipaBundleID: String) -> MatchKind {
        if isWildcard && !teamID.isEmpty { return .wildcard }
        if bundleID == ipaBundleID { return .exact }
        if bundleID == "\(ipaBundleID).\(teamID)" { return .teamSuffixed }
        return .none
    }

    func matches(_ ipaBundleID: String) -> Bool { matchKind(for: ipaBundleID) != .none }

    /// zsign-ready display string.
    var commandLineLabel: String { appIdentifier }
}

struct SigningCertificate: Hashable, Sendable {
    let subject: String
    let commonName: String
    let teamID: String
    let notBefore: Date?
    let notAfter: Date?
    let isValid: Bool

    var expiryLabel: String {
        guard let notAfter else { return "未知" }
        if notAfter < Date() { return "已过期" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: notAfter).day ?? 0
        if days < 30 { return "\(days) 天后过期" }
        if days < 365 { return "\(days / 30) 个月后过期" }
        return "\(days / 365) 年后过期"
    }
}
