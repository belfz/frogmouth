import Foundation

public enum QualityPolicy {
    public static let referenceMinimumBitrate = 35_000_000
    public static let maximumBitrate = 80_000_000
    public static let sourceMultiplier = 0.60
    public static let referenceWidth = 4_096
    public static let referenceHeight = 2_160
    public static let referenceFramesPerSecond = 24.0

    public static func targetVideoBitrate(
        sourceBitrate: Double,
        outputWidth: Int,
        outputHeight: Int,
        outputFramesPerSecond: Double
    ) -> Int {
        let referencePixelRate = Double(referenceWidth)
            * Double(referenceHeight)
            * referenceFramesPerSecond
        let outputPixelRate = Double(max(0, outputWidth))
            * Double(max(0, outputHeight))
            * max(0, outputFramesPerSecond)
        let pixelRateScale = min(1, outputPixelRate / referencePixelRate)
        let scaledMinimum = Double(referenceMinimumBitrate) * pixelRateScale

        // A source-relative target preserves the existing Canon/4K policy. The
        // scaled floor protects lower-resolution exports without applying a
        // 4K-sized minimum, and a known source rate caps that floor so an
        // already-efficient source is never expanded merely to reach it.
        let knownSourceBitrate = max(0, sourceBitrate)
        let effectiveMinimum = knownSourceBitrate > 0
            ? min(scaledMinimum, knownSourceBitrate)
            : scaledMinimum
        let proposed = max(
            knownSourceBitrate * sourceMultiplier,
            effectiveMinimum
        )
        return min(maximumBitrate, Int(proposed.rounded()))
    }
}
