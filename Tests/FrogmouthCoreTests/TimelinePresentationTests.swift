import Foundation
import Testing

@testable import FrogmouthCore

@Test func timelineViewportMapsFramesAndPixelsWithoutCumulativePositions() throws {
    let math = TimelineViewportMath()
    let rate = try FrameRate(numerator: 30_000, denominator: 1_001)
    let pixelsPerSecond = 180.0

    for frame in [Int64(0), 1, 29, 30, 1_000, 53_946] {
        let x = try math.x(
            forFrame: frame,
            frameRate: rate,
            pixelsPerSecond: pixelsPerSecond
        )
        let mapped = try math.frame(
            atX: x,
            frameRate: rate,
            pixelsPerSecond: pixelsPerSecond
        )
        #expect(mapped == frame)
    }
}

@Test func fitAndZoomPreserveTheChosenViewportAnchor() throws {
    let math = TimelineViewportMath()
    let duration = try MediaTime(value: 30, timescale: 1)
    let fit = try math.fittedPixelsPerSecond(
        totalDuration: duration,
        viewportWidth: 924,
        minimum: 8,
        maximum: 800
    )
    #expect(fit == 30)

    let offset = try math.zoomedOffset(
        oldOffset: 100,
        oldPixelsPerSecond: 100,
        newPixelsPerSecond: 200,
        anchorInViewport: 300,
        viewportWidth: 800,
        newContentWidth: 2_000
    )
    #expect(offset == 500)
    let oldAnchoredSeconds = (100.0 + 300.0) / 100.0
    let newAnchoredSeconds = (offset + 300.0) / 200.0
    #expect(oldAnchoredSeconds == newAnchoredSeconds)
}

@Test func adaptiveTicksStayLegibleAndSnappingCanBeTemporarilyDisabled() throws {
    let math = TimelineViewportMath()
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let denseStep = try math.adaptiveTickStepFrames(
        frameRate: rate,
        pixelsPerSecond: 240
    )
    let fitStep = try math.adaptiveTickStepFrames(
        frameRate: rate,
        pixelsPerSecond: 12
    )
    #expect(denseStep == 10)
    #expect(fitStep == 300)

    let snapped = try math.snappedFrame(
        proposedFrame: 98,
        boundaryFrames: [0, 100, 220],
        frameRate: rate,
        pixelsPerSecond: 96,
        snappingDisabled: false
    )
    let unsnapped = try math.snappedFrame(
        proposedFrame: 98,
        boundaryFrames: [0, 100, 220],
        frameRate: rate,
        pixelsPerSecond: 96,
        snappingDisabled: true
    )
    #expect(snapped == 100)
    #expect(unsnapped == 98)
}

@Test func emptyAndInvalidViewportInputsAreHandledPredictably() throws {
    let math = TimelineViewportMath()
    #expect(try math.fittedPixelsPerSecond(
        totalDuration: .zero,
        viewportWidth: 800,
        minimum: 10,
        maximum: 500
    ) == 10)
    #expect(throws: TimelinePresentationError.invalidPixelsPerSecond(0)) {
        try math.x(for: .zero, pixelsPerSecond: 0)
    }
    #expect(throws: TimelinePresentationError.invalidViewportWidth(10)) {
        try math.fittedPixelsPerSecond(
            totalDuration: MediaTime(value: 1, timescale: 1),
            viewportWidth: 10,
            minimum: 10,
            maximum: 500
        )
    }
}

@Test func fitScaleKeepsLongFiftyClipTimelinesAndOneFrameClipsAddressable() throws {
    let math = TimelineViewportMath()
    let rate = try FrameRate(numerator: 60, denominator: 1)
    let duration = try MediaTime(value: 1_800, timescale: 1)
    let fit = try math.fittedPixelsPerSecond(
        totalDuration: duration,
        viewportWidth: 924,
        minimum: 0.25,
        maximum: 800
    )
    let totalWidth = try math.x(for: duration, pixelsPerSecond: fit)
    let oneFrameWidth = try math.x(
        forFrame: 1,
        frameRate: rate,
        pixelsPerSecond: fit
    )
    #expect(totalWidth == 900)
    #expect(oneFrameWidth > 0)

    let clipDurationFrames: Int64 = 2_160
    let starts = try (0..<50).map { index in
        try math.x(
            forFrame: Int64(index) * clipDurationFrames,
            frameRate: rate,
            pixelsPerSecond: fit
        )
    }
    #expect(starts.count == 50)
    #expect(zip(starts, starts.dropFirst()).allSatisfy { $0.0 < $0.1 })
}
