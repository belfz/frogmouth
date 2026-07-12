import Foundation

public struct SessionWorkspace: Equatable, Sendable {
    public let directory: URL

    public init(baseDirectory: URL = FileManager.default.temporaryDirectory) throws {
        directory = baseDirectory
            .appendingPathComponent("frogmouth", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var transformsURL: URL { directory.appendingPathComponent("transforms.trf") }
    public var previewURL: URL { directory.appendingPathComponent("preview.mp4") }

    public func transformsURL(for id: UUID) -> URL {
        directory.appendingPathComponent("transforms-\(id.uuidString).trf")
    }

    public func previewURL(for id: UUID = UUID()) -> URL {
        directory.appendingPathComponent("preview-\(id.uuidString).mp4")
    }

    public func logURL(for phase: String) -> URL {
        directory.appendingPathComponent("ffmpeg-\(phase).log")
    }

    public func removeGeneratedMedia() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where url.pathExtension == "trf" || url.pathExtension == "mp4" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
