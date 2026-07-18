import Foundation

public enum TimelineRenderPlanningError: LocalizedError, Equatable, Sendable {
    case emptyTimeline
    case missingTimelineFormat
    case missingMediaURL(MediaAsset.ID)
    case unrepresentableSourceBoundary(clipID: TimelineClip.ID, time: MediaTime)
    case invalidStabilizationMode(StabilizationEffect.ID)
    case invalidStabilizationCoverage(StabilizationEffect.ID)
    case missingStabilizationTransforms(StabilizationEffect.ID)

    public var errorDescription: String? {
        switch self {
        case .emptyTimeline:
            "The timeline is empty."
        case .missingTimelineFormat:
            "The timeline has no output format."
        case let .missingMediaURL(assetID):
            "The source file for media \(assetID.uuidString) is unavailable."
        case let .unrepresentableSourceBoundary(clipID, time):
            "Clip \(clipID.uuidString) has a source boundary at \(time.value)/\(time.timescale) that is not on a source frame."
        case let .invalidStabilizationMode(effectID):
            "Stabilization pass \(effectID.uuidString) has no render profile."
        case let .invalidStabilizationCoverage(effectID):
            "Stabilization pass \(effectID.uuidString) has invalid or non-nested analysis coverage."
        case let .missingStabilizationTransforms(effectID):
            "The transform cache for stabilization pass \(effectID.uuidString) is unavailable. Update stabilization."
        }
    }
}

public struct TimelineRenderInput: Equatable, Sendable {
    public let index: Int
    public let assetID: MediaAsset.ID
    public let url: URL

    public init(index: Int, assetID: MediaAsset.ID, url: URL) {
        self.index = index
        self.assetID = assetID
        self.url = url
    }
}

public struct StabilizationRenderPass: Equatable, Sendable {
    public let effectID: StabilizationEffect.ID
    public let mode: StabilizationMode
    public let coverageStartFrame: Int64
    public let coverageEndFrame: Int64
    public let transformsURL: URL

    public init(
        effectID: StabilizationEffect.ID,
        mode: StabilizationMode,
        coverageStartFrame: Int64,
        coverageEndFrame: Int64,
        transformsURL: URL
    ) {
        self.effectID = effectID
        self.mode = mode
        self.coverageStartFrame = coverageStartFrame
        self.coverageEndFrame = coverageEndFrame
        self.transformsURL = transformsURL
    }
}

public struct ClipRenderPlan: Equatable, Sendable {
    public let clipID: TimelineClip.ID
    public let assetID: MediaAsset.ID
    public let inputIndex: Int
    public let sourceRange: MediaTimeRange
    public let sourceStartFrame: Int64
    public let sourceEndFrame: Int64
    public let sourceFrameRate: FrameRate
    public let timelineFrameCount: Int64
    public let timelineDuration: MediaTime
    public let hasSourceAudio: Bool
    public let audioFadeInDuration: TimeInterval
    public let audioFadeOutDuration: TimeInterval
    public let stabilizationPasses: [StabilizationRenderPass]

    public init(
        clipID: TimelineClip.ID,
        assetID: MediaAsset.ID,
        inputIndex: Int,
        sourceRange: MediaTimeRange,
        sourceStartFrame: Int64,
        sourceEndFrame: Int64,
        sourceFrameRate: FrameRate,
        timelineFrameCount: Int64,
        timelineDuration: MediaTime,
        hasSourceAudio: Bool,
        audioFadeInDuration: TimeInterval,
        audioFadeOutDuration: TimeInterval,
        stabilizationPasses: [StabilizationRenderPass]
    ) {
        self.clipID = clipID
        self.assetID = assetID
        self.inputIndex = inputIndex
        self.sourceRange = sourceRange
        self.sourceStartFrame = sourceStartFrame
        self.sourceEndFrame = sourceEndFrame
        self.sourceFrameRate = sourceFrameRate
        self.timelineFrameCount = timelineFrameCount
        self.timelineDuration = timelineDuration
        self.hasSourceAudio = hasSourceAudio
        self.audioFadeInDuration = audioFadeInDuration
        self.audioFadeOutDuration = audioFadeOutDuration
        self.stabilizationPasses = stabilizationPasses
    }
}

