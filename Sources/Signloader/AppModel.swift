import AppKit
import Foundation
import Observation

struct LogEntry: Identifiable, Sendable {
    enum Level: Sendable {
        case command, info, success, warning, error

        var symbol: String {
            switch self {
            case .command: return "chevron.right"
            case .info: return "circle"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }

    let id = UUID()
    let level: Level
    let text: String
    let date = Date()
}

enum BusyTask: Sendable, Equatable {
    case idle
    case parsingIPA
    case scanningKit
    case scanningDevices
    case scanningApps
    case signing
    case installing
    case uninstalling

    var isBusy: Bool { self != .idle }

    var label: String {
        switch self {
        case .idle: return "就绪"
        case .parsingIPA: return "解析 IPA…"
        case .scanningKit: return "扫描签名工具包…"
        case .scanningDevices: return "查找设备…"
        case .scanningApps: return "读取已安装 App…"
        case .signing: return "签名中…"
        case .installing: return "安装中…"
        case .uninstalling: return "卸载中…"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: Kit / settings

    var kitPath: String { didSet { UserDefaults.standard.set(kitPath, forKey: Self.kitKey) } }
    var outputDirectory: String { didSet { UserDefaults.standard.set(outputDirectory, forKey: Self.outKey) } }
    private var storedPassword = ""

    /// The password as edited in Settings. Assigning **persists** it, so only a
    /// real user edit may assign here — startup populates the field through
    /// `adoptStoredPassword(_:)` instead. Assigning at startup used to rewrite
    /// the stored credential on every launch.
    var password: String {
        get { storedPassword }
        set {
            storedPassword = newValue
            PasswordStore.shared.set(newValue)
        }
    }

    /// Populate the password field from the store without persisting it back.
    func adoptStoredPassword(_ value: String) {
        storedPassword = value
    }
    var passwordIsFromEnvironment: Bool { PasswordStore.shared.isManagedByEnvironment }
    var options: SigningOptions {
        // SigningOptions is a Swift struct — not a property-list object — so a
        // direct UserDefaults.set here throws NSInvalidArgumentException from
        // _CFPrefsValidateValueForKey, and AppKit crashes the app the moment a
        // TextField in SigningOptionsCard writes back. Persist as JSON Data.
        didSet {
            if let data = try? JSONEncoder().encode(options) {
                UserDefaults.standard.set(data, forKey: Self.optsKey)
            }
        }
    }

    private static let kitKey = "kitPath"
    private static let outKey = "outputDirectory"
    private static let optsKey = "signingOptions"



    // MARK: State

    var kit = SigningKit(root: URL(fileURLWithPath: "/"), certificateURL: nil, certificate: nil, profiles: [], scannedFileCount: 0, problems: [])
    var ipa: IPAInfo?
    var selectedProfile: ProvisionProfile?
    var detailProfile: ProvisionProfile?
    var outputURL: URL?
    var lastOutcome: SignOutcome?
    var selectedDevice: Device?
    var devices: [Device] = []
    var installedApps: [InstalledApp] = []
    var busy: BusyTask = .idle
    var log: [LogEntry] = []
    var errorMessage: String?
    var lastProfileSelectionWasAutomatic = false

    var profileFilter: String = ""
    var appFilter: String = ""
    var isBusy: Bool { busy.isBusy }

    private let maxLogLines = 4000

    init() {
        let defaults = UserDefaults.standard
        kitPath = defaults.string(forKey: Self.kitKey) ?? SignloaderPaths.expanded(SignloaderPaths.defaultKitPath)
        outputDirectory = defaults.string(forKey: Self.outKey) ?? SignloaderPaths.expanded(SignloaderPaths.defaultOutputDirectory)
        // Deliberately not touching PasswordStore here: its first credential
        // read must happen off-main (see PasswordStore).
        storedPassword = ""
        if let data = defaults.data(forKey: Self.optsKey),
           let decoded = try? JSONDecoder().decode(SigningOptions.self, from: data) {
            options = decoded
        } else {
            var o = SigningOptions()
            o.zipLevel = 9
            options = o
        }
    }



    // MARK: Derived

    var resolvedKitURL: URL { URL(fileURLWithPath: kitPath) }

    var outputDirectoryURL: URL? {
        outputDirectory.isEmpty ? nil : URL(fileURLWithPath: (outputDirectory as NSString).expandingTildeInPath)
    }

    var hasCertificate: Bool { kit.certificateURL != nil }

    var bundleIDDraft = ""
    var appNameDraft = ""
    /// 首次聚焦才预填原值；换 IPA 后重置。
    private var bundleIDDraftInitialized = false
    private var appNameDraftInitialized = false

    /// 首次激活输入框时，用当前 IPA 的原值预填（用户要求的行为）。
    func prefillBundleIDDraft() {
        guard !bundleIDDraftInitialized, let ipa else { return }
        bundleIDDraft = ipa.bundleID
        bundleIDDraftInitialized = true
    }

    func prefillAppNameDraft() {
        guard !appNameDraftInitialized, let ipa else { return }
        appNameDraft = ipa.displayName
        appNameDraftInitialized = true
    }

    /// 有效覆盖值 = 输入框草稿。草稿是**按 IPA** 的临时状态（换 IPA 即清空），
    /// 不进持久化——否则上一个 App 的 bundle id 会静默套到下一个 App 上。
    private func applyDraftOverrides() {
        options.overrideBundleID = bundleIDDraft
        options.overrideAppName = appNameDraft
    }

    var missingTools: [String] { Toolchain.missing() }

    var filteredProfiles: [ProvisionProfile] {
        let query = profileFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = kit.profiles.sorted { lhs, rhs in
            if let ipa {
                let l = lhs.matchKind(for: ipa.bundleID)
                let r = rhs.matchKind(for: ipa.bundleID)
                if l != r { return l.rawValue < r.rawValue }
            }
            if lhs.isWildcard != rhs.isWildcard { return !lhs.isWildcard }
            if lhs.isExpired != rhs.isExpired { return !lhs.isExpired }
            return lhs.displayBundleID.localizedCaseInsensitiveCompare(rhs.displayBundleID) == .orderedAscending
        }
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.displayBundleID.lowercased().contains(query)
                || $0.appIdentifier.lowercased().contains(query)
                || $0.name.lowercased().contains(query)
        }
    }

    var filteredApps: [InstalledApp] {
        let query = appFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return installedApps }
        return installedApps.filter {
            $0.bundleID.lowercased().contains(query) || $0.name.lowercased().contains(query)
        }
    }

