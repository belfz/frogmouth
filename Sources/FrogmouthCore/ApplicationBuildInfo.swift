import Foundation

public struct ApplicationBuildInfo: Equatable, Sendable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    public static func current(in bundle: Bundle = .main) -> ApplicationBuildInfo {
        ApplicationBuildInfo(
            version: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "development",
            build: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "development"
        )
    }

    public var displayVersion: String {
        version == "development" ? version : "\(version) (\(build))"
    }
}
