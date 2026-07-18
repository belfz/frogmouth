import AppKit
import FrogmouthCore
import SwiftUI

struct SequenceTimelineView: View {
    @ObservedObject var document: ProjectDocumentViewModel
    let project: ProjectState

    @State private var pixelsPerSecond = 80.0
    @State private var horizontalOffset = 0.0
    @State private var pinchStartScale: Double?

    private let math = TimelineViewportMath()
    private let minimumScale = 0.25
    private let maximumScale = 800.0
    private let trackHeight = 116.0

    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = max(1, geometry.size.width)
            let timelineIndex = try? TimelineIndex(project: project)
            let contentWidth = width(
                for: timelineIndex?.totalDuration ?? .zero,
                viewportWidth: viewportWidth,
                scale: pixelsPerSecond
            )

            VStack(spacing: 6) {
                controls(
                    timelineIndex: timelineIndex,
                    viewportWidth: viewportWidth
                )

                HorizontalTimelineScrollView(
                    contentWidth: contentWidth,
                    contentHeight: trackHeight,
                    horizontalOffset: $horizontalOffset
                ) {
                    TimelineTrackContent(
                        document: document,
                        project: project,
                        timelineIndex: timelineIndex,
                        pixelsPerSecond: pixelsPerSecond,
                        horizontalOffset: horizontalOffset,
                        viewportWidth: viewportWidth,
                        contentWidth: contentWidth
                    )
                }
                .frame(height: trackHeight)
                .simultaneousGesture(magnificationGesture(viewportWidth: viewportWidth))
            }
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    @ViewBuilder
    private func controls(
        timelineIndex: TimelineIndex?,
        viewportWidth: Double
    ) -> some View {
        HStack(spacing: 10) {
            Text("Timeline")
                .font(.headline)
            Text(playheadTimecode)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { log2(pixelsPerSecond) },
                    set: { exponent in
                        updateScale(
                            to: pow(2, exponent),
                            anchorX: preferredZoomAnchor(viewportWidth: viewportWidth),
                            viewportWidth: viewportWidth,
                            totalDuration: timelineIndex?.totalDuration ?? .zero
                        )
                    }
                ),
                in: log2(minimumScale)...log2(maximumScale)
            )
            .frame(width: 150)
            .accessibilityLabel("Timeline zoom")
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
            Button("Fit Timeline") {
                let totalDuration = timelineIndex?.totalDuration ?? .zero
                if let fitted = try? math.fittedPixelsPerSecond(
                    totalDuration: totalDuration,
                    viewportWidth: viewportWidth,
                    minimum: minimumScale,
                    maximum: maximumScale
                ) {
                    pixelsPerSecond = fitted
                    horizontalOffset = 0
                }
            }
            .disabled((timelineIndex?.totalFrames ?? 0) == 0)
            .help("Fit the complete timeline in the visible width")
        }
        .padding(.horizontal, 12)
    }

    private var playheadTimecode: String {
        guard let rate = project.timelineFormat?.frameRate else { return "00:00:00:00" }
        return (try? rate.timecode(forFrame: document.playheadFrame)) ?? "00:00:00:00"
    }

    private func width(
        for duration: MediaTime,
        viewportWidth: Double,
        scale: Double
    ) -> Double {
        let timelineWidth = (try? math.x(for: duration, pixelsPerSecond: scale)) ?? 0
        return max(viewportWidth, timelineWidth + 24)
    }

    private func preferredZoomAnchor(viewportWidth: Double) -> Double {
        guard let rate = project.timelineFormat?.frameRate,
              let playheadX = try? math.x(
                forFrame: document.playheadFrame,
                frameRate: rate,
                pixelsPerSecond: pixelsPerSecond
              ) else { return viewportWidth / 2 }
        let location = playheadX - horizontalOffset
        return (0...viewportWidth).contains(location) ? location : viewportWidth / 2
    }

    private func updateScale(
        to proposedScale: Double,
        anchorX: Double,
        viewportWidth: Double,
        totalDuration: MediaTime
    ) {
        let newScale = min(maximumScale, max(minimumScale, proposedScale))
        guard newScale != pixelsPerSecond else { return }
        let newContentWidth = width(
            for: totalDuration,
            viewportWidth: viewportWidth,
            scale: newScale
        )
        if let newOffset = try? math.zoomedOffset(
            oldOffset: horizontalOffset,
            oldPixelsPerSecond: pixelsPerSecond,
            newPixelsPerSecond: newScale,
            anchorInViewport: anchorX,
            viewportWidth: viewportWidth,
            newContentWidth: newContentWidth
        ) {
            horizontalOffset = newOffset
        }
        pixelsPerSecond = newScale
    }

    private func magnificationGesture(viewportWidth: Double) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStartScale == nil { pinchStartScale = pixelsPerSecond }
                guard let pinchStartScale else { return }
                let duration = (try? TimelineIndex(project: project).totalDuration) ?? .zero
                updateScale(
                    to: pinchStartScale * value.magnification,
                    anchorX: value.startLocation.x,
                    viewportWidth: viewportWidth,
                    totalDuration: duration
                )
            }
            .onEnded { _ in
                pinchStartScale = nil
            }
    }
}