    var isBundleIDInstalled: Bool {
        guard let id = ipa?.bundleID else { return false }
        return installedApps.contains { $0.bundleID == id }
    }

    var canSign: Bool {
        guard let ipa, let selectedProfile, let p12 = kit.certificateURL else { return false }
        return !isBusy && !ipa.bundleID.isEmpty && selectedProfile.matches(ipa.bundleID)
            && !p12.path.isEmpty && FileManager.default.fileExists(atPath: p12.path)
    }

    var canInstall: Bool {
        guard let outputURL, let device = selectedDevice else { return false }
        return !isBusy && FileManager.default.fileExists(atPath: outputURL.path) && !device.udid.isEmpty
    }

    // MARK: Logging

    func log(_ text: String, _ level: LogEntry.Level = .info) {
        log.append(LogEntry(level: level, text: text))
        if log.count > maxLogLines {
            log.removeFirst(log.count - maxLogLines)
        }
    }

    func logCommand(_ text: String) {
        log("$ " + text, .command)
    }

    // MARK: Kit

    func loadKit() async {
        guard !isBusy else { return }
        busy = .scanningKit
        defer { busy = .idle }

        // The kit loader parses the certificate, so the password has to be in
        // hand first. This is also the only place it is pulled into the UI.
        // Off-main, for symmetry with the rest of the credential path. Populated
        // via `adoptStoredPassword` so it does not write back.
        if PasswordStore.shared.isManagedByEnvironment {
            adoptStoredPassword(PasswordStore.shared.password)
        } else {
            adoptStoredPassword(await PasswordStore.currentAsync())
        }

        let root = resolvedKitURL
        log("扫描签名工具包：\(root.path)", .info)
        kit = await SigningKitLoader.load(root: root)
        log(
            "找到 \(kit.profiles.count) 个可用描述文件（去重自 \(kit.scannedFileCount) 个文件），团队 \(kit.teamIDs.joined(separator: ", "))",
            .success
        )
        for problem in kit.problems.prefix(5) { log(problem, .warning) }
        if let cert = kit.certificate {
            log("证书：\(cert.commonName) · \(cert.expiryLabel)", cert.isValid ? .success : .warning)
        } else if kit.certificateURL != nil {
            log("找到 p12 但没解析出证书：密码可能没填或不对（设置里填一次，存 Keychain）。", .warning)
        } else {
            log("未找到 p12 证书，请在设置里指定工具包目录。", .warning)
        }

        reselectProfile(automatic: true)

    }

