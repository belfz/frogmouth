import CryptoKit
import Foundation

public struct CacheKeyComponent: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct CacheEntryIdentity: Codable, Equatable, Hashable, Sendable {
    public var namespace: String
    public var logicalArtifactID: String
    public var assetID: MediaAsset.ID
    public var sourceFingerprint: MediaFingerprint
    public var processingRevision: Int
    public var toolRevision: String?
    public var orderedParameters: [CacheKeyComponent]

    public init(
        namespace: String,
        logicalArtifactID: String,
        assetID: MediaAsset.ID,
        sourceFingerprint: MediaFingerprint,
        processingRevision: Int,
        toolRevision: String? = nil,
        orderedParameters: [CacheKeyComponent] = []
    ) {
        self.namespace = namespace
        self.logicalArtifactID = logicalArtifactID
        self.assetID = assetID
        self.sourceFingerprint = sourceFingerprint
        self.processingRevision = processingRevision
        self.toolRevision = toolRevision
        self.orderedParameters = orderedParameters
    }
}

public enum CacheKeyError: LocalizedError, Equatable, Sendable {
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .encodingFailed(reason):
            "The cache identity could not be encoded: \(reason)"
        }
    }
}

public struct CacheKeyBuilder: Sendable {
    public init() {}

    public func key(for identity: CacheEntryIdentity) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(identity)
        } catch {
            throw CacheKeyError.encodingFailed(error.localizedDescription)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct CacheManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let key: String
    public let identity: CacheEntryIdentity
    public let artifactFilename: String
    public let artifactByteCount: Int64

    public init(
        key: String,
        identity: CacheEntryIdentity,
        artifactFilename: String,
        artifactByteCount: Int64
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.key = key
        self.identity = identity
        self.artifactFilename = artifactFilename
        self.artifactByteCount = artifactByteCount
    }
}

public struct CacheArtifact: Equatable, Sendable {
    public let key: String
    public let url: URL
    public let byteCount: Int64
    public let manifest: CacheManifest

    public init(key: String, url: URL, byteCount: Int64, manifest: CacheManifest) {
        self.key = key
        self.url = url
        self.byteCount = byteCount
        self.manifest = manifest
    }
}

public enum CacheIdentityField: String, Equatable, Sendable {
    case sourceFingerprint
    case processingRevision
    case toolRevision
    case orderedParameters
}

public enum CacheStaleReason: LocalizedError, Equatable, Sendable {
    case notCached
    case identityChanged([CacheIdentityField])
    case manifestMissing
    case manifestUnreadable(String)
    case unsupportedManifestVersion(Int)
    case keyMismatch(expected: String, actual: String)
    case unsafeArtifactFilename(String)
    case artifactMissing(String)
    case artifactByteCountChanged(expected: Int64, actual: Int64)
    case cacheUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notCached:
            "No compatible cached artifact exists."
        case let .identityChanged(fields):
            "A cached artifact exists, but these identity inputs changed: \(fields.map(\.rawValue).joined(separator: ", "))."
        case .manifestMissing:
            "The cache entry has no manifest."
        case let .manifestUnreadable(reason):
            "The cache manifest is unreadable: \(reason)"
        case let .unsupportedManifestVersion(version):
            "The cache manifest version \(version) is unsupported."
        case let .keyMismatch(expected, actual):
            "The cache manifest key does not match (expected \(expected), found \(actual))."
        case let .unsafeArtifactFilename(filename):
            "The cache manifest contains an unsafe artifact filename: \(filename)"
        case let .artifactMissing(path):
            "The cached artifact is missing: \(path)"
        case let .artifactByteCountChanged(expected, actual):
            "The cached artifact size changed (expected \(expected) bytes, found \(actual))."
        case let .cacheUnreadable(reason):
            "The cache is unreadable: \(reason)"
        }
    }
}

public enum CacheLookupResult: Equatable, Sendable {
    case hit(CacheArtifact)
    case stale(CacheStaleReason)
}

public enum ProjectCacheError: LocalizedError, Equatable, Sendable {
    case invalidFileExtension(String)
    case directoryCreationFailed(path: String, reason: String)
    case manifestEncodingFailed(String)
    case writeFailed(path: String, reason: String)
    case clearFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidFileExtension(fileExtension):
            "The cache artifact extension is invalid: \(fileExtension)"
        case let .directoryCreationFailed(path, reason):
            "The cache directory could not be created at \(path): \(reason)"
        case let .manifestEncodingFailed(reason):
            "The cache manifest could not be encoded: \(reason)"
        case let .writeFailed(path, reason):
            "The cache artifact could not be written at \(path): \(reason)"
        case let .clearFailed(path, reason):
            "The cache could not be cleared at \(path): \(reason)"
        }
    }
}

