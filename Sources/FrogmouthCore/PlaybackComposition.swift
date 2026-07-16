@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

public enum PlaybackCompositionError: LocalizedError, Equatable, Sendable {
    case missingTimelineFormat
    case missingMediaURL(MediaAsset.ID)
    case missingVideoTrack(MediaAsset.ID)
    case couldNotCreateVideoTrack
    case couldNotCreateAudioTrack(TimelineClip.ID)

    public var errorDescription: String? {
        switch self {
        case .missingTimelineFormat:
            "The timeline has no playback format."
        case let .missingMediaURL(assetID):
            "The source file for media \(assetID.uuidString) is unavailable."
        case let .missingVideoTrack(assetID):
            "The source file for media \(assetID.uuidString) has no readable video track."
        case .couldNotCreateVideoTrack:
            "AVFoundation could not create the timeline video track."
        case let .couldNotCreateAudioTrack(clipID):
            "AVFoundation could not create the audio track for clip \(clipID.uuidString)."
        }
    }
}

/// The physical media and range inserted for a logical timeline clip.
///
/// Phase 3 can supply a valid stabilized proxy here while the composition
/// builder and timeline/source mapping continue to use the same public API.
public struct PlaybackMediaSource: Equatable, Sendable {
    public let url: URL
    public let range: MediaTimeRange

    public init(url: URL, range: MediaTimeRange) {
        self.url = url
        self.range = range
    }
}

public struct PlaybackBuildRequest: Sendable {
    public let project: ProjectState
    public let mediaURLs: [MediaAsset.ID: URL]
    public let clipSourceOverrides: [TimelineClip.ID: PlaybackMediaSource]

    public init(
        project: ProjectState,
        mediaURLs: [MediaAsset.ID: URL],
        clipSourceOverrides: [TimelineClip.ID: PlaybackMediaSource] = [:]
    ) {
        self.project = project
        self.mediaURLs = mediaURLs
        self.clipSourceOverrides = clipSourceOverrides
    }
}

public struct PlaybackLocation: Equatable, Sendable {
    public let clipID: TimelineClip.ID
    public let assetID: MediaAsset.ID
    public let timelineFrame: Int64
    public let timelineTime: MediaTime
    public let clipFrameOffset: Int64
    public let sourceTime: MediaTime
}

public struct PlaybackSegment: Equatable, Sendable {
    public let clipID: TimelineClip.ID
    public let assetID: MediaAsset.ID
    public let timelineRange: MediaTimeRange
    public let startFrame: Int64
    public let durationFrames: Int64
    public let sourceRange: MediaTimeRange
    public let sourceFrameRate: FrameRate
}

public struct PlaybackSegmentMap: Equatable, Sendable {
    public let timelineFrameRate: FrameRate
    public let segments: [PlaybackSegment]
    public let totalFrames: Int64

    public init(project: ProjectState) throws {
        guard let format = project.timelineFormat else {
            if project.clips.isEmpty {
                timelineFrameRate = try FrameRate(numerator: 1, denominator: 1)
                segments = []
                totalFrames = 0
                return
            }
            throw PlaybackCompositionError.missingTimelineFormat
        }

        let index = try TimelineIndex(project: project)
        let assetsByID = Dictionary(uniqueKeysWithValues: project.mediaLibrary.map { ($0.id, $0) })
        timelineFrameRate = format.frameRate
        segments = try index.entries.map { entry in
            let clip = project.clips[entry.clipIndex]
            guard let asset = assetsByID[clip.assetID] else {
                throw TimelineEditError.mediaNotFound(clip.assetID)
            }
            return PlaybackSegment(
                clipID: clip.id,
                assetID: clip.assetID,
                timelineRange: entry.timelineRange,
                startFrame: entry.startFrame,
                durationFrames: entry.durationFrames,
                sourceRange: clip.sourceRange,
                sourceFrameRate: asset.inspected.frameRate
            )
        }
        totalFrames = index.totalFrames
    }

    public func location(atTimelineFrame requestedFrame: Int64) throws -> PlaybackLocation? {
        guard requestedFrame >= 0, requestedFrame < totalFrames,
              let segment = segments.first(where: {
                  requestedFrame >= $0.startFrame
                      && requestedFrame < $0.startFrame + $0.durationFrames
              }) else { return nil }

        let offset = requestedFrame - segment.startFrame
        let sourceTime = try TimelineTimeMapper(
            timelineRate: timelineFrameRate,
            sourceRate: segment.sourceFrameRate
        ).sourceTime(
            forTimelineFrame: offset,
            sourceStart: segment.sourceRange.start
        )
        return PlaybackLocation(
            clipID: segment.clipID,
            assetID: segment.assetID,
            timelineFrame: requestedFrame,
            timelineTime: try timelineFrameRate.time(forFrame: requestedFrame),
            clipFrameOffset: offset,
            sourceTime: sourceTime
        )
    }

    public func location(atTimelineTime time: MediaTime) throws -> PlaybackLocation? {
        let frame = try timelineFrameRate.frameIndex(
            for: time,
            rounding: .towardNegativeInfinity
        )
        return try location(atTimelineFrame: frame)
    }
}