    // MARK: IPA

    func loadIPA(_ url: URL) async {
        guard !isBusy else { return }
        busy = .parsingIPA
        errorMessage = nil
        lastOutcome = nil
        outputURL = nil
        defer { busy = .idle }
        do {
            let info = try await IPAParser.parse(url: url)
            ipa = info
            // 草稿按 IPA 归零：上一个 App 的覆盖值绝不能带过来
            bundleIDDraft = ""
            appNameDraft = ""
            bundleIDDraftInitialized = false
            appNameDraftInitialized = false
            log("载入 \(url.lastPathComponent) · \(ByteFormat.string(info.fileSize))", .success)
            log("App: \(info.displayName) \(info.versionLabel)", .info)
            log("Bundle ID: \(info.bundleID)", .info)
            if !info.appExtensionNames.isEmpty {
                log("包含扩展 \(info.appExtensionNames.count) 个：\(info.extensionSummary)", .info)
            }
            if let watch = info.watchAppName { log("包含 Watch App：\(watch)", .info) }
            if info.recommendsSafeMode && !options.safeMode {
                log("包体 \(ByteFormat.string(info.fileSize)) 偏大，建议在选项里打开「大 App 安全模式」。", .warning)
            }
            reselectProfile(automatic: true)
            outputURL = Signer.defaultOutputURL(
                for: url,
                directory: outputDirectoryURL,
                appName: sanitizedName(info.displayName)
            )
        } catch {
            ipa = nil
            errorMessage = error.localizedDescription
            log("解析失败：\(error.localizedDescription)", .error)
        }
    }

    private func sanitizedName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }

    func reselectProfile(automatic: Bool) {
        guard let ipa else {
            selectedProfile = nil
            return
        }
        guard let best = kit.suggestedProfile(for: ipa.bundleID) else {
            selectedProfile = nil
            if automatic { log("工具包里没有能签 \(ipa.bundleID) 的描述文件。", .error) }
            return
        }
        selectedProfile = best
        lastProfileSelectionWasAutomatic = automatic
        switch best.matchKind(for: ipa.bundleID) {
        case .teamSuffixed:
            log("自动选择覆盖安装 profile：\(best.displayBundleID)（可保留应用数据）", .success)
        case .exact:
            log("自动选择描述文件：\(best.displayBundleID)", .success)
        case .wildcard:
            log("自动选择通配符 profile：只适用于新装，覆盖旧版会报 MismatchedApplicationIdentifierEntitlement。", .warning)
        case .none:
            break
        }
    }

    // MARK: Devices

    /// 队列卡片的目标设备提示用；设备列表没刷新过时先刷一次。
    func refreshDevicesForQueueHint() async {
        if devices.isEmpty { await loadDevices() }
    }

