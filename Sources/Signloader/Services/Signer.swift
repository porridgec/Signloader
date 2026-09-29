import Foundation

struct SignRequest: Sendable {
    let ipa: URL
    let output: URL
    let p12: URL
    let password: String
    let profile: ProvisionProfile
    let appPath: String
    let options: SigningOptions
}

struct SignOutcome: Sendable {
    let outputURL: URL
    let verification: IPAParser.Verification
    let duration: TimeInterval
    let mode: String
    let sizeBefore: Int64
    let sizeAfter: Int64
}

/// The two signing pipelines described in the kit README.
///
/// * **direct** — one `zsign` invocation straight on the archive. Fast, this is
///   what you want for everything up to ~500 MB.
/// * **safe** — `unzip` → `zsign` on the app folder → `ditto`. Slower, but the
///   zip step happens in `ditto`, which does not blow up on multi-hundred-MB apps.
struct Signer: Sendable {
    private var fm: FileManager { .default }

    func run(_ request: SignRequest, onLine: @escaping @Sendable ([String]) -> Void) async throws -> SignOutcome {
        let start = Date()
        let sizeBefore = fileSize(request.ipa)

        if request.options.safeMode {
            try await runSafe(request, onLine: onLine)
        } else {
            try await runDirect(request, onLine: onLine)
        }

        guard fm.fileExists(atPath: request.output.path) else {
            throw ShellError.failed(command: "zsign", code: -1, output: "输出文件没有生成：\(request.output.lastPathComponent)")
        }
        let sizeAfter = fileSize(request.output)
        var verification = await IPAParser.verify(
            signedIPA: request.output,
            expectedAppIdentifier: request.profile.appIdentifier
        )
        if !verification.hasEmbeddedProfile && request.options.stripEmbeddedProfile {
            verification.hasEmbeddedProfile = false   // expected: -R deleted it
        }
        return SignOutcome(
            outputURL: request.output,
            verification: verification,
            duration: Date().timeIntervalSince(start),
            mode: request.options.safeMode ? "安全模式 (unzip + ditto)" : "标准模式 (zsign)",
            sizeBefore: sizeBefore,
            sizeAfter: sizeAfter
        )
    }

    // MARK: Direct

    private func runDirect(_ request: SignRequest, onLine: @escaping @Sendable ([String]) -> Void) async throws {
        var args = baseArgs(request)
        args += ["-o", request.output.path]
        args.append(request.ipa.path)          // zsign takes the input last
        try await Shell.run("zsign", args, secrets: [request.password], onLine: onLine)
    }

    // MARK: Safe

    private func runSafe(_ request: SignRequest, onLine: @escaping @Sendable ([String]) -> Void) async throws {
        let work = request.output.deletingLastPathComponent()
            .appendingPathComponent(".signloader-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        onLine(["── 解包 IPA ──"])
        try await Shell.run("/usr/bin/unzip", ["-q", "-o", request.ipa.path, "-d", work.path], onLine: onLine)

        let appFolder = work.appendingPathComponent(request.appPath)
        var guard_ = appFolder
        while guard_.path != work.path, !fm.fileExists(atPath: guard_.path) {
            guard_.deleteLastPathComponent()
        }
        guard guard_.pathExtension == "app" else {
            throw ShellError.failed(command: "unzip", code: -1, output: "解包后没找到 .app 目录：\(request.appPath)")
        }

        onLine(["── 对 \(guard_.lastPathComponent) 目录签名 ──"])
        var args = baseArgs(request)
        args.append("-f")
        args.append(guard_.path)
        try await Shell.run("zsign", args, secrets: [request.password], onLine: onLine)

        onLine(["── 重新打包 ──"])
        if fm.fileExists(atPath: request.output.path) {
            try fm.removeItem(at: request.output)
        }
        let payload = guard_.deletingLastPathComponent()   // .../Payload
        // `--norsrc --noextattr` are required: macOS stamps every extracted file
        // with a SIP-protected `com.apple.provenance` xattr, and plain ditto
        // turns each one into a `._name` AppleDouble entry (or a `__MACOSX/`
        // sidecar tree with `--sequesterRsrc`) — ~1000 junk files in the IPA.
        // An iOS app bundle has no resource forks worth preserving.
        try await Shell.run(
            "/usr/bin/ditto",
            ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", payload.path, request.output.path],
            onLine: onLine
        )
    }

    // MARK: Shared

    private func baseArgs(_ request: SignRequest) -> [String] {
        var args = [
            "-k", request.p12.path,
            "-p", request.password,
            "-m", request.profile.url.path,
        ]
        if !request.options.overrideBundleID.isEmpty {
            args += ["-b", request.options.overrideBundleID]
        }
        if !request.options.overrideAppName.isEmpty {
            args += ["-n", request.options.overrideAppName]
        }
        if request.options.removeAppExtensions { args.append("-E") }
        if request.options.removeWatchApp { args.append("-W") }
        if request.options.stripEmbeddedProfile { args.append("-R") }
        args += ["-z", String(request.options.zipLevel)]
        return args
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Build a non-clashing output path next to the source IPA.
    static func defaultOutputURL(for ipa: URL, directory: URL?, appName: String) -> URL {
        let base = "\(appName.isEmpty ? ipa.deletingPathExtension().lastPathComponent : appName)-signed"
        if let directory {
            let candidate = directory.appendingPathComponent("\(base).ipa")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            for n in 2...99 {
                let next = directory.appendingPathComponent("\(base)-\(n).ipa")
                if !FileManager.default.fileExists(atPath: next.path) { return next }
            }
            return directory.appendingPathComponent("\(base).ipa")
        }
        let sibling = ipa.deletingLastPathComponent().appendingPathComponent("\(base).ipa")
        if !FileManager.default.fileExists(atPath: sibling.path) { return sibling }
        for n in 2...99 {
            let next = ipa.deletingLastPathComponent().appendingPathComponent("\(base)-\(n).ipa")
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return sibling
    }
}
