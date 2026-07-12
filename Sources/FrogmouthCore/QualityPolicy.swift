import Foundation

public enum QualityPolicy {
    public static let minimumBitrate = 35_000_000
    public static let maximumBitrate = 80_000_000
    public static let sourceMultiplier = 0.60

    public static func targetVideoBitrate(sourceBitrate: Double) -> Int {
        let proposed = Int((sourceBitrate * sourceMultiplier).rounded())
        return min(maximumBitrate, max(minimumBitrate, proposed))
    }
}