public struct TimelineRenderPlan: Equatable, Sendable {
    public let projectID: ProjectState.ID
    public let format: TimelineFormat
    public let inputs: [TimelineRenderInput]
    public let clips: [ClipRenderPlan]
    public let totalFrames: Int64
    public let totalDuration: MediaTime
    public let hasAudio: Bool
    public let targetVideoBitrate: Int

    public init(
        projectID: ProjectState.ID,
        format: TimelineFormat,
        inputs: [TimelineRenderInput],
        clips: [ClipRenderPlan],
        totalFrames: Int64,
        totalDuration: MediaTime,
        hasAudio: Bool,
        targetVideoBitrate: Int
    ) {
        self.projectID = projectID
        self.format = format
        self.inputs = inputs
        self.clips = clips
        self.totalFrames = totalFrames
        self.totalDuration = totalDuration
        self.hasAudio = hasAudio
        self.targetVideoBitrate = targetVideoBitrate
    }
}

public struct TimelineRenderRequest: Sendable {
    public let project: ProjectState
    public let mediaURLs: [MediaAsset.ID: URL]
    public let stabilizationTransforms: [TimelineClip.ID: [StabilizationEffect.ID: URL]]

    public init(
        project: ProjectState,
        mediaURLs: [MediaAsset.ID: URL],
        stabilizationTransforms: [TimelineClip.ID: [StabilizationEffect.ID: URL]] = [:]
    ) {
        self.project = project
        self.mediaURLs = mediaURLs
        self.stabilizationTransforms = stabilizationTransforms
    }
}

public struct TimelineRenderPlanner: Sendable {
    public static let audioFadeDuration: TimeInterval = 0.008

    public init() {}

