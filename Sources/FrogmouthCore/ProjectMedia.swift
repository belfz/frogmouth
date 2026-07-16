import Darwin
import Foundation

public struct MissingMediaSource: Equatable, Sendable {
    public let assetID: MediaAsset.ID
    public let attemptedPaths: [String]

    public init(assetID: MediaAsset.ID, attemptedPaths: [String]) {
        self.assetID = assetID
        self.attemptedPaths = attemptedPaths
    }
}

public struct ProjectMediaValidationIssue: Equatable, Sendable {
    public let assetID: MediaAsset.ID
    public let path: String
    public let reason: String

    public init(assetID: MediaAsset.ID, path: String, reason: String) {
        self.assetID = assetID
        self.path = path
        self.reason = reason
    }
}

public enum ProjectMediaError: LocalizedError, Equatable, Sendable {
    case missingSources([MissingMediaSource])
    case fingerprintFailed(path: String, errorCode: Int32)
    case notRegularFile(String)
    case invalidDimensions(path: String, width: Int, height: Int)
    case incompatibleColour(path: String, mismatches: [ColourMismatch])
    case invalidChangedSources([ProjectMediaValidationIssue])
    case invalidProject(String)

    public var errorDescription: String? {
        switch self {
        case let .missingSources(sources):
            let paths = sources.map { source in
                source.attemptedPaths.joined(separator: " or ")
            }.joined(separator: "\n")
            return "The project cannot be opened because these source files are missing:\n\(paths)\nRestore the files at one of the listed paths and try again."
        case let .fingerprintFailed(path, errorCode):
            return "frogmouth could not inspect the file identity for \(path) (system error \(errorCode))."
        case let .notRegularFile(path):
            return "The media path is not a regular file: \(path)"
        case let .invalidDimensions(path, width, height):
            return "The media has invalid dimensions \(width)×\(height): \(path)"
        case let .incompatibleColour(path, mismatches):
            let details = mismatches.map { mismatch in
                let property = mismatch.property
                return "\(property.displayName) (timeline: \(property.describe(mismatch.timelineValue)); clip: \(property.describe(mismatch.clipValue)))"
            }.joined(separator: ", ")
            return "\(path) cannot be added because its colour metadata does not match the timeline: \(details). frogmouth does not convert colour spaces yet. Choose a clip with matching colour metadata."
        case let .invalidChangedSources(issues):
            let details = issues.map { "\($0.path): \($0.reason)" }.joined(separator: "\n")
            return "The project cannot be opened because changed source files invalidate existing edits:\n\(details)\nFix or restore the listed files and try again."
        case let .invalidProject(reason):
            return "The project cannot be opened because its timeline is invalid: \(reason)"
        }
    }
}

public struct ProjectMediaResolver: Sendable {
    public init() {}

    public func candidates(
        for reference: MediaPathReference,
        projectURL: URL
    ) -> [URL] {
        var candidates: [URL] = []
        if let relativePath = reference.relativeToProject,
           !relativePath.isEmpty,
           !(relativePath as NSString).isAbsolutePath {
            candidates.append(
                projectURL.deletingLastPathComponent()
                    .appendingPathComponent(relativePath)
                    .standardizedFileURL
            )
        }
        if !reference.absoluteFallback.isEmpty,
           (reference.absoluteFallback as NSString).isAbsolutePath {
            candidates.append(
                URL(fileURLWithPath: reference.absoluteFallback).standardizedFileURL
            )
        }

        var seenPaths: Set<String> = []
        return candidates.filter { seenPaths.insert($0.path).inserted }
    }

    public func resolve(
        _ reference: MediaPathReference,
        projectURL: URL
    ) -> URL? {
        candidates(for: reference, projectURL: projectURL).first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ) && !isDirectory.boolValue
        }
    }
}

public protocol MediaFingerprinting: Sendable {
    func fingerprint(url: URL) throws -> MediaFingerprint
}

public struct MediaFingerprinter: MediaFingerprinting {
    public init() {}

    public func fingerprint(url: URL) throws -> MediaFingerprint {
        var information = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &information)
        }
        guard status == 0 else {
            throw ProjectMediaError.fingerprintFailed(path: url.path, errorCode: errno)
        }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            throw ProjectMediaError.notRegularFile(url.path)
        }
        let seconds = Int64(information.st_mtimespec.tv_sec)
        let nanos = Int64(information.st_mtimespec.tv_nsec)
        let scaled = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !scaled.overflow else {
            throw ProjectMediaError.fingerprintFailed(path: url.path, errorCode: EOVERFLOW)
        }
        let timestamp = scaled.partialValue.addingReportingOverflow(nanos)
        guard !timestamp.overflow else {
            throw ProjectMediaError.fingerprintFailed(path: url.path, errorCode: EOVERFLOW)
        }
        return MediaFingerprint(
            fileSize: Int64(information.st_size),
            modificationTimeNanoseconds: timestamp.partialValue
        )
    }
}

