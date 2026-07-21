import CoreMedia
import Foundation
import Testing

@testable import FrogmouthCore

@Test func mediaTimeNormalizesAndBridgesCMTimeExactly() throws {
    let time = try MediaTime(value: 120_000, timescale: 60_000)
    let twoSeconds = try MediaTime(value: 2, timescale: 1)
    #expect(time == twoSeconds)
    #expect(time.cmTime == CMTime(value: 2, timescale: 1))
    #expect(try MediaTime(cmTime: CMTime(value: 2_002, timescale: 60_000)) == MediaTime(
        value: 1_001,
        timescale: 30_000
    ))
    #expect(try MediaTime(value: 0, timescale: Int32.max) == .zero)
}

@Test func mediaTimeArithmeticIsExactAndChecked() throws {
    let a = try MediaTime(value: 1, timescale: 24)
    let b = try MediaTime(value: 1_001, timescale: 30_000)
    #expect(try a.adding(b) == MediaTime(value: 2_251, timescale: 30_000))
    #expect(try a.adding(b).subtracting(b) == a)
    #expect(throws: MediaTimeError.arithmeticOverflow) {
        _ = try MediaTime(value: Int64.max, timescale: 1).adding(
            MediaTime(value: 1, timescale: 1)
        )
    }
}

@Test func invalidExactTimesFailPredictably() throws {
    #expect(throws: MediaTimeError.invalidTimescale(0)) {
        _ = try MediaTime(value: 1, timescale: 0)
    }
    #expect(throws: MediaTimeError.invalidTimescale(-1)) {
        _ = try MediaTime(value: 1, timescale: -1)
    }
    #expect(throws: MediaTimeError.invalidFrameRate(numerator: 0, denominator: 1)) {
        _ = try FrameRate(numerator: 0, denominator: 1)
    }
    #expect(throws: MediaTimeError.nonNumericCMTime) {
        _ = try MediaTime(cmTime: .indefinite)
    }
    #expect(throws: MediaTimeError.nonZeroCMTimeEpoch(1)) {
        _ = try MediaTime(cmTime: CMTime(value: 1, timescale: 24, flags: .valid, epoch: 1))
    }
    #expect(throws: MediaTimeError.negativeDuration) {
        _ = try MediaTimeRange(
            start: .zero,
            duration: MediaTime(value: -1, timescale: 24)
        )
    }
}

@Test(arguments: [
    (Int32(24), Int32(1)),
    (25, 1),
    (30, 1),
    (50, 1),
    (60, 1),
    (24_000, 1_001),
    (30_000, 1_001),
    (60_000, 1_001),
])
func supportedFrameRatesRoundTripWithoutDrift(numerator: Int32, denominator: Int32) throws {
    let rate = try FrameRate(numerator: numerator, denominator: denominator)
    let tenHourFrame = Int64(numerator) * 60 * 60 * 10 / Int64(denominator)
    let exactTime = try rate.time(forFrame: tenHourFrame)
    #expect(try rate.frameIndex(
        for: exactTime,
        rounding: .nearestTiesAwayFromZero
    ) == tenHourFrame)

    var accumulated = MediaTime.zero
    for _ in 0..<10_000 {
        accumulated = try accumulated.adding(rate.frameDuration)
    }
    let tenThousandFrames = try rate.time(forFrame: 10_000)
    #expect(accumulated == tenThousandFrames)
}

@Test func frameSnappingUsesExplicitRoundingIncludingNegativeTimes() throws {
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let positive = try MediaTime(value: 5, timescale: 48)
    let negative = try MediaTime(value: -5, timescale: 48)

    #expect(try rate.frameIndex(for: positive, rounding: .towardNegativeInfinity) == 2)
    #expect(try rate.frameIndex(for: positive, rounding: .towardPositiveInfinity) == 3)
    #expect(try rate.frameIndex(for: positive, rounding: .nearestTiesAwayFromZero) == 3)
    #expect(try rate.frameIndex(for: negative, rounding: .towardNegativeInfinity) == -3)
    #expect(try rate.frameIndex(for: negative, rounding: .towardPositiveInfinity) == -2)
    #expect(try rate.frameIndex(for: negative, rounding: .nearestTiesAwayFromZero) == -3)
}

@Test func timelineMapperConformsDurationAndMapsSourceFramesExactly() throws {
    let timelineRate = try FrameRate(numerator: 24, denominator: 1)
    let sourceRate = try FrameRate(numerator: 30_000, denominator: 1_001)
    let mapper = TimelineTimeMapper(timelineRate: timelineRate, sourceRate: sourceRate)
    let thirtySourceFrames = try sourceRate.time(forFrame: 30)

    #expect(try mapper.timelineFrameCount(forSourceDuration: thirtySourceFrames) == 24)
    #expect(try mapper.timelineDuration(forSourceDuration: thirtySourceFrames) == MediaTime(
        value: 1,
        timescale: 1
    ))
    #expect(try mapper.sourceFrameIndex(forTimelineFrame: 12) == 15)
    #expect(try mapper.sourceTime(
        forTimelineFrame: 12,
        sourceStart: sourceRate.time(forFrame: 30)
    ) == sourceRate.time(forFrame: 45))
}

@Test func oneFrameMinimumUsesSnappedTimelineDuration() throws {
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let tooShort = try MediaTimeRange(
        start: .zero,
        duration: MediaTime(value: 1, timescale: 100)
    )
    let oneFrame = try MediaTimeRange(start: .zero, duration: rate.frameDuration)

    #expect(throws: MediaTimeError.shorterThanOneTimelineFrame) {
        _ = try tooShort.validatingOneFrame(at: rate)
    }
    #expect(try oneFrame.validatingOneFrame(at: rate) == oneFrame)
}

@Test func nonDropTimecodeUsesNominalFrameCount() throws {
    let rate24 = try FrameRate(numerator: 24, denominator: 1)
    #expect(try rate24.timecode(forFrame: 90_371) == "01:02:45:11")
    #expect(try rate24.timecode(forFrame: -25) == "-00:00:01:01")

    let rate5994 = try FrameRate(numerator: 60_000, denominator: 1_001)
    #expect(try rate5994.timecode(forFrame: 216_000) == "01:00:00:00")
}

@Test func exactTimeJSONRejectsInvalidPersistedRationals() throws {
    let encoded = try JSONEncoder().encode(MediaTime(value: 2, timescale: 4))
    #expect(try JSONDecoder().decode(MediaTime.self, from: encoded) == MediaTime(
        value: 1,
        timescale: 2
    ))
    let invalid = Data(#"{"value":1,"timescale":0}"#.utf8)
    #expect(throws: MediaTimeError.invalidTimescale(0)) {
        _ = try JSONDecoder().decode(MediaTime.self, from: invalid)
    }
    let negativeRange = Data(
        #"{"start":{"value":0,"timescale":1},"duration":{"value":-1,"timescale":24}}"#.utf8
    )
    #expect(throws: MediaTimeError.negativeDuration) {
        _ = try JSONDecoder().decode(MediaTimeRange.self, from: negativeRange)
    }
}