    public func plan(_ request: TimelineRenderRequest) throws -> TimelineRenderPlan {
        let project = request.project
        guard !project.clips.isEmpty else { throw TimelineRenderPlanningError.emptyTimeline }
        guard let format = project.timelineFormat else {
            throw TimelineRenderPlanningError.missingTimelineFormat
        }
        let timelineIndex = try TimelineIndex(project: project)
        let assets = Dictionary(uniqueKeysWithValues: project.mediaLibrary.map { ($0.id, $0) })

        var inputs: [TimelineRenderInput] = []
        var inputIndexByAsset: [MediaAsset.ID: Int] = [:]
        for clip in project.clips where inputIndexByAsset[clip.assetID] == nil {
            guard let url = request.mediaURLs[clip.assetID] else {
                throw TimelineRenderPlanningError.missingMediaURL(clip.assetID)
            }
            let index = inputs.count
            inputs.append(TimelineRenderInput(index: index, assetID: clip.assetID, url: url))
            inputIndexByAsset[clip.assetID] = index
        }

        var clips: [ClipRenderPlan] = []
        for (clipIndex, clip) in project.clips.enumerated() {
            guard let asset = assets[clip.assetID] else {
                throw TimelineEditError.mediaNotFound(clip.assetID)
            }
            _ = try TimelineCompatibilityValidator().validate(asset: asset, against: format)
            guard let inputIndex = inputIndexByAsset[clip.assetID] else {
                throw TimelineRenderPlanningError.missingMediaURL(clip.assetID)
            }
            let sourceBounds = try exactFrameBounds(
                clip.sourceRange,
                rate: asset.inspected.frameRate,
                clipID: clip.id
            )
            let indexEntry = timelineIndex.entries[clipIndex]
            let transforms = request.stabilizationTransforms[clip.id] ?? [:]
            let stabilizationPasses = try renderPasses(
                for: clip,
                asset: asset,
                transforms: transforms
            )
            clips.append(ClipRenderPlan(
                clipID: clip.id,
                assetID: clip.assetID,
                inputIndex: inputIndex,
                sourceRange: clip.sourceRange,
                sourceStartFrame: sourceBounds.start,
                sourceEndFrame: sourceBounds.end,
                sourceFrameRate: asset.inspected.frameRate,
                timelineFrameCount: indexEntry.durationFrames,
                timelineDuration: indexEntry.timelineRange.duration,
                hasSourceAudio: asset.inspected.audioCodec != nil,
                audioFadeInDuration: 0,
                audioFadeOutDuration: 0,
                stabilizationPasses: stabilizationPasses
            ))
        }

        let hasAudio = clips.contains(where: \.hasSourceAudio)
        if hasAudio {
            clips = applyAudioBoundaryPolicy(clips)
        }

        let normalizedPeakBitrate = project.clips.compactMap { clip -> Double? in
            guard let asset = assets[clip.assetID] else { return nil }
            let sourcePixels = Double(asset.inspected.width) * Double(asset.inspected.height)
            let timelinePixels = Double(format.width) * Double(format.height)
            let sourceFPS = Self.framesPerSecond(asset.inspected.frameRate)
            let timelineFPS = Self.framesPerSecond(format.frameRate)
            guard sourcePixels > 0, sourceFPS > 0 else { return nil }
            return Double(asset.inspected.videoBitrate)
                * timelinePixels * timelineFPS
                / (sourcePixels * sourceFPS)
        }.max() ?? 0

        return TimelineRenderPlan(
            projectID: project.id,
            format: format,
            inputs: inputs,
            clips: clips,
            totalFrames: timelineIndex.totalFrames,
            totalDuration: timelineIndex.totalDuration,
            hasAudio: hasAudio,
            targetVideoBitrate: QualityPolicy.targetVideoBitrate(
                sourceBitrate: normalizedPeakBitrate
            )
        )
    }

    private func renderPasses(
        for clip: TimelineClip,
        asset: MediaAsset,
        transforms: [StabilizationEffect.ID: URL]
    ) throws -> [StabilizationRenderPass] {
        var result: [StabilizationRenderPass] = []
        var previousCoverage: MediaTimeRange?
        var seenEffectIDs: Set<StabilizationEffect.ID> = []
        for effect in clip.stabilizationPasses {
            guard seenEffectIDs.insert(effect.id).inserted else {
                throw TimelineRenderPlanningError.invalidStabilizationCoverage(effect.id)
            }
            guard effect.mode != .none,
                  StabilizationProfile.profile(for: effect.mode) != nil else {
                throw TimelineRenderPlanningError.invalidStabilizationMode(effect.id)
            }
            guard Self.isValidCoverage(effect.analysisCoverage, for: asset),
                  Self.contains(effect.analysisCoverage, clip.sourceRange),
                  previousCoverage.map({ Self.contains($0, effect.analysisCoverage) }) ?? true else {
                throw TimelineRenderPlanningError.invalidStabilizationCoverage(effect.id)
            }
            guard let transformsURL = transforms[effect.id] else {
                throw TimelineRenderPlanningError.missingStabilizationTransforms(effect.id)
            }
            let bounds: (start: Int64, end: Int64)
            do {
                bounds = try exactFrameBounds(
                    effect.analysisCoverage,
                    rate: asset.inspected.frameRate,
                    clipID: clip.id
                )
            } catch {
                throw TimelineRenderPlanningError.invalidStabilizationCoverage(effect.id)
            }
            result.append(StabilizationRenderPass(
                effectID: effect.id,
                mode: effect.mode,
                coverageStartFrame: bounds.start,
                coverageEndFrame: bounds.end,
                transformsURL: transformsURL
            ))
            previousCoverage = effect.analysisCoverage
        }
        return result
    }