private struct TimelineTrackContent: View {
    @ObservedObject var document: ProjectDocumentViewModel
    let project: ProjectState
    let timelineIndex: TimelineIndex?
    let pixelsPerSecond: Double
    let horizontalOffset: Double
    let viewportWidth: Double
    let contentWidth: Double

    @State private var isTrackDropTargeted = false

    private let math = TimelineViewportMath()
    private let rulerHeight = 28.0
    private let clipHeight = 80.0
    private let prefetchWidth = 260.0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .controlBackgroundColor)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(
                        minimumDistance: 0,
                        coordinateSpace: .named(TimelineCoordinateSpace.track)
                    )
                    .onChanged { value in scrub(atX: value.location.x) }
                )

            TimelineRuler(
                frameRate: project.timelineFormat?.frameRate,
                totalFrames: timelineIndex?.totalFrames ?? 0,
                pixelsPerSecond: pixelsPerSecond,
                horizontalOffset: horizontalOffset,
                viewportWidth: viewportWidth
            )
            .frame(width: contentWidth, height: rulerHeight)
            .allowsHitTesting(false)

            if let timelineIndex {
                if timelineIndex.entries.isEmpty {
                    Text("Drag a Media Library source here")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: min(320, contentWidth), height: clipHeight)
                        .offset(y: rulerHeight + 2)
                }
                ForEach(timelineIndex.entries, id: \.clipID) { entry in
                    if let clip = project.clips.first(where: { $0.id == entry.clipID }) {
                        let startX = x(forFrame: entry.startFrame)
                        let width = max(1, x(forFrame: entry.durationFrames))
                        TimelinePresentationClip(
                            document: document,
                            projectID: project.id,
                            clip: clip,
                            asset: project.mediaLibrary.first { $0.id == clip.assetID },
                            width: width,
                            timelineRate: project.timelineFormat?.frameRate,
                            pixelsPerSecond: pixelsPerSecond,
                            requestsThumbnail: intersectsPrefetch(startX: startX, width: width),
                            isSelected: document.selectedClipID == clip.id,
                            stabilizationStatus: document.stabilizationStatus(
                                for: clip,
                                in: project
                            )
                        )
                        .position(
                            x: startX + width / 2,
                            y: rulerHeight + 2 + clipHeight / 2
                        )
                        .zIndex(document.selectedClipID == clip.id ? 2 : 0)
                    }
                }

                ForEach(Array(boundaryFrames.enumerated()), id: \.offset) { _, frame in
                    TimelineDropBoundary(
                        document: document,
                        insertionIndex: insertionIndex(forBoundaryFrame: frame)
                    )
                    .offset(x: x(forFrame: frame) - 9, y: rulerHeight)
                }

                playhead(frameRate: project.timelineFormat?.frameRate)
                    .zIndex(3)
            } else {
                Text("Drag a Media Library source here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: min(320, contentWidth), height: clipHeight)
                    .offset(y: rulerHeight + 2)
            }
        }
        .frame(width: contentWidth, height: rulerHeight + clipHeight + 4)
        .coordinateSpace(name: TimelineCoordinateSpace.track)
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isTrackDropTargeted ? Color.accentColor : .clear,
                    lineWidth: 2
                )
                .allowsHitTesting(false)
        }
        .dropDestination(for: String.self) { values, location in
            handleDrop(values, atX: location.x)
        } isTargeted: {
            isTrackDropTargeted = $0
        }
    }

    @ViewBuilder
    private func playhead(frameRate: FrameRate?) -> some View {
        if let frameRate {
            let playheadX = x(forFrame: document.playheadFrame)
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 1.5, height: rulerHeight + clipHeight + 2)
                Image(systemName: "triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.red)
                    .rotationEffect(.degrees(180))
                    .offset(y: -1)
            }
            .offset(x: playheadX - 0.75)
            .allowsHitTesting(false)
            .accessibilityLabel("Playhead")
            .accessibilityValue((try? frameRate.timecode(forFrame: document.playheadFrame)) ?? "")
        }
    }

    private var boundaryFrames: [Int64] {
        guard let timelineIndex else { return [0] }
        return timelineIndex.entries.map(\.startFrame) + [timelineIndex.totalFrames]
    }

    private func insertionIndex(forBoundaryFrame frame: Int64) -> Int {
        guard let timelineIndex else { return 0 }
        return timelineIndex.entries.firstIndex(where: { $0.startFrame == frame })
            ?? timelineIndex.entries.count
    }

    private func nearestInsertionIndex(atX locationX: Double) -> Int {
        boundaryFrames.enumerated().min { lhs, rhs in
            abs(x(forFrame: lhs.element) - locationX)
                < abs(x(forFrame: rhs.element) - locationX)
        }?.offset ?? 0
    }

    private func handleDrop(_ values: [String], atX locationX: Double) -> Bool {
        guard let payload = values.compactMap(TimelineDragPayload.init).first else {
            return false
        }
        let insertionIndex = nearestInsertionIndex(atX: locationX)
        switch payload {
        case let .asset(assetID):
            document.insertAssetOnTimeline(assetID, at: insertionIndex)
        case let .clip(clipID):
            document.moveClip(clipID, toBoundaryIndex: insertionIndex)
        }
        return true
    }

    private func x(forFrame frame: Int64) -> Double {
        guard let rate = project.timelineFormat?.frameRate else { return 0 }
        return (try? math.x(
            forFrame: frame,
            frameRate: rate,
            pixelsPerSecond: pixelsPerSecond
        )) ?? 0
    }

    private func intersectsPrefetch(startX: Double, width: Double) -> Bool {
        let lower = horizontalOffset - prefetchWidth
        let upper = horizontalOffset + viewportWidth + prefetchWidth
        return startX + width >= lower && startX <= upper
    }

    private func scrub(atX location: Double) {
        guard document.trimPreview == nil,
              let frameRate = project.timelineFormat?.frameRate,
              let timelineIndex,
              let proposed = try? math.frame(
                atX: location,
                frameRate: frameRate,
                pixelsPerSecond: pixelsPerSecond
              ) else { return }
        let clamped = min(max(0, proposed), timelineIndex.totalFrames)
        let snapped = (try? math.snappedFrame(
            proposedFrame: clamped,
            boundaryFrames: boundaryFrames,
            frameRate: frameRate,
            pixelsPerSecond: pixelsPerSecond,
            snappingDisabled: NSEvent.modifierFlags.contains(.option)
        )) ?? clamped
        document.setPlayheadFrame(snapped)
    }
}