    func loadDevices() async {
        guard !isBusy else { return }
        busy = .scanningDevices
        defer { busy = .idle }
        do {
            let found = try await DeviceService.shared.listDevices()
            devices = found
            if found.isEmpty {
                log("没有检测到 iOS 设备。USB 直连，或 Wi-Fi 设备（需先用 USB 配对过）都可以。", .warning)
                selectedDevice = nil
            } else {
                let perTransport = Dictionary(grouping: found, by: \.transport)
                    .mapValues { $0.count }
                let summary = Device.Transport.allCases
                    .compactMap { transport -> String? in
                        guard let n = perTransport[transport], n > 0 else { return nil }
                        return "\(transport.label) \(n)"
                    }
                    .joined(separator: "，")
                log("检测到 \(found.count) 台设备：\(found.map(\.displayName).joined(separator: ", "))（\(summary)）", .success)
                if let current = selectedDevice, let keep = found.first(where: { $0.udid == current.udid }) {
                    selectedDevice = keep
                } else {
                    selectedDevice = found.first
                }
                await loadInstalledApps()
            }
        } catch {
            errorMessage = error.localizedDescription
            log("读取设备失败：\(error.localizedDescription)", .error)
        }
    }

    func loadInstalledApps() async {
        guard let device = selectedDevice, !isBusy else { return }
        busy = .scanningApps
        defer { busy = .idle }
        do {
            installedApps = try await DeviceService.shared.installedApps(udid: device.udid, transport: device.transport)
            log("\(device.displayName) 上有 \(installedApps.count) 个用户 App", .info)
            if let id = ipa?.bundleID {
                let match = installedApps.first { $0.bundleID == id }
                if let match {
                    log("设备上已存在 \(match.name) \(match.versionLabel)。覆盖安装若报 MismatchedApplicationIdentifierEntitlement，先卸载再装。", .warning)
                }
            }
        } catch {
            log("读取已安装 App 失败：\(error.localizedDescription)", .error)
        }
    }

    // MARK: Actions

    func sign() async {
        guard let ipa, let profile = selectedProfile, let p12 = kit.certificateURL else { return }
        let output = outputURL ?? Signer.defaultOutputURL(for: ipa.url, directory: outputDirectoryURL, appName: ipa.displayName)
        outputURL = output
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        busy = .signing
        lastOutcome = nil
        defer { busy = .idle }

        // 把输入框草稿套进签名参数（草稿按 IPA 生命周期管理）
        applyDraftOverrides()

        let request = SignRequest(
            ipa: ipa.url,
            output: output,
            p12: p12,
            password: password,
            profile: profile,
            appPath: ipa.appPath,
            options: options
        )
        log("开始签名 → \(output.lastPathComponent)", .info)
        log("模式：\(options.safeMode ? "安全模式 (unzip + zsign -f + ditto)" : "标准模式 (zsign)")", .info)
        log("profile：\(profile.appIdentifier)", .info)

        let sink: @Sendable ([String]) -> Void = { [weak self] lines in
            Task { @MainActor in
                for line in lines { self?.log(line) }
            }
        }

        do {
            let outcome = try await Signer().run(request, onLine: sink)
            lastOutcome = outcome
            log("签名完成，用时 \(String(format: "%.2f", outcome.duration))s，产物 \(ByteFormat.string(outcome.sizeAfter))", .success)
            if outcome.verification.hasCodeSignature {
                log("已嵌入代码签名 _CodeSignature", .success)
            } else {
                log("产物里没找到 _CodeSignature，请检查日志。", .warning)
            }
            if outcome.verification.hasEmbeddedProfile {
                let name = outcome.verification.embeddedProfileName ?? "未知"
                log("已嵌入 profile：\(name)", .success)
                if outcome.verification.matchesProfile {
                    log("application-identifier 与所选 profile 一致，覆盖安装可用。", .success)
                } else {
                    log(
                        "注意：内嵌 application-identifier = \(outcome.verification.embeddedAppIdentifier ?? "?")，与所选 profile 不一致，覆盖安装可能失败。",
                        .warning
                    )
                }
            } else {
                log("产物里没有 embedded.mobileprovision，装到手机上会失败。", .error)
            }

            if options.installAfterSigning {
                if options.uninstallBeforeInstall { await uninstallCurrent() }
                await install()
            }
        } catch {
            log("签名失败：\(error.localizedDescription)", .error)
            errorMessage = error.localizedDescription
        }
    }

