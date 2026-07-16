import Foundation
import Testing

@testable import FrogmouthCore

@Test func mediaResolverPrefersRelativePathThenUsesAbsoluteFallback() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectDirectory = root.appendingPathComponent("Project", isDirectory: true)
    let mediaDirectory = projectDirectory.appendingPathComponent("Media", isDirectory: true)
    try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    let projectURL = projectDirectory.appendingPathComponent("Birds.frogmouth")
    let relativeURL = mediaDirectory.appendingPathComponent("żuraw clip.mp4")
    let fallbackURL = root.appendingPathComponent("fallback clip.mp4")
    try Data([1]).write(to: relativeURL)
    try Data([2, 3]).write(to: fallbackURL)
    let reference = MediaPathReference(
        relativeToProject: "Media/żuraw clip.mp4",
        absoluteFallback: fallbackURL.path
    )
    let resolver = ProjectMediaResolver()

    #expect(resolver.resolve(reference, projectURL: projectURL) == relativeURL.standardizedFileURL)
    try FileManager.default.removeItem(at: relativeURL)
    #expect(resolver.resolve(reference, projectURL: projectURL) == fallbackURL.standardizedFileURL)
}

@Test func projectOpenAggregatesEveryMissingSourceWithoutReturningPartialState() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectURL = root.appendingPathComponent("Missing.frogmouth")
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let first = try makeProjectMediaAsset(
        id: UUID(uuidString: "AAAAAAAA-1000-0000-0000-000000000001")!,
        path: MediaPathReference(
            relativeToProject: "Media/missing one.mp4",
            absoluteFallback: "/Volumes/Missing/missing one.mp4"
        ),
        facts: makeProjectMediaFacts(rate: rate, frameCount: 48)
    )
    let second = try makeProjectMediaAsset(
        id: UUID(uuidString: "BBBBBBBB-1000-0000-0000-000000000002")!,
        path: MediaPathReference(
            relativeToProject: "Media/missing two.mp4",
            absoluteFallback: "/Volumes/Missing/missing two.mp4"
        ),
        facts: makeProjectMediaFacts(rate: rate, frameCount: 48)
    )
    let project = ProjectState(name: "Missing", mediaLibrary: [first, second])
    let validator = ProjectOpenValidator(inspector: StubProjectMediaInspector(factsByName: [:]))

    do {
        _ = try await validator.validate(project: project, projectURL: projectURL)
        Issue.record("Expected missing-source validation to fail")
    } catch let error as ProjectMediaError {
        guard case let .missingSources(missing) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(missing.count == 2)
        #expect(missing[0].attemptedPaths.count == 2)
        #expect(missing[1].attemptedPaths.count == 2)
        #expect(error.errorDescription?.contains("missing one.mp4") == true)
        #expect(error.errorDescription?.contains("missing two.mp4") == true)
        #expect(error.errorDescription?.contains("Restore the files") == true)
    }
    #expect(project.mediaLibrary[0].fingerprint.fileSize == 1)
}

@Test func changedSourceIsReinspectedAndAcceptedAtomicallyWhenEditsRemainValid() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let mediaURL = root.appendingPathComponent("changed bird.mp4")
    try Data(repeating: 7, count: 12).write(to: mediaURL)
    let projectURL = root.appendingPathComponent("Changed.frogmouth")
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let oldFacts = makeProjectMediaFacts(rate: rate, frameCount: 96, videoBitrate: 10_000_000)
    let newFacts = makeProjectMediaFacts(rate: rate, frameCount: 120, videoBitrate: 12_000_000)
    let assetID = UUID(uuidString: "AAAAAAAA-2000-0000-0000-000000000001")!
    let asset = try makeProjectMediaAsset(
        id: assetID,
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: mediaURL.path),
        facts: oldFacts
    )
    let clip = TimelineClip(
        id: UUID(uuidString: "CCCCCCCC-2000-0000-0000-000000000001")!,
        assetID: assetID,
        sourceRange: try MediaTimeRange(
            start: rate.time(forFrame: 24),
            duration: rate.time(forFrame: 48)
        )
    )
    let project = ProjectState(
        name: "Changed",
        mediaLibrary: [asset],
        timelineFormat: makeProjectTimelineFormat(facts: oldFacts),
        clips: [clip]
    )
    let validator = ProjectOpenValidator(
        inspector: StubProjectMediaInspector(factsByName: [mediaURL.lastPathComponent: newFacts])
    )

    let resolved = try await validator.validate(project: project, projectURL: projectURL)
    #expect(resolved.changedAssetIDs == [assetID])
    #expect(resolved.resolvedURLs[assetID] == mediaURL)
    #expect(resolved.project.mediaLibrary[0].inspected == newFacts)
    #expect(resolved.project.mediaLibrary[0].fingerprint.fileSize == 12)
    #expect(project.mediaLibrary[0].inspected == oldFacts)
    #expect(project.mediaLibrary[0].fingerprint.fileSize == 1)
}

