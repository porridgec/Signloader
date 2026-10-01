import Foundation

/// Command-line front end — the machine interface to the same service layer the
/// GUI uses.
///
/// Contract for agents:
/// - `--json` makes stdout a single JSON document; human progress goes to stderr.
/// - Without `--json`, stdout is human-readable.
/// - Exit codes: 0 success · 1 error · 2 verification failed · 64 bad usage.
/// - Never interactive: pass the p12 password via `SIGNLOADER_P12_PASSWORD`.
enum CLI {
    static let version = "1.0.0"

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
    Signloader — 本地 iOS IPA 重签名工具

    USAGE
      Signloader                          启动 GUI
      Signloader profiles                 列出工具包里的描述文件
      Signloader profile -m <子串>        展开单个 profile 详情（设备/证书/entitlements）
      Signloader devices                  列出已连接的设备（USB + Wi-Fi）
      Signloader info <app.ipa>           解析 IPA（Info.plist / 图标 / 扩展）
      Signloader sign <app.ipa>           签名，必要时安装
      Signloader verify <signed.ipa>      校验产物里的签名与 profile
      Signloader doctor                   自检：工具链 / 工具包 / 设备
      Signloader version                  打印版本

    AGENT 接口
      所有命令都接受 --json：stdout 输出单个 JSON 文档（含 command/ok 字段），
      人类可读进度走 stderr。退出码：0 成功 · 1 错误 · 2 校验未通过 · 64 用法错误。
      永远不会交互式提问——密码用 SIGNLOADER_P12_PASSWORD 环境变量提供。

