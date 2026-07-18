import Foundation

public enum StabilizationPassPlanner {
    public static func appending(
        mode: StabilizationMode,
        to clip: TimelineClip,
        processingRevision: Int = StabilizationCacheIdentityBuilder.currentProcessingRevision
    ) -> [StabilizationEffect]? {
        guard mode != .none, StabilizationProfile.profile(for: mode) != nil else { return nil }
        return clip.stabilizationPasses + [StabilizationEffect(
            mode: mode,
            analysisCoverage: clip.sourceRange,
            processingRevision: processingRevision
        )]
    }

    public static func updating(
        _ clip: TimelineClip,
        processingRevision: Int = StabilizationCacheIdentityBuilder.currentProcessingRevision
    ) throws -> [StabilizationEffect] {
        try clip.stabilizationPasses.map { effect in
            StabilizationEffect(
                id: effect.id,
                mode: effect.mode,
                analysisCoverage: try union(effect.analysisCoverage, clip.sourceRange),
                processingRevision: processingRevision
            )
        }
    }

    private static func union(
        _ lhs: MediaTimeRange,
        _ rhs: MediaTimeRange
    ) throws -> MediaTimeRange {
        let start = min(lhs.start, rhs.start)
        let end = max(try lhs.end(), try rhs.end())
        return try MediaTimeRange(start: start, duration: end.subtracting(start))
    }
}

public enum StabilizedPlaybackSourceBuilder {
    public static func source(
        for clip: TimelineClip,
        validation: StabilizationValidation
    ) -> PlaybackMediaSource? {
        guard validation.status == .valid,
              let effect = clip.stabilizationPasses.last,
              let preview = validation.artifacts.last?.preview,
              let relativeStart = try? clip.sourceRange.start.subtracting(
                effect.analysisCoverage.start
              ),
              let range = try? MediaTimeRange(
                start: relativeStart,
                duration: clip.sourceRange.duration
              ) else { return nil }
        return PlaybackMediaSource(url: preview.url, range: range)
    }
}
