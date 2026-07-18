import Foundation

public enum TimelineEditError: LocalizedError, Equatable, Sendable {
    case missingTimelineFormat
    case mediaNotFound(UUID)
    case clipNotFound(UUID)
    case duplicateMediaID(UUID)
    case duplicateClipID(UUID)
    case invalidInsertionIndex(Int)
    case invalidMoveIndex(Int)
    case sourceRangeOutsideAsset(UUID)
    case splitAtClipEdge
    case unrepresentableSplit
    case mediaInUse(assetID: UUID, usageCount: Int)
    case trimTransactionAlreadyActive
    case noActiveTrimTransaction
    case commandDuringTrimTransaction
    case duplicateStabilizationEffectID(UUID)
    case unsupportedStabilizationMode(UUID)
    case invalidStabilizationCoverage(UUID)
    case nonNestedStabilizationCoverage(parent: UUID, child: UUID)
    case timing(MediaTimeError)

    public var errorDescription: String? {
        switch self {
        case .missingTimelineFormat:
            "The timeline has clips but no timeline format."
        case let .mediaNotFound(id):
            "The timeline references missing media ID \(id.uuidString)."
        case let .clipNotFound(id):
            "Timeline clip \(id.uuidString) was not found."
        case let .duplicateMediaID(id):
            "Media ID \(id.uuidString) already exists in the project."
        case let .duplicateClipID(id):
            "Clip ID \(id.uuidString) already exists in the timeline."
        case let .invalidInsertionIndex(index):
            "Clip insertion index \(index) is outside the timeline."
        case let .invalidMoveIndex(index):
            "Clip destination index \(index) is outside the timeline."
        case let .sourceRangeOutsideAsset(id):
            "A clip range is outside media \(id.uuidString)."
        case .splitAtClipEdge:
            "Split is only available inside a clip, not on either edge."
        case .unrepresentableSplit:
            "This timeline boundary cannot be represented exactly at the source frame rate."
        case let .mediaInUse(_, usageCount):
            "This source is used by \(usageCount) timeline clip\(usageCount == 1 ? "" : "s") and cannot be removed."
        case .trimTransactionAlreadyActive:
            "Another trim gesture is already active."
        case .noActiveTrimTransaction:
            "There is no trim gesture to update or commit."
        case .commandDuringTrimTransaction:
            "Finish or cancel the active trim before another project edit."
        case let .duplicateStabilizationEffectID(id):
            "Stabilization pass \(id.uuidString) appears more than once."
        case let .unsupportedStabilizationMode(id):
            "Stabilization pass \(id.uuidString) has no supported processing mode."
        case let .invalidStabilizationCoverage(id):
            "Stabilization pass \(id.uuidString) does not cover a valid range for this clip."
        case let .nonNestedStabilizationCoverage(parent, child):
            "Stabilization pass \(child.uuidString) extends outside preceding pass \(parent.uuidString)."
        case let .timing(error):
            "The edit has invalid or overflowing media timing: \(String(describing: error))."
        }
    }
}

public struct TimelineIndexEntry: Equatable, Sendable {
    public let clipID: TimelineClip.ID
    public let clipIndex: Int
    public let timelineRange: MediaTimeRange
    public let startFrame: Int64
    public let durationFrames: Int64
}

public struct TimelineIndex: Equatable, Sendable {
    public let entries: [TimelineIndexEntry]
    public let totalFrames: Int64
    public let totalDuration: MediaTime

