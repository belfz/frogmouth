import Foundation

public final class DiagnosticLogStore: @unchecked Sendable {
    public let directory: URL
    private let fileURL: URL
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    public init(baseDirectory: URL? = nil) {
        let root = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("frogmouth/Logs", isDirectory: true)
        directory = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("frogmouth.log")
        append(level: "INFO", sessionID: "app", phase: "startup", message: Self.systemDescription())
    }

    public func append(level: String, sessionID: String, phase: String, message: String) {
        lock.withLock {
            let timestamp = formatter.string(from: Date())
            let line = "\(timestamp) [\(level)] session=\(sessionID) phase=\(phase) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    return
                }
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    public func append(
        level: String,
        sessionID: String,
        phase: String,
        event: String,
        fields: [String: String] = [:]
    ) {
        let components = ["event=\(Self.structuredValue(event))"] + fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.structuredValue($0.value))" }
        append(
            level: level,
            sessionID: sessionID,
            phase: phase,
            message: components.joined(separator: " ")
        )
    }

    public func appendProcessLog(
        sessionID: String,
        phase: String,
        executable: URL,
        arguments: [String],
        exitStatus: Int32,
        output: String
    ) {
        let displayCommand = ([executable.path] + arguments).map(Self.shellDisplayQuote).joined(separator: " ")
        append(
            level: exitStatus == 0 ? "INFO" : "ERROR",
            sessionID: sessionID,
            phase: phase,
            message: "command=\(displayCommand) exit=\(exitStatus)\n\(output)"
        )
    }

    public func contents() -> String {
        lock.withLock {
            (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "No diagnostics are available."
        }
    }

    private static func shellDisplayQuote(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || "'\"\\".contains($0) }) else { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func structuredValue(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"<unencodable>\""
        }
        return encoded
    }

    private static func systemDescription() -> String {
        let info = ProcessInfo.processInfo
        return "frogmouth=development macOS=\(info.operatingSystemVersionString) architecture=\(architecture)"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
