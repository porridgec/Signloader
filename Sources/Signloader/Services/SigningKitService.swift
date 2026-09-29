import Foundation

/// Reads the on-disk signing kit: the team p12, the wildcard profile and the
/// pool of profiles exported from the phone.
struct SigningKit: Sendable {
    let root: URL
    let certificateURL: URL?
    let certificate: SigningCertificate?
    let profiles: [ProvisionProfile]
    let scannedFileCount: Int
    let problems: [String]

    static let wildcardID = "*"

    var p12URL: URL? { certificateURL }

    var profileDirectory: URL { root.appendingPathComponent("profiles-from-device") }

    var teamIDs: [String] {
        Array(Set(profiles.map(\.teamID))).filter { !$0.isEmpty }.sorted()
    }

    func exactProfiles(for bundleID: String) -> [ProvisionProfile] {
        profiles.filter { $0.bundleID == bundleID }
    }

    /// Rank the profiles for a given IPA bundle id:
    /// 1. `TEAM.bundleid.TEAM` (team-suffixed App ID) — the only one that can
    ///    upgrade an existing install without losing its data.
    /// 2. plain `bundleid`
    /// 3. the team wildcard.
    func suggestedProfile(for bundleID: String) -> ProvisionProfile? {
        let alive = profiles.filter { !$0.isExpired }
        let pool = alive.isEmpty ? profiles : alive
        let rank: (ProvisionProfile) -> Int = { profile in
            switch profile.matchKind(for: bundleID) {
            case .teamSuffixed: return 0
            case .exact: return 1
            case .wildcard: return 2
            case .none: return 3
            }
        }
        return pool
            .filter { $0.matches(bundleID) }
            .min { lhs, rhs in
                let l = rank(lhs), r = rank(rhs)
                if l != r { return l < r }
                if lhs.isWildcard != rhs.isWildcard { return !lhs.isWildcard }
                return lhs.expiration > rhs.expiration
            }
    }
}

// MARK: - Loading

enum SigningKitLoader {
    static let fm = FileManager.default

    /// Decoded profile payload (kept separate so the cache stays Codable).
    private struct Record: Codable {
        let uuid: String
        let name: String
        let teamID: String
        let appIdentifier: String
        let bundleID: String
        let expiration: Double
        let creation: Double
        let certificateCount: Int
        let deviceCount: Int
        let isXcodeManaged: Bool
        let platforms: [String]
        let devices: [String]
        let entitlements: [String: String]
        let certificates: [CertRecord]

        struct CertRecord: Codable {
            let commonName: String
            let teamID: String
            let notBefore: Double?
            let notAfter: Double?
        }
    }

    private struct Cache: Codable {
        let version: Int
        let entries: [String: Record]
    }

    /// Bump whenever `Record` gains fields, so stale caches re-parse.
    private static let cacheVersion = 2

