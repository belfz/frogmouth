import Foundation
import Testing

@testable import FrogmouthCore

@Test func timelineExportDestinationUsesProjectThenFirstUsedSourceDirectory() throws {
    let fixture = try exportFixture()
    let savedProjectURL = URL(fileURLWithPath: "/Users/birder/Projects/Owls.frogmouth")
    let saved = try #require(TimelineExportDestinationPolicy.suggestion(
        project: fixture.project,
        projectFileURL: savedProjectURL,
        mediaURLs: [fixture.asset.id: fixture.sourceURL]
    ))
    #expect(saved.directoryURL.path == "/Users/birder/Projects")
    #expect(saved.filename == "Owls-Warsaw—frogmouth.mp4")

    let untitled = try #require(TimelineExportDestinationPolicy.suggestion(
        project: fixture.project,
        projectFileURL: nil,
        mediaURLs: [fixture.asset.id: fixture.sourceURL]
    ))
    #expect(untitled.directoryURL == fixture.sourceURL.deletingLastPathComponent())
}

@Test func timelineMetadataKeepsOnlyIdenticalSafeValuesAndSetsProvenance() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let metadata = TimelineExportMetadataPolicy.metadata(
        projectName: "Marsh birds",
        sourceMetadata: [
            [
                "artist": "Marcin",
                "albumName": "Wetlands",
                "copyrights": "Personal",
                "make": "Canon",
                "model": "EOS R5",
                "location": "52.1, 21.0",
                "creationDate": "source date one",
                "title": "First source",
            ],
            [
                "artist": "Marcin",
                "albumName": "Different album",
                "copyrights": "Personal",
                "make": "Canon",
                "model": "EOS R5",
                "location": "elsewhere",
                "creationDate": "source date two",
                "title": "Second source",
            ],
        ],
        creationDate: date
    )

    #expect(metadata.commonSourceTags == [
        "artist": "Marcin",
        "copyright": "Personal",
    ])
    #expect(metadata.ffmpegTags["title"] == "Marsh birds")
    #expect(metadata.ffmpegTags["comment"] == "Encoded by frogmouth")
    #expect(metadata.ffmpegTags["creation_time"] == "2023-11-14T22:13:20Z")
    #expect(metadata.ffmpegTags["make"] == nil)
    #expect(metadata.ffmpegTags["location"] == nil)
}

@Test func timelineCommandWritesColourOrientationAndProjectMetadata() throws {
    let fixture = try exportFixture()
    let plan = try TimelineRenderPlanner().plan(fixture.renderRequest)
    let metadata = TimelineExportMetadata(
        commonSourceTags: ["artist": "Marcin"],
        creationTime: "2026-07-18T08:00:00Z",
        projectName: fixture.project.name
    )
    let arguments = try TimelineFFmpegCommandFactory.arguments(
        for: plan,
        output: URL(fileURLWithPath: "/tmp/Owls.mp4"),
        metadata: metadata
    )

    #expect(arguments.contains("hevc_videotoolbox"))
    #expect(arguments.contains("hvc1"))
    #expect(arguments.contains("aac"))
    #expect(arguments.contains("256k"))
    #expect(arguments.contains("+faststart"))
    #expect(argumentValue(after: "-color_primaries", in: arguments) == "bt709")
    #expect(argumentValue(after: "-color_trc", in: arguments) == "bt709")
    #expect(argumentValue(after: "-colorspace", in: arguments) == "bt709")
    #expect(argumentValue(after: "-color_range", in: arguments) == "tv")
    #expect(arguments.contains("rotate=0"))
    #expect(arguments.contains("title=Owls/Warsaw"))
    #expect(arguments.contains("comment=Encoded by frogmouth"))
    #expect(arguments.contains("artist=Marcin"))
}