    public init(project: ProjectState) throws {
        var assetsByID: [MediaAsset.ID: MediaAsset] = [:]
        for asset in project.mediaLibrary {
            guard assetsByID.updateValue(asset, forKey: asset.id) == nil else {
                throw TimelineEditError.duplicateMediaID(asset.id)
            }
        }

        guard project.clips.isEmpty || project.timelineFormat != nil else {
            throw TimelineEditError.missingTimelineFormat
        }
        guard let format = project.timelineFormat else {
            entries = []
            totalFrames = 0
            totalDuration = .zero
            return
        }

        var seenClipIDs: Set<TimelineClip.ID> = []
        var builtEntries: [TimelineIndexEntry] = []
        var cursor: Int64 = 0
        for (index, clip) in project.clips.enumerated() {
            guard seenClipIDs.insert(clip.id).inserted else {
                throw TimelineEditError.duplicateClipID(clip.id)
            }
            guard let asset = assetsByID[clip.assetID] else {
                throw TimelineEditError.mediaNotFound(clip.assetID)
            }
            try Self.validateSourceRange(clip.sourceRange, for: asset)

            let mapper = TimelineTimeMapper(
                timelineRate: format.frameRate,
                sourceRate: asset.inspected.frameRate
            )
            let durationFrames: Int64
            do {
                durationFrames = try mapper.validatedTimelineFrameCount(
                    forSourceDuration: clip.sourceRange.duration
                )
            } catch let error as MediaTimeError {
                throw TimelineEditError.timing(error)
            }

            let start = try Self.mapTiming { try format.frameRate.time(forFrame: cursor) }
            let duration = try Self.mapTiming { try format.frameRate.time(forFrame: durationFrames) }
            let range = try Self.mapTiming { try MediaTimeRange(start: start, duration: duration) }
            builtEntries.append(TimelineIndexEntry(
                clipID: clip.id,
                clipIndex: index,
                timelineRange: range,
                startFrame: cursor,
                durationFrames: durationFrames
            ))
            cursor = try Self.mapTiming { try MediaTime.checkedAdd(cursor, durationFrames) }
        }

        entries = builtEntries
        totalFrames = cursor
        totalDuration = try Self.mapTiming { try format.frameRate.time(forFrame: cursor) }
    }

    public func entry(for clipID: TimelineClip.ID) -> TimelineIndexEntry? {
        entries.first { $0.clipID == clipID }
    }

    static func validateSourceRange(
        _ range: MediaTimeRange,
        for asset: MediaAsset
    ) throws {
        let end = try mapTiming { try range.end() }
        guard range.start >= .zero,
              range.duration > .zero,
              end <= asset.inspected.duration else {
            throw TimelineEditError.sourceRangeOutsideAsset(asset.id)
        }
    }

    fileprivate static func mapTiming<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as MediaTimeError {
            throw TimelineEditError.timing(error)
        }
    }
}

public enum ProjectCommand: Equatable, Sendable {
    case importMedia(MediaAsset)
    case removeUnusedMedia(assetID: MediaAsset.ID)
    case insertClip(TimelineClip, atIndex: Int)
    case appendClip(TimelineClip)
    case splitClip(clipID: TimelineClip.ID, atTimelineFrameOffset: Int64, rightClipID: TimelineClip.ID)
    case trimClip(clipID: TimelineClip.ID, sourceRange: MediaTimeRange)
    case duplicateClip(clipID: TimelineClip.ID, newClipID: TimelineClip.ID)
    case moveClip(clipID: TimelineClip.ID, toIndex: Int)
    case deleteClip(clipID: TimelineClip.ID)
    case setStabilizationPasses(clipID: TimelineClip.ID, passes: [StabilizationEffect])

