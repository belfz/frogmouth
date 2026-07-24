import Foundation

public struct MediaPathReference: Codable, Equatable, Hashable, Sendable {
    public var relativeToProject: String?
    public var absoluteFallback: String

    public init(relativeToProject: String?, absoluteFallback: String) {
        self.relativeToProject = relativeToProject
        self.absoluteFallback = absoluteFallback
    }
}

public struct MediaFingerprint: Codable, Equatable, Hashable, Sendable {
    public var fileSize: Int64
    public var modificationTimeNanoseconds: Int64

    public init(fileSize: Int64, modificationTimeNanoseconds: Int64) {
        self.fileSize = fileSize
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
    }
}

public struct PersistedMediaFacts: Codable, Equatable, Hashable, Sendable {
    public var duration: MediaTime
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate
    public var videoBitrate: Int64
    public var videoCodec: String
    public var audioCodec: String?
    public var audioSampleRate: Int?
    public var audioChannelCount: Int?
    public var colour: VideoColourMetadata

    public init(
        duration: MediaTime,
        width: Int,
        height: Int,
        frameRate: FrameRate,
        videoBitrate: Int64,
        videoCodec: String,
        audioCodec: String?,
        audioSampleRate: Int?,
        audioChannelCount: Int?,
        colour: VideoColourMetadata
    ) {
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoBitrate = videoBitrate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
        self.colour = colour
    }
}

public struct MediaAsset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var path: MediaPathReference
    public var fingerprint: MediaFingerprint
    public var inspected: PersistedMediaFacts

    public init(
        id: UUID = UUID(),
        path: MediaPathReference,
        fingerprint: MediaFingerprint,
        inspected: PersistedMediaFacts
    ) {
        self.id = id
        self.path = path
        self.fingerprint = fingerprint
        self.inspected = inspected
    }
}

public struct TimelineFormat: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate
    public var colour: VideoColourMetadata
    public var audioSampleRate: Int
    public var audioChannelCount: Int

    public init(
        width: Int,
        height: Int,
        frameRate: FrameRate,
        colour: VideoColourMetadata,
        audioSampleRate: Int,
        audioChannelCount: Int
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.colour = colour
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
    }
}

public struct StabilizationEffect: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var mode: StabilizationMode
    public var analysisCoverage: MediaTimeRange
    public var processingRevision: Int

    public init(
        id: UUID = UUID(),
        mode: StabilizationMode,
        analysisCoverage: MediaTimeRange,
        processingRevision: Int
    ) {
        self.id = id
        self.mode = mode
        self.analysisCoverage = analysisCoverage
        self.processingRevision = processingRevision
    }
}

public enum VideoFadeEdge: String, Codable, Equatable, Hashable, Sendable {
    case fadeIn
    case fadeOut
}

public struct VideoFade: Codable, Equatable, Hashable, Sendable {
    public static let defaultDurationMilliseconds: Int64 = 1_000

    public var durationMilliseconds: Int64

    public init(durationMilliseconds: Int64) {
        self.durationMilliseconds = durationMilliseconds
    }

    public var duration: MediaTime {
        get throws {
            try MediaTime(value: durationMilliseconds, timescale: 1_000)
        }
    }
}

public struct TimelineClip: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var assetID: MediaAsset.ID
    public var sourceRange: MediaTimeRange
    public var stabilizationPasses: [StabilizationEffect]
    public var videoFadeIn: VideoFade?
    public var videoFadeOut: VideoFade?

    public init(
        id: UUID = UUID(),
        assetID: MediaAsset.ID,
        sourceRange: MediaTimeRange,
        stabilizationPasses: [StabilizationEffect] = [],
        videoFadeIn: VideoFade? = nil,
        videoFadeOut: VideoFade? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.sourceRange = sourceRange
        self.stabilizationPasses = stabilizationPasses
        self.videoFadeIn = videoFadeIn
        self.videoFadeOut = videoFadeOut
    }

    public func videoFade(at edge: VideoFadeEdge) -> VideoFade? {
        switch edge {
        case .fadeIn: videoFadeIn
        case .fadeOut: videoFadeOut
        }
    }
}

public enum ProjectSchemaError: LocalizedError, Equatable, Sendable {
    case missingSchemaVersion
    case invalidSchemaVersion
    case unsupportedVersion(found: Int, supported: Int)
    case noMigration(fromVersion: Int)
    case invalidMigration(expectedVersion: Int, actualVersion: Int)

