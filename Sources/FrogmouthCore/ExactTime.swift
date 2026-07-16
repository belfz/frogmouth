import CoreMedia
import Foundation

public enum MediaTimeError: Error, Equatable, Sendable {
    case invalidTimescale(Int32)
    case invalidFrameRate(numerator: Int32, denominator: Int32)
    case nonNumericCMTime
    case nonZeroCMTimeEpoch(Int64)
    case arithmeticOverflow
    case negativeDuration
    case shorterThanOneTimelineFrame
}

public enum MediaTimeRoundingRule: String, Codable, Equatable, Sendable {
    case towardNegativeInfinity
    case towardPositiveInfinity
    case nearestTiesAwayFromZero
}

public struct MediaTime: Codable, Hashable, Comparable, Sendable {
    public let value: Int64
    public let timescale: Int32

    public init(value: Int64, timescale: Int32) throws {
        guard timescale > 0 else { throw MediaTimeError.invalidTimescale(timescale) }
        if value == 0 {
            self.value = 0
            self.timescale = 1
            return
        }

        let divisor = Self.greatestCommonDivisor(value.magnitude, UInt64(timescale))
        self.value = value / Int64(divisor)
        self.timescale = Int32(UInt64(timescale) / divisor)
    }

    public init(cmTime: CMTime) throws {
        guard cmTime.isNumeric else { throw MediaTimeError.nonNumericCMTime }
        guard cmTime.epoch == 0 else { throw MediaTimeError.nonZeroCMTimeEpoch(cmTime.epoch) }
        try self.init(value: cmTime.value, timescale: cmTime.timescale)
    }

    public static let zero = MediaTime(uncheckedValue: 0, timescale: 1)

    public var cmTime: CMTime {
        CMTime(value: value, timescale: timescale)
    }

    public func adding(_ other: MediaTime) throws -> MediaTime {
        let scaleGCD = Self.greatestCommonDivisor(UInt64(timescale), UInt64(other.timescale))
        let leftMultiplier = Int64(UInt64(other.timescale) / scaleGCD)
        let rightMultiplier = Int64(UInt64(timescale) / scaleGCD)
        let commonScale = try Self.checkedMultiply(Int64(timescale), leftMultiplier)
        guard commonScale <= Int64(Int32.max) else { throw MediaTimeError.arithmeticOverflow }

        let leftValue = try Self.checkedMultiply(value, leftMultiplier)
        let rightValue = try Self.checkedMultiply(other.value, rightMultiplier)
        let sum = try Self.checkedAdd(leftValue, rightValue)
        return try MediaTime(value: sum, timescale: Int32(commonScale))
    }

    public func subtracting(_ other: MediaTime) throws -> MediaTime {
        let negated = Int64.zero.subtractingReportingOverflow(other.value)
        guard !negated.overflow else { throw MediaTimeError.arithmeticOverflow }
        return try adding(MediaTime(value: negated.partialValue, timescale: other.timescale))
    }

    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool {
        CMTimeCompare(lhs.cmTime, rhs.cmTime) < 0
    }

    fileprivate init(uncheckedValue: Int64, timescale: Int32) {
        value = uncheckedValue
        self.timescale = timescale
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case timescale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int64.self, forKey: .value)
        let timescale = try container.decode(Int32.self, forKey: .timescale)
        try self.init(value: value, timescale: timescale)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(timescale, forKey: .timescale)
    }

    fileprivate static func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw MediaTimeError.arithmeticOverflow }
        return result.partialValue
    }

    fileprivate static func checkedMultiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw MediaTimeError.arithmeticOverflow }
        return result.partialValue
    }

    fileprivate static func roundedQuotient(
        numerator: Int64,
        denominator: Int64,
        rule: MediaTimeRoundingRule
    ) throws -> Int64 {
        guard denominator > 0 else { throw MediaTimeError.arithmeticOverflow }
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        guard remainder != 0 else { return quotient }

        switch rule {
        case .towardNegativeInfinity:
            return numerator < 0 ? try checkedAdd(quotient, -1) : quotient
        case .towardPositiveInfinity:
            return numerator > 0 ? try checkedAdd(quotient, 1) : quotient
        case .nearestTiesAwayFromZero:
            let remainderMagnitude = remainder.magnitude
            let denominatorMagnitude = UInt64(denominator)
            let half = denominatorMagnitude / 2
            let roundsAway = remainderMagnitude > half
                || (denominatorMagnitude.isMultiple(of: 2) && remainderMagnitude == half)
            guard roundsAway else { return quotient }
            return try checkedAdd(quotient, numerator > 0 ? 1 : -1)
        }
    }

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a
    }
}

public struct MediaTimeRange: Codable, Hashable, Sendable {
    public let start: MediaTime
    public let duration: MediaTime

    public init(start: MediaTime, duration: MediaTime) throws {
        guard duration >= .zero else { throw MediaTimeError.negativeDuration }
        self.start = start
        self.duration = duration
    }

    public func end() throws -> MediaTime {
        try start.adding(duration)
    }

    public func validatingOneFrame(at frameRate: FrameRate) throws -> MediaTimeRange {
        let frameCount = try frameRate.frameIndex(
            for: duration,
            rounding: .nearestTiesAwayFromZero
        )
        guard frameCount >= 1 else { throw MediaTimeError.shorterThanOneTimelineFrame }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case start
        case duration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(MediaTime.self, forKey: .start)
        let duration = try container.decode(MediaTime.self, forKey: .duration)
        try self.init(start: start, duration: duration)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(duration, forKey: .duration)
    }
}

