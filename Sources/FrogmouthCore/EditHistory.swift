import Foundation

public struct EditHistory: Sendable {
    private var past: [EditState] = []
    private var future: [EditState] = []

    public init() {}

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    public mutating func record(previous: EditState, current: EditState) {
        guard previous != current else { return }
        past.append(previous)
        future.removeAll()
    }

    public mutating func undo(current: EditState) -> EditState? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        return previous
    }

    public mutating func redo(current: EditState) -> EditState? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }

    public mutating func clear() {
        past.removeAll()
        future.removeAll()
    }
}