    /// 直接安装：把**已签名**的 IPA 不经重签装到当前设备。多个文件顺序装，
    /// 单个失败不中断。装前校验 _CodeSignature / 内嵌 profile——没签过的
    /// IPA 装到设备必然失败，提前拦下并给出明确原因。
    func installDirectly(urls: [URL]) async {
        let files = urls.filter { $0.pathExtension.lowercased() == "ipa" }
        guard !files.isEmpty else { return }
        guard let device = selectedDevice else {
            log("未选择设备，无法直接安装（顶部选择设备）", .warning)
            return
        }
        guard !isBusy else { return }
        busy = .installing
        defer { busy = .idle }

        log("直接安装 \(files.count) 个 IPA → \(device.displayName)（\(device.transport.label)）", .info)

        var installed = 0
        for file in files {
            do {
                let info = try await IPAParser.parse(url: file)
                let check = await IPAParser.verify(signedIPA: file, expectedAppIdentifier: nil)
                guard check.hasCodeSignature && check.hasEmbeddedProfile else {
                    log("「\(info.displayName)」没有代码签名/内嵌 profile，先签名再安装（已跳过）", .error)
                    continue
                }

                if options.uninstallBeforeInstall {
                    try await DeviceService.shared.uninstall(
                        udid: device.udid, transport: device.transport, bundleID: info.bundleID
                    ) { lines in
                        Task { @MainActor in lines.forEach { self.log($0) } }
                    }
                }

                log("「\(info.displayName)」安装中…", .info)
                try await DeviceService.shared.install(
                    udid: device.udid, transport: device.transport, ipa: file
                ) { lines in
                    Task { @MainActor in lines.forEach { self.log($0) } }
                }
                installed += 1
                log("「\(info.displayName)」安装成功", .success)
            } catch {
                log("「\(file.lastPathComponent)」安装失败：\(error.localizedDescription)", .error)
            }
        }

        log("直接安装结束：成功 \(installed) / \(files.count)", installed == files.count ? .success : .warning)
        await loadInstalledApps()
    }

    func install() async {
        guard let outputURL, let device = selectedDevice else { return }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            log("还没有产物，先签名。", .warning)
            return
        }
        busy = .installing
        defer { busy = .idle }
        log("安装到 \(device.displayName)…", .info)
        let sink: @Sendable ([String]) -> Void = { [weak self] lines in
            Task { @MainActor in for line in lines { self?.log(line) } }
        }
        do {
            try await DeviceService.shared.install(udid: device.udid, transport: device.transport, ipa: outputURL, onLine: sink)
            log("安装成功 ✅", .success)
            installedApps = try await DeviceService.shared.installedApps(udid: device.udid, transport: device.transport)
        } catch {
            let text = error.localizedDescription
            log("安装失败：\(text)", .error)
            if text.contains("ApplicationVerificationFailed") || text.contains("MismatchedApplicationIdentifier") {
                log("这是签名/entitlement 不匹配：多半是旧版是别的团队签的，先「卸载再装」。", .warning)
            }
            errorMessage = text
        }
    }

