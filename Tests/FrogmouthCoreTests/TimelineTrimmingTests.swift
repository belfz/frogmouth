import Foundation
import Testing

@testable import FrogmouthCore

@Test func trimMapperConvertsTimelineDragToExactMixedRateSourceFrames() throws {
    let timelineRate = try FrameRate(numerator: 24, denominator: 1)
    let sourceRate = try FrameRate(numerator: 60, denominator: 1)
    let original = try MediaTimeRange(
        start: sourceRate.time(forFrame: 60),
        duration: sourceRate.time(forFrame: 120)
    )
    let assetDuration = try sourceRate.time(forFrame: 240)
    let mapper = TimelineTrimMapper()

    let leading = try mapper.sourceRange(
        originalRange: original,
        assetDuration: assetDuration,
        edge: .leading,
        timelineFrameDelta: 12,
        timelineRate: timelineRate,
        sourceRate: sourceRate
    )
    let trailing = try mapper.sourceRange(
        originalRange: original,
        assetDuration: assetDuration,
        edge: .trailing,
        timelineFrameDelta: 12,
        timelineRate: timelineRate,
        sourceRate: sourceRate
    )

    let expectedLeadingStart = try sourceRate.time(forFrame: 90)
    let leadingEnd = try leading.end()
    let originalEnd = try original.end()
    #expect(leading.start == expectedLeadingStart)
    #expect(leadingEnd == originalEnd)
    #expect(trailing.start == original.start)
    let trailingEnd = try trailing.end()
    let expectedTrailingEnd = try sourceRate.time(forFrame: 210)
    #expect(trailingEnd == expectedTrailingEnd)
}

@Test func trimMapperSupportsOutwardRestorationAndClampsToSourceBounds() throws {
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let original = try MediaTimeRange(
        start: rate.time(forFrame: 24),
        duration: rate.time(forFrame: 48)
    )
    let assetDuration = try rate.time(forFrame: 96)
    let mapper = TimelineTrimMapper()

    let outwardLeading = try mapper.sourceRange(
        originalRange: original,
        assetDuration: assetDuration,
        edge: .leading,
        timelineFrameDelta: -100,
        timelineRate: rate,
        sourceRate: rate
    )
    let outwardTrailing = try mapper.sourceRange(
        originalRange: original,
        assetDuration: assetDuration,
        edge: .trailing,
        timelineFrameDelta: 100,
        timelineRate: rate,
        sourceRate: rate
    )
    let collapsedLeading = try mapper.sourceRange(
        originalRange: original,
        assetDuration: assetDuration,
        edge: .leading,
        timelineFrameDelta: 100,
        timelineRate: rate,
        sourceRate: rate
    )

    #expect(outwardLeading.start == .zero)
    let outwardLeadingEnd = try outwardLeading.end()
    let originalEnd = try original.end()
    let outwardTrailingEnd = try outwardTrailing.end()
    #expect(outwardLeadingEnd == originalEnd)
    #expect(outwardTrailingEnd == assetDuration)
    #expect(collapsedLeading.duration == rate.frameDuration)
}

@Test func trimMapperRejectsRangesOutsideTheDeclaredSource() throws {
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let invalid = try MediaTimeRange(
        start: rate.time(forFrame: 24),
        duration: rate.time(forFrame: 48)
    )
    #expect(throws: TimelineTrimMappingError.invalidSourceBounds) {
        try TimelineTrimMapper().sourceRange(
            originalRange: invalid,
            assetDuration: rate.time(forFrame: 60),
            edge: .trailing,
            timelineFrameDelta: 0,
            timelineRate: rate,
            sourceRate: rate
        )
    }
}
