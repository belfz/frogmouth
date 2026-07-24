import Foundation
import Testing

@testable import FrogmouthCore

@Test func diagnosticsCaptureTheProjectDecisionGraphWithExactRanges() throws {
    let root = try diagnosticsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let diagnostics = DiagnosticLogStore(baseDirectory: root)
    let fixture = try diagnosticsProjectFixture(root: root)

    diagnostics.appendProjectSnapshot(
        fixture.project,
        fileURL: root.appendingPathComponent("Marsh birds.frogmouth"),
        resolvedMediaURLs: [fixture.asset.id: fixture.mediaURL]
    )

    let contents = diagnostics.contents()
    #expect(contents.contains("event=\"project.snapshot\""))
    #expect(contents.contains("schema_version=\"2\""))
    #expect(contents.contains("project_id=\"\(fixture.project.id.uuidString)\""))
    #expect(contents.contains("event=\"project.media\""))
    #expect(contents.contains("asset_id=\"\(fixture.asset.id.uuidString)\""))
    #expect(contents.contains("resolved_path=\"\(fixture.mediaURL.path)\""))
    #expect(contents.contains("event=\"project.clip\""))
    #expect(contents.contains("clip_id=\"\(fixture.clip.id.uuidString)\""))
    #expect(contents.contains("source_range=\"start=1/2,duration=3/2,end=2/1\""))
    #expect(contents.contains("event=\"project.stabilization-pass\""))
}

@Test func structuredDiagnosticValuesKeepOneEventPerLine() throws {
    let root = try diagnosticsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let diagnostics = DiagnosticLogStore(baseDirectory: root)

    diagnostics.append(
        level: "ERROR",
        sessionID: "test",
        phase: "diagnostics-test",
        event: "path.failure",
        fields: ["path": "/Volumes/Wild life/bird\nclip.mp4"]
    )

    let matchingLines = diagnostics.contents().split(separator: "\n").filter {
        $0.contains("path.failure")
    }
    #expect(matchingLines.count == 1)
    #expect(matchingLines[0].contains(#"path="/Volumes/Wild life/bird\nclip.mp4""#))
}

@Test func diagnosticsRecordApplicationVersionAndBuild() throws {
    let root = try diagnosticsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let diagnostics = DiagnosticLogStore(
        baseDirectory: root,
        buildInfo: ApplicationBuildInfo(version: "1.0.0", build: "27")
    )

    let contents = diagnostics.contents()
    #expect(contents.contains("frogmouth_version=1.0.0"))
    #expect(contents.contains("frogmouth_build=27"))
}

@Test func asynchronousDiagnosticReadFlushesQueuedWrites() async throws {
    let root = try diagnosticsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let diagnostics = DiagnosticLogStore(baseDirectory: root)
    diagnostics.append(
        level: "INFO",
        sessionID: "test",
        phase: "async-read",
        event: "diagnostics.ready"
    )

    let contents = await diagnostics.contentsAsync()
    #expect(contents.contains("diagnostics.ready"))
}

@Test func cacheDiagnosticsRecordKeysHitsAndStaleReasons() async throws {
    let root = try diagnosticsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let diagnostics = DiagnosticLogStore(baseDirectory: root.appendingPathComponent("logs"))
    let store = ProjectCacheStore(
        rootURL: root.appendingPathComponent("cache"),
        diagnostics: diagnostics
    )
    let projectID = UUID(uuidString: "AAAAAAAA-9000-0000-0000-000000000001")!
    let identity = CacheEntryIdentity(
        namespace: "diagnostics-fixture",
        logicalArtifactID: "thumbnail-1",
        assetID: UUID(uuidString: "BBBBBBBB-9000-0000-0000-000000000002")!,
        sourceFingerprint: MediaFingerprint(fileSize: 42, modificationTimeNanoseconds: 84),
        processingRevision: 1
    )

    #expect(await store.lookup(projectID: projectID, identity: identity) == .stale(.notCached))
    let artifact = try await store.store(
        Data([1, 2, 3]),
        projectID: projectID,
        identity: identity,
        fileExtension: "jpg"
    )
    #expect(await store.lookup(projectID: projectID, identity: identity) == .hit(artifact))

    let contents = diagnostics.contents()
    #expect(contents.contains("event=\"cache.lookup\""))
    #expect(contents.contains("cache_key=\"\(artifact.key)\""))
    #expect(contents.contains("result=\"stale\""))
    #expect(contents.contains("reason=\"No compatible cached artifact exists.\""))
    #expect(contents.contains("event=\"cache.store\""))
    #expect(contents.contains("result=\"hit\""))
}

