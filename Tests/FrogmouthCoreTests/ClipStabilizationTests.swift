import Foundation
import Testing

@testable import FrogmouthCore

@Test func clipStabilizationCommandsPreserveOrderedNestedPassDomainsAndAudio() throws {
    let fixture = try makeClipStabilizationFixture()
    let firstTransforms = URL(fileURLWithPath: "/tmp/frogmouth work/first bird's pass.trf")
    let secondTransforms = URL(fileURLWithPath: "/tmp/frogmouth work/second.trf")
    let transforms = [
        fixture.passes[0].id: firstTransforms,
        fixture.passes[1].id: secondTransforms,
    ]

    let analysis = try ClipStabilizationCommandFactory.analysis(
        input: fixture.input,
        clip: fixture.clip,
        effectIndex: 1,
        precedingTransforms: transforms,
        outputTransforms: URL(fileURLWithPath: "/tmp/frogmouth work/new.trf")
    )
    #expect(analysis.contains(fixture.input.path))
    #expect(analysis.contains("1.000000"))
    #expect(analysis.contains("4.000000"))
    let analysisFilterIndex = try #require(analysis.firstIndex(of: "-vf"))
    let analysisFilter = analysis[analysisFilterIndex + 1]
    #expect(analysisFilter.contains("vidstabtransform"))
    #expect(analysisFilter.contains("first bird\\'s pass.trf"))
    #expect(analysisFilter.contains("interpol=bicubic"))
    #expect(analysisFilter.contains("trim=start=2.000000:duration=4.000000"))
    #expect(analysisFilter.contains("vidstabdetect"))

    let preview = try ClipStabilizationCommandFactory.preview(
        input: fixture.input,
        clip: fixture.clip,
        effectIndex: 1,
        transforms: transforms,
        output: URL(fileURLWithPath: "/tmp/frogmouth work/preview.mp4")
    )
    #expect(preview.filter { $0 == fixture.input.path }.count == 2)
    #expect(preview.contains("1:a?"))
    #expect(preview.contains("aac"))
    #expect(preview.contains("192k"))
    let previewFilterIndex = try #require(preview.firstIndex(of: "-vf"))
    let previewFilter = preview[previewFilterIndex + 1]
    #expect(previewFilter.contains("second.trf"))
    #expect(previewFilter.contains("interpol=bilinear"))
    #expect(previewFilter.contains("scale=1024:-2"))
}

@Test func stabilizationPassPlanningStacksAndExplicitlyExpandsStaleCoverage() throws {
    let fixture = try makeClipStabilizationFixture()
    let inwardRange = try MediaTimeRange(
        start: MediaTime(value: 4, timescale: 1),
        duration: MediaTime(value: 2, timescale: 1)
    )
    var clip = fixture.clip
    clip.sourceRange = inwardRange

    let stacked = try #require(StabilizationPassPlanner.appending(
        mode: .naturalMotion,
        to: clip
    ))
    #expect(stacked.dropLast() == clip.stabilizationPasses)
    #expect(stacked.last?.analysisCoverage == inwardRange)

    let outwardRange = try MediaTimeRange(
        start: .zero,
        duration: MediaTime(value: 10, timescale: 1)
    )
    clip.sourceRange = outwardRange
    let updated = try StabilizationPassPlanner.updating(clip)
    #expect(updated.map(\.id) == fixture.passes.map(\.id))
    #expect(updated.allSatisfy { $0.analysisCoverage == outwardRange })
    #expect(updated.allSatisfy {
        $0.processingRevision == StabilizationCacheIdentityBuilder.currentProcessingRevision
    })
}

@Test func validProxyMappingUsesFinalAnalysisDomainForTrimmedAndSplitDescendants() throws {
    let fixture = try makeClipStabilizationFixture()
    var child = fixture.clip
    child.sourceRange = try MediaTimeRange(
        start: MediaTime(value: 4, timescale: 1),
        duration: MediaTime(value: 2, timescale: 1)
    )
    let previewURL = URL(fileURLWithPath: "/cache/stabilized preview.mp4")
    let identity = CacheEntryIdentity(
        namespace: "test",
        logicalArtifactID: "preview",
        assetID: fixture.asset.id,
        sourceFingerprint: fixture.asset.fingerprint,
        processingRevision: 1
    )
    let manifest = CacheManifest(
        key: "key",
        identity: identity,
        artifactFilename: previewURL.lastPathComponent,
        artifactByteCount: 10
    )
    let artifact = CacheArtifact(
        key: "key",
        url: previewURL,
        byteCount: 10,
        manifest: manifest
    )
    let passArtifacts = fixture.passes.map {
        StabilizationPassArtifacts(effectID: $0.id, transforms: artifact, preview: artifact)
    }
    let source = try #require(StabilizedPlaybackSourceBuilder.source(
        for: child,
        validation: StabilizationValidation(status: .valid, artifacts: passArtifacts)
    ))
    #expect(source.url == previewURL)
    let expectedRelativeStart = try MediaTime(value: 1, timescale: 1)
    #expect(source.range.start == expectedRelativeStart)
    #expect(source.range.duration == child.sourceRange.duration)
    #expect(StabilizedPlaybackSourceBuilder.source(
        for: child,
        validation: StabilizationValidation(status: .stale(.validationPending))
    ) == nil)
}