@Test func changedSourceCannotSilentlyTruncateExistingClipRanges() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let mediaURL = root.appendingPathComponent("shortened.mp4")
    try Data(repeating: 9, count: 4).write(to: mediaURL)
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let oldFacts = makeProjectMediaFacts(rate: rate, frameCount: 96)
    let shortenedFacts = makeProjectMediaFacts(rate: rate, frameCount: 24)
    let assetID = UUID(uuidString: "AAAAAAAA-3000-0000-0000-000000000001")!
    let asset = try makeProjectMediaAsset(
        id: assetID,
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: mediaURL.path),
        facts: oldFacts
    )
    let clip = TimelineClip(
        id: UUID(uuidString: "CCCCCCCC-3000-0000-0000-000000000001")!,
        assetID: assetID,
        sourceRange: try MediaTimeRange(
            start: rate.time(forFrame: 48),
            duration: rate.time(forFrame: 24)
        )
    )
    let project = ProjectState(
        name: "Shortened",
        mediaLibrary: [asset],
        timelineFormat: makeProjectTimelineFormat(facts: oldFacts),
        clips: [clip]
    )
    let validator = ProjectOpenValidator(
        inspector: StubProjectMediaInspector(
            factsByName: [mediaURL.lastPathComponent: shortenedFacts]
        )
    )

    do {
        _ = try await validator.validate(
            project: project,
            projectURL: root.appendingPathComponent("Shortened.frogmouth")
        )
        Issue.record("Expected the shortened source to invalidate the clip")
    } catch let error as ProjectMediaError {
        guard case let .invalidChangedSources(issues) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(issues.count == 1)
        #expect(issues[0].path == mediaURL.path)
        #expect(issues[0].reason.contains(clip.id.uuidString))
        #expect(error.errorDescription?.contains("Fix or restore") == true)
    }
    #expect(project.mediaLibrary[0].inspected == oldFacts)
}

@Test func timelineInsertionRejectsColourConflictAndNamesTheFile() throws {
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let baseFacts = makeProjectMediaFacts(rate: rate, frameCount: 48)
    let conflictingFacts = makeProjectMediaFacts(
        rate: rate,
        frameCount: 48,
        colour: VideoColourMetadata(
            primaries: "bt2020",
            transferFunction: "smpte2084",
            matrix: "bt2020nc",
            range: "limited"
        )
    )
    let base = try makeProjectMediaAsset(
        id: UUID(uuidString: "AAAAAAAA-4000-0000-0000-000000000001")!,
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: "/tmp/base.mp4"),
        facts: baseFacts
    )
    let conflicting = try makeProjectMediaAsset(
        id: UUID(uuidString: "BBBBBBBB-4000-0000-0000-000000000002")!,
        path: MediaPathReference(
            relativeToProject: nil,
            absoluteFallback: "/Volumes/Wildlife/HDR owl.mp4"
        ),
        facts: conflictingFacts
    )
    let baseClip = TimelineClip(
        id: UUID(uuidString: "CCCCCCCC-4000-0000-0000-000000000001")!,
        assetID: base.id,
        sourceRange: try MediaTimeRange(start: .zero, duration: rate.time(forFrame: 24))
    )
    let conflictingClip = TimelineClip(
        id: UUID(uuidString: "DDDDDDDD-4000-0000-0000-000000000002")!,
        assetID: conflicting.id,
        sourceRange: try MediaTimeRange(start: .zero, duration: rate.time(forFrame: 24))
    )
    let project = ProjectState(
        name: "Colour",
        mediaLibrary: [base, conflicting],
        timelineFormat: makeProjectTimelineFormat(facts: baseFacts),
        clips: [baseClip]
    )
    var editor = ProjectEditor(project: project)

    do {
        try editor.apply(.appendClip(conflictingClip))
        Issue.record("Expected incompatible colour insertion to fail")
    } catch let error as ProjectMediaError {
        guard case let .incompatibleColour(path, mismatches) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(path == "/Volumes/Wildlife/HDR owl.mp4")
        #expect(mismatches.map(\.property) == ColourProperty.allCases)
        #expect(error.errorDescription?.contains("HDR owl.mp4") == true)
        #expect(error.errorDescription?.contains("primaries") == true)
        #expect(error.errorDescription?.contains("transfer function") == true)
    }
    #expect(editor.project == project)
    #expect(!editor.history.canUndo)
}