    public var errorDescription: String? {
        switch self {
        case .missingSchemaVersion:
            "This is not a valid frogmouth project because schemaVersion is missing."
        case .invalidSchemaVersion:
            "This is not a valid frogmouth project because schemaVersion is not an integer."
        case let .unsupportedVersion(found, supported) where found > supported:
            "This project uses newer schema version \(found); this frogmouth build supports version \(supported). Update frogmouth and try again."
        case let .unsupportedVersion(found, supported):
            "This project uses unsupported schema version \(found); this frogmouth build supports version \(supported)."
        case let .noMigration(fromVersion):
            "No project migration is available from schema version \(fromVersion)."
        case let .invalidMigration(expectedVersion, actualVersion):
            "A project migration produced schema version \(actualVersion) instead of \(expectedVersion)."
        }
    }
}

public struct ProjectState: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 2

    public private(set) var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var mediaLibrary: [MediaAsset]
    public var timelineFormat: TimelineFormat?
    public var clips: [TimelineClip]

    public init(
        id: UUID = UUID(),
        name: String,
        mediaLibrary: [MediaAsset] = [],
        timelineFormat: TimelineFormat? = nil,
        clips: [TimelineClip] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.mediaLibrary = mediaLibrary
        self.timelineFormat = timelineFormat
        self.clips = clips
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case mediaLibrary
        case timelineFormat
        case clips
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProjectSchemaError.unsupportedVersion(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        self.schemaVersion = schemaVersion
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mediaLibrary = try container.decode([MediaAsset].self, forKey: .mediaLibrary)
        timelineFormat = try container.decodeIfPresent(TimelineFormat.self, forKey: .timelineFormat)
        clips = try container.decode([TimelineClip].self, forKey: .clips)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(mediaLibrary, forKey: .mediaLibrary)
        try container.encodeIfPresent(timelineFormat, forKey: .timelineFormat)
        try container.encode(clips, forKey: .clips)
    }
}

public protocol ProjectMigration: Sendable {
    var sourceVersion: Int { get }
    var destinationVersion: Int { get }
    func migrate(_ projectData: Data) throws -> Data
}

public struct ProjectMigrationPipeline: Sendable {
    public let migrations: [any ProjectMigration]

    public init(migrations: [any ProjectMigration] = []) {
        self.migrations = migrations
    }

    public func migrateToCurrentSchema(_ projectData: Data) throws -> Data {
        var data = projectData
        var version = try Self.schemaVersion(in: data)
        guard version <= ProjectState.currentSchemaVersion else {
            throw ProjectSchemaError.unsupportedVersion(
                found: version,
                supported: ProjectState.currentSchemaVersion
            )
        }

        while version < ProjectState.currentSchemaVersion {
            guard let migration = migrations.first(where: { $0.sourceVersion == version }) else {
                throw ProjectSchemaError.noMigration(fromVersion: version)
            }
            data = try migration.migrate(data)
            let actualVersion = try Self.schemaVersion(in: data)
            guard actualVersion == migration.destinationVersion,
                  actualVersion > version,
                  actualVersion <= ProjectState.currentSchemaVersion else {
                throw ProjectSchemaError.invalidMigration(
                    expectedVersion: migration.destinationVersion,
                    actualVersion: actualVersion
                )
            }
            version = actualVersion
        }
        return data
    }

    private struct SchemaHeader: Decodable {
        let schemaVersion: Int
    }

    private static func schemaVersion(in data: Data) throws -> Int {
        do {
            return try JSONDecoder().decode(SchemaHeader.self, from: data).schemaVersion
        } catch DecodingError.keyNotFound {
            throw ProjectSchemaError.missingSchemaVersion
        } catch DecodingError.typeMismatch {
            throw ProjectSchemaError.invalidSchemaVersion
        } catch DecodingError.valueNotFound {
            throw ProjectSchemaError.invalidSchemaVersion
        }
    }
}

public struct ProjectJSONCodec: Sendable {
    public let migrationPipeline: ProjectMigrationPipeline

    public init(migrations: [any ProjectMigration] = []) {
        migrationPipeline = ProjectMigrationPipeline(migrations: migrations)
    }

    public func encode(_ project: ProjectState) throws -> Data {
        _ = try TimelineIndex(project: project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(project)
    }

    public func decode(_ data: Data) throws -> ProjectState {
        let migrated = try migrationPipeline.migrateToCurrentSchema(data)
        let project = try JSONDecoder().decode(ProjectState.self, from: migrated)
        _ = try TimelineIndex(project: project)
        return project
    }
}
