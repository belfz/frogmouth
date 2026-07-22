import Foundation

@testable import FrogmouthCore

enum IntegrationTestPrerequisiteError: LocalizedError {
    case missingMediaFiles([String])

    var errorDescription: String? {
        switch self {
        case .missingMediaFiles(let paths):
            let joinedPaths = paths.joined(separator: ", ")
            return "Required integration-test media is missing: \(joinedPaths)"
        }
    }
}

enum IntegrationTestSupport {
    private static let environment = ProcessInfo.processInfo.environment

    static var requiresMediaIntegration: Bool {
        environment["FROGMOUTH_REQUIRE_MEDIA_INTEGRATION"] == "1"
    }

    static func ffmpegInstallation() async throws -> FFmpegInstallation? {
        var supportedVersions: Set<String> = ["7.1.1"]
        if let testVersion = environment["FROGMOUTH_TEST_FFMPEG_VERSION"],
           !testVersion.isEmpty {
            supportedVersions.insert(testVersion)
        }

        do {
            return try await FFmpegLocator(
                supportedVersions: supportedVersions
            ).locateAndValidate()
        } catch {
            if requiresMediaIntegration {
                throw error
            }
            return nil
        }
    }

    static func mediaFilesExist(_ urls: [URL]) throws -> Bool {
        let missingPaths = urls.compactMap { url in
            FileManager.default.fileExists(atPath: url.path) ? nil : url.path
        }
        guard !missingPaths.isEmpty else { return true }
        if requiresMediaIntegration {
            throw IntegrationTestPrerequisiteError.missingMediaFiles(missingPaths)
        }
        return false
    }
}
