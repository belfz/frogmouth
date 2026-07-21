import Foundation

public enum TimelinePresentationError: Error, Equatable, Sendable {
    case invalidPixelsPerSecond(Double)
    case invalidViewportWidth(Double)
}

public struct TimelineViewportMath: Sendable {
    public init() {}

    public func x(
        for time: MediaTime,
        pixelsPerSecond: Double
    ) throws -> Double {
        try validatePixelsPerSecond(pixelsPerSecond)
        return Double(time.value) / Double(time.timescale) * pixelsPerSecond
    }

    public func x(
        forFrame frame: Int64,
        frameRate: FrameRate,
        pixelsPerSecond: Double
    ) throws -> Double {
        try x(for: frameRate.time(forFrame: frame), pixelsPerSecond: pixelsPerSecond)
    }

    public func frame(
        atX x: Double,
        frameRate: FrameRate,
        pixelsPerSecond: Double,
        rounding: MediaTimeRoundingRule = .nearestTiesAwayFromZero
    ) throws -> Int64 {
        try validatePixelsPerSecond(pixelsPerSecond)
        guard x.isFinite else { throw TimelinePresentationError.invalidViewportWidth(x) }
        let frames = max(0, x / pixelsPerSecond)
            * Double(frameRate.numerator) / Double(frameRate.denominator)
        guard frames <= Double(Int64.max) else {
            throw MediaTimeError.arithmeticOverflow
        }
        switch rounding {
        case .towardNegativeInfinity:
            return Int64(frames.rounded(.down))
        case .towardPositiveInfinity:
            return Int64(frames.rounded(.up))
        case .nearestTiesAwayFromZero:
            return Int64(frames.rounded(.toNearestOrAwayFromZero))
        }
    }

    public func fittedPixelsPerSecond(
        totalDuration: MediaTime,
        viewportWidth: Double,
        horizontalPadding: Double = 24,
        minimum: Double,
        maximum: Double
    ) throws -> Double {
        guard viewportWidth.isFinite, viewportWidth > horizontalPadding else {
            throw TimelinePresentationError.invalidViewportWidth(viewportWidth)
        }
        try validatePixelsPerSecond(minimum)
        try validatePixelsPerSecond(maximum)
        let seconds = Double(totalDuration.value) / Double(totalDuration.timescale)
        guard seconds > 0 else { return minimum }
        return min(maximum, max(minimum, (viewportWidth - horizontalPadding) / seconds))
    }

    public func zoomedOffset(
        oldOffset: Double,
        oldPixelsPerSecond: Double,
        newPixelsPerSecond: Double,
        anchorInViewport: Double,
        viewportWidth: Double,
        newContentWidth: Double
    ) throws -> Double {
        try validatePixelsPerSecond(oldPixelsPerSecond)
        try validatePixelsPerSecond(newPixelsPerSecond)
        guard viewportWidth.isFinite, viewportWidth >= 0,
              anchorInViewport.isFinite else {
            throw TimelinePresentationError.invalidViewportWidth(viewportWidth)
        }
        let clampedAnchor = min(max(0, anchorInViewport), viewportWidth)
        let anchoredSeconds = (max(0, oldOffset) + clampedAnchor) / oldPixelsPerSecond
        let proposed = anchoredSeconds * newPixelsPerSecond - clampedAnchor
        let maximumOffset = max(0, newContentWidth - viewportWidth)
        return min(max(0, proposed), maximumOffset)
    }

    public func adaptiveTickStepFrames(
        frameRate: FrameRate,
        pixelsPerSecond: Double,
        minimumMajorTickSpacing: Double = 72
    ) throws -> Int64 {
        try validatePixelsPerSecond(pixelsPerSecond)
        let framesPerSecond = Double(frameRate.numerator) / Double(frameRate.denominator)
        let minimumFrames = max(1, minimumMajorTickSpacing / pixelsPerSecond * framesPerSecond)
        let candidates: [Double] = [
            1, 2, 5, 10, 15, 20, 30,
            60, 120, 300, 600, 900, 1_800,
            3_600, 7_200, 18_000, 36_000,
        ]
        if let candidate = candidates.first(where: { $0 >= minimumFrames }) {
            return Int64(candidate)
        }
        let magnitude = pow(10, floor(log10(minimumFrames)))
        for multiplier in [1.0, 2.0, 5.0, 10.0] {
            let candidate = multiplier * magnitude
            if candidate >= minimumFrames { return Int64(candidate.rounded(.up)) }
        }
        return Int64(minimumFrames.rounded(.up))
    }

    public func snappedFrame(
        proposedFrame: Int64,
        boundaryFrames: [Int64],
        frameRate: FrameRate,
        pixelsPerSecond: Double,
        thresholdPixels: Double = 8,
        snappingDisabled: Bool
    ) throws -> Int64 {
        guard !snappingDisabled else { return proposedFrame }
        let frameWidth = try x(
            forFrame: 1,
            frameRate: frameRate,
            pixelsPerSecond: pixelsPerSecond
        )
        guard frameWidth > 0 else { return proposedFrame }
        let thresholdFrames = max(1, Int64((thresholdPixels / frameWidth).rounded(.up)))
        return boundaryFrames
            .filter { abs($0 - proposedFrame) <= thresholdFrames }
            .min { lhs, rhs in
                let leftDistance = abs(lhs - proposedFrame)
                let rightDistance = abs(rhs - proposedFrame)
                return leftDistance == rightDistance ? lhs < rhs : leftDistance < rightDistance
            } ?? proposedFrame
    }

    private func validatePixelsPerSecond(_ value: Double) throws {
        guard value.isFinite, value > 0 else {
            throw TimelinePresentationError.invalidPixelsPerSecond(value)
        }
    }
}
