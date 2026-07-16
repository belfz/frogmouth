import Foundation
import Testing

@testable import FrogmouthCore

private let assetAID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
private let assetBID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
private let clipAID = UUID(uuidString: "CAAAAAAA-0000-0000-0000-000000000001")!
private let clipBID = UUID(uuidString: "CBBBBBBB-0000-0000-0000-000000000002")!
private let clipCID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!

@Test func timelineIndexDerivesGaplessStartsAcrossMixedFrameRates() throws {
    let rate24 = try FrameRate(numerator: 24, denominator: 1)
    let rate2997 = try FrameRate(numerator: 30_000, denominator: 1_001)
    let assetA = try makeAsset(id: assetAID, rate: rate24, frameCount: 96)
    let assetB = try makeAsset(id: assetBID, rate: rate2997, frameCount: 60)
    let clips = [
        TimelineClip(
            id: clipAID,
            assetID: assetA.id,
            sourceRange: try makeRange(rate: rate24, startFrame: 0, frameCount: 24)
        ),
        TimelineClip(
            id: clipBID,
            assetID: assetB.id,
            sourceRange: try makeRange(rate: rate2997, startFrame: 15, frameCount: 30)
        ),
        TimelineClip(
            id: clipCID,
            assetID: assetA.id,
            sourceRange: try makeRange(rate: rate24, startFrame: 24, frameCount: 12)
        ),
    ]
    let project = ProjectState(
        name: "Mixed rates",
        mediaLibrary: [assetA, assetB],
        timelineFormat: makeFormat(from: assetA),
        clips: clips
    )

    let index = try TimelineIndex(project: project)
    #expect(index.entries.map(\.startFrame) == [0, 24, 48])
    #expect(index.entries.map(\.durationFrames) == [24, 24, 12])
    #expect(index.totalFrames == 60)
    let expectedDuration = try rate24.time(forFrame: 60)
    #expect(index.totalDuration == expectedDuration)
    for pair in zip(index.entries, index.entries.dropFirst()) {
        #expect(try pair.0.timelineRange.end() == pair.1.timelineRange.start)
    }
}

@Test func importingAndInsertingClipsDerivesAndRetainsTimelineFormat() throws {
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let assetA = try makeAsset(id: assetAID, rate: rate, frameCount: 48, hasAudio: false)
    let assetB = try makeAsset(id: assetBID, rate: rate, frameCount: 48, width: 426)
    let clipA = TimelineClip(
        id: clipAID,
        assetID: assetA.id,
        sourceRange: try makeRange(rate: rate, startFrame: 0, frameCount: 24)
    )
    let clipB = TimelineClip(
        id: clipBID,
        assetID: assetB.id,
        sourceRange: try makeRange(rate: rate, startFrame: 0, frameCount: 12)
    )
    var editor = ProjectEditor(project: ProjectState(name: "Untitled"))

    try editor.apply(.importMedia(assetA))
    #expect(try editor.undo())
    #expect(editor.project.mediaLibrary.isEmpty)
    #expect(try editor.redo())
    #expect(editor.project.mediaLibrary.map(\.id) == [assetAID])
    try editor.apply(.importMedia(assetB))
    try editor.apply(.appendClip(clipA))
    #expect(try editor.undo())
    #expect(editor.project.clips.isEmpty)
    #expect(editor.project.timelineFormat == nil)
    #expect(try editor.redo())
    #expect(editor.project.timelineFormat == makeFormat(from: assetA))
    try editor.apply(.insertClip(clipB, atIndex: 0))
    #expect(editor.project.clips.map(\.id) == [clipBID, clipAID])

    #expect(try editor.undo())
    #expect(editor.project.clips.map(\.id) == [clipAID])
    #expect(try editor.redo())
    #expect(editor.project.clips.map(\.id) == [clipBID, clipAID])

    try editor.apply(.deleteClip(clipID: clipBID))
    try editor.apply(.deleteClip(clipID: clipAID))
    #expect(editor.project.clips.isEmpty)
    #expect(editor.project.timelineFormat == makeFormat(from: assetA))
}