private struct TimelineRuler: View {
    let frameRate: FrameRate?
    let totalFrames: Int64
    let pixelsPerSecond: Double
    let horizontalOffset: Double
    let viewportWidth: Double

    private let math = TimelineViewportMath()

    var body: some View {
        Canvas { context, size in
            guard let frameRate,
                  totalFrames > 0,
                  let step = try? math.adaptiveTickStepFrames(
                    frameRate: frameRate,
                    pixelsPerSecond: pixelsPerSecond
                  ), step > 0,
                  let visibleStart = try? math.frame(
                    atX: horizontalOffset,
                    frameRate: frameRate,
                    pixelsPerSecond: pixelsPerSecond,
                    rounding: .towardNegativeInfinity
                  ),
                  let visibleEnd = try? math.frame(
                    atX: horizontalOffset + viewportWidth,
                    frameRate: frameRate,
                    pixelsPerSecond: pixelsPerSecond,
                    rounding: .towardPositiveInfinity
                  ) else { return }
            var frame = max(0, visibleStart / step * step)
            let end = min(totalFrames, visibleEnd + step)
            while frame <= end {
                guard let x = try? math.x(
                    forFrame: frame,
                    frameRate: frameRate,
                    pixelsPerSecond: pixelsPerSecond
                ) else { break }
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height - 8))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.secondary.opacity(0.65)), lineWidth: 1)
                if let label = try? frameRate.timecode(forFrame: frame) {
                    context.draw(
                        Text(label)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary),
                        at: CGPoint(x: x + 3, y: 8),
                        anchor: .leading
                    )
                }
                let next = frame.addingReportingOverflow(step)
                if next.overflow { break }
                frame = next.partialValue
            }
        }
    }
}

