import Foundation

public enum StabilizationArtifactKind: String, Equatable, Sendable {
    case transforms
    case preview
}

public struct StabilizationPassCacheIdentities: Equatable, Sendable {
    public let transforms: CacheEntryIdentity
    public let preview: CacheEntryIdentity

    public init(transforms: CacheEntryIdentity, preview: CacheEntryIdentity) {
        self.transforms = transforms
        self.preview = preview
    }
}

public struct StabilizationPassArtifacts: Equatable, Sendable {
    public let effectID: StabilizationEffect.ID
    public let transforms: CacheArtifact
    public let preview: CacheArtifact

    public init(
        effectID: StabilizationEffect.ID,
        transforms: CacheArtifact,
        preview: CacheArtifact
    ) {
        self.effectID = effectID
        self.transforms = transforms
        self.preview = preview
    }
}

public enum StabilizationStaleReason: LocalizedError, Equatable, Sendable {
    case validationPending
    case mediaMissing(MediaAsset.ID)
    case duplicateEffectID(StabilizationEffect.ID)
    case unsupportedMode(effectID: StabilizationEffect.ID, mode: StabilizationMode)
    case invalidAnalysisCoverage(effectID: StabilizationEffect.ID)
    case clipOutsideAnalysisCoverage(
        effectID: StabilizationEffect.ID,
        clipRange: MediaTimeRange,
        analysisCoverage: MediaTimeRange
    )
    case processingRevisionChanged(
        effectID: StabilizationEffect.ID,
        analyzedWith: Int,
        current: Int
    )
    case artifactUnavailable(
        effectID: StabilizationEffect.ID,
        kind: StabilizationArtifactKind,
        reason: CacheStaleReason
    )

    public var errorDescription: String? {
        switch self {
        case .validationPending:
            "Checking stabilization cache compatibility."
        case let .mediaMissing(assetID):
            "The stabilized clip references missing media \(assetID.uuidString)."
        case let .duplicateEffectID(effectID):
            "Stabilization pass \(effectID.uuidString) appears more than once."
        case let .unsupportedMode(effectID, mode):
            "Stabilization pass \(effectID.uuidString) uses unsupported mode \(mode.rawValue)."
        case let .invalidAnalysisCoverage(effectID):
            "Stabilization pass \(effectID.uuidString) has invalid analysis coverage."
        case let .clipOutsideAnalysisCoverage(effectID, _, _):
            "The clip extends outside the analyzed range for stabilization pass \(effectID.uuidString). Update stabilization before export."
        case let .processingRevisionChanged(effectID, analyzedWith, current):
            "Stabilization pass \(effectID.uuidString) was processed with revision \(analyzedWith), but this build requires revision \(current). Update stabilization."
        case let .artifactUnavailable(effectID, kind, reason):
            "The \(kind.rawValue) cache for stabilization pass \(effectID.uuidString) is stale: \(reason.localizedDescription)"
        }
    }
}

public enum StabilizationStatus: Equatable, Sendable {
    case none
    case valid
    case stale(StabilizationStaleReason)

    public var blocksExport: Bool {
        if case .stale = self { true } else { false }
    }
}

public struct StabilizationValidation: Equatable, Sendable {
    public let status: StabilizationStatus
    public let artifacts: [StabilizationPassArtifacts]

    public init(status: StabilizationStatus, artifacts: [StabilizationPassArtifacts] = []) {
        self.status = status
        self.artifacts = artifacts
    }
}

public struct StabilizationCacheIdentityBuilder: Sendable {
    public static let currentProcessingRevision = 1
    public static let previewPixelWidth = 1_024

    public let processingRevision: Int
    public let previewPixelWidth: Int

    public init(
        processingRevision: Int = Self.currentProcessingRevision,
        previewPixelWidth: Int = Self.previewPixelWidth
    ) {
        self.processingRevision = processingRevision
        self.previewPixelWidth = previewPixelWidth
    }