    func uninstallCurrent() async {
        guard let id = ipa?.bundleID, let device = selectedDevice else { return }
        busy = .uninstalling
        defer { busy = .idle }
        let sink: @Sendable ([String]) -> Void = { [weak self] lines in
            Task { @MainActor in for line in lines { self?.log(line) } }
        }
        do {
            try await DeviceService.shared.uninstall(udid: device.udid, transport: device.transport, bundleID: id, onLine: sink)
            log("已卸载 \(id)", .success)
            installedApps = try await DeviceService.shared.installedApps(udid: device.udid, transport: device.transport)
        } catch {
            log("卸载失败：\(error.localizedDescription)", .error)
        }
    }

    func uninstall(_ app: InstalledApp) async {
        guard let device = selectedDevice else { return }
        busy = .uninstalling
        defer { busy = .idle }
        do {
            try await DeviceService.shared.uninstall(udid: device.udid, transport: device.transport, bundleID: app.bundleID) { lines in
                Task { @MainActor in for line in lines { self.log(line) } }
            }
            log("已卸载 \(app.name)", .success)
            installedApps = try await DeviceService.shared.installedApps(udid: device.udid, transport: device.transport)
        } catch {
            log("卸载失败：\(error.localizedDescription)", .error)
        }
    }

    func refreshProfilesFromDevice() async {
        guard let device = selectedDevice else { return }
        busy = .scanningKit
        defer { busy = .idle }
        let target = kit.profileDirectory
        log("从 \(device.displayName) 导出描述文件到 \(target.lastPathComponent)…", .info)
        let sink: @Sendable ([String]) -> Void = { [weak self] lines in
            Task { @MainActor in for line in lines { self?.log(line) } }
        }
        do {
            try await DeviceService.shared.exportProfiles(udid: device.udid, transport: device.transport, to: target, onLine: sink)
            log("导出完成，重新扫描工具包…", .success)
            kit = await SigningKitLoader.load(root: resolvedKitURL)
            reselectProfile(automatic: true)
        } catch {
            log("导出失败：\(error.localizedDescription)", .error)
        }
    }

    // MARK: Shell helpers

    func revealOutput() {
        guard let outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    func revealKit() {
        NSWorkspace.shared.activateFileViewerSelecting([resolvedKitURL])
    }

    func revealIPA() {
        guard let ipa else { return }
        NSWorkspace.shared.activateFileViewerSelecting([ipa.url])
    }

    func revealKitInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([resolvedKitURL])
    }

