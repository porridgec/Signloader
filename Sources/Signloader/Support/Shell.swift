import Foundation

// MARK: - Result

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let command: String

    var succeeded: Bool { exitCode == 0 }

    var combined: String {
        if stderr.isEmpty { return stdout }
        if stdout.isEmpty { return stderr }
        return stdout + "\n" + stderr
    }
}

enum ShellError: LocalizedError {
    case toolMissing(String)
    case launchFailed(tool: String, message: String)
    case failed(command: String, code: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .toolMissing(let tool):
            return "找不到工具 \(tool)。请先 `brew install \(tool)`。"
        case .launchFailed(let tool, let message):
            return "无法启动 \(tool)：\(message)"
        case .failed(let command, let code, let output):
            let tail = output.split(separator: "\n").suffix(12).joined(separator: "\n")
            return "命令失败（退出码 \(code)）：\(command)\n\(tail)"
        }
    }
}

// MARK: - Byte collector

/// Thread-safe sink for a child process' output. When a line handler is
/// supplied the bytes are decoded and split on CR/LF as they arrive, so the
/// caller can render a live console while the process is still running.
private final class ByteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: [UInt8] = []
    private let lineHandler: (@Sendable ([String]) -> Void)?

    init(lineHandler: (@Sendable ([String]) -> Void)?) {
        self.lineHandler = lineHandler
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        buffer.append(chunk)
        if lineHandler != nil {
            pending.append(contentsOf: chunk)
            while let idx = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let slice = pending[0..<idx]
                pending.removeSubrange(0...idx)
                lines.append(String(decoding: slice, as: UTF8.self))
            }
        }
        lock.unlock()

        if let lineHandler {
            let cleaned = lines
                .map { TextCleaner.stripANSI($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !cleaned.isEmpty { lineHandler(cleaned) }
        }
    }

    func drain() -> (data: Data, tail: String) {
        lock.lock()
        defer { lock.unlock() }
        var tail = ""
        if !pending.isEmpty {
            tail = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
        }
        return (buffer, tail)
    }
}

// MARK: - Shell

/// Resumes a continuation exactly once, whether the process finished or failed
/// to launch.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Error>?
    private var result: Result<Int32, Error>?

    init(_ continuation: CheckedContinuation<Int32, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Int32) {
        settle(.success(value))
    }

    func resume(throwing error: Error) {
        settle(.failure(error))
    }

    private func settle(_ value: Result<Int32, Error>) {
        lock.lock()
        guard let continuation, result == nil else {
            lock.unlock()
            return
        }
        result = value
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: value)
    }
}

/// Thin async wrapper around `Process` that never deadlocks on large output and
/// optionally streams decoded lines to a callback.
enum Shell {
    private static let fileManager = FileManager.default

    /// Resolve a tool through `PATH` (plus the usual Homebrew locations).
    static func locate(_ tool: String) -> String? {
        if tool.contains("/") {
            return fileManager.isExecutableFile(atPath: tool) ? tool : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var directories = path.split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in directories {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        secrets: [String] = [],
        onLine: (@Sendable ([String]) -> Void)? = nil
    ) async throws -> ProcessResult {
        guard let path = locate(executable) else { throw ShellError.toolMissing(executable) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outCollector = ByteCollector(lineHandler: onLine)
        let errCollector = ByteCollector(lineHandler: onLine)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            outCollector.append(handle.availableData)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            errCollector.append(handle.availableData)
        }

        defer {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }

        let command = Redactor.redact(
            ([path] + arguments)
                .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
                .joined(separator: " "),
            secrets: secrets
        )

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            process.terminationHandler = { proc in
                once.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                once.resume(throwing: ShellError.launchFailed(tool: executable, message: error.localizedDescription))
            }
        }

        // Give the readability handlers a moment to drain whatever is left in
        // the pipe buffers before we read the tail synchronously.
        try? await Task.sleep(nanoseconds: 40_000_000)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty { outCollector.append(rest) }
        if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty { errCollector.append(rest) }

        let out = outCollector.drain()
        let err = errCollector.drain()
        let tail = TextCleaner.stripANSI(out.tail + err.tail).trimmingCharacters(in: .whitespacesAndNewlines)
        if let lineHandler = onLine, !tail.isEmpty {
            lineHandler(tail.split(separator: "\n").map {
                TextCleaner.stripANSI(String($0)).trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty })
        }

        let result = ProcessResult(
            exitCode: status,
            stdout: TextCleaner.stripANSI(String(decoding: out.data, as: UTF8.self)),
            stderr: TextCleaner.stripANSI(String(decoding: err.data, as: UTF8.self)),
            command: command
        )
        guard result.succeeded else {
            throw ShellError.failed(
                command: command,
                code: status,
                output: Redactor.redact(result.combined, secrets: secrets)
            )
        }
        return result
    }

    /// Convenience wrapper for a custom environment (used for OpenSSL's legacy provider).
    @discardableResult
    static func runWithEnvironment(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]
    ) async throws -> ProcessResult {
        try await run(executable, arguments, environment: environment)
    }

    /// Run and return the raw stdout bytes (for binary payloads like icons).
    static func data(_ executable: String, _ arguments: [String] = []) async throws -> Data {
        guard let path = locate(executable) else { throw ShellError.toolMissing(executable) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let collector = ByteCollector(lineHandler: nil)
        outPipe.fileHandleForReading.readabilityHandler = { collector.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { handle in _ = try? handle.readToEnd() }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            process.terminationHandler = { proc in
                once.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                once.resume(throwing: ShellError.launchFailed(tool: executable, message: error.localizedDescription))
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty { collector.append(rest) }
        guard status == 0 else {
            throw ShellError.failed(command: ([path] + arguments).joined(separator: " "), code: status, output: "")
        }
        return collector.drain().data
    }
}

// MARK: - Text utilities

/// Strips secrets out of anything that might end up in a log or an error.
enum Redactor {
    static func redact(_ text: String, secrets: [String]) -> String {
        var redacted = text
        for secret in secrets where !secret.isEmpty {
            redacted = redacted.replacingOccurrences(of: secret, with: "••••••")
        }
        return redacted
    }
}

enum TextCleaner {
    private static let ansiPattern = "\u{001B}\\[[0-9;?]*[ -/]*[@-~]"

    static func stripANSI(_ input: String) -> String {
        guard input.unicodeScalars.contains("\u{1B}") else { return input }
        return input.replacingOccurrences(
            of: ansiPattern,
            with: "",
            options: .regularExpression
        )
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