@Test func splitChildrenExactlyCoverTheParentAndInheritStabilization() throws {
    let rate = try FrameRate(numerator: 30_000, denominator: 1_001)
    let asset = try makeAsset(id: assetAID, rate: rate, frameCount: 120)
    let parentRange = try makeRange(rate: rate, startFrame: 30, frameCount: 60)
    let effect = StabilizationEffect(
        id: UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001")!,
        mode: .steady,
        analysisCoverage: parentRange,
        processingRevision: 1
    )
    let parent = TimelineClip(
        id: clipAID,
        assetID: asset.id,
        sourceRange: parentRange,
        stabilizationPasses: [effect]
    )
    var editor = ProjectEditor(project: ProjectState(
        name: "Split",
        mediaLibrary: [asset],
        timelineFormat: TimelineFormat(
            width: 320,
            height: 180,
            frameRate: try FrameRate(numerator: 24, denominator: 1),
            colour: asset.inspected.colour,
            audioSampleRate: 48_000,
            audioChannelCount: 2
        ),
        clips: [parent]
    ))

    try editor.apply(.splitClip(
        clipID: clipAID,
        atTimelineFrameOffset: 24,
        rightClipID: clipBID
    ))
    let left = editor.project.clips[0]
    let right = editor.project.clips[1]
    #expect(left.id == clipAID)
    #expect(right.id == clipBID)
    #expect(left.stabilizationPasses == [effect])
    #expect(right.stabilizationPasses == [effect])
    #expect(try left.sourceRange.end() == right.sourceRange.start)
    #expect(try right.sourceRange.end() == parentRange.end())
    #expect(left.sourceRange.start == parentRange.start)
    #expect(try TimelineIndex(project: editor.project).totalFrames == 48)

    #expect(try editor.undo())
    #expect(editor.project.clips == [parent])
    #expect(try editor.redo())
    #expect(editor.project.clips.count == 2)
}

@Test func splitRefusesEdgesAndUnrepresentableSourceBoundariesAtomically() throws {
    let rate24 = try FrameRate(numerator: 24, denominator: 1)
    let asset = try makeAsset(id: assetAID, rate: rate24, frameCount: 48)
    let clip = TimelineClip(
        id: clipAID,
        assetID: asset.id,
        sourceRange: try makeRange(rate: rate24, startFrame: 0, frameCount: 24)
    )
    let format60 = TimelineFormat(
        width: 320,
        height: 180,
        frameRate: try FrameRate(numerator: 60, denominator: 1),
        colour: asset.inspected.colour,
        audioSampleRate: 48_000,
        audioChannelCount: 2
    )
    let project = ProjectState(
        name: "Precise split",
        mediaLibrary: [asset],
        timelineFormat: format60,
        clips: [clip]
    )
    var editor = ProjectEditor(project: project)

    #expect(throws: TimelineEditError.splitAtClipEdge) {
        try editor.apply(.splitClip(
            clipID: clipAID,
            atTimelineFrameOffset: 0,
            rightClipID: clipBID
        ))
    }
    #expect(throws: TimelineEditError.unrepresentableSplit) {
        try editor.apply(.splitClip(
            clipID: clipAID,
            atTimelineFrameOffset: 1,
            rightClipID: clipBID
        ))
    }
    #expect(editor.project == project)
    #expect(!editor.history.canUndo)
}

@Test func trimGestureIsOneUndoableCommitAndNeverPublishesTransientRanges() throws {
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let asset = try makeAsset(id: assetAID, rate: rate, frameCount: 96)
    let originalRange = try makeRange(rate: rate, startFrame: 0, frameCount: 72)
    let effect = StabilizationEffect(
        mode: .naturalMotion,
        analysisCoverage: originalRange,
        processingRevision: 1
    )
    let clip = TimelineClip(
        id: clipAID,
        assetID: asset.id,
        sourceRange: originalRange,
        stabilizationPasses: [effect]
    )
    let project = ProjectState(
        name: "Trim",
        mediaLibrary: [asset],
        timelineFormat: makeFormat(from: asset),
        clips: [clip]
    )
    var editor = ProjectEditor(project: project)
    let firstPending = try makeRange(rate: rate, startFrame: 6, frameCount: 60)
    let finalPending = try makeRange(rate: rate, startFrame: 12, frameCount: 36)

    try editor.beginTrim(clipID: clipAID)
    try editor.updateTrim(to: firstPending)
    try editor.updateTrim(to: finalPending)
    #expect(editor.project == project)
    #expect(editor.trimTransaction?.pendingRange == finalPending)
    #expect(!editor.history.canUndo)

    try editor.commitTrim()
    #expect(editor.project.clips[0].sourceRange == finalPending)
    #expect(editor.project.clips[0].stabilizationPasses == [effect])
    #expect(editor.history.canUndo)
    #expect(try editor.undo())
    #expect(editor.project == project)
    #expect(!(try editor.undo()))
    #expect(try editor.redo())
    #expect(editor.project.clips[0].sourceRange == finalPending)

    try editor.beginTrim(clipID: clipAID)
    try editor.updateTrim(to: firstPending)
    try editor.cancelTrim()
    #expect(editor.project.clips[0].sourceRange == finalPending)
    #expect(try editor.undo())
    #expect(editor.project == project)
    #expect(!(try editor.undo()))
}