@Test func selectedClipProcessorPersistsBothArtifactsAndReusesThemOnTheNextRun() async throws {
    let fixture = try makeClipStabilizationFixture()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("frogmouth-stabilization-processor-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ProjectCacheStore(rootURL: root)
    let runner = RecordingStabilizationRunner()
    let processor = ClipStabilizationProcessor(cacheStore: cache, runner: runner)
    let installation = FFmpegInstallation(
        executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
        versionDescription: "ffmpeg version 7.1.1",
        semanticVersion: "7.1.1",
        majorVersion: 7,
        stabilizationCacheToolRevision: "test-tool-revision"
    )

    let first = try await processor.process(
        project: fixture.project,
        clipID: fixture.clip.id,
        passes: fixture.passes,
        sourceURLs: [fixture.asset.id: fixture.input],
        installation: installation,
        progress: { _ in }
    )
    #expect(first.passes == fixture.passes)
    #expect(first.artifacts.count == 2)
    #expect(runner.runCount == 4)
    #expect(first.artifacts.allSatisfy {
        FileManager.default.fileExists(atPath: $0.transforms.url.path)
            && FileManager.default.fileExists(atPath: $0.preview.url.path)
    })

    let second = try await processor.process(
        project: fixture.project,
        clipID: fixture.clip.id,
        passes: fixture.passes,
        sourceURLs: [fixture.asset.id: fixture.input],
        installation: installation,
        progress: { _ in }
    )
    #expect(second.artifacts == first.artifacts)
    #expect(runner.runCount == 4)

    var committedProject = fixture.project
    committedProject.clips[0].stabilizationPasses = fixture.passes
    let validation = await StabilizationStatusResolver(cacheStore: cache).validation(
        for: committedProject.clips[0],
        in: committedProject,
        toolRevision: installation.stabilizationCacheToolRevision
    )
    #expect(validation.status == .valid)
}

@Test func cancellingSelectedClipProcessingDoesNotCommitPartialCacheArtifacts() async throws {
    let fixture = try makeClipStabilizationFixture()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("frogmouth-stabilization-cancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = ProjectCacheStore(rootURL: root)
    let runner = SuspendedStabilizationRunner()
    let processor = ClipStabilizationProcessor(cacheStore: cache, runner: runner)
    let installation = FFmpegInstallation(
        executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
        versionDescription: "ffmpeg version 7.1.1",
        semanticVersion: "7.1.1",
        majorVersion: 7,
        stabilizationCacheToolRevision: "cancel-test-tool"
    )
    let task = Task {
        try await processor.process(
            project: fixture.project,
            clipID: fixture.clip.id,
            passes: fixture.passes,
            sourceURLs: [fixture.asset.id: fixture.input],
            installation: installation,
            progress: { _ in }
        )
    }
    try await Task.sleep(for: .milliseconds(30))
    task.cancel()
    let result = await task.result
    switch result {
    case .success:
        Issue.record("Expected clip stabilization processing to be cancelled")
    case let .failure(error):
        #expect(error is CancellationError)
    }

    let identities = try #require(StabilizationCacheIdentityBuilder().identities(
        for: 0,
        in: fixture.clip,
        asset: fixture.asset,
        toolRevision: installation.stabilizationCacheToolRevision
    ))
    #expect(await cache.lookup(
        projectID: fixture.project.id,
        identity: identities.transforms
    ) == .stale(.notCached))
    #expect(await cache.lookup(
        projectID: fixture.project.id,
        identity: identities.preview
    ) == .stale(.notCached))
}