    fileprivate func apply(to project: inout ProjectState) throws {
        switch self {
        case let .importMedia(asset):
            guard !project.mediaLibrary.contains(where: { $0.id == asset.id }) else {
                throw TimelineEditError.duplicateMediaID(asset.id)
            }
            project.mediaLibrary.append(asset)

        case let .removeUnusedMedia(assetID):
            guard let mediaIndex = project.mediaLibrary.firstIndex(where: { $0.id == assetID }) else {
                throw TimelineEditError.mediaNotFound(assetID)
            }
            let usageCount = project.clips.count { $0.assetID == assetID }
            guard usageCount == 0 else {
                throw TimelineEditError.mediaInUse(assetID: assetID, usageCount: usageCount)
            }
            project.mediaLibrary.remove(at: mediaIndex)

        case let .insertClip(clip, index):
            guard project.clips.indices.contains(index) || index == project.clips.endIndex else {
                throw TimelineEditError.invalidInsertionIndex(index)
            }
            try Self.prepareForInsertion(of: clip, into: &project)
            project.clips.insert(clip, at: index)

        case let .appendClip(clip):
            try Self.prepareForInsertion(of: clip, into: &project)
            project.clips.append(clip)

        case let .splitClip(clipID, timelineFrame, rightClipID):
            guard let clipIndex = project.clips.firstIndex(where: { $0.id == clipID }) else {
                throw TimelineEditError.clipNotFound(clipID)
            }
            guard !project.clips.contains(where: { $0.id == rightClipID }) else {
                throw TimelineEditError.duplicateClipID(rightClipID)
            }
            let index = try TimelineIndex(project: project)
            guard let entry = index.entry(for: clipID) else {
                throw TimelineEditError.clipNotFound(clipID)
            }
            guard timelineFrame > 0, timelineFrame < entry.durationFrames else {
                throw TimelineEditError.splitAtClipEdge
            }
            let clip = project.clips[clipIndex]
            guard let asset = project.mediaLibrary.first(where: { $0.id == clip.assetID }),
                  let format = project.timelineFormat else {
                throw TimelineEditError.mediaNotFound(clip.assetID)
            }
            let mapper = TimelineTimeMapper(
                timelineRate: format.frameRate,
                sourceRate: asset.inspected.frameRate
            )
            let sourceSplit = try TimelineIndex.mapTiming {
                try mapper.sourceTime(
                    forTimelineFrame: timelineFrame,
                    sourceStart: clip.sourceRange.start
                )
            }
            let parentEnd = try TimelineIndex.mapTiming { try clip.sourceRange.end() }
            guard sourceSplit > clip.sourceRange.start, sourceSplit < parentEnd else {
                throw TimelineEditError.unrepresentableSplit
            }
            let leftDuration = try TimelineIndex.mapTiming {
                try sourceSplit.subtracting(clip.sourceRange.start)
            }
            let rightDuration = try TimelineIndex.mapTiming { try parentEnd.subtracting(sourceSplit) }
            let leftRange = try TimelineIndex.mapTiming {
                try MediaTimeRange(start: clip.sourceRange.start, duration: leftDuration)
            }
            let rightRange = try TimelineIndex.mapTiming {
                try MediaTimeRange(start: sourceSplit, duration: rightDuration)
            }
            let leftFrames = try TimelineIndex.mapTiming {
                try mapper.validatedTimelineFrameCount(forSourceDuration: leftDuration)
            }
            let rightFrames = try TimelineIndex.mapTiming {
                try mapper.validatedTimelineFrameCount(forSourceDuration: rightDuration)
            }
            guard leftFrames == timelineFrame,
                  rightFrames == entry.durationFrames - timelineFrame else {
                throw TimelineEditError.unrepresentableSplit
            }

            project.clips[clipIndex].sourceRange = leftRange
            project.clips.insert(TimelineClip(
                id: rightClipID,
                assetID: clip.assetID,
                sourceRange: rightRange,
                stabilizationPasses: clip.stabilizationPasses
            ), at: clipIndex + 1)

        case let .trimClip(clipID, sourceRange):
            guard let clipIndex = project.clips.firstIndex(where: { $0.id == clipID }) else {
                throw TimelineEditError.clipNotFound(clipID)
            }
            let assetID = project.clips[clipIndex].assetID
            guard let asset = project.mediaLibrary.first(where: { $0.id == assetID }) else {
                throw TimelineEditError.mediaNotFound(assetID)
            }
            try TimelineIndex.validateSourceRange(sourceRange, for: asset)
            project.clips[clipIndex].sourceRange = sourceRange

        case let .duplicateClip(clipID, newClipID):
            guard let clipIndex = project.clips.firstIndex(where: { $0.id == clipID }) else {
                throw TimelineEditError.clipNotFound(clipID)
            }
            guard !project.clips.contains(where: { $0.id == newClipID }) else {
                throw TimelineEditError.duplicateClipID(newClipID)
            }
            let source = project.clips[clipIndex]
            project.clips.insert(TimelineClip(
                id: newClipID,
                assetID: source.assetID,
                sourceRange: source.sourceRange,
                stabilizationPasses: source.stabilizationPasses
            ), at: clipIndex + 1)

        case let .moveClip(clipID, destinationIndex):
            guard let sourceIndex = project.clips.firstIndex(where: { $0.id == clipID }) else {
                throw TimelineEditError.clipNotFound(clipID)
            }
            guard project.clips.indices.contains(destinationIndex) else {
                throw TimelineEditError.invalidMoveIndex(destinationIndex)
            }
            guard sourceIndex != destinationIndex else { return }
            let clip = project.clips.remove(at: sourceIndex)
            project.clips.insert(clip, at: destinationIndex)

        case let .deleteClip(clipID):
            guard let clipIndex = project.clips.firstIndex(where: { $0.id == clipID }) else {
                throw TimelineEditError.clipNotFound(clipID)
            }
            project.clips.remove(at: clipIndex)

        case let .setStabilizationPasses(clipID, passes):
            guard let clipIndex = project.clips.firstIndex(where: { $0.id == clipID }) else {
                throw TimelineEditError.clipNotFound(clipID)
            }
            let clip = project.clips[clipIndex]
            guard let asset = project.mediaLibrary.first(where: { $0.id == clip.assetID }) else {
                throw TimelineEditError.mediaNotFound(clip.assetID)
            }
            var seen: Set<StabilizationEffect.ID> = []
            var previous: StabilizationEffect?
            for effect in passes {
                guard seen.insert(effect.id).inserted else {
                    throw TimelineEditError.duplicateStabilizationEffectID(effect.id)
                }
                guard effect.mode != .none,
                      StabilizationProfile.profile(for: effect.mode) != nil else {
                    throw TimelineEditError.unsupportedStabilizationMode(effect.id)
                }
                guard effect.processingRevision > 0,
                      Self.contains(effect.analysisCoverage, clip.sourceRange),
                      (try? TimelineIndex.validateSourceRange(
                        effect.analysisCoverage,
                        for: asset
                      )) != nil else {
                    throw TimelineEditError.invalidStabilizationCoverage(effect.id)
                }
                if let previous,
                   !Self.contains(previous.analysisCoverage, effect.analysisCoverage) {
                    throw TimelineEditError.nonNestedStabilizationCoverage(
                        parent: previous.id,
                        child: effect.id
                    )
                }
                previous = effect
            }
            project.clips[clipIndex].stabilizationPasses = passes
        }

        _ = try TimelineIndex(project: project)
    }