public protocol ProjectMediaFactsInspecting: Sendable {
    func inspect(url: URL) async throws -> PersistedMediaFacts
}

public struct AVProjectMediaFactsInspector: ProjectMediaFactsInspecting {
    private let mediaInspector: any MediaInspecting

    public init(mediaInspector: any MediaInspecting = MediaInspector()) {
        self.mediaInspector = mediaInspector
    }

    public func inspect(url: URL) async throws -> PersistedMediaFacts {
        let info = try await mediaInspector.inspect(url: url)
        guard info.videoBitrate.isFinite,
              info.videoBitrate >= 0,
              info.videoBitrate <= Double(Int64.max) else {
            throw FrogmouthError.unsupportedMedia("The reported video bitrate is invalid.")
        }
        return PersistedMediaFacts(
            duration: info.exactDuration,
            width: info.width,
            height: info.height,
            frameRate: info.exactFrameRate,
            videoBitrate: Int64(info.videoBitrate.rounded()),
            videoCodec: info.videoCodec,
            audioCodec: info.audioCodec,
            audioSampleRate: info.audioSampleRate.map { Int($0.rounded()) },
            audioChannelCount: info.audioChannelCount,
            colour: info.colour
        )
    }
}

public struct TimelineConformanceFacts: Equatable, Sendable {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let scaledWidth: Int
    public let scaledHeight: Int
    public let padLeft: Int
    public let padRight: Int
    public let padTop: Int
    public let padBottom: Int
    public let requiresFrameRateConformance: Bool
    public let requiresAudioResampling: Bool
    public let requiresAudioChannelConformance: Bool
}

public struct TimelineCompatibilityValidator: Sendable {
    public init() {}

    public func validate(
        asset: MediaAsset,
        against format: TimelineFormat
    ) throws -> TimelineConformanceFacts {
        let mismatches = ColourCompatibility.mismatches(
            timeline: format.colour,
            clip: asset.inspected.colour
        )
        guard mismatches.isEmpty else {
            throw ProjectMediaError.incompatibleColour(
                path: asset.path.absoluteFallback,
                mismatches: mismatches
            )
        }
        guard asset.inspected.width > 0,
              asset.inspected.height > 0,
              format.width > 0,
              format.height > 0 else {
            throw ProjectMediaError.invalidDimensions(
                path: asset.path.absoluteFallback,
                width: asset.inspected.width,
                height: asset.inspected.height
            )
        }

        let sourceWidth = Int64(asset.inspected.width)
        let sourceHeight = Int64(asset.inspected.height)
        let canvasWidth = Int64(format.width)
        let canvasHeight = Int64(format.height)
        let sourceCross = sourceWidth.multipliedReportingOverflow(by: canvasHeight)
        let canvasCross = sourceHeight.multipliedReportingOverflow(by: canvasWidth)
        guard !sourceCross.overflow, !canvasCross.overflow else {
            throw ProjectMediaError.invalidDimensions(
                path: asset.path.absoluteFallback,
                width: asset.inspected.width,
                height: asset.inspected.height
            )
        }

        let scaledWidth: Int64
        let scaledHeight: Int64
        if sourceCross.partialValue >= canvasCross.partialValue {
            scaledWidth = canvasWidth
            scaledHeight = try Self.roundedProduct(
                sourceHeight,
                canvasWidth,
                dividedBy: sourceWidth,
                path: asset.path.absoluteFallback
            )
        } else {
            scaledHeight = canvasHeight
            scaledWidth = try Self.roundedProduct(
                sourceWidth,
                canvasHeight,
                dividedBy: sourceHeight,
                path: asset.path.absoluteFallback
            )
        }
        let horizontalPadding = canvasWidth - scaledWidth
        let verticalPadding = canvasHeight - scaledHeight
        let padLeft = horizontalPadding / 2
        let padTop = verticalPadding / 2

        return TimelineConformanceFacts(
            sourceWidth: asset.inspected.width,
            sourceHeight: asset.inspected.height,
            canvasWidth: format.width,
            canvasHeight: format.height,
            scaledWidth: Int(scaledWidth),
            scaledHeight: Int(scaledHeight),
            padLeft: Int(padLeft),
            padRight: Int(horizontalPadding - padLeft),
            padTop: Int(padTop),
            padBottom: Int(verticalPadding - padTop),
            requiresFrameRateConformance: asset.inspected.frameRate != format.frameRate,
            requiresAudioResampling: asset.inspected.audioSampleRate.map {
                $0 != format.audioSampleRate
            } ?? false,
            requiresAudioChannelConformance: asset.inspected.audioChannelCount.map {
                $0 != format.audioChannelCount
            } ?? false
        )
    }

