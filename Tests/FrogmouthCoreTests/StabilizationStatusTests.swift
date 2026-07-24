import Foundation
import Testing

@testable import FrogmouthCore

@Test func stabilizationCacheIdentitiesEncodeEffectLineageAndProxyPolicy() throws {
    let fixture = try makeStabilizationFixture()
    let first = StabilizationEffect(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        mode: .steady,
        analysisCoverage: fixture.fullRange,
        processingRevision: 1
    )
    let second = StabilizationEffect(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
        mode: .naturalMotion,
        analysisCoverage: fixture.fullRange,
        processingRevision: 1
    )
    let clip = TimelineClip(
        id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
        assetID: fixture.asset.id,
        sourceRange: fixture.fullRange,
        stabilizationPasses: [first, second]
    )
    let builder = StabilizationCacheIdentityBuilder()
    let identities = try #require(builder.identities(
        for: 1,
        in: clip,
        asset: fixture.asset,
        toolRevision: fixture.toolRevision
    ))

    #expect(identities.transforms.namespace == "stabilization-transforms")
    #expect(identities.preview.namespace == "stabilization-preview")
    #expect(identities.transforms.logicalArtifactID == second.id.uuidString.lowercased())
    #expect(identities.transforms.processingRevision == 1)
    #expect(identities.transforms.toolRevision == fixture.toolRevision)
    #expect(identities.transforms.orderedParameters.contains(.init(
        name: "preceding-0-id",
        value: first.id.uuidString.lowercased()
    )))
    #expect(identities.transforms.orderedParameters.contains(.init(
        name: "profile-smoothing",
        value: "8"
    )))
    #expect(!identities.transforms.orderedParameters.contains {
        $0.name == "proxy-pixel-width"
    })
    #expect(identities.preview.orderedParameters.contains(.init(
        name: "proxy-pixel-width",
        value: "1024"
    )))

    var fadedClip = clip
    fadedClip.videoFadeIn = VideoFade(durationMilliseconds: 500)
    fadedClip.videoFadeOut = VideoFade(durationMilliseconds: 750)
    #expect(builder.identities(
        for: 1,
        in: fadedClip,
        asset: fixture.asset,
        toolRevision: fixture.toolRevision
    ) == identities)

    let inwardRange = try makeRange(rate: fixture.rate, startFrame: 24, frameCount: 96)
    let descendant = TimelineClip(
        assetID: fixture.asset.id,
        sourceRange: inwardRange,
        stabilizationPasses: clip.stabilizationPasses
    )
    #expect(builder.identities(
        for: 1,
        in: descendant,
        asset: fixture.asset,
        toolRevision: fixture.toolRevision
    ) == identities)

    let widerProxy = StabilizationCacheIdentityBuilder(previewPixelWidth: 1_280)
    let widerIdentities = try #require(widerProxy.identities(
        for: 1,
        in: clip,
        asset: fixture.asset,
        toolRevision: fixture.toolRevision
    ))
    #expect(widerIdentities.transforms == identities.transforms)
    #expect(widerIdentities.preview != identities.preview)
}