    private static func prepareForInsertion(
        of clip: TimelineClip,
        into project: inout ProjectState
    ) throws {
        guard !project.clips.contains(where: { $0.id == clip.id }) else {
            throw TimelineEditError.duplicateClipID(clip.id)
        }
        guard let asset = project.mediaLibrary.first(where: { $0.id == clip.assetID }) else {
            throw TimelineEditError.mediaNotFound(clip.assetID)
        }
        try TimelineIndex.validateSourceRange(clip.sourceRange, for: asset)
        if let format = project.timelineFormat {
            _ = try TimelineCompatibilityValidator().validate(asset: asset, against: format)
        }
        if project.timelineFormat == nil {
            project.timelineFormat = TimelineFormat(
                width: asset.inspected.width,
                height: asset.inspected.height,
                frameRate: asset.inspected.frameRate,
                colour: asset.inspected.colour,
                audioSampleRate: asset.inspected.audioSampleRate ?? 48_000,
                audioChannelCount: asset.inspected.audioChannelCount ?? 2
            )
        }
    }

    private static func contains(_ parent: MediaTimeRange, _ child: MediaTimeRange) -> Bool {
        guard let parentEnd = try? parent.end(),
              let childEnd = try? child.end() else { return false }
        return child.start >= parent.start && childEnd <= parentEnd
    }
}

