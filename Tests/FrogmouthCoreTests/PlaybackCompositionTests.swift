@preconcurrency import AVFoundation
@testable import FrogmouthCore
import Foundation
import Testing

@Test
func playbackSegmentMapTracksMixedRateClipAndSourceTimeExactly() async throws {
    let fixture = try await makeStandardPlaybackFixture()
    let map = try PlaybackSegmentMap(project: fixture.project)

    #expect(map.totalFrames == 60)
    #expect(map.segments.map(\.startFrame) == [0, 24, 48])
    #expect(map.segments.map(\.durationFrames) == [24, 24, 12])

    let first = try #require(try map.location(atTimelineFrame: 23))
    let expectedFirstSourceTime = try fixture.baseRate.time(forFrame: 35)
    #expect(first.clipID == fixture.project.clips[0].id)
    #expect(first.clipFrameOffset == 23)
    #expect(first.sourceTime == expectedFirstSourceTime)

    let boundary = try #require(try map.location(atTimelineFrame: 24))
    let expectedBoundarySourceTime = try fixture.wideRate.time(forFrame: 15)
    #expect(boundary.clipID == fixture.project.clips[1].id)
    #expect(boundary.clipFrameOffset == 0)
    #expect(boundary.sourceTime == expectedBoundarySourceTime)

    let finalClip = try #require(try map.location(atTimelineFrame: 48))
    let expectedFinalSourceTime = try fixture.baseRate.time(forFrame: 36)
    #expect(finalClip.clipID == fixture.project.clips[2].id)
    #expect(finalClip.sourceTime == expectedFinalSourceTime)
    #expect(try map.location(atTimelineFrame: 60) == nil)
}

@Test
func playbackCompositionUsesHardCutsCanvasRateAndIsolatedAudioTracks() async throws {
    let fixture = try await makeStandardPlaybackFixture()
    let result = try await PlaybackCompositionBuilder().build(
        PlaybackBuildRequest(project: fixture.project, mediaURLs: fixture.mediaURLs)
    )

    #expect(result.videoComposition.renderSize == CGSize(width: 320, height: 180))
    #expect(result.videoComposition.frameDuration == fixture.baseRate.frameDuration.cmTime)
    #expect(result.videoComposition.instructions.count == 3)
    #expect(result.audioMix.inputParameters.count == 3)

    let videoTracks = try await result.composition.loadTracks(withMediaType: .video)
    let audioTracks = try await result.composition.loadTracks(withMediaType: .audio)
    #expect(videoTracks.count == 1)
    #expect(audioTracks.count == 3)
    let expectedDuration = try fixture.baseRate.time(forFrame: 60).cmTime
    let expectedFirstDuration = try fixture.baseRate.time(forFrame: 24).cmTime
    let expectedSecondStart = try fixture.baseRate.time(forFrame: 24).cmTime
    let expectedThirdStart = try fixture.baseRate.time(forFrame: 48).cmTime
    #expect(result.composition.duration == expectedDuration)

    let instructionRanges = result.videoComposition.instructions.map(\.timeRange)
    #expect(instructionRanges[0].start == .zero)
    #expect(instructionRanges[0].duration == expectedFirstDuration)
    #expect(instructionRanges[1].start == expectedSecondStart)
    #expect(instructionRanges[2].start == expectedThirdStart)
}

@Test
func playbackSourceOverrideDoesNotChangeLogicalTimelineMapping() async throws {
    let fixture = try await makeStandardPlaybackFixture()
    let secondClip = fixture.project.clips[1]
    let proxyRange = try MediaTimeRange(
        start: .zero,
        duration: fixture.wideRate.time(forFrame: 30)
    )
    let result = try await PlaybackCompositionBuilder().build(
        PlaybackBuildRequest(
            project: fixture.project,
            mediaURLs: fixture.mediaURLs,
            clipSourceOverrides: [
                secondClip.id: PlaybackMediaSource(
                    url: fixture.wideURL,
                    range: proxyRange
                )
            ]
        )
    )

    let location = try #require(try result.segmentMap.location(atTimelineFrame: 24))
    let expectedSourceTime = try fixture.wideRate.time(forFrame: 15)
    #expect(location.clipID == secondClip.id)
    #expect(location.sourceTime == expectedSourceTime)
}

