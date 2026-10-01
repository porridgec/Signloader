import Foundation

/// Command line front end. Useful for scripting and for verifying the pipeline
/// without touching the GUI:
///
///     Signloader profiles
///     Signloader devices
///     Signloader info game.ipa
///     Signloader sign game.ipa --install auto
///     Signloader verify signed.ipa
enum CLI {
    struct Options {
        var positional: [String] = []
        var profile: String?
        var forceWildcard = false
        var safe = false
        var out: String?
        var install: String?
        var uninstallFirst = false
        var zipLevel: Int?
        var overrideBundleID: String?
        var removeExtensions = false
        var removeWatch = false
        var kit: String?
        var json = false
        var verbose = false
        var help = false
    }

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 1   // arguments[0] is the binary path
        while index < arguments.count {
            let arg = arguments[index]
            func value() -> String? {
                index += 1
                return index < arguments.count ? arguments[index] : nil
            }
            switch arg {
            case "-h", "--help": options.help = true
            case "--profile", "-m": options.profile = value()
            case "--wildcard": options.forceWildcard = true
            case "--safe": options.safe = true
            case "-o", "--out": options.out = value()
            case "--install", "-i": options.install = value()
            case "--uninstall-first": options.uninstallFirst = true
            case "-z", "--zip": options.zipLevel = value().flatMap(Int.init)
            case "-b", "--bundle-id": options.overrideBundleID = value()
            case "--remove-extensions": options.removeExtensions = true
            case "--remove-watch": options.removeWatch = true
            case "--kit", "-k": options.kit = value()
            case "--json": options.json = true
            case "-v", "--verbose": options.verbose = true
            default:
                if !arg.hasPrefix("-") { options.positional.append(arg) }
            }
            index += 1
        }
        return options
    }

    static let usage = """
    Signloader — 本地 iOS 签名工具

    USAGE
      Signloader                          启动 GUI
      Signloader profiles                 列出工具包里的描述文件
      Signloader devices                  列出已连接的设备
      Signloader info <app.ipa>           解析 IPA（Info.plist / 图标 / 扩展）
      Signloader sign <app.ipa>           签名，必要时安装
      Signloader verify <signed.ipa>      校验产物里的签名与 profile

    OPTIONS
      -m, --profile <substring>  用 bundle id 含该子串的 profile（默认自动匹配）
          --wildcard             强制使用通配符 profile
          --safe                 大 App 安全模式：unzip → zsign -f → ditto
      -o, --out <path>           输出路径
      -i, --install <udid|auto>  签名后安装到指定设备
          --uninstall-first      安装前先卸载旧版
      -z, --zip <0-9>            zip 压缩等级（0=store）
      -b, --bundle-id <id>       改写 bundle id
          --remove-extensions    移除 PlugIns
          --remove-watch         移除 Watch App
      -k, --kit <path>           指定 _signing-kit 目录
          --json                 以 JSON 输出（info / profiles / devices）
      -v, --verbose              profiles: 展开单个 profile 的设备/证书/entitlements
                                  （与 -m 连用，或默认取第一个匹配）
    """

    /// Exit code for the process. 0 = success.
    static func run(_ arguments: [String]) async -> Int {
        let args = Array(arguments.dropFirst())
        guard !args.isEmpty else { return 0 }
        let options = parse(arguments)

        if options.help || args.first == "help" {
            print(usage)
            return 0
        }

        // Everything that is neither the command nor a flag is an operand.
        let operands = args.dropFirst().filter { !$0.hasPrefix("-") }

        let kitPath = options.kit.map { ($0 as NSString).expandingTildeInPath }
            ?? AppModel.expanded(AppModel.defaultKitPath)
        let kit = await SigningKitLoader.load(root: URL(fileURLWithPath: kitPath))

        do {
            switch args.first {
            case "profiles":
                if options.verbose {
                    try await printProfileDetail(options, kit: kit)
                } else {
                    try await printProfiles(kit, json: options.json)
                }
            case "devices": try await printDevices(json: options.json)
            case "info": try await printInfo(options, operand: operands.first)
            case "sign": try await sign(options, operand: operands.first, kit: kit)
            case "verify": return try await verify(options, operand: operands.first)
            default:
                FileHandle.standardError.write(Data("未知命令: \(args[0])\n\n\(usage)\n".utf8))
                return 64
            }
        } catch {
            FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
            return 1
        }
        return 0
    }

    // MARK: profiles

    private static func printProfiles(_ kit: SigningKit, json: Bool) async throws {
        if json {
            let payload = kit.profiles.map {
                [
                    "bundleID": $0.displayBundleID,
                    "appIdentifier": $0.appIdentifier,
                    "team": $0.teamID,
                    "name": $0.name,
                    "expiration": ISO8601DateFormatter().string(from: $0.expiration),
                    "expired": $0.isExpired,
                    "duplicates": $0.duplicateCount,
                    "path": $0.url.path,
                ] as [String: Any]
            }
            print(String(data: try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? "[]")
            return
        }
        if let cert = kit.certificate {
            print("证书  \(cert.commonName)")
            print("      团队 \(cert.teamID) · \(cert.expiryLabel)")
        }
        print("工具包  \(kit.root.path)")
        print("profile \(kit.profiles.count) 个（去重自 \(kit.scannedFileCount) 个文件）")
        print("")
        for profile in kit.profiles {
            let flag = profile.isExpired ? "!" : " "
            let dup = profile.duplicateCount > 1 ? " ×\(profile.duplicateCount)" : ""
            print("  \(flag) \(profile.displayBundleID)\(dup)")
            print("      \(profile.appIdentifier) · \(profile.expiryLabel)")
        }
        for problem in kit.problems { print("  ! \(problem)") }
    }

    // MARK: Profile detail (CLI mirror of ProfileDetailView)

    private static func printProfileDetail(_ options: Options, kit: SigningKit) async throws {
        let candidates: [ProvisionProfile]
        if let query = options.profile {
            candidates = kit.profiles.filter {
                $0.displayBundleID.localizedCaseInsensitiveContains(query)
                    || $0.appIdentifier.localizedCaseInsensitiveContains(query)
            }
        } else {
            candidates = kit.profiles
        }
        guard let profile = candidates.first else {
            throw CLIError.usage(options.profile.map { "没有匹配「\($0)」的 profile" } ?? "工具包里没有 profile")
        }

        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd HH:mm"

        print("名称      \(profile.name)")
        print("App ID    \(profile.appIdentifier)")
        print("团队      \(profile.teamID)")
        print("UUID      \(profile.uuid)")
        print("创建      \(day.string(from: profile.creation))")
        print("到期      \(day.string(from: profile.expiration))（\(profile.expiryLabel)）")
        print("平台      \(profile.platforms.joined(separator: ", "))")
        print("Xcode托管 \(profile.isXcodeManaged ? "是" : "否")")
        print("副本      \(profile.duplicateCount) 份相同内容")
        print("文件      \(profile.url.path)")

        print("")
        print("证书 (\(profile.certificates.count))")
        let kitCert = kit.certificate
        for (index, cert) in profile.certificates.enumerated() {
            let marker = cert.matches(kitCert) ? "  ← 当前 p12" : ""
            print("  [\(index)] \(cert.commonName.isEmpty ? "(无法解析)" : cert.commonName)\(marker)")
            print("        团队 \(cert.teamID)  \(cert.validityLabel)")
        }

        print("")
        print("设备 (\(profile.devices.count))")
        for udid in profile.devices {
            print("  \(udid)")
        }
        if profile.devices.isEmpty { print("  （无 —— 分发类 profile）") }

        print("")
        print("Entitlements (\(profile.entitlements.count))")
        for (key, value) in profile.entitlements.sorted(by: { $0.key < $1.key }) {
            print("  \(key) = \(value)")
        }
    }

    // MARK: devices

    private static func printDevices(json: Bool) async throws {
        let devices = try await DeviceService.shared.listDevices()
        if json {
            let payload = devices.map {
                [
                    "udid": $0.udid, "name": $0.displayName, "productType": $0.productType,
                    "version": $0.productVersion, "transport": $0.transport.rawValue,
                ] as [String: Any]
            }
            print(String(data: try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? "[]")
            return
        }
        if devices.isEmpty {
            print("没有检测到 iOS 设备。USB 直连，或 Wi-Fi 设备（需先用 USB 配对过）都可以。")
            return
        }
        for device in devices {
            print("\(device.displayName)  \(device.productType) iOS \(device.productVersion)  [\(device.transport.label)]")
            print("    \(device.udid)")
        }
    }

    // MARK: info

    private static func printInfo(_ options: Options, operand: String?) async throws {
        guard let path = operand else { throw CLIError.usage("需要一个 .ipa 路径") }
        let info = try await IPAParser.parse(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        if options.json {
            let payload: [String: Any] = [
                "path": info.url.path,
                "appName": info.appName,
                "bundleID": info.bundleID,
                "shortVersion": info.shortVersion,
                "buildVersion": info.buildVersion,
                "executable": info.executable,
                "minimumOS": info.minimumOS,
                "size": info.fileSize,
                "entryCount": info.entryCount,
                "appExtensions": info.appExtensionNames,
                "watchApp": info.watchAppName ?? "",
                "hasIcon": info.iconData != nil,
            ]
            print(String(data: try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? "{}")
            return
        }
        print("文件        \(info.url.path)  (\(ByteFormat.string(info.fileSize)))")
        print("App         \(info.displayName)  \(info.versionLabel)")
        print("Bundle ID   \(info.bundleID)")
        print("可执行文件   \(info.executable)")
        print("最低系统     iOS \(info.minimumOS)")
        print("条目数      \(info.entryCount)")
        print("图标        \(info.iconData != nil ? "有" : "无（可能在 Assets.car）")")
        if !info.appExtensionNames.isEmpty {
            print("扩展        \(info.extensionSummary)")
        }
        if let watch = info.watchAppName { print("Watch App   \(watch)") }
        if info.recommendsSafeMode { print("提示        包体较大，建议 --safe") }
    }

    // MARK: verify

    private static func verify(_ options: Options, operand: String?) async throws -> Int {
        guard let path = operand else { throw CLIError.usage("需要一个 .ipa 路径") }
        let result = await IPAParser.verify(
            signedIPA: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
            expectedAppIdentifier: options.profile
        )
        print("文件                  \((path as NSString).lastPathComponent)")
        print("代码签名              \(result.hasCodeSignature ? "有" : "无")")
        print("内嵌 profile          \(result.hasEmbeddedProfile ? "有" : "无")")
        print("profile 名称          \(result.embeddedProfileName ?? "-")")
        print("application-identifier \(result.embeddedAppIdentifier ?? "-")")
        if let signedAt = result.signedAt {
            print("创建时间              \(signedAt.formatted(date: .numeric, time: .shortened))")
        }
        if let expected = options.profile {
            print("与期望一致            \(result.matchesProfile ? "是" : "否（期望 \(expected)）")")
        }
        let ok = result.hasCodeSignature && result.hasEmbeddedProfile
        return ok ? 0 : 1
    }

    // MARK: sign

    private static func sign(_ options: Options, operand: String?, kit: SigningKit) async throws {
        guard let path = operand else { throw CLIError.usage("需要一个 .ipa 路径") }
        let ipaURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let p12 = kit.certificateURL else { throw CLIError.usage("工具包里没有 p12：\(kit.root.path)") }

        let info = try await IPAParser.parse(url: ipaURL)
        print("源文件   \(ipaURL.lastPathComponent)  (\(ByteFormat.string(info.fileSize)))")
        print("App      \(info.displayName) \(info.versionLabel)")
        print("Bundle   \(info.bundleID)")

        let profile: ProvisionProfile
        if options.forceWildcard {
            guard let wildcard = kit.profiles.first(where: { $0.isWildcard && !$0.isExpired }) ?? kit.profiles.first(where: { $0.isWildcard }) else {
                throw CLIError.usage("工具包里没有通配符 profile")
            }
            profile = wildcard
        } else if let query = options.profile {
            let matches = kit.profiles.filter {
                $0.displayBundleID.localizedCaseInsensitiveContains(query)
                    || $0.appIdentifier.localizedCaseInsensitiveContains(query)
            }
            guard let best = matches.min(by: { $0.expiration > $1.expiration }) else {
                throw CLIError.usage("没有匹配「\(query)」的 profile")
            }
            profile = best
        } else {
            guard let best = kit.suggestedProfile(for: info.bundleID) else {
                throw CLIError.usage("没有可用于 \(info.bundleID) 的 profile")
            }
            profile = best
        }
        print("Profile  \(profile.appIdentifier)")
        print("         \(profile.matchKind(for: info.bundleID).rawValue) · \(profile.expiryLabel)")

        var signingOptions = SigningOptions()
        signingOptions.safeMode = options.safe || info.recommendsSafeMode
        signingOptions.zipLevel = options.zipLevel ?? 9
        signingOptions.overrideBundleID = options.overrideBundleID ?? ""
        signingOptions.removeAppExtensions = options.removeExtensions
        signingOptions.removeWatchApp = options.removeWatch
        signingOptions.stripEmbeddedProfile = false
        signingOptions.installAfterSigning = options.install != nil
        signingOptions.uninstallBeforeInstall = options.uninstallFirst

        if signingOptions.safeMode && !options.safe {
            print("模式     自动切换到安全模式（包体 \(ByteFormat.string(info.fileSize))）")
        }

        let output: URL
        if let out = options.out {
            output = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        } else {
            output = Signer.defaultOutputURL(for: ipaURL, directory: nil, appName: info.displayName)
        }
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        let request = SignRequest(
            ipa: ipaURL,
            output: output,
            p12: p12,
            password: PasswordStore.shared.password,
            profile: profile,
            appPath: info.appPath,
            options: signingOptions
        )

        print("输出     \(output.path)")
        print("── 开始 ──")
        let outcome = try await Signer().run(request) { lines in
            for line in lines { print(line) }
        }
        print("── 完成 ──")
        print("用时     \(String(format: "%.2f", outcome.duration))s")
        print("大小     \(ByteFormat.string(outcome.sizeBefore)) → \(ByteFormat.string(outcome.sizeAfter))")
        print("代码签名 \(outcome.verification.hasCodeSignature ? "有" : "无")")
        print("内嵌profile \(outcome.verification.embeddedProfileName ?? "无")")
        print("app-id  \(outcome.verification.embeddedAppIdentifier ?? "-")")
        print("一致     \(outcome.verification.matchesProfile ? "是" : "否")")

        if let install = options.install {
            let known = (try? await DeviceService.shared.listDevices()) ?? []
            let target: Device
            if install == "auto" {
                // listDevices puts USB first — auto prefers it for large transfers.
                guard let first = known.first else {
                    throw CLIError.usage("没有已连接的设备")
                }
                target = first
            } else if let match = known.first(where: { $0.udid == install }) {
                target = match
            } else {
                // Explicit UDID we haven't discovered; assume USB.
                target = Device(udid: install, name: "", productName: "", productType: "",
                                productVersion: "", transport: .usb)
            }
            print("设备     \(target.displayName) (\(target.udid)) · \(target.transport.label)")
            if options.uninstallFirst {
                try await DeviceService.shared.uninstall(udid: target.udid, transport: target.transport, bundleID: info.bundleID) { print($0) }
            }
            try await DeviceService.shared.install(udid: target.udid, transport: target.transport, ipa: output) { lines in
                for line in lines { print(line) }
            }
            print("安装成功 \(info.displayName) → \(target.udid)")
        }
    }
}

enum CLIError: LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message): return "\(message)\n\n\(CLI.usage)"
        }
    }
}