public struct ProjectHistory: Sendable {
    private var undoStack: [ProjectState] = []
    private var redoStack: [ProjectState] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    fileprivate mutating func record(previous: ProjectState) {
        undoStack.append(previous)
        redoStack.removeAll()
    }

    fileprivate mutating func undo(current: ProjectState) -> ProjectState? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    fileprivate mutating func redo(current: ProjectState) -> ProjectState? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    public mutating func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    fileprivate mutating func reassignProjectID(_ id: ProjectState.ID) {
        for index in undoStack.indices {
            undoStack[index].id = id
        }
        for index in redoStack.indices {
            redoStack[index].id = id
        }
    }
}

public struct TrimTransaction: Equatable, Sendable {
    public let clipID: TimelineClip.ID
    public let originalRange: MediaTimeRange
    public private(set) var pendingRange: MediaTimeRange

    fileprivate init(clipID: TimelineClip.ID, originalRange: MediaTimeRange) {
        self.clipID = clipID
        self.originalRange = originalRange
        pendingRange = originalRange
    }

    fileprivate mutating func update(_ range: MediaTimeRange) {
        pendingRange = range
    }
}

public struct ProjectEditor: Sendable {
    public private(set) var project: ProjectState
    public private(set) var history: ProjectHistory
    public private(set) var trimTransaction: TrimTransaction?

    public init(project: ProjectState) {
        self.project = project
        history = ProjectHistory()
        trimTransaction = nil
    }

    public mutating func apply(_ command: ProjectCommand) throws {
        guard trimTransaction == nil else {
            throw TimelineEditError.commandDuringTrimTransaction
        }
        try applyCommitted(command)
    }

    public mutating func undo() throws -> Bool {
        guard trimTransaction == nil else {
            throw TimelineEditError.commandDuringTrimTransaction
        }
        guard let previous = history.undo(current: project) else { return false }
        project = previous
        return true
    }

    public mutating func redo() throws -> Bool {
        guard trimTransaction == nil else {
            throw TimelineEditError.commandDuringTrimTransaction
        }
        guard let next = history.redo(current: project) else { return false }
        project = next
        return true
    }

    public mutating func beginTrim(clipID: TimelineClip.ID) throws {
        guard trimTransaction == nil else {
            throw TimelineEditError.trimTransactionAlreadyActive
        }
        guard let clip = project.clips.first(where: { $0.id == clipID }) else {
            throw TimelineEditError.clipNotFound(clipID)
        }
        trimTransaction = TrimTransaction(clipID: clipID, originalRange: clip.sourceRange)
    }

    public mutating func updateTrim(to sourceRange: MediaTimeRange) throws {
        guard var transaction = trimTransaction else {
            throw TimelineEditError.noActiveTrimTransaction
        }
        var candidate = project
        try ProjectCommand.trimClip(
            clipID: transaction.clipID,
            sourceRange: sourceRange
        ).apply(to: &candidate)
        transaction.update(sourceRange)
        trimTransaction = transaction
    }

    public mutating func commitTrim() throws {
        guard let transaction = trimTransaction else {
            throw TimelineEditError.noActiveTrimTransaction
        }
        if transaction.pendingRange != transaction.originalRange {
            try applyCommitted(.trimClip(
                clipID: transaction.clipID,
                sourceRange: transaction.pendingRange
            ))
        }
        trimTransaction = nil
    }

    public mutating func cancelTrim() throws {
        guard trimTransaction != nil else {
            throw TimelineEditError.noActiveTrimTransaction
        }
        trimTransaction = nil
    }

    mutating func reassignProjectID(_ id: ProjectState.ID) {
        project.id = id
        history.reassignProjectID(id)
    }

    private mutating func applyCommitted(_ command: ProjectCommand) throws {
        let previous = project
        var candidate = project
        try command.apply(to: &candidate)
        guard candidate != previous else { return }
        history.record(previous: previous)
        project = candidate
    }
}