@Test func timelineValidatorChecksTechnicalFactsAudioDurationAndProvenance() throws {
    let fixture = try exportFixture()
    let plan = try TimelineRenderPlanner().plan(fixture.renderRequest)
    let metadata = TimelineExportMetadata(
        commonSourceTags: ["artist": "Marcin"],
        creationTime: "2026-07-18T08:00:00Z",
        projectName: fixture.project.name
    )
    let valid = outputInfo(
        fixture: fixture,
        metadata: [
            "title": fixture.project.name,
            "creationDate": metadata.creationTime,
            "description": TimelineExportMetadata.provenance,
            "artist": "Marcin",
        ]
    )
    try TimelineExportValidator().validate(
        output: valid,
        against: plan,
        metadata: metadata
    )

    let wrongRate = MediaInfo(
        url: valid.url,
        duration: valid.duration,
        exactDuration: valid.exactDuration,
        width: valid.width,
        height: valid.height,
        frameRate: 30,
        exactFrameRate: try FrameRate(numerator: 30, denominator: 1),
        videoBitrate: valid.videoBitrate,
        videoCodec: valid.videoCodec,
        audioCodec: valid.audioCodec,
        audioSampleRate: valid.audioSampleRate,
        audioChannelCount: valid.audioChannelCount,
        fileSize: valid.fileSize,
        metadata: valid.metadata,
        colour: valid.colour
    )
    #expect(throws: TimelineExportValidationError.unexpectedFrameRate(
        try FrameRate(numerator: 30, denominator: 1)
    )) {
        try TimelineExportValidator().validate(
            output: wrongRate,
            against: plan,
            metadata: metadata
        )
    }
}

@Test func atomicTimelineFinalizerReplacesExistingDestination() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "frogmouth-export-finalizer-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let temporary = directory.appendingPathComponent("partial.mp4")
    let destination = directory.appendingPathComponent("final.mp4")
    try Data("new video".utf8).write(to: temporary)
    try Data("old video".utf8).write(to: destination)

    try AtomicTimelineExportFileFinalizer().finalize(
        temporaryURL: temporary,
        destinationURL: destination
    )

    #expect(try Data(contentsOf: destination) == Data("new video".utf8))
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
}

@Test func failedAndCancelledTimelineExportsPreserveExistingDestinationAndCleanTemporaryFiles() async throws {
    for failure in [FrogmouthError.processingFailed("fixture failure"), .cancelled] {
        let fixture = try exportFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "frogmouth-export-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("final.mp4")
        try Data("existing valid export".utf8).write(to: destination)
        let runner = FailingExportRunner(error: failure, writesPartialOutput: true)
        let exporter = TimelineExporter(
            runner: runner,
            inspector: ExportInspector(sourceURL: fixture.sourceURL, sourceInfo: fixture.sourceInfo)
        )
        let request = TimelineExportRequest(
            renderRequest: fixture.renderRequest,
            destinationURL: destination,
            installation: FFmpegInstallation(
                executableURL: URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
                versionDescription: "fixture",
                semanticVersion: "7.1.1",
                majorVersion: 7
            ),
            sessionID: "failure-test"
        )

        await #expect(throws: failure) {
            _ = try await exporter.export(request) { _ in }
        }
        #expect(try Data(contentsOf: destination) == Data("existing valid export".utf8))
        let directoryContents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        #expect(directoryContents.map(\.lastPathComponent) == [destination.lastPathComponent])
    }
}

@Test func verificationExporterRendersValidatesAndInstallsCompleteTimeline() async throws {
    guard let installation = try? await FFmpegLocator().locateAndValidate() else { return }
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/test-media-fixtures/base-24fps-320x180.mp4")
    guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

    let persisted = try await AVProjectMediaFactsInspector().inspect(url: sourceURL)
    let asset = MediaAsset(
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: sourceURL.path),
        fingerprint: MediaFingerprint(fileSize: 1, modificationTimeNanoseconds: 1),
        inspected: persisted
    )
    let clipDuration = try persisted.frameRate.time(forFrame: 12)
    let project = ProjectState(
        name: "Verification birds",
        mediaLibrary: [asset],
        timelineFormat: TimelineFormat(
            width: persisted.width,
            height: persisted.height,
            frameRate: persisted.frameRate,
            colour: persisted.colour,
            audioSampleRate: persisted.audioSampleRate ?? 48_000,
            audioChannelCount: persisted.audioChannelCount ?? 2
        ),
        clips: [TimelineClip(
            assetID: asset.id,
            sourceRange: try MediaTimeRange(start: .zero, duration: clipDuration)
        )]
    )
    let workspace = try SessionWorkspace()
    defer { workspace.removeAll() }
    let destination = workspace.directory.appendingPathComponent("complete timeline.mov")
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let exporter = TimelineExporter(
        runner: FFmpegRunner(diagnostics: DiagnosticLogStore(baseDirectory: workspace.directory)),
        creationDate: { fixedDate }
    )

    let result = try await exporter.export(
        TimelineExportRequest(
            renderRequest: TimelineRenderRequest(
                project: project,
                mediaURLs: [asset.id: sourceURL]
            ),
            destinationURL: destination,
            installation: installation,
            sessionID: "timeline-export-integration"
        ),
        encoding: .verification
    ) { _ in }

    #expect(result.destinationURL == destination)
    #expect(FileManager.default.fileExists(atPath: destination.path))
    let inspected = try await MediaInspector().inspect(url: destination)
    #expect(inspected.metadata["title"] == project.name)
    #expect(inspected.metadata.values.contains(TimelineExportMetadata.provenance))
    #expect(try persisted.frameRate.frameIndex(
        for: inspected.exactDuration,
        rounding: .nearestTiesAwayFromZero
    ) == 12)
}