    public func identities(
        for effectIndex: Int,
        in clip: TimelineClip,
        asset: MediaAsset,
        toolRevision: String
    ) -> StabilizationPassCacheIdentities? {
        guard clip.stabilizationPasses.indices.contains(effectIndex) else { return nil }
        let effect = clip.stabilizationPasses[effectIndex]
        guard let profile = StabilizationProfile.profile(for: effect.mode) else { return nil }

        var commonParameters = rangeParameters(effect.analysisCoverage, prefix: "analysis")
        commonParameters.append(.init(name: "effect-id", value: canonical(effect.id)))
        commonParameters.append(.init(name: "effect-mode", value: effect.mode.rawValue))
        commonParameters.append(.init(name: "profile-shakiness", value: String(profile.shakiness)))
        commonParameters.append(.init(name: "profile-accuracy", value: String(profile.accuracy)))
        commonParameters.append(.init(name: "profile-step-size", value: String(profile.stepSize)))
        commonParameters.append(.init(name: "profile-smoothing", value: String(profile.smoothing)))
        commonParameters.append(.init(name: "preceding-pass-count", value: String(effectIndex)))

        for (index, preceding) in clip.stabilizationPasses[..<effectIndex].enumerated() {
            let prefix = "preceding-\(index)"
            commonParameters.append(.init(name: "\(prefix)-id", value: canonical(preceding.id)))
            commonParameters.append(.init(name: "\(prefix)-mode", value: preceding.mode.rawValue))
            commonParameters.append(.init(
                name: "\(prefix)-processing-revision",
                value: String(preceding.processingRevision)
            ))
            commonParameters.append(contentsOf: rangeParameters(
                preceding.analysisCoverage,
                prefix: "\(prefix)-analysis"
            ))
        }

        let logicalArtifactID = canonical(effect.id)
        let base = CacheEntryIdentity(
            namespace: "stabilization-transforms",
            logicalArtifactID: logicalArtifactID,
            assetID: asset.id,
            sourceFingerprint: asset.fingerprint,
            processingRevision: processingRevision,
            toolRevision: toolRevision,
            orderedParameters: commonParameters + [
                .init(name: "artifact-format", value: "vidstab-ascii-trf"),
            ]
        )
        let preview = CacheEntryIdentity(
            namespace: "stabilization-preview",
            logicalArtifactID: logicalArtifactID,
            assetID: asset.id,
            sourceFingerprint: asset.fingerprint,
            processingRevision: processingRevision,
            toolRevision: toolRevision,
            orderedParameters: commonParameters + [
                .init(name: "proxy-pixel-width", value: String(previewPixelWidth)),
                .init(name: "proxy-scaling", value: "aspect-preserving"),
                .init(name: "proxy-interpolation", value: "bilinear"),
                .init(name: "proxy-video-codec", value: "hevc-videotoolbox-hvc1"),
                .init(name: "proxy-audio", value: "linked-aac"),
            ]
        )
        return StabilizationPassCacheIdentities(transforms: base, preview: preview)
    }

    private func rangeParameters(
        _ range: MediaTimeRange,
        prefix: String
    ) -> [CacheKeyComponent] {
        [
            .init(name: "\(prefix)-start", value: canonical(range.start)),
            .init(name: "\(prefix)-duration", value: canonical(range.duration)),
        ]
    }

    private func canonical(_ time: MediaTime) -> String {
        "\(time.value)/\(time.timescale)"
    }

    private func canonical(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}

public struct StabilizationStatusResolver: Sendable {
    public let cacheStore: ProjectCacheStore
    public let identityBuilder: StabilizationCacheIdentityBuilder

    public init(
        cacheStore: ProjectCacheStore = ProjectCacheStore(),
        identityBuilder: StabilizationCacheIdentityBuilder = StabilizationCacheIdentityBuilder()
    ) {
        self.cacheStore = cacheStore
        self.identityBuilder = identityBuilder
    }

    public func statuses(
        for project: ProjectState,
        toolRevision: String
    ) async -> [TimelineClip.ID: StabilizationStatus] {
        var result: [TimelineClip.ID: StabilizationStatus] = [:]
        for clip in project.clips {
            guard !Task.isCancelled else { return result }
            result[clip.id] = await validation(
                for: clip,
                in: project,
                toolRevision: toolRevision
            ).status
        }
        return result
    }

