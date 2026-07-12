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

    public func logURL(for phase: String) -> URL {
        directory.appendingPathComponent("ffmpeg-\(phase).log")
    }

    public func removeGeneratedMedia() {
        try? FileManager.default.removeItem(at: transformsURL)
        try? FileManager.default.removeItem(at: previewURL)
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