    private func exactFrameBounds(
        _ range: MediaTimeRange,
        rate: FrameRate,
        clipID: TimelineClip.ID
    ) throws -> (start: Int64, end: Int64) {
        let end = try range.end()
        let startFrame = try exactFrame(for: range.start, rate: rate, clipID: clipID)
        let endFrame = try exactFrame(for: end, rate: rate, clipID: clipID)
        return (startFrame, endFrame)
    }

    private func exactFrame(
        for time: MediaTime,
        rate: FrameRate,
        clipID: TimelineClip.ID
    ) throws -> Int64 {
        let frame = try rate.frameIndex(for: time, rounding: .nearestTiesAwayFromZero)
        guard try rate.time(forFrame: frame) == time else {
            throw TimelineRenderPlanningError.unrepresentableSourceBoundary(
                clipID: clipID,
                time: time
            )
        }
        return frame
    }

    private func applyAudioBoundaryPolicy(_ original: [ClipRenderPlan]) -> [ClipRenderPlan] {
        var result = original
        guard result.count > 1 else { return result }
        for boundary in 0..<(result.count - 1) {
            let left = result[boundary]
            let right = result[boundary + 1]
            let continuous = left.assetID == right.assetID
                && left.sourceEndFrame == right.sourceStartFrame
            guard !continuous else { continue }
            result[boundary] = replacingAudioFades(
                in: left,
                fadeIn: left.audioFadeInDuration,
                fadeOut: Self.boundedFade(for: left, addingFadeIn: false)
            )
            result[boundary + 1] = replacingAudioFades(
                in: right,
                fadeIn: Self.boundedFade(for: right, addingFadeIn: true),
                fadeOut: right.audioFadeOutDuration
            )
        }
        return result
    }

    private func replacingAudioFades(
        in clip: ClipRenderPlan,
        fadeIn: TimeInterval,
        fadeOut: TimeInterval
    ) -> ClipRenderPlan {
        ClipRenderPlan(
            clipID: clip.clipID,
            assetID: clip.assetID,
            inputIndex: clip.inputIndex,
            sourceRange: clip.sourceRange,
            sourceStartFrame: clip.sourceStartFrame,
            sourceEndFrame: clip.sourceEndFrame,
            sourceFrameRate: clip.sourceFrameRate,
            timelineFrameCount: clip.timelineFrameCount,
            timelineDuration: clip.timelineDuration,
            hasSourceAudio: clip.hasSourceAudio,
            audioFadeInDuration: fadeIn,
            audioFadeOutDuration: fadeOut,
            stabilizationPasses: clip.stabilizationPasses
        )
    }

    private static func boundedFade(
        for clip: ClipRenderPlan,
        addingFadeIn: Bool
    ) -> TimeInterval {
        let duration = seconds(clip.timelineDuration)
        let otherFade = addingFadeIn
            ? clip.audioFadeOutDuration
            : clip.audioFadeInDuration
        return min(audioFadeDuration, max(0, duration - otherFade))
    }

    private static func contains(_ parent: MediaTimeRange, _ child: MediaTimeRange) -> Bool {
        guard let parentEnd = try? parent.end(), let childEnd = try? child.end() else {
            return false
        }
        return child.start >= parent.start && childEnd <= parentEnd
    }

    private static func isValidCoverage(
        _ coverage: MediaTimeRange,
        for asset: MediaAsset
    ) -> Bool {
        guard coverage.start >= .zero,
              coverage.duration > .zero,
              let end = try? coverage.end() else { return false }
        return end <= asset.inspected.duration
    }

    private static func seconds(_ time: MediaTime) -> TimeInterval {
        Double(time.value) / Double(time.timescale)
    }

    private static func framesPerSecond(_ rate: FrameRate) -> Double {
        Double(rate.numerator) / Double(rate.denominator)
    }
}
