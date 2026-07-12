import Foundation

public struct FFmpegResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let output: String

    public init(terminationStatus: Int32, output: String) {
        self.terminationStatus = terminationStatus
        self.output = output
    }
}

public protocol FFmpegExecuting: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        duration: TimeInterval,
        sessionID: String,
        phase: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> FFmpegResult

    func cancel()
}

public final class FFmpegRunner: FFmpegExecuting, @unchecked Sendable {
    private let diagnostics: DiagnosticLogStore
    private let processLock = NSLock()
    private var activeProcess: Process?
    private var cancellationRequested = false

    public init(diagnostics: DiagnosticLogStore) {
        self.diagnostics = diagnostics
    }

    public func run(
        executable: URL,
        arguments: [String],
        duration: TimeInterval,
        sessionID: String,
        phase: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> FFmpegResult {
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let collector = ProcessOutputCollector(duration: duration, progress: progress)

                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    collector.appendProgressData(handle.availableData)
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    collector.appendErrorData(handle.availableData)
                }

                process.terminationHandler = { [weak self] terminated in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    collector.appendProgressData(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    collector.appendErrorData(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    let output = collector.output
                    let wasCancelled = self?.processLock.withLock {
                        let value = self?.cancellationRequested ?? false
                        self?.activeProcess = nil
                        self?.cancellationRequested = false
                        return value
                    } ?? false
                    self?.diagnostics.appendProcessLog(
                        sessionID: sessionID,
                        phase: phase,
                        executable: executable,
                        arguments: arguments,
                        exitStatus: terminated.terminationStatus,
                        output: output
                    )

                    if wasCancelled {
                        continuation.resume(throwing: FrogmouthError.cancelled)
                    } else if terminated.terminationStatus == 0 {
                        continuation.resume(returning: FFmpegResult(
                            terminationStatus: terminated.terminationStatus,
                            output: output
                        ))
                    } else {
                        let summary = output.split(separator: "\n").suffix(12).joined(separator: "\n")
                        continuation.resume(throwing: FrogmouthError.processingFailed(summary))
                    }
                }

                do {
                    processLock.withLock {
                        cancellationRequested = false
                        activeProcess = process
                    }
                    try process.run()
                } catch {
                    processLock.withLock { activeProcess = nil }
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: FrogmouthError.processingFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            cancel()
        }
    }

    public func cancel() {
        processLock.withLock {
            guard let activeProcess, activeProcess.isRunning else { return }
            cancellationRequested = true
            activeProcess.interrupt()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if activeProcess.isRunning {
                    activeProcess.terminate()
                }
            }
        }
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let duration: TimeInterval
    private let progress: @Sendable (Double) -> Void
    private var stdout = Data()
    private var stderr = Data()
    private var progressBuffer = ""

    init(duration: TimeInterval, progress: @escaping @Sendable (Double) -> Void) {
        self.duration = duration
        self.progress = progress
    }

    func appendProgressData(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            stdout.append(data)
            progressBuffer += String(decoding: data, as: UTF8.self)
            let lines = progressBuffer.split(separator: "\n", omittingEmptySubsequences: false)
            progressBuffer = lines.last.map(String.init) ?? ""
            for line in lines.dropLast() {
                parseProgressLine(String(line))
            }
        }
    }

    func appendErrorData(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { stderr.append(data) }
    }

    var output: String {
        lock.withLock {
            let progressOutput = String(decoding: stdout, as: UTF8.self)
            let errorOutput = String(decoding: stderr, as: UTF8.self)
            return [progressOutput, errorOutput].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    private func parseProgressLine(_ line: String) {
        guard duration > 0 else { return }
        if line.hasPrefix("out_time_us="),
           let microseconds = Double(line.dropFirst("out_time_us=".count)) {
            progress(min(1, max(0, microseconds / 1_000_000 / duration)))
        } else if line == "progress=end" {
            progress(1)
        }
    }
}