@Test func conformanceFactsDescribeAspectFitPaddingFrameRateAndAudio() throws {
    let sourceRate = try FrameRate(numerator: 30_000, denominator: 1_001)
    let timelineRate = try FrameRate(numerator: 24, denominator: 1)
    let sourceFacts = makeProjectMediaFacts(
        rate: sourceRate,
        frameCount: 60,
        width: 426,
        height: 180,
        audioSampleRate: 44_100,
        audioChannelCount: 1
    )
    let asset = try makeProjectMediaAsset(
        id: UUID(uuidString: "AAAAAAAA-5000-0000-0000-000000000001")!,
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: "/tmp/wide.mp4"),
        facts: sourceFacts
    )
    let format = TimelineFormat(
        width: 320,
        height: 180,
        frameRate: timelineRate,
        colour: sourceFacts.colour,
        audioSampleRate: 48_000,
        audioChannelCount: 2
    )

    let facts = try TimelineCompatibilityValidator().validate(asset: asset, against: format)
    #expect(facts.scaledWidth == 320)
    #expect(facts.scaledHeight == 135)
    #expect(facts.padLeft == 0)
    #expect(facts.padRight == 0)
    #expect(facts.padTop == 22)
    #expect(facts.padBottom == 23)
    #expect(facts.requiresFrameRateConformance)
    #expect(facts.requiresAudioResampling)
    #expect(facts.requiresAudioChannelConformance)
}

@Test func mediaInspectorExposesExactFixtureFrameRates() async throws {
    let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/test-media-fixtures", isDirectory: true)
    let baseURL = fixtures.appendingPathComponent("base-24fps-320x180.mp4")
    let wideURL = fixtures.appendingPathComponent("wide-30000-1001-426x180.mp4")
    guard FileManager.default.fileExists(atPath: baseURL.path),
          FileManager.default.fileExists(atPath: wideURL.path) else { return }

    let inspector = MediaInspector()
    let base = try await inspector.inspect(url: baseURL)
    let wide = try await inspector.inspect(url: wideURL)
    let rate24 = try FrameRate(numerator: 24, denominator: 1)
    let rate2997 = try FrameRate(numerator: 30_000, denominator: 1_001)
    let twoSeconds = try MediaTime(value: 2, timescale: 1)
    #expect(base.exactFrameRate == rate24)
    #expect(wide.exactFrameRate == rate2997)
    #expect(base.exactDuration == twoSeconds)
}

private struct StubProjectMediaInspector: ProjectMediaFactsInspecting {
    let factsByName: [String: PersistedMediaFacts]

    func inspect(url: URL) async throws -> PersistedMediaFacts {
        guard let facts = factsByName[url.lastPathComponent] else {
            throw StubInspectionError.noFacts(url.lastPathComponent)
        }
        return facts
    }
}

private enum StubInspectionError: LocalizedError {
    case noFacts(String)

    var errorDescription: String? {
        switch self {
        case let .noFacts(name): "No stub facts for \(name)."
        }
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("frogmouth-project-media-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeProjectMediaAsset(
    id: UUID,
    path: MediaPathReference,
    facts: PersistedMediaFacts
) throws -> MediaAsset {
    MediaAsset(
        id: id,
        path: path,
        fingerprint: MediaFingerprint(fileSize: 1, modificationTimeNanoseconds: 1),
        inspected: facts
    )
}

private func makeProjectMediaFacts(
    rate: FrameRate,
    frameCount: Int64,
    width: Int = 320,
    height: Int = 180,
    videoBitrate: Int64 = 10_000_000,
    audioSampleRate: Int? = 48_000,
    audioChannelCount: Int? = 2,
    colour: VideoColourMetadata = VideoColourMetadata(
        primaries: "bt709",
        transferFunction: "bt709",
        matrix: "bt709",
        range: "full"
    )
) -> PersistedMediaFacts {
    PersistedMediaFacts(
        duration: try! rate.time(forFrame: frameCount),
        width: width,
        height: height,
        frameRate: rate,
        videoBitrate: videoBitrate,
        videoCodec: "avc1",
        audioCodec: audioSampleRate == nil ? nil : "aac",
        audioSampleRate: audioSampleRate,
        audioChannelCount: audioChannelCount,
        colour: colour
    )
}

private func makeProjectTimelineFormat(facts: PersistedMediaFacts) -> TimelineFormat {
    TimelineFormat(
        width: facts.width,
        height: facts.height,
        frameRate: facts.frameRate,
        colour: facts.colour,
        audioSampleRate: facts.audioSampleRate ?? 48_000,
        audioChannelCount: facts.audioChannelCount ?? 2
    )
}
