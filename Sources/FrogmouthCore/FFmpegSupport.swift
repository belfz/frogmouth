import Foundation

public struct FFmpegInstallation: Equatable, Sendable {
    public let executableURL: URL
    public let versionDescription: String
    public let semanticVersion: String
    public let majorVersion: Int
    public let stabilizationCacheToolRevision: String

    public init(
        executableURL: URL,
        versionDescription: String,
        semanticVersion: String,
        majorVersion: Int,
        stabilizationCacheToolRevision: String? = nil
    ) {
        self.executableURL = executableURL
        self.versionDescription = versionDescription
        self.semanticVersion = semanticVersion
        self.majorVersion = majorVersion
        self.stabilizationCacheToolRevision = stabilizationCacheToolRevision
            ?? "\(versionDescription) / libvidstab filters"
    }
}

public protocol FFmpegLocating: Sendable {
    func locateAndValidate() async throws -> FFmpegInstallation
}

public struct FFmpegLocator: FFmpegLocating, @unchecked Sendable {
    public static let testedVersions: Set<String> = ["7.1.1", "8.1.2"]

    private let fileManager: FileManager
    private let supportedVersions: Set<String>

    public init(
        fileManager: FileManager = .default,
        supportedVersions: Set<String> = Self.testedVersions
    ) {
        self.fileManager = fileManager
        self.supportedVersions = supportedVersions
    }

    public func locateAndValidate() async throws -> FFmpegInstallation {
        guard let executableURL = candidateURLs().first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            throw FrogmouthError.ffmpegNotFound
        }

        let version = try await Self.capture(executableURL: executableURL, arguments: ["-version"])
        guard let semanticVersion = Self.parseSemanticVersion(version),
              let majorVersion = Int(semanticVersion.split(separator: ".").first ?? "") else {
            throw FrogmouthError.unsupportedFFmpeg("Could not parse `ffmpeg -version`.")
        }
        guard supportedVersions.contains(semanticVersion) else {
            let expected = supportedVersions.sorted().joined(separator: ", ")
            throw FrogmouthError.unsupportedFFmpeg("Expected tested version \(expected), found \(semanticVersion).")
        }

        let filters = try await Self.capture(
            executableURL: executableURL,
            arguments: ["-hide_banner", "-filters"]
        )
        guard filters.contains("vidstabdetect"), filters.contains("vidstabtransform") else {
            throw FrogmouthError.unsupportedFFmpeg("The build is missing libvidstab filters.")
        }

        let encoders = try await Self.capture(
            executableURL: executableURL,
            arguments: ["-hide_banner", "-encoders"]
        )
        guard encoders.contains("hevc_videotoolbox") else {
            throw FrogmouthError.unsupportedFFmpeg("The build is missing the VideoToolbox HEVC encoder.")
        }

        let firstLine = version.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? version
        let executableFingerprint = try? MediaFingerprinter().fingerprint(url: executableURL)
        let toolRevision = [
            firstLine,
            executableFingerprint.map {
                "binary=\($0.fileSize):\($0.modificationTimeNanoseconds)"
            } ?? "binary=unavailable",
            "libvidstab-filters=present",
        ].joined(separator: " / ")
        return FFmpegInstallation(
            executableURL: executableURL,
            versionDescription: firstLine,
            semanticVersion: semanticVersion,
            majorVersion: majorVersion,
            stabilizationCacheToolRevision: toolRevision
        )
    }

    public static func parseMajorVersion(_ output: String) -> Int? {
        guard let version = parseSemanticVersion(output) else { return nil }
        return Int(version.split(separator: ".").first ?? "")
    }

    public static func parseSemanticVersion(_ output: String) -> String? {
        guard let marker = output.range(of: "ffmpeg version ") else { return nil }
        let suffix = output[marker.upperBound...]
        let token = suffix.split(whereSeparator: { $0 == " " || $0 == "-" }).first.map(String.init) ?? ""
        let numericStart = token.drop(while: { !$0.isNumber })
        let version = numericStart.prefix { $0.isNumber || $0 == "." }
        return version.isEmpty ? nil : String(version)
    }

    private func candidateURLs() -> [URL] {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["FROGMOUTH_FFMPEG"], !override.isEmpty {
            paths.append(override)
        }
        paths.append(contentsOf: [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
        ])
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map { "\($0)/ffmpeg" })
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }.map(URL.init(fileURLWithPath:))
    }

    private static func capture(executableURL: URL, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                throw FrogmouthError.unsupportedFFmpeg(error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw FrogmouthError.unsupportedFFmpeg(String(decoding: data, as: UTF8.self))
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