    private static func roundedProduct(
        _ lhs: Int64,
        _ rhs: Int64,
        dividedBy divisor: Int64,
        path: String
    ) throws -> Int64 {
        let product = lhs.multipliedReportingOverflow(by: rhs)
        guard !product.overflow, divisor > 0 else {
            throw ProjectMediaError.invalidDimensions(path: path, width: Int(lhs), height: Int(rhs))
        }
        let quotient = product.partialValue / divisor
        let remainder = product.partialValue % divisor
        let rounded = remainder >= (divisor + 1) / 2 ? quotient + 1 : quotient
        return max(1, rounded)
    }
}

public struct ResolvedProjectMedia: Sendable {
    public let project: ProjectState
    public let resolvedURLs: [MediaAsset.ID: URL]
    public let changedAssetIDs: Set<MediaAsset.ID>
}

public struct ProjectOpenValidator: Sendable {
    private let resolver: ProjectMediaResolver
    private let fingerprinter: any MediaFingerprinting
    private let inspector: any ProjectMediaFactsInspecting
    private let compatibilityValidator: TimelineCompatibilityValidator

    public init(
        resolver: ProjectMediaResolver = ProjectMediaResolver(),
        fingerprinter: any MediaFingerprinting = MediaFingerprinter(),
        inspector: any ProjectMediaFactsInspecting = AVProjectMediaFactsInspector(),
        compatibilityValidator: TimelineCompatibilityValidator = TimelineCompatibilityValidator()
    ) {
        self.resolver = resolver
        self.fingerprinter = fingerprinter
        self.inspector = inspector
        self.compatibilityValidator = compatibilityValidator
    }

    public func validate(
        project: ProjectState,
        projectURL: URL
    ) async throws -> ResolvedProjectMedia {
        var resolvedURLs: [MediaAsset.ID: URL] = [:]
        var missing: [MissingMediaSource] = []
        for asset in project.mediaLibrary {
            if let resolved = resolver.resolve(asset.path, projectURL: projectURL) {
                resolvedURLs[asset.id] = resolved
            } else {
                missing.append(MissingMediaSource(
                    assetID: asset.id,
                    attemptedPaths: resolver.candidates(
                        for: asset.path,
                        projectURL: projectURL
                    ).map(\.path)
                ))
            }
        }
        guard missing.isEmpty else { throw ProjectMediaError.missingSources(missing) }

        var candidate = project
        var changedAssetIDs: Set<MediaAsset.ID> = []
        var issues: [ProjectMediaValidationIssue] = []
        for index in candidate.mediaLibrary.indices {
            let asset = candidate.mediaLibrary[index]
            guard let url = resolvedURLs[asset.id] else { continue }
            let currentFingerprint = try fingerprinter.fingerprint(url: url)
            guard currentFingerprint != asset.fingerprint else { continue }
            do {
                let facts = try await inspector.inspect(url: url)
                candidate.mediaLibrary[index].fingerprint = currentFingerprint
                candidate.mediaLibrary[index].inspected = facts
                changedAssetIDs.insert(asset.id)
            } catch {
                issues.append(ProjectMediaValidationIssue(
                    assetID: asset.id,
                    path: url.path,
                    reason: "Reinspection failed: \(error.localizedDescription)"
                ))
            }
        }
        guard issues.isEmpty else {
            throw ProjectMediaError.invalidChangedSources(issues)
        }

        var colourValidatedAssets: Set<MediaAsset.ID> = []
        for clip in candidate.clips {
            guard let asset = candidate.mediaLibrary.first(where: { $0.id == clip.assetID }),
                  let url = resolvedURLs[clip.assetID] else {
                continue
            }
            do {
                try TimelineIndex.validateSourceRange(clip.sourceRange, for: asset)
                if let format = candidate.timelineFormat {
                    let mapper = TimelineTimeMapper(
                        timelineRate: format.frameRate,
                        sourceRate: asset.inspected.frameRate
                    )
                    _ = try mapper.validatedTimelineFrameCount(
                        forSourceDuration: clip.sourceRange.duration
                    )
                    if colourValidatedAssets.insert(asset.id).inserted {
                        _ = try compatibilityValidator.validate(asset: asset, against: format)
                    }
                }
            } catch {
                issues.append(ProjectMediaValidationIssue(
                    assetID: asset.id,
                    path: url.path,
                    reason: "Clip \(clip.id.uuidString): \(error.localizedDescription)"
                ))
            }
        }
        guard issues.isEmpty else {
            throw ProjectMediaError.invalidChangedSources(issues)
        }

        do {
            _ = try TimelineIndex(project: candidate)
        } catch {
            throw ProjectMediaError.invalidProject(error.localizedDescription)
        }
        return ResolvedProjectMedia(
            project: candidate,
            resolvedURLs: resolvedURLs,
            changedAssetIDs: changedAssetIDs
        )
    }
}