private struct TimelinePresentationClip: View {
    @ObservedObject var document: ProjectDocumentViewModel
    let projectID: ProjectState.ID
    let clip: TimelineClip
    let asset: MediaAsset?
    let width: Double
    let timelineRate: FrameRate?
    let pixelsPerSecond: Double
    let requestsThumbnail: Bool
    let isSelected: Bool
    let stabilizationStatus: StabilizationStatus

    var body: some View {
        ZStack(alignment: .topLeading) {
            ThumbnailArtwork(
                service: document.thumbnailService,
                projectID: projectID,
                request: requestsThumbnail ? thumbnailRequest : nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            LinearGradient(
                colors: [.black.opacity(0.62), .clear],
                startPoint: .top,
                endPoint: .center
            )

            HStack(spacing: 4) {
                if width > 48 {
                    Text(filename)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                stabilizationBadge
            }
            .padding(5)
        }
        .frame(width: width, height: 80)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.22), lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture { document.selectClip(clip.id) }
        .draggable("clip:\(clip.id.uuidString)")
        .overlay(alignment: .leading) {
            if isSelected {
                trimHandle(edge: .leading)
            }
        }
        .overlay(alignment: .trailing) {
            if isSelected {
                trimHandle(edge: .trailing)
            }
        }
        .help(filename)
    }

    @ViewBuilder
    private var stabilizationBadge: some View {
        switch stabilizationStatus {
        case .none:
            EmptyView()
        case .valid:
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
                .help("Stabilization is current")
                .accessibilityLabel("Stabilization current")
        case let .stale(reason):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(reason.localizedDescription)
                .accessibilityLabel("Stabilization stale")
                .accessibilityHint(reason.localizedDescription)
        }
    }

    private var filename: String {
        guard let asset else { return "Missing source" }
        return URL(fileURLWithPath: asset.path.absoluteFallback).lastPathComponent
    }

    private var thumbnailRequest: ThumbnailRequest? {
        guard let asset else { return nil }
        return try? ThumbnailRequest(
            assetID: asset.id,
            sourceFingerprint: asset.fingerprint,
            mediaURL: document.resolvedURL(for: asset.id)
                ?? URL(fileURLWithPath: asset.path.absoluteFallback),
            frameRate: asset.inspected.frameRate,
            requestedSourceTime: clip.sourceRange.start,
            pixelWidth: max(80, min(640, Int(width.rounded(.up)) * 2)),
            pixelHeight: 160
        )
    }

    private func trimHandle(edge: ProjectDocumentViewModel.TrimEdge) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 5)
            Capsule()
                .fill(Color.white.opacity(0.9))
                .frame(width: 2, height: 24)
        }
        .frame(width: 14, height: 80)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(
                minimumDistance: 0,
                coordinateSpace: .named(TimelineCoordinateSpace.track)
            )
                .onChanged { value in
                    document.updateTrimPreview(
                        clipID: clip.id,
                        edge: edge,
                        timelineFrameDelta: timelineFrameDelta(for: value.translation.width)
                    )
                }
                .onEnded { value in
                    document.updateTrimPreview(
                        clipID: clip.id,
                        edge: edge,
                        timelineFrameDelta: timelineFrameDelta(for: value.translation.width)
                    )
                    document.commitTrimPreview()
                }
        )
        .onHover { hovering in
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .help(edge == .leading ? "Trim the clip start" : "Trim the clip end")
        .accessibilityLabel(edge == .leading ? "Leading trim handle" : "Trailing trim handle")
    }

    private func timelineFrameDelta(for horizontalTranslation: Double) -> Int64 {
        guard let timelineRate, pixelsPerSecond > 0 else { return 0 }
        let frames = horizontalTranslation / pixelsPerSecond
            * Double(timelineRate.numerator) / Double(timelineRate.denominator)
        guard frames.isFinite,
              frames >= Double(Int64.min),
              frames <= Double(Int64.max) else { return 0 }
        return Int64(frames.rounded(.toNearestOrAwayFromZero))
    }
}