public actor ProjectCacheStore {
    public static var defaultRootURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("dev.frogmouth.app", isDirectory: true)
    }

    public let rootURL: URL

    private let fileManager: FileManager
    private let keyBuilder: CacheKeyBuilder
    private let writer: any ProjectFileWriting

    public init(
        rootURL: URL = ProjectCacheStore.defaultRootURL,
        fileManager: FileManager = .default,
        keyBuilder: CacheKeyBuilder = CacheKeyBuilder(),
        writer: any ProjectFileWriting = AtomicProjectFileWriter()
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.keyBuilder = keyBuilder
        self.writer = writer
    }

    @discardableResult
    public func store(
        _ data: Data,
        projectID: ProjectState.ID,
        identity: CacheEntryIdentity,
        fileExtension: String
    ) throws -> CacheArtifact {
        let normalizedExtension = try Self.normalizedFileExtension(fileExtension)
        let key = try keyBuilder.key(for: identity)
        let entryURL = entryURL(projectID: projectID, identity: identity, key: key)
        try createDirectory(entryURL)

        let artifactFilename = "artifact-\(UUID().uuidString).\(normalizedExtension)"
        let artifactURL = entryURL.appendingPathComponent(artifactFilename)
        let manifestURL = entryURL.appendingPathComponent("manifest.json")
        let manifest = CacheManifest(
            key: key,
            identity: identity,
            artifactFilename: artifactFilename,
            artifactByteCount: Int64(data.count)
        )
        let manifestData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            manifestData = try encoder.encode(manifest)
        } catch {
            throw ProjectCacheError.manifestEncodingFailed(error.localizedDescription)
        }

        do {
            try writer.write(data, atomicallyTo: artifactURL)
            do {
                try writer.write(manifestData, atomicallyTo: manifestURL)
            } catch {
                try? fileManager.removeItem(at: artifactURL)
                throw error
            }
        } catch {
            throw ProjectCacheError.writeFailed(
                path: entryURL.path,
                reason: error.localizedDescription
            )
        }

        removeSupersededArtifacts(in: entryURL, keeping: artifactFilename)
        return CacheArtifact(
            key: key,
            url: artifactURL,
            byteCount: Int64(data.count),
            manifest: manifest
        )
    }

    public func lookup(
        projectID: ProjectState.ID,
        identity: CacheEntryIdentity
    ) -> CacheLookupResult {
        let key: String
        do {
            key = try keyBuilder.key(for: identity)
        } catch {
            return .stale(.cacheUnreadable(error.localizedDescription))
        }
        let entryURL = entryURL(projectID: projectID, identity: identity, key: key)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: entryURL.path, isDirectory: &isDirectory) else {
            return nearestStaleReason(projectID: projectID, expected: identity)
        }
        guard isDirectory.boolValue else {
            return .stale(.cacheUnreadable("The cache entry is not a directory: \(entryURL.path)"))
        }

        let manifestURL = entryURL.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return .stale(.manifestMissing)
        }
        let manifest: CacheManifest
        do {
            manifest = try JSONDecoder().decode(
                CacheManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            return .stale(.manifestUnreadable(error.localizedDescription))
        }
        guard manifest.schemaVersion == CacheManifest.currentSchemaVersion else {
            return .stale(.unsupportedManifestVersion(manifest.schemaVersion))
        }
        guard manifest.identity == identity else {
            let changed = Self.changedFields(from: manifest.identity, to: identity)
            if changed.isEmpty {
                return .stale(.keyMismatch(expected: key, actual: manifest.key))
            }
            return .stale(.identityChanged(changed))
        }
        guard manifest.key == key else {
            return .stale(.keyMismatch(expected: key, actual: manifest.key))
        }
        guard Self.isSafeArtifactFilename(manifest.artifactFilename) else {
            return .stale(.unsafeArtifactFilename(manifest.artifactFilename))
        }

        let artifactURL = entryURL.appendingPathComponent(manifest.artifactFilename)
        var artifactIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: artifactURL.path,
            isDirectory: &artifactIsDirectory
        ), !artifactIsDirectory.boolValue else {
            return .stale(.artifactMissing(artifactURL.path))
        }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: artifactURL.path)
            let actualByteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard actualByteCount == manifest.artifactByteCount else {
                return .stale(.artifactByteCountChanged(
                    expected: manifest.artifactByteCount,
                    actual: actualByteCount
                ))
            }
        } catch {
            return .stale(.cacheUnreadable(error.localizedDescription))
        }
        return .hit(CacheArtifact(
            key: key,
            url: artifactURL,
            byteCount: manifest.artifactByteCount,
            manifest: manifest
        ))
    }

    public func clearProjectCache(projectID: ProjectState.ID) throws {
        let projectURL = projectsURL.appendingPathComponent(
            projectID.uuidString.lowercased(),
            isDirectory: true
        )
        try removeManagedItemIfPresent(projectURL)
    }

    public func clearAllCaches() throws {
        try removeManagedItemIfPresent(projectsURL)
    }

    private var projectsURL: URL {
        rootURL.appendingPathComponent("projects", isDirectory: true)
    }

    private func assetURL(projectID: ProjectState.ID, assetID: MediaAsset.ID) -> URL {
        projectsURL
            .appendingPathComponent(projectID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(assetID.uuidString.lowercased(), isDirectory: true)
    }

    private func entryURL(
        projectID: ProjectState.ID,
        identity: CacheEntryIdentity,
        key: String
    ) -> URL {
        assetURL(projectID: projectID, assetID: identity.assetID)
            .appendingPathComponent("entries", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    private func createDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ProjectCacheError.directoryCreationFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private func nearestStaleReason(
        projectID: ProjectState.ID,
        expected: CacheEntryIdentity
    ) -> CacheLookupResult {
        let entriesURL = assetURL(projectID: projectID, assetID: expected.assetID)
            .appendingPathComponent("entries", isDirectory: true)
        let entryURLs: [URL]
        do {
            entryURLs = try fileManager.contentsOfDirectory(
                at: entriesURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .stale(.notCached)
        } catch {
            if !fileManager.fileExists(atPath: entriesURL.path) {
                return .stale(.notCached)
            }
            return .stale(.cacheUnreadable(error.localizedDescription))
        }

        var candidates: [([CacheIdentityField], String)] = []
        for entryURL in entryURLs {
            let manifestURL = entryURL.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(CacheManifest.self, from: data),
                  manifest.identity.namespace == expected.namespace,
                  manifest.identity.logicalArtifactID == expected.logicalArtifactID else {
                continue
            }
            let fields = Self.changedFields(from: manifest.identity, to: expected)
            if !fields.isEmpty { candidates.append((fields, entryURL.lastPathComponent)) }
        }
        guard let closest = candidates.min(by: { lhs, rhs in
            if lhs.0.count != rhs.0.count { return lhs.0.count < rhs.0.count }
            return lhs.1 < rhs.1
        }) else {
            return .stale(.notCached)
        }
        return .stale(.identityChanged(closest.0))
    }

    private func removeSupersededArtifacts(in entryURL: URL, keeping filename: String) {
        guard let children = try? fileManager.contentsOfDirectory(
            at: entryURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for child in children where child.lastPathComponent.hasPrefix("artifact-")
            && child.lastPathComponent != filename {
            try? fileManager.removeItem(at: child)
        }
    }

    private func removeManagedItemIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw ProjectCacheError.clearFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    private static func changedFields(
        from actual: CacheEntryIdentity,
        to expected: CacheEntryIdentity
    ) -> [CacheIdentityField] {
        var fields: [CacheIdentityField] = []
        if actual.sourceFingerprint != expected.sourceFingerprint {
            fields.append(.sourceFingerprint)
        }
        if actual.processingRevision != expected.processingRevision {
            fields.append(.processingRevision)
        }
        if actual.toolRevision != expected.toolRevision {
            fields.append(.toolRevision)
        }
        if actual.orderedParameters != expected.orderedParameters {
            fields.append(.orderedParameters)
        }
        return fields
    }

    private static func normalizedFileExtension(_ fileExtension: String) throws -> String {
        let normalized = fileExtension.hasPrefix(".")
            ? String(fileExtension.dropFirst())
            : fileExtension
        guard !normalized.isEmpty,
              normalized.count <= 12,
              normalized.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw ProjectCacheError.invalidFileExtension(fileExtension)
        }
        return normalized.lowercased()
    }

    private static func isSafeArtifactFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename != "."
            && filename != ".."
            && !filename.contains("/")
            && !filename.contains(":")
            && URL(fileURLWithPath: filename).lastPathComponent == filename
    }
}