@Test func stabilizationStatusRequiresBothArtifactsAndCacheDeletionMakesItStale() async throws {
    let root = try makeStatusTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeStabilizationFixture()
    let effect = StabilizationEffect(
        mode: .steady,
        analysisCoverage: fixture.fullRange,
        processingRevision: 1
    )
    let clip = TimelineClip(
        assetID: fixture.asset.id,
        sourceRange: fixture.fullRange,
        stabilizationPasses: [effect]
    )
    let project = makeProject(fixture: fixture, clips: [clip])
    let store = ProjectCacheStore(rootURL: root.appendingPathComponent("cache"))
    let resolver = StabilizationStatusResolver(cacheStore: store)

    #expect(await resolver.validation(
        for: TimelineClip(assetID: fixture.asset.id, sourceRange: fixture.fullRange),
        in: project,
        toolRevision: fixture.toolRevision
    ).status == .none)
    #expect(await resolver.validation(
        for: clip,
        in: project,
        toolRevision: fixture.toolRevision
    ).status == .stale(.artifactUnavailable(
        effectID: effect.id,
        kind: .transforms,
        reason: .notCached
    )))

    let identities = try #require(StabilizationCacheIdentityBuilder().identities(
        for: 0,
        in: clip,
        asset: fixture.asset,
        toolRevision: fixture.toolRevision
    ))
    _ = try await store.store(
        Data("transforms".utf8),
        projectID: project.id,
        identity: identities.transforms,
        fileExtension: "trf"
    )
    #expect(await resolver.validation(
        for: clip,
        in: project,
        toolRevision: fixture.toolRevision
    ).status == .stale(.artifactUnavailable(
        effectID: effect.id,
        kind: .preview,
        reason: .notCached
    )))

    _ = try await store.store(
        Data("preview".utf8),
        projectID: project.id,
        identity: identities.preview,
        fileExtension: "mp4"
    )
    let valid = await resolver.validation(
        for: clip,
        in: project,
        toolRevision: fixture.toolRevision
    )
    #expect(valid.status == .valid)
    #expect(valid.artifacts.map(\.effectID) == [effect.id])
    #expect(!valid.status.blocksExport)

    let transformsURL = try #require(valid.artifacts.first?.transforms.url)
    try FileManager.default.removeItem(at: transformsURL)
    #expect(await resolver.validation(
        for: clip,
        in: project,
        toolRevision: fixture.toolRevision
    ).status == .stale(.artifactUnavailable(
        effectID: effect.id,
        kind: .transforms,
        reason: .artifactMissing(transformsURL.path)
    )))

    try await store.clearProjectCache(projectID: project.id)
    let afterClear = await resolver.validation(
        for: clip,
        in: project,
        toolRevision: fixture.toolRevision
    )
    #expect(afterClear.status.blocksExport)
    #expect(afterClear.status == .stale(.artifactUnavailable(
        effectID: effect.id,
        kind: .transforms,
        reason: .notCached
    )))
}

@Test func inwardTrimSplitDuplicateAndReorderRetainValidStabilizationCoverage() async throws {
    let root = try makeStatusTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeStabilizationFixture()
    let coverage = try makeRange(rate: fixture.rate, startFrame: 24, frameCount: 144)
    let effect = StabilizationEffect(
        mode: .naturalMotion,
        analysisCoverage: coverage,
        processingRevision: 1
    )
    let original = TimelineClip(
        assetID: fixture.asset.id,
        sourceRange: coverage,
        stabilizationPasses: [effect]
    )
    let projectID = UUID()
    let baseProject = makeProject(fixture: fixture, id: projectID, clips: [original])
    let store = ProjectCacheStore(rootURL: root.appendingPathComponent("cache"))
    let resolver = StabilizationStatusResolver(cacheStore: store)
    try await storeArtifacts(
        for: original,
        project: baseProject,
        asset: fixture.asset,
        toolRevision: fixture.toolRevision,
        store: store
    )

    let left = TimelineClip(
        assetID: fixture.asset.id,
        sourceRange: try makeRange(rate: fixture.rate, startFrame: 24, frameCount: 48),
        stabilizationPasses: [effect]
    )
    let right = TimelineClip(
        assetID: fixture.asset.id,
        sourceRange: try makeRange(rate: fixture.rate, startFrame: 72, frameCount: 72),
        stabilizationPasses: [effect]
    )
    let reorderedProject = makeProject(
        fixture: fixture,
        id: projectID,
        clips: [right, left]
    )
    let statuses = await resolver.statuses(
        for: reorderedProject,
        toolRevision: fixture.toolRevision
    )
    #expect(statuses[left.id] == .valid)
    #expect(statuses[right.id] == .valid)

    let extended = TimelineClip(
        assetID: fixture.asset.id,
        sourceRange: try makeRange(rate: fixture.rate, startFrame: 0, frameCount: 192),
        stabilizationPasses: [effect]
    )
    #expect(await resolver.validation(
        for: extended,
        in: makeProject(fixture: fixture, id: projectID, clips: [extended]),
        toolRevision: fixture.toolRevision
    ).status == .stale(.clipOutsideAnalysisCoverage(
        effectID: effect.id,
        clipRange: extended.sourceRange,
        analysisCoverage: coverage
    )))
}