@Test
func playbackCompositionAppliesIndependentVideoOpacityRampsWithoutChangingAudio() async throws {
    let fixture = try await makeStandardPlaybackFixture()
    var project = fixture.project
    project.clips[0].videoFadeIn = VideoFade(durationMilliseconds: 500)
    project.clips[0].videoFadeOut = VideoFade(durationMilliseconds: 250)
    let result = try await PlaybackCompositionBuilder().build(
        PlaybackBuildRequest(project: project, mediaURLs: fixture.mediaURLs)
    )
    let instruction = try #require(
        result.videoComposition.instructions.first
            as? AVMutableVideoCompositionInstruction
    )
    let layer = try #require(
        instruction.layerInstructions.first
            as? AVMutableVideoCompositionLayerInstruction
    )

    var startOpacity: Float = -1
    var endOpacity: Float = -1
    var rampRange = CMTimeRange.invalid
    #expect(layer.getOpacityRamp(
        for: .zero,
        startOpacity: &startOpacity,
        endOpacity: &endOpacity,
        timeRange: &rampRange
    ))
    #expect(startOpacity == 0)
    #expect(endOpacity == 1)
    #expect(rampRange == CMTimeRange(
        start: .zero,
        duration: try MediaTime(value: 500, timescale: 1_000).cmTime
    ))

    let firstClipDuration = try fixture.baseRate.time(forFrame: 24)
    let fadeOutStart = try firstClipDuration.subtracting(
        MediaTime(value: 250, timescale: 1_000)
    )
    #expect(layer.getOpacityRamp(
        for: fadeOutStart.cmTime,
        startOpacity: &startOpacity,
        endOpacity: &endOpacity,
        timeRange: &rampRange
    ))
    #expect(startOpacity == 1)
    #expect(endOpacity == 0)
    #expect(rampRange == CMTimeRange(
        start: fadeOutStart.cmTime,
        duration: try MediaTime(value: 250, timescale: 1_000).cmTime
    ))
    #expect(result.audioMix.inputParameters.count == 3)
}

private struct StandardPlaybackFixture {
    let project: ProjectState
    let mediaURLs: [MediaAsset.ID: URL]
    let wideURL: URL
    let baseRate: FrameRate
    let wideRate: FrameRate
}

private func makeStandardPlaybackFixture() async throws -> StandardPlaybackFixture {
    let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/test-media-fixtures", isDirectory: true)
    let baseURL = fixtures.appendingPathComponent("base-24fps-320x180.mp4")
    let wideURL = fixtures.appendingPathComponent("wide-30000-1001-426x180.mp4")
    let inspector = AVProjectMediaFactsInspector()
    let baseFacts = try await inspector.inspect(url: baseURL)
    let wideFacts = try await inspector.inspect(url: wideURL)
    let base = MediaAsset(
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: baseURL.path),
        fingerprint: MediaFingerprint(fileSize: 1, modificationTimeNanoseconds: 1),
        inspected: baseFacts
    )
    let wide = MediaAsset(
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: wideURL.path),
        fingerprint: MediaFingerprint(fileSize: 1, modificationTimeNanoseconds: 1),
        inspected: wideFacts
    )
    let baseRate = try FrameRate(numerator: 24, denominator: 1)
    let wideRate = try FrameRate(numerator: 30_000, denominator: 1_001)
    let clips = [
        TimelineClip(
            assetID: base.id,
            sourceRange: try MediaTimeRange(
                start: baseRate.time(forFrame: 12),
                duration: baseRate.time(forFrame: 24)
            )
        ),
        TimelineClip(
            assetID: wide.id,
            sourceRange: try MediaTimeRange(
                start: wideRate.time(forFrame: 15),
                duration: wideRate.time(forFrame: 30)
            )
        ),
        TimelineClip(
            assetID: base.id,
            sourceRange: try MediaTimeRange(
                start: baseRate.time(forFrame: 36),
                duration: baseRate.time(forFrame: 12)
            )
        ),
    ]
    let format = TimelineFormat(
        width: 320,
        height: 180,
        frameRate: baseRate,
        colour: baseFacts.colour,
        audioSampleRate: baseFacts.audioSampleRate ?? 48_000,
        audioChannelCount: baseFacts.audioChannelCount ?? 2
    )
    let project = ProjectState(
        name: "Playback",
        mediaLibrary: [base, wide],
        timelineFormat: format,
        clips: clips
    )
    return StandardPlaybackFixture(
        project: project,
        mediaURLs: [base.id: baseURL, wide.id: wideURL],
        wideURL: wideURL,
        baseRate: baseRate,
        wideRate: wideRate
    )
}