    private static var cacheURL: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Signloader/profile-cache.json")
    }

    static func load(root: URL) async -> SigningKit {
        var problems: [String] = []
        guard fm.fileExists(atPath: root.path) else {
            return SigningKit(
                root: root,
                certificateURL: nil,
                certificate: nil,
                profiles: [],
                scannedFileCount: 0,
                problems: ["签名工具包目录不存在：\(root.path)"]
            )
        }

        // Any .p12 in the kit root works; prefer the conventional names first.
        let preferred = ["cert.p12", "signing.p12", "identity.p12"]
        let allP12s = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "p12" } ?? []
        let p12 = preferred.compactMap { name in allP12s.first { $0.lastPathComponent == name } }.first
            ?? allP12s.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
        let certificate = await readCertificate(p12: p12, problems: &problems)

        // Collect every profile under the kit (root + profiles-from-device).
        var files: [URL] = []
        if let en = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            files += en.filter { $0.pathExtension == "mobileprovision" }
        }
        for dir in [root.appendingPathComponent("profiles-from-device")] where fm.fileExists(atPath: dir.path) {
            if let en = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                files += en.filter { $0.pathExtension == "mobileprovision" }
            }
        }
        files.sort { $0.lastPathComponent < $1.lastPathComponent }

        let scanned = files.count
        var cache = readCache()
        var profiles: [ProvisionProfile] = []
        var byContent: [String: ProvisionProfile] = [:]
        var toDecode: [URL] = []

        for file in files {
            let key = cacheKey(for: file)
            if let record = cache.entries[key], let info = profile(from: record, url: file) {
                merge(info, into: &byContent)
            } else {
                toDecode.append(file)
            }
        }

        var freshEntries: [String: Record] = cache.entries
        for file in toDecode {
            guard let record = await decodeRecord(at: file) else {
                problems.append("无法解析描述文件：\(file.lastPathComponent)")
                continue
            }
            freshEntries[cacheKey(for: file)] = record
            if let info = profile(from: record, url: file) {
                merge(info, into: &byContent)
            }
        }
        cache = Cache(version: 1, entries: freshEntries)
        writeCache(cache)
        profiles = byContent.values.sorted { lhs, rhs in
            if lhs.isWildcard != rhs.isWildcard { return lhs.isWildcard }
            if lhs.bundleID != rhs.bundleID { return lhs.bundleID < rhs.bundleID }
            return lhs.expiration > rhs.expiration
        }

        return SigningKit(
            root: root,
            certificateURL: p12,
            certificate: certificate,
            profiles: profiles,
            scannedFileCount: scanned,
            problems: problems
        )
    }

    // MARK: Dedup

    private static func merge(_ profile: ProvisionProfile, into table: inout [String: ProvisionProfile]) {
        let key = profile.appIdentifier
        guard let existing = table[key] else {
            table[key] = profile
            return
        }
        // Identical content ⇒ identical details. Keep the freshest copy, count
        // the rest as duplicates.
        let keep = profile.expiration >= existing.expiration ? profile : existing
        table[key] = ProvisionProfile(
            id: keep.id, url: keep.url, uuid: keep.uuid, name: keep.name,
            teamID: keep.teamID, appIdentifier: keep.appIdentifier,
            bundleID: keep.bundleID, expiration: keep.expiration,
            creation: keep.creation, certificateCount: keep.certificateCount,
            deviceCount: keep.deviceCount,
            duplicateCount: existing.duplicateCount + 1,
            isXcodeManaged: keep.isXcodeManaged,
            platforms: keep.platforms,
            devices: keep.devices,
            entitlements: keep.entitlements,
            certificates: keep.certificates
        )
    }

    // MARK: Decoding

    private static func profile(from record: Record, url: URL) -> ProvisionProfile? {
        guard !record.appIdentifier.isEmpty else { return nil }
        let team = record.teamID
        var bundleID = record.appIdentifier
        if !team.isEmpty {
            if bundleID.hasPrefix(team + ".") { bundleID.removeFirst(team.count + 1) }
        }
        return ProvisionProfile(
            id: url.lastPathComponent,
            url: url,
            uuid: record.uuid,
            name: record.name,
            teamID: team,
            appIdentifier: record.appIdentifier,
            bundleID: bundleID,
            expiration: Date(timeIntervalSince1970: record.expiration),
            creation: Date(timeIntervalSince1970: record.creation),
            certificateCount: record.certificateCount,
            deviceCount: record.deviceCount,
            duplicateCount: 1,
            isXcodeManaged: record.isXcodeManaged,
            platforms: record.platforms,
            devices: record.devices,
            entitlements: record.entitlements,
            certificates: record.certificates.map {
                ProfileCertificate(
                    commonName: $0.commonName,
                    teamID: $0.teamID,
                    notBefore: $0.notBefore.map(Date.init(timeIntervalSince1970:)),
                    notAfter: $0.notAfter.map(Date.init(timeIntervalSince1970:))
                )
            }
        )
    }

    private static func decodeRecord(at url: URL) async -> Record? {
        guard let xml = try? await Shell.data("/usr/bin/security", ["cms", "-D", "-i", url.path]) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil),
              let dict = plist as? [String: Any] else { return nil }
        return record(from: dict, url: url)
    }

    private static func record(from dict: [String: Any], url: URL) -> Record? {
        guard let entitlements = dict["Entitlements"] as? [String: Any],
              let appIdentifier = entitlements["application-identifier"] as? String,
              !appIdentifier.isEmpty else { return nil }

        let teams = dict["TeamIdentifier"] as? [String] ?? []
        let teamID = teams.first ?? (dict["TeamIdentifier"] as? String ?? "")
        let expiration = (dict["ExpirationDate"] as? Date) ?? Date.distantPast
        let creation = (dict["CreationDate"] as? Date) ?? Date.distantPast
        let certs = dict["DeveloperCertificates"] as? [Data] ?? []
        let devices = ((dict["ProvisionedDevices"] as? [String]) ?? [])
            .filter { !$0.isEmpty }
        let entitlementsRaw = dict["Entitlements"] as? [String: Any] ?? [:]
        let platforms = ((dict["Platform"] as? [String]) ?? [])
            .filter { !$0.isEmpty }

        // Flatten entitlement values to display strings.
        var flattenedEntitlements: [String: String] = [:]
        for (key, value) in entitlementsRaw {
            flattenedEntitlements[key] = flatten(value)
        }

        return Record(
            uuid: dict["UUID"] as? String ?? url.deletingPathExtension().lastPathComponent,
            name: dict["Name"] as? String ?? appIdentifier,
            teamID: teamID,
            appIdentifier: appIdentifier,
            bundleID: appIdentifier,
            expiration: expiration.timeIntervalSince1970,
            creation: creation.timeIntervalSince1970,
            certificateCount: max(certs.count, 1),
            deviceCount: devices.count,
            isXcodeManaged: (dict["IsXcodeManaged"] as? Bool) ?? false,
            platforms: platforms,
            devices: devices,
            entitlements: flattenedEntitlements,
            certificates: certs.map { der in
                if let summary = DER.certificateSummary(der) {
                    return Record.CertRecord(
                        commonName: summary.commonName,
                        teamID: summary.teamID,
                        notBefore: summary.notBefore?.timeIntervalSince1970,
                        notAfter: summary.notAfter?.timeIntervalSince1970
                    )
                }
                return Record.CertRecord(commonName: "", teamID: "", notBefore: nil, notAfter: nil)
            }
        )
    }

    private static func flatten(_ value: Any) -> String {
        switch value {
        case let string as String: return string
        case let bool as Bool: return bool ? "是" : "否"
        case let int as Int: return String(int)
        case let double as Double: return String(double)
        case let array as [Any]: return array.map(flatten).joined(separator: ", ")
        case let date as Date:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.string(from: date)
        case let data as Data: return "<\(data.count) bytes>"
        default: return String(describing: value)
        }
    }

    // MARK: Cache

    private static func cacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.lastPathComponent)|\(size)|\(String(format: "%.0f", mtime))"
    }

    private static func readCache() -> Cache {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == cacheVersion else { return Cache(version: cacheVersion, entries: [:]) }
        return cache
    }

    private static func writeCache(_ cache: Cache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let dir = cacheURL.deletingLastPathComponent()
        try? fm.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: cacheURL, options: .atomic)
        // Carries device UDIDs and certificate subjects — treat as private.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }

    // MARK: Certificate

    private static func readCertificate(p12: URL?, problems: inout [String]) async -> SigningCertificate? {
        guard let p12 else { return nil }
        let password = PasswordStore.shared.password

        // The kit's p12 is encrypted with RC2-40-CBC. LibreSSL (`/usr/bin/openssl`)
        // reads it; OpenSSL 3 needs the legacy provider. Try the candidates in
        // order and keep the first that yields a certificate.
        let candidates = [
            "/usr/bin/openssl",
            Shell.locate("openssl"),
            "/opt/homebrew/opt/openssl@3/bin/openssl",
        ].compactMap { $0 }

        var pem: String?
        var lastError: Error?
        for openssl in dedupe(candidates) {
            let arguments = ["pkcs12", "-in", p12.path, "-nokeys", "-passin", "pass:\(password)"]
            if let result = try? await Shell.run(openssl, arguments, secrets: [password]) {
                pem = result.stdout
                break
            }
            if openssl.hasSuffix("openssl@3/bin/openssl") {
                // Retry with the legacy provider enabled.
                var env = ProcessInfo.processInfo.environment
                env["OPENSSL_CONF"] = "/opt/homebrew/etc/openssl@3/openssl.cnf"
                if let result = try? await Shell.runWithEnvironment(openssl, arguments, environment: env) {
                    pem = result.stdout
                    break
                }
            }
            lastError = ShellError.toolMissing(openssl)
        }

        guard let pem, let pemData = pem.data(using: .utf8), pem.contains("BEGIN CERTIFICATE") else {
            problems.append("读取证书失败：\(lastError?.localizedDescription ?? "openssl 无法解析 \(p12.lastPathComponent)")")
            return nil
        }

        let temp = fm.temporaryDirectory.appendingPathComponent("signloader-cert-\(UUID().uuidString).pem")
        do {
            try pemData.write(to: temp, options: .atomic)
            // Certificate material; keep it out of other local users' reach.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            defer { try? fm.removeItem(at: temp) }
            let info = try await Shell.run(
                "/usr/bin/openssl",
                ["x509", "-in", temp.path, "-noout", "-subject", "-startdate", "-enddate"]
            ).stdout

            var subject = ""
            var start: Date?
            var end: Date?
            for line in info.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("subject=") {
                    // LibreSSL prints `subject= /CN=…` — note the space.
                    subject = String(trimmed.dropFirst("subject=".count))
                        .trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("notBefore=") {
                    start = opensslDate(String(trimmed.dropFirst("notBefore=".count)))
                } else if trimmed.hasPrefix("notAfter=") {
                    end = opensslDate(String(trimmed.dropFirst("notAfter=".count)))
                }
            }
            let components = distinguishedNameComponents(subject)
            let cn = components.first { $0.key == "CN" }?.value
            let ou = components.first { $0.key == "OU" }?.value

            return SigningCertificate(
                subject: subject,
                commonName: cn ?? subject,
                teamID: ou ?? "",
                notBefore: start,
                notAfter: end,
                isValid: (end ?? .distantPast) > Date()
            )
        } catch {
            problems.append("解析证书信息失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// `openssl x509 -subject` prints either `/CN=x/O=y` (legacy) or
    /// `CN=x, O=y` (RFC 2253). Handle both.
    static func distinguishedNameComponents(_ raw: String) -> [(key: String, value: String)] {
        let dn = raw.trimmingCharacters(in: .whitespaces)
        let separators: Character = dn.hasPrefix("/") ? "/" : ","
        return dn.split(separator: separators)
            .compactMap { part -> (key: String, value: String)? in
                let piece = part.trimmingCharacters(in: .whitespaces)
                guard let equals = piece.firstIndex(of: "=") else { return nil }
                let key = String(piece[piece.startIndex..<equals]).trimmingCharacters(in: .whitespaces).uppercased()
                let value = String(piece[piece.index(after: equals)...])
                    .trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                return (key, value)
            }
    }

    private static func dedupe(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// `Aug 30 08:13:51 2027 GMT` → `Date`
    private static func opensslDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "MMM d HH:mm:ss yyyy z"
        return formatter.date(from: raw)
    }
}

// MARK: - Password

/// Where the p12 password comes from.
///
/// Precedence: `SIGNLOADER_P12_PASSWORD` environment variable (scripting / CI)
/// → Keychain → empty. It is never hardcoded and never written to UserDefaults,
/// which are plaintext to any reader.
///
/// A one-time migration pulls the password in from the 0600 file that earlier
/// builds used while the app was ad-hoc signed (see `CredentialStore`), then
/// removes the file.
final class PasswordStore: @unchecked Sendable {
    static let shared = PasswordStore()
    static let environmentVariable = "SIGNLOADER_P12_PASSWORD"

    private let lock = NSLock()
    private var cached: String?
    private let fromEnvironment: Bool

    private init() {
        let env = ProcessInfo.processInfo.environment[Self.environmentVariable] ?? ""
        fromEnvironment = !env.isEmpty
        if fromEnvironment { cached = env }
    }

    var password: String {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        var value = Keychain.read() ?? ""
        if value.isEmpty, let legacy = CredentialStore.read() {
            Keychain.write(legacy)
            CredentialStore.delete()
            value = legacy
        }
        cached = value
        return value
    }

    /// True when the value came from the environment; writes are ignored in
    /// that case so the GUI cannot silently diverge from the invocation.
    var isManagedByEnvironment: Bool { fromEnvironment }

    func set(_ value: String) {
        guard !fromEnvironment else { return }
        lock.lock()
        cached = value
        lock.unlock()
        // Off-main: a Keychain write can surface an authorization prompt when
        // the item's ACL predates this binary; never let that sit on main.
        DispatchQueue.global(qos: .userInitiated).async {
            if value.isEmpty {
                Keychain.delete()
            } else {
                Keychain.write(value)
            }
        }
    }

    /// Keeps the first credential read off the caller's actor.
    static func currentAsync() async -> String {
        await Task.detached(priority: .userInitiated) {
            shared.password
        }.value
    }
}