public struct FrameRate: Codable, Hashable, Sendable {
    public let numerator: Int32
    public let denominator: Int32

    public init(numerator: Int32, denominator: Int32) throws {
        guard numerator > 0, denominator > 0 else {
            throw MediaTimeError.invalidFrameRate(numerator: numerator, denominator: denominator)
        }
        let divisor = Self.greatestCommonDivisor(UInt32(numerator), UInt32(denominator))
        self.numerator = Int32(UInt32(numerator) / divisor)
        self.denominator = Int32(UInt32(denominator) / divisor)
    }

    public var frameDuration: MediaTime {
        MediaTime(uncheckedValue: Int64(denominator), timescale: numerator)
    }

    public func time(forFrame frameIndex: Int64) throws -> MediaTime {
        let value = try MediaTime.checkedMultiply(frameIndex, Int64(denominator))
        return try MediaTime(value: value, timescale: numerator)
    }

    public func frameIndex(
        for time: MediaTime,
        rounding: MediaTimeRoundingRule
    ) throws -> Int64 {
        let numerator = try MediaTime.checkedMultiply(time.value, Int64(self.numerator))
        let denominator = try MediaTime.checkedMultiply(
            Int64(time.timescale),
            Int64(self.denominator)
        )
        return try MediaTime.roundedQuotient(
            numerator: numerator,
            denominator: denominator,
            rule: rounding
        )
    }

    public func snapped(
        _ time: MediaTime,
        rounding: MediaTimeRoundingRule
    ) throws -> MediaTime {
        try self.time(forFrame: frameIndex(for: time, rounding: rounding))
    }

    public func timecode(
        for time: MediaTime,
        rounding: MediaTimeRoundingRule = .nearestTiesAwayFromZero
    ) throws -> String {
        try timecode(forFrame: frameIndex(for: time, rounding: rounding))
    }

    public func timecode(forFrame frameIndex: Int64) throws -> String {
        let magnitude = frameIndex.magnitude
        guard magnitude <= UInt64(Int64.max) else { throw MediaTimeError.arithmeticOverflow }
        let frames = Int64(magnitude)
        let nominalRate = Int64((Int64(numerator) + Int64(denominator) / 2) / Int64(denominator))
        guard nominalRate > 0 else { throw MediaTimeError.arithmeticOverflow }

        let framesPerMinute = try MediaTime.checkedMultiply(nominalRate, 60)
        let framesPerHour = try MediaTime.checkedMultiply(framesPerMinute, 60)
        let hours = frames / framesPerHour
        let afterHours = frames % framesPerHour
        let minutes = afterHours / framesPerMinute
        let afterMinutes = afterHours % framesPerMinute
        let seconds = afterMinutes / nominalRate
        let frame = afterMinutes % nominalRate
        let sign = frameIndex < 0 ? "-" : ""
        return String(format: "%@%02lld:%02lld:%02lld:%02lld", sign, hours, minutes, seconds, frame)
    }

    private enum CodingKeys: String, CodingKey {
        case numerator
        case denominator
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let numerator = try container.decode(Int32.self, forKey: .numerator)
        let denominator = try container.decode(Int32.self, forKey: .denominator)
        try self.init(numerator: numerator, denominator: denominator)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(numerator, forKey: .numerator)
        try container.encode(denominator, forKey: .denominator)
    }

    private static func greatestCommonDivisor(_ lhs: UInt32, _ rhs: UInt32) -> UInt32 {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a
    }
}

public struct TimelineTimeMapper: Equatable, Sendable {
    public let timelineRate: FrameRate
    public let sourceRate: FrameRate

    public init(timelineRate: FrameRate, sourceRate: FrameRate) {
        self.timelineRate = timelineRate
        self.sourceRate = sourceRate
    }

    public func timelineFrameCount(
        forSourceDuration duration: MediaTime,
        rounding: MediaTimeRoundingRule = .nearestTiesAwayFromZero
    ) throws -> Int64 {
        try timelineRate.frameIndex(for: duration, rounding: rounding)
    }

    public func validatedTimelineFrameCount(forSourceDuration duration: MediaTime) throws -> Int64 {
        let count = try timelineFrameCount(forSourceDuration: duration)
        guard count >= 1 else { throw MediaTimeError.shorterThanOneTimelineFrame }
        return count
    }

    public func timelineDuration(forSourceDuration duration: MediaTime) throws -> MediaTime {
        try timelineRate.time(forFrame: validatedTimelineFrameCount(forSourceDuration: duration))
    }

    public func sourceFrameIndex(
        forTimelineFrame timelineFrame: Int64,
        rounding: MediaTimeRoundingRule = .nearestTiesAwayFromZero
    ) throws -> Int64 {
        let timelineTime = try timelineRate.time(forFrame: timelineFrame)
        return try sourceRate.frameIndex(for: timelineTime, rounding: rounding)
    }

    public func sourceTime(
        forTimelineFrame timelineFrame: Int64,
        sourceStart: MediaTime = .zero,
        rounding: MediaTimeRoundingRule = .nearestTiesAwayFromZero
    ) throws -> MediaTime {
        let sourceFrame = try sourceFrameIndex(forTimelineFrame: timelineFrame, rounding: rounding)
        return try sourceStart.adding(sourceRate.time(forFrame: sourceFrame))
    }
}