    public func validation(
        for clip: TimelineClip,
        in project: ProjectState,
        toolRevision: String
    ) async -> StabilizationValidation {
        guard !clip.stabilizationPasses.isEmpty else {
            return StabilizationValidation(status: .none)
        }
        guard let asset = project.mediaLibrary.first(where: { $0.id == clip.assetID }) else {
            return stale(.mediaMissing(clip.assetID))
        }

        var seenEffectIDs: Set<StabilizationEffect.ID> = []
        for effect in clip.stabilizationPasses {
            guard seenEffectIDs.insert(effect.id).inserted else {
                return stale(.duplicateEffectID(effect.id))
            }
        }

        var artifacts: [StabilizationPassArtifacts] = []
        for (index, effect) in clip.stabilizationPasses.enumerated() {
            guard effect.mode != .none,
                  StabilizationProfile.profile(for: effect.mode) != nil else {
                return stale(.unsupportedMode(effectID: effect.id, mode: effect.mode))
            }
            guard effect.processingRevision == identityBuilder.processingRevision else {
                return stale(.processingRevisionChanged(
                    effectID: effect.id,
                    analyzedWith: effect.processingRevision,
                    current: identityBuilder.processingRevision
                ))
            }
            guard Self.isValidCoverage(effect.analysisCoverage, for: asset) else {
                return stale(.invalidAnalysisCoverage(effectID: effect.id))
            }
            guard Self.contains(effect.analysisCoverage, clip.sourceRange) else {
                return stale(.clipOutsideAnalysisCoverage(
                    effectID: effect.id,
                    clipRange: clip.sourceRange,
                    analysisCoverage: effect.analysisCoverage
                ))
            }
            guard let identities = identityBuilder.identities(
                for: index,
                in: clip,
                asset: asset,
                toolRevision: toolRevision
            ) else {
                return stale(.unsupportedMode(effectID: effect.id, mode: effect.mode))
            }

            let transforms = await cacheStore.lookup(
                projectID: project.id,
                identity: identities.transforms
            )
            guard case let .hit(transformArtifact) = transforms else {
                guard case let .stale(reason) = transforms else { preconditionFailure() }
                return stale(.artifactUnavailable(
                    effectID: effect.id,
                    kind: .transforms,
                    reason: reason
                ))
            }

            let preview = await cacheStore.lookup(
                projectID: project.id,
                identity: identities.preview
            )
            guard case let .hit(previewArtifact) = preview else {
                guard case let .stale(reason) = preview else { preconditionFailure() }
                return stale(.artifactUnavailable(
                    effectID: effect.id,
                    kind: .preview,
                    reason: reason
                ))
            }
            artifacts.append(StabilizationPassArtifacts(
                effectID: effect.id,
                transforms: transformArtifact,
                preview: previewArtifact
            ))
        }
        return StabilizationValidation(status: .valid, artifacts: artifacts)
    }

    public static func coverageStatus(
        for clip: TimelineClip,
        asset: MediaAsset?
    ) -> StabilizationStatus? {
        guard !clip.stabilizationPasses.isEmpty else { return StabilizationStatus.none }
        guard let asset else { return .stale(.mediaMissing(clip.assetID)) }
        for effect in clip.stabilizationPasses {
            guard isValidCoverage(effect.analysisCoverage, for: asset) else {
                return .stale(.invalidAnalysisCoverage(effectID: effect.id))
            }
            guard contains(effect.analysisCoverage, clip.sourceRange) else {
                return .stale(.clipOutsideAnalysisCoverage(
                    effectID: effect.id,
                    clipRange: clip.sourceRange,
                    analysisCoverage: effect.analysisCoverage
                ))
            }
        }
        return nil
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

    private static func contains(
        _ coverage: MediaTimeRange,
        _ clipRange: MediaTimeRange
    ) -> Bool {
        guard let coverageEnd = try? coverage.end(),
              let clipEnd = try? clipRange.end() else { return false }
        return clipRange.start >= coverage.start && clipEnd <= coverageEnd
    }

    private func stale(_ reason: StabilizationStaleReason) -> StabilizationValidation {
        StabilizationValidation(status: .stale(reason))
    }
}