    func copyOutputPath() {
        guard let outputURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputURL.path, forType: .string)
    }

    // MARK: Queue

    var queue: [QueueItem] = []
    var queueRunning = false
    private var queueStopRequested = false

    var queueSummary: String {
        let counts = Dictionary(grouping: queue, by: \.state).mapValues(\.count)
        return QueueItem.State.allCases
            .compactMap { state in
                guard let n = counts[state], n > 0 else { return nil }
                return "\(state.rawValue) \(n)"
            }
            .joined(separator: " · ")
    }

    /// 入队（自动过滤非 .ipa）。重复入队允许——产物用 -2/-3 后缀避免覆盖。
    func addToQueue(_ urls: [URL]) {
        let items = urls
            .filter { $0.pathExtension.lowercased() == "ipa" }
            .map { QueueItem(url: $0) }
        guard !items.isEmpty else { return }
        queue.append(contentsOf: items)
        let names = items.map(\.displayName)
        log("队列 +\(items.count)，共 \(queue.count) 个：\(names.prefix(3).joined(separator: "、"))\(names.count > 3 ? " 等" : "")", .info)
    }

    func removeFromQueue(_ id: QueueItem.ID) {
        // 处理中的项不能在这里移除，先停止队列
        queue.removeAll { $0.id == id && $0.state != .working }
    }

    func clearQueue(finishedOnly: Bool) {
        if finishedOnly {
            queue.removeAll { $0.state.isFinished }
        } else {
            queue.removeAll { $0.state != .working }
        }
    }

    /// 当前项结束后停止；未开始的项标记为已取消。
    func stopQueue() {
        guard queueRunning else { return }
        queueStopRequested = true
        log("队列将在当前项结束后停止", .warning)
    }

    func runQueue() async {
        guard !queueRunning, !isBusy else { return }
        guard queue.contains(where: { !$0.state.isFinished }) else {
            log("队列里没有待处理项", .warning)
            return
        }
        queueRunning = true
        queueStopRequested = false
        defer { queueRunning = false }

        let installing = selectedDevice != nil
        log(
            "开始队列：\(queue.filter { !$0.state.isFinished }.count) 项，\(installing ? "签名并安装到 \(selectedDevice!.displayName)" : "仅签名（未选设备）")",
            .info
        )

        for index in queue.indices {
            if queueStopRequested {
                if queue[index].state == .pending {
                    queue[index].state = .cancelled
                    queue[index].note = "用户停止"
                }
                continue
            }
            guard queue[index].state == .pending else { continue }
            await processQueueItem(at: index)
        }

        let ok = queue.filter { $0.state == .done }.count
        let bad = queue.filter { $0.state == .failed }.count
        let skipped = queue.filter { $0.state == .cancelled }.count
        log(
            "队列结束：成功 \(ok) · 失败 \(bad)\(skipped > 0 ? " · 取消 \(skipped)" : "")",
            bad == 0 ? .success : .warning
        )
    }

    /// 单项流水线：解析 → 自动匹配 profile → 签名 →（有设备则）安装。
    /// 失败只标记本项，不中断队列。
    private func processQueueItem(at index: Int) async {
        let url = queue[index].url
        queue[index].state = .working

        func note(_ text: String) { queue[index].note = text }

        do {
            note("解析中")
            let info = try await IPAParser.parse(url: url)
            log("「\(info.displayName)」\(info.versionLabel) · \(info.bundleID)", .info)

            guard let profile = kit.suggestedProfile(for: info.bundleID) else {
                throw QueueError.noProfile(info.bundleID)
            }
            guard let p12 = kit.certificateURL else {
                throw QueueError.noCertificate
            }
            note("签名 · \(profile.displayBundleID)")

            // 队列项不继承聚焦 IPA 的草稿（bundle id / 显示名覆盖是按 App 的），
            // 也不走 options.installAfterSigning——安装由本循环统一处理。
            var opts = options
            opts.overrideBundleID = ""
            opts.overrideAppName = ""
            opts.installAfterSigning = false

            let output = Signer.defaultOutputURL(
                for: url, directory: outputDirectoryURL, appName: info.displayName
            )
            try? FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let request = SignRequest(
                ipa: url, output: output, p12: p12, password: password,
                profile: profile, appPath: info.appPath, options: opts
            )
            let outcome = try await Signer().run(request) { lines in
                Task { @MainActor in lines.forEach { self.log($0) } }
            }
            guard outcome.verification.hasEmbeddedProfile else {
                throw QueueError.badSignature
            }

            if let device = selectedDevice {
                note("安装 → \(device.displayName)")
                try await DeviceService.shared.install(
                    udid: device.udid, transport: device.transport, ipa: output
                ) { lines in
                    Task { @MainActor in lines.forEach { self.log($0) } }
                }
                queue[index].state = .done
                note("已安装 · \(device.displayName)")
                log("「\(info.displayName)」安装完成", .success)
            } else {
                queue[index].state = .done
                note("已签名（未选设备）")
                log("「\(info.displayName)」签名完成：\(output.lastPathComponent)", .success)
            }
        } catch {
            queue[index].state = .failed
            queue[index].note = error.localizedDescription
            log("「\(url.lastPathComponent)」失败：\(error.localizedDescription)", .error)
        }
    }
}

enum QueueError: LocalizedError {
    case noProfile(String)
    case noCertificate
    case badSignature

    var errorDescription: String? {
        switch self {
        case .noProfile(let bundleID): return "工具包里没有能签 \(bundleID) 的 profile"
        case .noCertificate: return "工具包里没有 p12 证书"
        case .badSignature: return "签出来的产物没有内嵌 profile，已跳过安装"
        }
    }
}