/// AVFoundation objects are constructed and fully configured before this value
/// crosses back to the main actor. They are then treated as immutable.
public final class PlaybackComposition: @unchecked Sendable {
    public let composition: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let audioMix: AVMutableAudioMix
    public let segmentMap: PlaybackSegmentMap

    init(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        audioMix: AVMutableAudioMix,
        segmentMap: PlaybackSegmentMap
    ) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.segmentMap = segmentMap
    }

    @MainActor
    public func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

public struct PlaybackCompositionBuilder: Sendable {
    public init() {}

    public func build(_ request: PlaybackBuildRequest) async throws -> PlaybackComposition {
        guard let format = request.project.timelineFormat else {
            throw PlaybackCompositionError.missingTimelineFormat
        }
        let segmentMap = try PlaybackSegmentMap(project: request.project)
        let assetsByID = Dictionary(
            uniqueKeysWithValues: request.project.mediaLibrary.map { ($0.id, $0) }
        )
        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PlaybackCompositionError.couldNotCreateVideoTrack
        }

        var videoInstructions: [AVMutableVideoCompositionInstruction] = []
        var compositionAudioTracks: [AVMutableCompositionTrack] = []

        for segment in segmentMap.segments {
            try Task.checkCancellation()
            let clip = request.project.clips.first { $0.id == segment.clipID }!
            guard let asset = assetsByID[clip.assetID] else {
                throw TimelineEditError.mediaNotFound(clip.assetID)
            }
            let physicalSource: PlaybackMediaSource
            if let override = request.clipSourceOverrides[clip.id] {
                physicalSource = override
            } else {
                guard let url = request.mediaURLs[asset.id] else {
                    throw PlaybackCompositionError.missingMediaURL(asset.id)
                }
                physicalSource = PlaybackMediaSource(url: url, range: clip.sourceRange)
            }

            let sourceAsset = AVURLAsset(url: physicalSource.url)
            guard let sourceVideo = try await sourceAsset.loadTracks(withMediaType: .video).first else {
                throw PlaybackCompositionError.missingVideoTrack(asset.id)
            }

            let timelineRange = segment.timelineRange.cmTimeRange
            let sourceRange = physicalSource.range.cmTimeRange
            try compositionVideo.insertTimeRange(sourceRange, of: sourceVideo, at: timelineRange.start)
            if CMTimeCompare(sourceRange.duration, timelineRange.duration) != 0 {
                compositionVideo.scaleTimeRange(
                    CMTimeRange(start: timelineRange.start, duration: sourceRange.duration),
                    toDuration: timelineRange.duration
                )
            }

            if let sourceAudio = try await sourceAsset.loadTracks(withMediaType: .audio).first {
                guard let compositionAudio = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw PlaybackCompositionError.couldNotCreateAudioTrack(clip.id)
                }
                try compositionAudio.insertTimeRange(sourceRange, of: sourceAudio, at: timelineRange.start)
                if CMTimeCompare(sourceRange.duration, timelineRange.duration) != 0 {
                    compositionAudio.scaleTimeRange(
                        CMTimeRange(start: timelineRange.start, duration: sourceRange.duration),
                        toDuration: timelineRange.duration
                    )
                }
                compositionAudioTracks.append(compositionAudio)
            }

            let transform = try await aspectFitTransform(
                sourceTrack: sourceVideo,
                canvas: CGSize(width: format.width, height: format.height)
            )
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideo)
            layer.setTransform(transform, at: timelineRange.start)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = timelineRange
            instruction.backgroundColor = CGColor.black
            instruction.layerInstructions = [layer]
            videoInstructions.append(instruction)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: format.width, height: format.height)
        videoComposition.frameDuration = format.frameRate.frameDuration.cmTime
        videoComposition.instructions = videoInstructions

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = compositionAudioTracks.map {
            AVMutableAudioMixInputParameters(track: $0)
        }

        return PlaybackComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            segmentMap: segmentMap
        )
    }

    private func aspectFitTransform(
        sourceTrack: AVAssetTrack,
        canvas: CGSize
    ) async throws -> CGAffineTransform {
        let naturalSize = try await sourceTrack.load(.naturalSize)
        let preferredTransform = try await sourceTrack.load(.preferredTransform)
        let orientedBounds = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        let orientedSize = orientedBounds.size
        guard orientedSize.width > 0, orientedSize.height > 0 else {
            return preferredTransform
        }
        let scale = min(
            canvas.width / orientedSize.width,
            canvas.height / orientedSize.height
        )
        let normalized = preferredTransform.translatedBy(
            x: -orientedBounds.minX,
            y: -orientedBounds.minY
        )
        let scaled = normalized.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let fitted = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
        return scaled.concatenating(CGAffineTransform(
            translationX: (canvas.width - fitted.width) / 2,
            y: (canvas.height - fitted.height) / 2
        ))
    }
}

private extension MediaTimeRange {
    var cmTimeRange: CMTimeRange {
        CMTimeRange(start: start.cmTime, duration: duration.cmTime)
    }
}