private struct ExportFixture {
    let project: ProjectState
    let asset: MediaAsset
    let sourceURL: URL
    let sourceInfo: MediaInfo
    let renderRequest: TimelineRenderRequest
}

private func exportFixture() throws -> ExportFixture {
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let colour = VideoColourMetadata(
        primaries: "bt709",
        transferFunction: "bt709",
        matrix: "bt709",
        range: "limited"
    )
    let sourceURL = URL(fileURLWithPath: "/Users/birder/Media/owls source.mp4")
    let duration = try rate.time(forFrame: 24)
    let asset = MediaAsset(
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: sourceURL.path),
        fingerprint: MediaFingerprint(fileSize: 1_000, modificationTimeNanoseconds: 2_000),
        inspected: PersistedMediaFacts(
            duration: duration,
            width: 320,
            height: 180,
            frameRate: rate,
            videoBitrate: 10_000_000,
            videoCodec: "avc1",
            audioCodec: "mp4a",
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            colour: colour
        )
    )
    let clip = TimelineClip(
        assetID: asset.id,
        sourceRange: try MediaTimeRange(start: .zero, duration: duration)
    )
    let project = ProjectState(
        name: "Owls/Warsaw",
        mediaLibrary: [asset],
        timelineFormat: TimelineFormat(
            width: 320,
            height: 180,
            frameRate: rate,
            colour: colour,
            audioSampleRate: 48_000,
            audioChannelCount: 2
        ),
        clips: [clip]
    )
    let sourceInfo = MediaInfo(
        url: sourceURL,
        duration: 1,
        exactDuration: duration,
        width: 320,
        height: 180,
        frameRate: 24,
        exactFrameRate: rate,
        videoBitrate: 10_000_000,
        videoCodec: "avc1",
        audioCodec: "mp4a",
        audioSampleRate: 48_000,
        audioChannelCount: 2,
        fileSize: 1_000,
        metadata: ["artist": "Marcin"],
        colour: colour
    )
    return ExportFixture(
        project: project,
        asset: asset,
        sourceURL: sourceURL,
        sourceInfo: sourceInfo,
        renderRequest: TimelineRenderRequest(
            project: project,
            mediaURLs: [asset.id: sourceURL]
        )
    )
}

private func outputInfo(
    fixture: ExportFixture,
    metadata: [String: String]
) -> MediaInfo {
    MediaInfo(
        url: URL(fileURLWithPath: "/tmp/output.mp4"),
        duration: 1,
        exactDuration: fixture.asset.inspected.duration,
        width: 320,
        height: 180,
        frameRate: 24,
        exactFrameRate: fixture.asset.inspected.frameRate,
        videoBitrate: 8_000_000,
        videoCodec: "hvc1",
        audioCodec: "mp4a",
        audioSampleRate: 48_000,
        audioChannelCount: 2,
        fileSize: 10_000,
        metadata: metadata,
        colour: fixture.asset.inspected.colour
    )
}

private func argumentValue(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private struct ExportInspector: MediaInspecting {
    let sourceURL: URL
    let sourceInfo: MediaInfo

    func inspect(url: URL) async throws -> MediaInfo {
        guard url == sourceURL else {
            throw FrogmouthError.outputValidationFailed("Output inspection should not run after failure.")
        }
        return sourceInfo
    }
}

private final class FailingExportRunner: FFmpegExecuting, @unchecked Sendable {
    let error: FrogmouthError
    let writesPartialOutput: Bool

    init(error: FrogmouthError, writesPartialOutput: Bool) {
        self.error = error
        self.writesPartialOutput = writesPartialOutput
    }

    func run(
        executable: URL,
        arguments: [String],
        duration: TimeInterval,
        sessionID: String,
        phase: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> FFmpegResult {
        if writesPartialOutput, let outputPath = arguments.last {
            try Data("incomplete".utf8).write(to: URL(fileURLWithPath: outputPath))
        }
        throw error
    }

    func cancel() {}
}