private enum TimelineCoordinateSpace {
    static let track = "frogmouth.timeline.track"
}

private struct TimelineDropBoundary: View {
    @ObservedObject var document: ProjectDocumentViewModel
    let insertionIndex: Int
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isTargeted ? Color.accentColor : .clear)
                .frame(width: 3, height: 84)
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(Color.accentColor)
                .opacity(isTargeted ? 1 : 0)
        }
        .frame(width: 18, height: 84)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { values, _ in
            guard let payload = values.compactMap(TimelineDragPayload.init).first else {
                return false
            }
            switch payload {
            case let .asset(assetID):
                document.insertAssetOnTimeline(assetID, at: insertionIndex)
            case let .clip(clipID):
                document.moveClip(clipID, toBoundaryIndex: insertionIndex)
            }
            return true
        } isTargeted: {
            isTargeted = $0
        }
        .accessibilityLabel("Insert clip at boundary \(insertionIndex + 1)")
    }
}

private enum TimelineDragPayload: Equatable {
    case asset(MediaAsset.ID)
    case clip(TimelineClip.ID)

    init?(_ value: String) {
        if value.hasPrefix("asset:"),
           let id = UUID(uuidString: String(value.dropFirst("asset:".count))) {
            self = .asset(id)
        } else if value.hasPrefix("clip:"),
                  let id = UUID(uuidString: String(value.dropFirst("clip:".count))) {
            self = .clip(id)
        } else {
            return nil
        }
    }
}

private struct HorizontalTimelineScrollView<Content: View>: NSViewRepresentable {
    let contentWidth: Double
    let contentHeight: Double
    @Binding var horizontalOffset: Double
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        let hosting = NSHostingView(rootView: AnyView(content()))
        scrollView.documentView = hosting
        context.coordinator.hostingView = hosting
        context.coordinator.scrollView = scrollView
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChangeNotification),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.hostingView?.rootView = AnyView(content())
        let width = max(contentWidth, scrollView.contentSize.width)
        context.coordinator.hostingView?.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: contentHeight
        )
        let maximumOffset = max(0, width - scrollView.contentSize.width)
        let target = min(max(0, horizontalOffset), maximumOffset)
        if abs(scrollView.contentView.bounds.origin.x - target) > 0.5 {
            scrollView.contentView.scroll(to: NSPoint(x: target, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(
            coordinator,
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.documentView = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: HorizontalTimelineScrollView
        weak var scrollView: NSScrollView?
        var hostingView: NSHostingView<AnyView>?

        init(parent: HorizontalTimelineScrollView) {
            self.parent = parent
        }

        @objc func boundsDidChangeNotification() {
            guard let offset = scrollView?.contentView.bounds.origin.x,
                  abs(parent.horizontalOffset - offset) > 0.5 else { return }
            parent.horizontalOffset = offset
        }
    }
}
