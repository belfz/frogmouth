import Foundation

public enum TimelineTrimEdge: Equatable, Sendable {
    case leading
    case trailing
}

public enum TimelineTrimMappingError: Error, Equatable, Sendable {
    case invalidSourceBounds
    case arithmeticOverflow
}

public struct TimelineTrimMapper: Sendable {
    public init() {}

    public func sourceRange(
        originalRange: MediaTimeRange,
        assetDuration: MediaTime,
        edge: TimelineTrimEdge,
        timelineFrameDelta: Int64,
        timelineRate: FrameRate,
        sourceRate: FrameRate
    ) throws -> MediaTimeRange {
        let originalEnd = try originalRange.end()
        let originalStartFrame = try sourceRate.frameIndex(
            for: originalRange.start,
            rounding: .nearestTiesAwayFromZero
        )
        let originalEndFrame = try sourceRate.frameIndex(
            for: originalEnd,
            rounding: .nearestTiesAwayFromZero
        )
        let assetEndFrame = try sourceRate.frameIndex(
            for: assetDuration,
            rounding: .towardNegativeInfinity
        )
        guard originalStartFrame >= 0,
              originalEndFrame > originalStartFrame,
              assetEndFrame >= originalEndFrame else {
            throw TimelineTrimMappingError.invalidSourceBounds
        }
        let sourceDelta = try TimelineTimeMapper(
            timelineRate: timelineRate,
            sourceRate: sourceRate
        ).sourceFrameIndex(forTimelineFrame: timelineFrameDelta)

        let startFrame: Int64
        let endFrame: Int64
        switch edge {
        case .leading:
            let proposed = try checkedAdd(originalStartFrame, sourceDelta)
            startFrame = min(max(0, proposed), originalEndFrame - 1)
            endFrame = originalEndFrame
        case .trailing:
            let proposed = try checkedAdd(originalEndFrame, sourceDelta)
            startFrame = originalStartFrame
            endFrame = min(max(originalStartFrame + 1, proposed), assetEndFrame)
        }

        let start = try sourceRate.time(forFrame: startFrame)
        let end = try sourceRate.time(forFrame: endFrame)
        return try MediaTimeRange(start: start, duration: end.subtracting(start))
    }

    private func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw TimelineTrimMappingError.arithmeticOverflow }
        return result.partialValue
    }
}