@Test func stabilizationStatusExplainsPersistedAndCacheIncompatibilities() async throws {
    let root = try makeStatusTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeStabilizationFixture()
    let effect = StabilizationEffect(
        mode: .steady,
        analysisCoverage: fixture.fullRange,
        processingRevision: 1
    )
    let clip = TimelineClip(
        assetID: fixture.asset.id,
        sourceRange: fixture.fullRange,
        stabilizationPasses: [effect]
    )
    let project = makeProject(fixture: fixture, clips: [clip])
    let store = ProjectCacheStore(rootURL: root.appendingPathComponent("cache"))
    let resolver = StabilizationStatusResolver(cacheStore: store)
    try await storeArtifacts(
        for: clip,
        project: project,
        asset: fixture.asset,
        toolRevision: fixture.toolRevision,
        store: store
    )

    #expect(await resolver.validation(
        for: clip,
        in: project,
        toolRevision: "ffmpeg 8.0 / libvidstab 2"
    ).status == .stale(.artifactUnavailable(
        effectID: effect.id,
        kind: .transforms,
        reason: .identityChanged([.toolRevision])
    )))

    var changedAsset = fixture.asset
    changedAsset.fingerprint.fileSize += 1
    let changedSourceProject = ProjectState(
        id: project.id,
        name: project.name,
        mediaLibrary: [changedAsset],
        timelineFormat: project.timelineFormat,
        clips: [clip]
    )
    #expect(await resolver.validation(
        for: clip,
        in: changedSourceProject,
        toolRevision: fixture.toolRevision
    ).status == .stale(.artifactUnavailable(
        effectID: effect.id,
        kind: .transforms,
        reason: .identityChanged([.sourceFingerprint])
    )))

    var oldRevisionClip = clip
    oldRevisionClip.stabilizationPasses[0].processingRevision = 0
    #expect(await resolver.validation(
        for: oldRevisionClip,
        in: project,
        toolRevision: fixture.toolRevision
    ).status == .stale(.processingRevisionChanged(
        effectID: effect.id,
        analyzedWith: 0,
        current: 1
    )))
}

@Test func invalidPersistedStabilizationConfigurationIsStaleWithoutCacheAccess() async throws {
    let fixture = try makeStabilizationFixture()
    let store = ProjectCacheStore(
        rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("unused-status-cache-\(UUID().uuidString)")
    )
    let resolver = StabilizationStatusResolver(cacheStore: store)
    let noneEffect = StabilizationEffect(
        mode: .none,
        analysisCoverage: fixture.fullRange,
        processingRevision: 1
    )
    let noneClip = TimelineClip(
        assetID: fixture.asset.id,
        sourceRange: fixture.fullRange,
        stabilizationPasses: [noneEffect]
    )
    #expect(await resolver.validation(
        for: noneClip,
        in: makeProject(fixture: fixture, clips: [noneClip]),
        toolRevision: fixture.toolRevision
    ).status == .stale(.unsupportedMode(effectID: noneEffect.id, mode: .none)))

    let negativeStart = try MediaTime(value: -1, timescale: 1)
    let invalidCoverage = try MediaTimeRange(
        start: negativeStart,
        duration: fixture.fullRange.duration
    )
    let invalidEffect = StabilizationEffect(
        mode: .steady,
        analysisCoverage: invalidCoverage,
        processingRevision: 1
    )
    let invalidClip = TimelineClip(
        assetID: fixture.asset.id,
        sourceRange: fixture.fullRange,
        stabilizationPasses: [invalidEffect]
    )
    #expect(await resolver.validation(
        for: invalidClip,
        in: makeProject(fixture: fixture, clips: [invalidClip]),
        toolRevision: fixture.toolRevision
    ).status == .stale(.invalidAnalysisCoverage(effectID: invalidEffect.id)))

    let duplicateEffect = StabilizationEffect(
        mode: .steady,
        analysisCoverage: fixture.fullRange,
        processingRevision: 1
    )
    let duplicateClip = TimelineClip(
        assetID: fixture.asset.id,
        sourceRange: fixture.fullRange,
        stabilizationPasses: [duplicateEffect, duplicateEffect]
    )
    #expect(await resolver.validation(
        for: duplicateClip,
        in: makeProject(fixture: fixture, clips: [duplicateClip]),
        toolRevision: fixture.toolRevision
    ).status == .stale(.duplicateEffectID(duplicateEffect.id)))

    let missingAssetClip = TimelineClip(
        assetID: UUID(),
        sourceRange: fixture.fullRange,
        stabilizationPasses: [StabilizationEffect(
            mode: .steady,
            analysisCoverage: fixture.fullRange,
            processingRevision: 1
        )]
    )
    #expect(await resolver.validation(
        for: missingAssetClip,
        in: makeProject(fixture: fixture, clips: []),
        toolRevision: fixture.toolRevision
    ).status == .stale(.mediaMissing(missingAssetClip.assetID)))
}