    OPTIONS
      -m, --profile <substring>  用 bundle id 含该子串的 profile（默认自动匹配）
          --wildcard             强制使用通配符 profile
          --safe                 大 App 安全模式：unzip → zsign -f → ditto
      -o, --out <path>           输出路径
      -i, --install <udid|auto>  签名后安装到指定设备（auto 优先 USB）
          --uninstall-first      安装前先卸载旧版
      -z, --zip <0-9>            zip 压缩等级（0=store）
      -b, --bundle-id <id>       改写 bundle id
          --remove-extensions    移除 PlugIns
          --remove-watch         移除 Watch App
      -k, --kit <path>           指定 _signing-kit 目录
          --json                 以 JSON 输出
      -v, --verbose              展开详情（profiles / profile）
    """

    /// Exit code for the process.
    static func run(_ arguments: [String]) async -> Int {
        let args = Array(arguments.dropFirst())
        guard !args.isEmpty else { return 0 }
        let options = parse(arguments)

        if options.help || args.first == "help" {
            print(usage)
            return 0
        }
        if args.first == "version" {
            print("Signloader \(CLI.version)")
            return 0
        }

        // Same resolution as the GUI (flag → env → saved setting → default), so
        // agents don't need to know where the kit lives.
        let kit = await SigningKitLoader.load(
            root: URL(fileURLWithPath: SignloaderPaths.resolveKitPath(options.kit))
        )

        do {
            switch args.first {
            case "profiles": try await printProfiles(kit, json: options.json)
            case "profile":  try await printProfileDetail(options, kit: kit)
            case "devices":  try await printDevices(json: options.json)
            case "info":     try await printInfo(options, operand: operands(of: args), json: options.json)
            case "sign":     return try await sign(options, operand: operands(of: args), kit: kit)
            case "verify":   return try await verify(options, operand: operands(of: args))
            case "doctor":   return await doctor(json: options.json)
            default:
                FileHandle.standardError.write(Data("未知命令: \(args[0])\n\n\(usage)\n".utf8))
                return 64
            }
        } catch {
            let payload: [String: Any] = ["command": args.first ?? "", "ok": false,
                                          "error": error.localizedDescription]
            if options.json, let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            } else {
                FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
            }
            return 1
        }
        return 0
    }

    private static func operands(of args: [String]) -> String? {
        args.dropFirst().first { !$0.hasPrefix("-") }
    }

    // MARK: - doctor

    private static func doctor(json: Bool) async -> Int {
        let tools = ["zsign", "idevice_id", "ideviceinfo", "ideviceinstaller",
                     "ideviceprovision", "unzip", "ditto", "security", "openssl"]
        let found = Dictionary(uniqueKeysWithValues: tools.map { ($0, Shell.locate($0) != nil) })
        let devices = (try? await DeviceService.shared.listDevices()) ?? []
        let kit = await SigningKitLoader.load(
            root: URL(fileURLWithPath: SignloaderPaths.resolveKitPath())
        )

        let payload: [String: Any] = [
            "command": "doctor",
            "ok": found.values.allSatisfy { $0 } && kit.certificateURL != nil,
            "tools": found,
            "kit": [
                "path": kit.root.path,
                "exists": FileManager.default.fileExists(atPath: kit.root.path),
                "profiles": kit.profiles.count,
                "certificate": kit.certificate.map { ["commonName": $0.commonName, "teamID": $0.teamID] } ?? NSNull(),
            ],
            "devices": devices.map {
                ["udid": $0.udid, "name": $0.displayName,
                 "transport": $0.transport.rawValue, "reachable": $0.reachable]
            },
        ]
        if json {
            print(jsonString(payload))
        } else {
            for (tool, present) in found.sorted(by: { $0.key < $1.key }) {
                print("  \(present ? "✓" : "✗") \(tool)")
            }
            print("  工具包  \(kit.root.path) · \(kit.profiles.count) 个 profile")
            if let cert = kit.certificate { print("  证书    \(cert.commonName) · \(cert.expiryLabel)") }
            print("  设备    \(devices.isEmpty ? "无" : devices.map(\.displayName).joined(separator: ", "))")
        }
        return found.values.allSatisfy { $0 } && kit.certificateURL != nil ? 0 : 1
    }

    // MARK: profiles

    private static func printProfiles(_ kit: SigningKit, json: Bool) async throws {
        if json {
            let payload: [String: Any] = [
                "command": "profiles", "ok": true, "kit": kit.root.path,
                "profiles": kit.profiles.map {
                    [
                        "bundleID": $0.displayBundleID,
                        "appIdentifier": $0.appIdentifier,
                        "team": $0.teamID,
                        "name": $0.name,
                        "expiration": ISO8601DateFormatter().string(from: $0.expiration),
                        "expired": $0.isExpired,
                        "daysRemaining": $0.daysRemaining,
                        "deviceCount": $0.deviceCount,
                        "certificateCount": $0.certificates.count,
                        "duplicates": $0.duplicateCount,
                        "wildcard": $0.isWildcard,
                        "path": $0.url.path,
                    ] as [String: Any]
                },
            ]
            print(jsonString(payload))
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

    /// Full detail for one profile — the CLI mirror of the GUI detail sheet.
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
            throw CLIError.usage("没有匹配的 profile")
        }

        if options.json {
            let payload: [String: Any] = [
                "command": "profile", "ok": true,
                "profile": [
                    "bundleID": profile.displayBundleID,
                    "appIdentifier": profile.appIdentifier,
                    "team": profile.teamID,
                    "name": profile.name,
                    "uuid": profile.uuid,
                    "creation": ISO8601DateFormatter().string(from: profile.creation),
                    "expiration": ISO8601DateFormatter().string(from: profile.expiration),
                    "expired": profile.isExpired,
                    "daysRemaining": profile.daysRemaining,
                    "platforms": profile.platforms,
                    "xcodeManaged": profile.isXcodeManaged,
                    "duplicates": profile.duplicateCount,
                    "path": profile.url.path,
                    "devices": profile.devices,
                    "certificates": profile.certificates.map {
                        ["commonName": $0.commonName, "teamID": $0.teamID,
                         "notBefore": $0.notBefore.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                         "notAfter": $0.notAfter.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                         "expired": $0.isExpired] as [String: Any]
                    },
                    "entitlements": profile.entitlements,
                ] as [String: Any],
            ]
            print(jsonString(payload))
            return
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
        for udid in profile.devices { print("  \(udid)") }
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
            let payload: [String: Any] = [
                "command": "devices", "ok": true,
                "devices": devices.map {
                    ["udid": $0.udid, "name": $0.displayName, "productType": $0.productType,
                     "version": $0.productVersion, "transport": $0.transport.rawValue,
                     "reachable": $0.reachable] as [String: Any]
                },
            ]
            print(jsonString(payload))
            return
        }
        if devices.isEmpty {
            print("没有检测到 iOS 设备。USB 直连，或 Wi-Fi 设备（需先用 USB 配对过）都可以。")
            return
        }
        for device in devices {
            print("\(device.displayName)  \(device.productType) iOS \(device.productVersion)  [\(device.transport.label)]\(device.reachable ? "" : " (不可达)"))".replacingOccurrences(of: "))", with: ")"))
            print("    \(device.udid)")
        }
    }

    // MARK: info

    private static func printInfo(_ options: Options, operand: String?, json: Bool) async throws {
        guard let path = operand else { throw CLIError.usage("需要一个 .ipa 路径") }
        let info = try await IPAParser.parse(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        if json {
            let payload: [String: Any] = [
                "command": "info", "ok": true,
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
            print(jsonString(payload))
            return
        }
        print("文件        \(info.url.path)  (\(ByteFormat.string(info.fileSize)))")
        print("App         \(info.displayName)  \(info.versionLabel)")
        print("Bundle ID   \(info.bundleID)")
        print("可执行文件   \(info.executable)")
        print("最低系统     iOS \(info.minimumOS)")
        print("条目数      \(info.entryCount)")
        print("图标        \(info.iconData != nil ? "有" : "无（可能在 Assets.car）")")
        if !info.appExtensionNames.isEmpty { print("扩展        \(info.extensionSummary)") }
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
        if options.json {
            let payload: [String: Any] = [
                "command": "verify", "ok": result.hasCodeSignature && result.hasEmbeddedProfile,
                "file": (path as NSString).lastPathComponent,
                "codeSignature": result.hasCodeSignature,
                "embeddedProfile": result.hasEmbeddedProfile,
                "profileName": result.embeddedProfileName ?? "",
                "appIdentifier": result.embeddedAppIdentifier ?? "",
                "expected": options.profile ?? "",
                "matchesExpected": result.matchesProfile,
                "createdAt": result.signedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            ]
            print(jsonString(payload))
        } else {
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
        }
        let ok = result.hasCodeSignature && result.hasEmbeddedProfile
        return ok ? 0 : 1
    }

    // MARK: sign

    private static func sign(_ options: Options, operand: String?, kit: SigningKit) async throws -> Int {
        guard let path = operand else { throw CLIError.usage("需要一个 .ipa 路径") }
        let ipaURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let p12 = kit.certificateURL else { throw CLIError.usage("工具包里没有 p12：\(kit.root.path)") }

        let info = try await IPAParser.parse(url: ipaURL)
        let say: (String) -> Void = { message in
            if options.json {
                FileHandle.standardError.write(Data("\(message)\n".utf8))
            } else {
                print(message)
            }
        }
        say("源文件   \(ipaURL.lastPathComponent)  (\(ByteFormat.string(info.fileSize)))")
        say("App      \(info.displayName) \(info.versionLabel)")
        say("Bundle   \(info.bundleID)")

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
        say("Profile  \(profile.appIdentifier)")
        say("         \(profile.matchKind(for: info.bundleID).rawValue) · \(profile.expiryLabel)")

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
            say("模式     自动切换到安全模式（包体 \(ByteFormat.string(info.fileSize))）")
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

        say("输出     \(output.path)")
        say("── 开始 ──")
        let outcome = try await Signer().run(request) { lines in
            for line in lines { say(line) }
        }
        say("── 完成 ──")

        if options.json {
            var payload: [String: Any] = [
                "command": "sign", "ok": true,
                "source": ipaURL.path,
                "output": output.path,
                "mode": outcome.mode,
                "bundleID": info.bundleID,
                "appName": info.appName,
                "profile": [
                    "appIdentifier": profile.appIdentifier,
                    "name": profile.name,
                    "expiration": ISO8601DateFormatter().string(from: profile.expiration),
                ],
                "verification": [
                    "codeSignature": outcome.verification.hasCodeSignature,
                    "embeddedProfile": outcome.verification.hasEmbeddedProfile,
                    "profileName": outcome.verification.embeddedProfileName ?? "",
                    "appIdentifier": outcome.verification.embeddedAppIdentifier ?? "",
                    "matchesProfile": outcome.verification.matchesProfile,
                ] as [String: Any],
                "durationSeconds": outcome.duration,
                "sizeBefore": outcome.sizeBefore,
                "sizeAfter": outcome.sizeAfter,
            ]
            if let install = options.install {
                payload["installed"] = true
                payload["device"] = install
            }
            print(jsonString(payload))
        } else {
            print("用时     \(String(format: "%.2f", outcome.duration))s")
            print("大小     \(ByteFormat.string(outcome.sizeBefore)) → \(ByteFormat.string(outcome.sizeAfter))")
            print("代码签名 \(outcome.verification.hasCodeSignature ? "有" : "无")")
            print("内嵌profile \(outcome.verification.embeddedProfileName ?? "无")")
            print("app-id  \(outcome.verification.embeddedAppIdentifier ?? "-")")
            print("一致     \(outcome.verification.matchesProfile ? "是" : "否")")
        }

        if let install = options.install {
            let known = (try? await DeviceService.shared.listDevices()) ?? []
            let target: Device
            if install == "auto" {
                guard let first = known.first else {
                    throw CLIError.usage("没有已连接的设备")
                }
                target = first
            } else if let match = known.first(where: { $0.udid == install }) {
                target = match
            } else {
                target = Device(udid: install, name: "", productName: "", productType: "",
                                productVersion: "", transport: .usb, reachable: true)
            }
            say("设备     \(target.displayName) (\(target.udid)) · \(target.transport.label)")
            if options.uninstallFirst {
                try await DeviceService.shared.uninstall(udid: target.udid, transport: target.transport, bundleID: info.bundleID) { lines in for line in lines { say(line) } }
            }
            try await DeviceService.shared.install(udid: target.udid, transport: target.transport, ipa: output) { lines in
                for line in lines { say(line) }
            }
            say("安装成功 \(info.displayName) → \(target.udid)")
        }
        return 0
    }

    // MARK: helpers

    private static func jsonString(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
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
