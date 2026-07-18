import Foundation

public struct ClipStabilizationProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case analyzing
        case renderingPreview
    }

    public let phase: Phase
    public let passIndex: Int
    public let passCount: Int
    public let fraction: Double

    public init(phase: Phase, passIndex: Int, passCount: Int, fraction: Double) {
        self.phase = phase
        self.passIndex = passIndex
        self.passCount = passCount
        self.fraction = min(1, max(0, fraction))
    }
}

public struct ClipStabilizationProcessingResult: Equatable, Sendable {
    public let passes: [StabilizationEffect]
    public let artifacts: [StabilizationPassArtifacts]

    public init(passes: [StabilizationEffect], artifacts: [StabilizationPassArtifacts]) {
        self.passes = passes
        self.artifacts = artifacts
    }
}

public enum ClipStabilizationProcessingError: LocalizedError, Equatable, Sendable {
    case clipNotFound(TimelineClip.ID)
    case mediaNotFound(MediaAsset.ID)
    case sourceURLMissing(MediaAsset.ID)
    case invalidPassConfiguration

    public var errorDescription: String? {
        switch self {
        case let .clipNotFound(id):
            "Timeline clip \(id.uuidString) no longer exists."
        case let .mediaNotFound(id):
            "The source record for media \(id.uuidString) is missing."
        case let .sourceURLMissing(id):
            "The source file for media \(id.uuidString) is unavailable."
        case .invalidPassConfiguration:
            "The stabilization pass configuration is invalid."
        }
    }
}

public struct ClipStabilizationProcessor: Sendable {
    public let cacheStore: ProjectCacheStore
    public let identityBuilder: StabilizationCacheIdentityBuilder
    private let runner: any FFmpegExecuting

    public init(
        cacheStore: ProjectCacheStore = ProjectCacheStore(),
        identityBuilder: StabilizationCacheIdentityBuilder = StabilizationCacheIdentityBuilder(),
        runner: any FFmpegExecuting
    ) {
        self.cacheStore = cacheStore
        self.identityBuilder = identityBuilder
        self.runner = runner
    }

    public func process(
        project: ProjectState,
        clipID: TimelineClip.ID,
        passes: [StabilizationEffect],
        sourceURLs: [MediaAsset.ID: URL],
        installation: FFmpegInstallation,
        progress: @escaping @Sendable (ClipStabilizationProgress) -> Void
    ) async throws -> ClipStabilizationProcessingResult {
        guard let originalClip = project.clips.first(where: { $0.id == clipID }) else {
            throw ClipStabilizationProcessingError.clipNotFound(clipID)
        }
        guard let asset = project.mediaLibrary.first(where: { $0.id == originalClip.assetID }) else {
            throw ClipStabilizationProcessingError.mediaNotFound(originalClip.assetID)
        }
        guard let input = sourceURLs[asset.id] else {
            throw ClipStabilizationProcessingError.sourceURLMissing(asset.id)
        }

        let clip = TimelineClip(
            id: originalClip.id,
            assetID: originalClip.assetID,
            sourceRange: originalClip.sourceRange,
            stabilizationPasses: passes
        )
        var validator = ProjectEditor(project: project)
        do {
            try validator.apply(.setStabilizationPasses(clipID: clipID, passes: passes))
        } catch {
            throw ClipStabilizationProcessingError.invalidPassConfiguration
        }

        let workspace = try SessionWorkspace()
        defer { workspace.removeAll() }
        let sessionID = "stabilization-\(clipID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        var transforms: [StabilizationEffect.ID: URL] = [:]
        var artifacts: [StabilizationPassArtifacts] = []

        for (index, effect) in passes.enumerated() {
            try Task.checkCancellation()
            guard let identities = identityBuilder.identities(
                for: index,
                in: clip,
                asset: asset,
                toolRevision: installation.stabilizationCacheToolRevision
            ) else {
                throw ClipStabilizationProcessingError.invalidPassConfiguration
            }

            let transformArtifact: CacheArtifact
            switch await cacheStore.lookup(projectID: project.id, identity: identities.transforms) {
            case let .hit(cached):
                transformArtifact = cached
            case .stale:
                let temporary = workspace.transformsURL(for: effect.id)
                let duration = Self.seconds(effect.analysisCoverage.duration)
                let arguments = try ClipStabilizationCommandFactory.analysis(
                    input: input,
                    clip: clip,
                    effectIndex: index,
                    precedingTransforms: transforms,
                    outputTransforms: temporary
                )
                _ = try await runner.run(
                    executable: installation.executableURL,
                    arguments: arguments,
                    duration: duration,
                    sessionID: sessionID,
                    phase: "analyze-pass-\(index + 1)",
                    progress: { fraction in
                        progress(.init(
                            phase: .analyzing,
                            passIndex: index,
                            passCount: passes.count,
                            fraction: fraction
                        ))
                    }
                )
                try Task.checkCancellation()
                transformArtifact = try await cacheStore.storeFile(
                    at: temporary,
                    projectID: project.id,
                    identity: identities.transforms,
                    fileExtension: "trf"
                )
            }
            transforms[effect.id] = transformArtifact.url

            let previewArtifact: CacheArtifact
            switch await cacheStore.lookup(projectID: project.id, identity: identities.preview) {
            case let .hit(cached):
                previewArtifact = cached
            case .stale:
                let temporary = workspace.previewURL(for: effect.id)
                let duration = Self.seconds(effect.analysisCoverage.duration)
                let arguments = try ClipStabilizationCommandFactory.preview(
                    input: input,
                    clip: clip,
                    effectIndex: index,
                    transforms: transforms,
                    output: temporary,
                    pixelWidth: identityBuilder.previewPixelWidth
                )
                _ = try await runner.run(
                    executable: installation.executableURL,
                    arguments: arguments,
                    duration: duration,
                    sessionID: sessionID,
                    phase: "preview-pass-\(index + 1)",
                    progress: { fraction in
                        progress(.init(
                            phase: .renderingPreview,
                            passIndex: index,
                            passCount: passes.count,
                            fraction: fraction
                        ))
                    }
                )
                try Task.checkCancellation()
                previewArtifact = try await cacheStore.storeFile(
                    at: temporary,
                    projectID: project.id,
                    identity: identities.preview,
                    fileExtension: "mp4"
                )
            }
            artifacts.append(.init(
                effectID: effect.id,
                transforms: transformArtifact,
                preview: previewArtifact
            ))
        }

        return ClipStabilizationProcessingResult(passes: passes, artifacts: artifacts)
    }

    public func cancel() {
        runner.cancel()
    }

    private static func seconds(_ time: MediaTime) -> TimeInterval {
        Double(time.value) / Double(time.timescale)
    }
}