@Test func projectJSONPersistsOrderedStabilizationDecisionsWithoutCacheLocations() throws {
    let fixture = try makeStabilizationFixture()
    let first = StabilizationEffect(
        mode: .steady,
        analysisCoverage: fixture.fullRange,
        processingRevision: 1
    )
    let second = StabilizationEffect(
        mode: .naturalMotion,
        analysisCoverage: try makeRange(rate: fixture.rate, startFrame: 12, frameCount: 120),
        processingRevision: 1
    )
    let clip = TimelineClip(
        assetID: fixture.asset.id,
        sourceRange: second.analysisCoverage,
        stabilizationPasses: [first, second]
    )
    let project = makeProject(fixture: fixture, clips: [clip])
    let data = try ProjectJSONCodec().encode(project)
    let reopened = try ProjectJSONCodec().decode(data)
    let text = try #require(String(data: data, encoding: .utf8))

    #expect(reopened.clips[0].stabilizationPasses == [first, second])
    #expect(text.contains("analysisCoverage"))
    #expect(text.contains("processingRevision"))
    #expect(!text.contains("transformsURL"))
    #expect(!text.contains("preview.mp4"))
    #expect(!text.contains("Library/Caches"))
}

private struct StabilizationFixture {
    let rate: FrameRate
    let asset: MediaAsset
    let fullRange: MediaTimeRange
    let toolRevision = "ffmpeg 7.1.1 / libvidstab 1"
}

private func makeStabilizationFixture() throws -> StabilizationFixture {
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let duration = try rate.time(forFrame: 240)
    let asset = MediaAsset(
        id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
        path: MediaPathReference(
            relativeToProject: "Media/source.mp4",
            absoluteFallback: "/tmp/source.mp4"
        ),
        fingerprint: MediaFingerprint(
            fileSize: 10_000,
            modificationTimeNanoseconds: 1_000_000
        ),
        inspected: PersistedMediaFacts(
            duration: duration,
            width: 4_096,
            height: 2_160,
            frameRate: rate,
            videoBitrate: 120_000_000,
            videoCodec: "avc1",
            audioCodec: "aac",
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            colour: VideoColourMetadata(
                primaries: "bt709",
                transferFunction: "bt709",
                matrix: "bt709",
                range: "full"
            )
        )
    )
    return StabilizationFixture(
        rate: rate,
        asset: asset,
        fullRange: try MediaTimeRange(start: .zero, duration: duration)
    )
}

private func makeProject(
    fixture: StabilizationFixture,
    id: UUID = UUID(),
    clips: [TimelineClip]
) -> ProjectState {
    ProjectState(
        id: id,
        name: "Status Test",
        mediaLibrary: [fixture.asset],
        timelineFormat: TimelineFormat(
            width: fixture.asset.inspected.width,
            height: fixture.asset.inspected.height,
            frameRate: fixture.rate,
            colour: fixture.asset.inspected.colour,
            audioSampleRate: 48_000,
            audioChannelCount: 2
        ),
        clips: clips
    )
}

private func makeRange(
    rate: FrameRate,
    startFrame: Int64,
    frameCount: Int64
) throws -> MediaTimeRange {
    try MediaTimeRange(
        start: rate.time(forFrame: startFrame),
        duration: rate.time(forFrame: frameCount)
    )
}

private func storeArtifacts(
    for clip: TimelineClip,
    project: ProjectState,
    asset: MediaAsset,
    toolRevision: String,
    store: ProjectCacheStore
) async throws {
    for index in clip.stabilizationPasses.indices {
        let identities = try #require(StabilizationCacheIdentityBuilder().identities(
            for: index,
            in: clip,
            asset: asset,
            toolRevision: toolRevision
        ))
        _ = try await store.store(
            Data("transforms-\(index)".utf8),
            projectID: project.id,
            identity: identities.transforms,
            fileExtension: "trf"
        )
        _ = try await store.store(
            Data("preview-\(index)".utf8),
            projectID: project.id,
            identity: identities.preview,
            fileExtension: "mp4"
        )
    }
}

private func makeStatusTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("frogmouth-stabilization-status-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