@Test func renderAndMetadataDiagnosticsDescribeNormalizedDecisions() throws {
    let root = try diagnosticsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let diagnostics = DiagnosticLogStore(baseDirectory: root)
    let fixture = try diagnosticsProjectFixture(root: root)
    let plan = try TimelineRenderPlanner().plan(TimelineRenderRequest(
        project: fixture.project,
        mediaURLs: [fixture.asset.id: fixture.mediaURL],
        stabilizationTransforms: [
            fixture.clip.id: [fixture.effect.id: root.appendingPathComponent("motion.trf")],
        ]
    ))
    let metadata = TimelineExportMetadata(
        commonSourceTags: ["artist": "Marcin"],
        creationTime: "2026-07-20T12:00:00Z",
        projectName: fixture.project.name
    )

    diagnostics.appendTimelineRenderPlan(
        plan,
        destinationURL: root.appendingPathComponent("Marsh export.mp4"),
        sessionID: fixture.project.id.uuidString
    )
    diagnostics.appendTimelineMetadata(
        metadata,
        sourceMetadata: [["artist": "Marcin", "model": "EOS R5"]],
        sessionID: fixture.project.id.uuidString
    )

    let contents = diagnostics.contents()
    #expect(contents.contains("event=\"render-plan.summary\""))
    #expect(contents.contains("event=\"render-plan.input\""))
    #expect(contents.contains("event=\"render-plan.clip\""))
    #expect(contents.contains("event=\"render-plan.stabilization-pass\""))
    #expect(contents.contains("source_frames=\"12..<48\""))
    #expect(contents.contains("event=\"metadata.decision\""))
    #expect(contents.contains("Encoded by frogmouth"))
}

@Test func exportReadinessAggregatesMissingAndStaleClipsWithRecoverySteps() throws {
    let root = try diagnosticsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try diagnosticsProjectFixture(root: root)
    let secondClip = TimelineClip(
        id: UUID(uuidString: "DDDDDDDD-9000-0000-0000-000000000004")!,
        assetID: fixture.asset.id,
        sourceRange: fixture.clip.sourceRange,
        stabilizationPasses: fixture.clip.stabilizationPasses
    )
    var project = fixture.project
    project.clips.append(secondClip)
    let validator = TimelineExportReadinessValidator()

    do {
        try validator.validate(
            project: project,
            mediaURLs: [:],
            stabilizationStatuses: [:]
        )
        Issue.record("Expected unavailable sources to block export")
    } catch let error as TimelineExportReadinessError {
        guard case let .missingSources(issues) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(issues.map(\.clipNumber) == [1, 2])
        #expect(error.localizedDescription.contains("Restore the listed files"))
        #expect(error.localizedDescription.contains(fixture.mediaURL.path))
    }

    try Data([0]).write(to: fixture.mediaURL)
    let staleReason = StabilizationStaleReason.processingRevisionChanged(
        effectID: fixture.effect.id,
        analyzedWith: 0,
        current: 1
    )
    do {
        try validator.validate(
            project: project,
            mediaURLs: [fixture.asset.id: fixture.mediaURL],
            stabilizationStatuses: [
                fixture.clip.id: .stale(staleReason),
                secondClip.id: .stale(staleReason),
            ]
        )
        Issue.record("Expected stale stabilization to block export")
    } catch let error as TimelineExportReadinessError {
        guard case let .staleStabilization(issues) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(issues.map(\.clipNumber) == [1, 2])
        #expect(error.localizedDescription.contains("Select each listed clip"))
        #expect(error.localizedDescription.contains("Update Stabilization"))
    }
}

private struct DiagnosticsProjectFixture {
    let project: ProjectState
    let asset: MediaAsset
    let clip: TimelineClip
    let effect: StabilizationEffect
    let mediaURL: URL
}

private func diagnosticsProjectFixture(root: URL) throws -> DiagnosticsProjectFixture {
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let colour = VideoColourMetadata(
        primaries: "bt709",
        transferFunction: "bt709",
        matrix: "bt709",
        range: "full"
    )
    let mediaURL = root.appendingPathComponent("R5 marsh source.mp4")
    let asset = MediaAsset(
        id: UUID(uuidString: "BBBBBBBB-9000-0000-0000-000000000002")!,
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: mediaURL.path),
        fingerprint: MediaFingerprint(fileSize: 42, modificationTimeNanoseconds: 84),
        inspected: PersistedMediaFacts(
            duration: try rate.time(forFrame: 120),
            width: 4_096,
            height: 2_160,
            frameRate: rate,
            videoBitrate: 120_000_000,
            videoCodec: "avc1",
            audioCodec: "aac",
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            colour: colour
        )
    )
    let range = try MediaTimeRange(
        start: rate.time(forFrame: 12),
        duration: rate.time(forFrame: 36)
    )
    let effect = StabilizationEffect(
        id: UUID(uuidString: "EEEEEEEE-9000-0000-0000-000000000005")!,
        mode: .steady,
        analysisCoverage: range,
        processingRevision: StabilizationCacheIdentityBuilder.currentProcessingRevision
    )
    let clip = TimelineClip(
        id: UUID(uuidString: "CCCCCCCC-9000-0000-0000-000000000003")!,
        assetID: asset.id,
        sourceRange: range,
        stabilizationPasses: [effect]
    )
    let project = ProjectState(
        id: UUID(uuidString: "AAAAAAAA-9000-0000-0000-000000000001")!,
        name: "Marsh birds",
        mediaLibrary: [asset],
        timelineFormat: TimelineFormat(
            width: asset.inspected.width,
            height: asset.inspected.height,
            frameRate: rate,
            colour: colour,
            audioSampleRate: 48_000,
            audioChannelCount: 2
        ),
        clips: [clip]
    )
    return DiagnosticsProjectFixture(
        project: project,
        asset: asset,
        clip: clip,
        effect: effect,
        mediaURL: mediaURL
    )
}

private func diagnosticsTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "frogmouth-diagnostics-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