private final class RecordingStabilizationRunner: FFmpegExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var runCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func run(
        executable _: URL,
        arguments: [String],
        duration _: TimeInterval,
        sessionID _: String,
        phase: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> FFmpegResult {
        lock.withLock { count += 1 }
        progress(0.5)
        if phase.hasPrefix("analyze") {
            let filterIndex = try #require(arguments.firstIndex(of: "-vf"))
            let filter = arguments[filterIndex + 1]
            let prefix = "result='"
            let start = try #require(filter.range(of: prefix)?.upperBound)
            let suffix = filter[start...]
            let end = try #require(suffix.range(of: "':shakiness")?.lowerBound)
            let escapedPath = String(suffix[..<end])
            let path = escapedPath
                .replacingOccurrences(of: "\\;", with: ";")
                .replacingOccurrences(of: "\\]", with: "]")
                .replacingOccurrences(of: "\\[", with: "[")
                .replacingOccurrences(of: "\\,", with: ",")
                .replacingOccurrences(of: "\\'", with: "'")
                .replacingOccurrences(of: "\\:", with: ":")
                .replacingOccurrences(of: "\\\\", with: "\\")
            try Data("VID.STAB 1\n".utf8).write(to: URL(fileURLWithPath: path))
        } else {
            let output = try #require(arguments.last)
            try Data("preview-with-audio".utf8).write(to: URL(fileURLWithPath: output))
        }
        progress(1)
        return FFmpegResult(terminationStatus: 0, output: "")
    }

    func cancel() {}
}

private final class SuspendedStabilizationRunner: FFmpegExecuting, @unchecked Sendable {
    func run(
        executable _: URL,
        arguments _: [String],
        duration _: TimeInterval,
        sessionID _: String,
        phase _: String,
        progress _: @escaping @Sendable (Double) -> Void
    ) async throws -> FFmpegResult {
        try await Task.sleep(for: .seconds(10))
        return FFmpegResult(terminationStatus: 0, output: "")
    }

    func cancel() {}
}

private struct ClipStabilizationFixture {
    let input: URL
    let asset: MediaAsset
    let clip: TimelineClip
    let passes: [StabilizationEffect]
    let project: ProjectState
}

private func makeClipStabilizationFixture() throws -> ClipStabilizationFixture {
    let input = URL(fileURLWithPath: "/tmp/Wild bird's clip.MP4")
    let asset = MediaAsset(
        id: UUID(uuidString: "AAAAAAAA-A100-0000-0000-000000000001")!,
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: input.path),
        fingerprint: MediaFingerprint(fileSize: 1_000, modificationTimeNanoseconds: 2_000),
        inspected: PersistedMediaFacts(
            duration: try MediaTime(value: 10, timescale: 1),
            width: 3_840,
            height: 2_160,
            frameRate: try FrameRate(numerator: 24, denominator: 1),
            videoBitrate: 80_000_000,
            videoCodec: "h264",
            audioCodec: "aac",
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            colour: VideoColourMetadata(
                primaries: "bt709",
                transferFunction: "bt709",
                matrix: "bt709",
                range: "limited"
            )
        )
    )
    let firstCoverage = try MediaTimeRange(
        start: MediaTime(value: 1, timescale: 1),
        duration: MediaTime(value: 8, timescale: 1)
    )
    let secondCoverage = try MediaTimeRange(
        start: MediaTime(value: 3, timescale: 1),
        duration: MediaTime(value: 4, timescale: 1)
    )
    let passes = [
        StabilizationEffect(
            id: UUID(uuidString: "EEEEEEEE-A100-0000-0000-000000000001")!,
            mode: .steady,
            analysisCoverage: firstCoverage,
            processingRevision: 1
        ),
        StabilizationEffect(
            id: UUID(uuidString: "EEEEEEEE-A100-0000-0000-000000000002")!,
            mode: .naturalMotion,
            analysisCoverage: secondCoverage,
            processingRevision: 1
        ),
    ]
    let clip = TimelineClip(
        id: UUID(uuidString: "CCCCCCCC-A100-0000-0000-000000000001")!,
        assetID: asset.id,
        sourceRange: secondCoverage,
        stabilizationPasses: passes
    )
    let project = ProjectState(
        id: UUID(uuidString: "BBBBBBBB-A100-0000-0000-000000000001")!,
        name: "Bird",
        mediaLibrary: [asset],
        timelineFormat: TimelineFormat(
            width: 3_840,
            height: 2_160,
            frameRate: asset.inspected.frameRate,
            colour: asset.inspected.colour,
            audioSampleRate: 48_000,
            audioChannelCount: 2
        ),
        clips: [clip]
    )
    return ClipStabilizationFixture(
        input: input,
        asset: asset,
        clip: clip,
        passes: passes,
        project: project
    )
}