@Test func duplicateReorderRippleDeleteAndDivergentHistoryAreReversible() throws {
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let asset = try makeAsset(id: assetAID, rate: rate, frameCount: 96)
    let first = TimelineClip(
        id: clipAID,
        assetID: asset.id,
        sourceRange: try makeRange(rate: rate, startFrame: 0, frameCount: 24)
    )
    let second = TimelineClip(
        id: clipBID,
        assetID: asset.id,
        sourceRange: try makeRange(rate: rate, startFrame: 24, frameCount: 24)
    )
    let project = ProjectState(
        name: "Commands",
        mediaLibrary: [asset],
        timelineFormat: makeFormat(from: asset),
        clips: [first, second]
    )
    var editor = ProjectEditor(project: project)

    try editor.apply(.duplicateClip(clipID: clipAID, newClipID: clipCID))
    #expect(editor.project.clips.map(\.id) == [clipAID, clipCID, clipBID])
    #expect(try editor.undo())
    #expect(editor.project == project)
    #expect(try editor.redo())

    try editor.apply(.moveClip(clipID: clipCID, toIndex: 2))
    #expect(editor.project.clips.map(\.id) == [clipAID, clipBID, clipCID])
    #expect(try editor.undo())
    #expect(editor.project.clips.map(\.id) == [clipAID, clipCID, clipBID])
    #expect(try editor.redo())

    try editor.apply(.deleteClip(clipID: clipBID))
    #expect(editor.project.clips.map(\.id) == [clipAID, clipCID])
    #expect(try editor.undo())
    #expect(editor.project.clips.map(\.id) == [clipAID, clipBID, clipCID])
    #expect(try editor.redo())
    #expect(editor.project.clips.map(\.id) == [clipAID, clipCID])
    #expect(try editor.undo())
    #expect(editor.history.canRedo)

    try editor.apply(.deleteClip(clipID: clipCID))
    #expect(!editor.history.canRedo)
}

@Test func unusedMediaRemovalIsUndoableButReferencedMediaIsProtected() throws {
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let assetA = try makeAsset(id: assetAID, rate: rate, frameCount: 48)
    let assetB = try makeAsset(id: assetBID, rate: rate, frameCount: 48)
    let clip = TimelineClip(
        id: clipAID,
        assetID: assetA.id,
        sourceRange: try makeRange(rate: rate, startFrame: 0, frameCount: 24)
    )
    let project = ProjectState(
        name: "Media removal",
        mediaLibrary: [assetA, assetB],
        timelineFormat: makeFormat(from: assetA),
        clips: [clip]
    )
    var editor = ProjectEditor(project: project)

    #expect(throws: TimelineEditError.mediaInUse(assetID: assetAID, usageCount: 1)) {
        try editor.apply(.removeUnusedMedia(assetID: assetAID))
    }
    try editor.apply(.removeUnusedMedia(assetID: assetBID))
    #expect(editor.project.mediaLibrary.map(\.id) == [assetAID])
    #expect(try editor.undo())
    #expect(editor.project == project)
    #expect(try editor.redo())
    #expect(editor.project.mediaLibrary.map(\.id) == [assetAID])
}

private func makeAsset(
    id: UUID,
    rate: FrameRate,
    frameCount: Int64,
    width: Int = 320,
    hasAudio: Bool = true
) throws -> MediaAsset {
    MediaAsset(
        id: id,
        path: MediaPathReference(
            relativeToProject: "Media/\(id.uuidString).mp4",
            absoluteFallback: "/tmp/\(id.uuidString).mp4"
        ),
        fingerprint: MediaFingerprint(
            fileSize: 1_000,
            modificationTimeNanoseconds: 1_000_000
        ),
        inspected: PersistedMediaFacts(
            duration: try rate.time(forFrame: frameCount),
            width: width,
            height: 180,
            frameRate: rate,
            videoBitrate: 10_000_000,
            videoCodec: "avc1",
            audioCodec: hasAudio ? "aac" : nil,
            audioSampleRate: hasAudio ? 48_000 : nil,
            audioChannelCount: hasAudio ? 2 : nil,
            colour: VideoColourMetadata(
                primaries: "bt709",
                transferFunction: "bt709",
                matrix: "bt709",
                range: "full"
            )
        )
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

private func makeFormat(from asset: MediaAsset) -> TimelineFormat {
    TimelineFormat(
        width: asset.inspected.width,
        height: asset.inspected.height,
        frameRate: asset.inspected.frameRate,
        colour: asset.inspected.colour,
        audioSampleRate: asset.inspected.audioSampleRate ?? 48_000,
        audioChannelCount: asset.inspected.audioChannelCount ?? 2
    )
}
