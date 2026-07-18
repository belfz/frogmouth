import AppKit
import FrogmouthCore
import SwiftUI

struct ProjectEditorShell: View {
    @ObservedObject var document: ProjectDocumentViewModel
    let project: ProjectState

    @State private var showsLibrary = true
    @State private var showsInspector = true

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if showsLibrary {
                    MediaLibraryView(document: document, project: project)
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                }

                TimelinePlayerView(document: document, project: project)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

                if showsInspector {
                    ProjectInspectorView(
                        document: document,
                        project: document.presentationProject ?? project
                    )
                        .frame(minWidth: 220, idealWidth: 270, maxWidth: 360)
                }
            }

            Divider()

            SequenceTimelineView(
                document: document,
                project: document.presentationProject ?? project
            )
                .frame(minHeight: 150, idealHeight: 190, maxHeight: 240)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    showsLibrary.toggle()
                } label: {
                    Label("Media Library", systemImage: "sidebar.left")
                }
                .help(showsLibrary ? "Hide Media Library" : "Show Media Library")

                Button(action: document.presentImportVideosPanel) {
                    Label("Import Videos", systemImage: "plus")
                }
                .disabled(!document.canImport)
            }
            ToolbarItemGroup {
                Button(action: document.splitSelectedClip) {
                    Label("Split Clip", systemImage: "scissors")
                }
                .disabled(!document.canSplitSelectedClip)
                .help("Split the selected clip at the playhead")

                Button(action: document.duplicateSelectedClip) {
                    Label("Duplicate Clip", systemImage: "plus.square.on.square")
                }
                .disabled(!document.canEditSelectedClip)

                Button(role: .destructive, action: document.deleteSelectedClip) {
                    Label("Delete Clip", systemImage: "trash")
                }
                .disabled(!document.canEditSelectedClip)

                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help(showsInspector ? "Hide Inspector" : "Show Inspector")

                Button(action: document.save) {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(!document.canSave)
            }
        }
        .onExitCommand(perform: document.cancelTrimPreview)
    }
}

private struct MediaLibraryView: View {
    @ObservedObject var document: ProjectDocumentViewModel
    let project: ProjectState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Media Library")
                    .font(.headline)
                Spacer()
                Text("\(project.mediaLibrary.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if project.mediaLibrary.isEmpty {
                ContentUnavailableView(
                    "No source files",
                    systemImage: "film.stack",
                    description: Text("Import videos to build the Media Library.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(project.mediaLibrary) { asset in
                            MediaLibraryRow(
                                document: document,
                                projectID: project.id,
                                asset: asset,
                                usageCount: project.clips.count { $0.assetID == asset.id },
                                isSelected: document.selectedAssetID == asset.id
                            )
                            .id(asset.id)
                        }
                    }
                    .padding(8)
                }
            }

            Divider()

            Button(action: document.presentImportVideosPanel) {
                Label("Import Videos…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(10)
            .disabled(!document.canImport)
        }
        .background(.regularMaterial)
    }
}

private struct MediaLibraryRow: View {
    @ObservedObject var document: ProjectDocumentViewModel
    let projectID: ProjectState.ID
    let asset: MediaAsset
    let usageCount: Int
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ThumbnailArtwork(
                service: document.thumbnailService,
                projectID: projectID,
                request: thumbnailRequest
            )
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                Text(formatDuration(asset.inspected.duration))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .padding(4)
            }

            Text(filename)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 5) {
                Text("\(asset.inspected.width)×\(asset.inspected.height)")
                Text("·")
                Text(formatFrameRate(asset.inspected.frameRate))
                Spacer()
                Text(usageCount == 1 ? "1 use" : "\(usageCount) uses")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack {
                Button {
                    document.insertAssetOnTimeline(asset.id)
                } label: {
                    Label("Append", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Append the complete source as another timeline clip")

                Spacer()

                Button(role: .destructive) {
                    document.removeAssetFromLibrary(asset.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(usageCount == 0
                      ? "Remove this unused source from the project"
                      : "Used by \(usageCount) timeline clip\(usageCount == 1 ? "" : "s"); removal will be refused")
            }
        }
        .padding(8)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { document.selectAsset(asset.id) }
        .draggable("asset:\(asset.id.uuidString)")
    }

    private var filename: String {
        URL(fileURLWithPath: asset.path.absoluteFallback).lastPathComponent
    }

    private var thumbnailRequest: ThumbnailRequest? {
        try? ThumbnailRequest(
            assetID: asset.id,
            sourceFingerprint: asset.fingerprint,
            mediaURL: document.resolvedURL(for: asset.id)
                ?? URL(fileURLWithPath: asset.path.absoluteFallback),
            frameRate: asset.inspected.frameRate,
            requestedSourceTime: .zero,
            pixelWidth: 320,
            pixelHeight: 180
        )
    }
}

private struct TimelinePlayerView: View {
    @ObservedObject var document: ProjectDocumentViewModel
    @ObservedObject var playback: PlaybackCoordinator
    let project: ProjectState

    init(document: ProjectDocumentViewModel, project: ProjectState) {
        self.document = document
        playback = document.playback
        self.project = project
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                NativeVideoPlayer(player: playback.player, controlsStyle: .none)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if project.clips.isEmpty {
                    viewerMessage(
                        icon: "rectangle.stack.badge.plus",
                        title: "Build the timeline",
                        detail: "Append or drag a source from the Media Library."
                    )
                } else if playback.isBuilding {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Building timeline preview…")
                            .font(.headline)
                    }
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                } else if let error = playback.errorMessage {
                    viewerMessage(
                        icon: "exclamationmark.triangle",
                        title: "Timeline preview unavailable",
                        detail: error
                    )
                }
            }

            playbackControls
        }
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline viewer")
    }

    @ViewBuilder
    private func viewerMessage(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 42))
            Text(title)
                .font(.title2.bold())
            Text(detail)
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .foregroundStyle(.secondary)
        .padding(24)
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button(action: playback.togglePlayback) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(project.clips.isEmpty || playback.isBuilding || playback.errorMessage != nil)
            .help(playback.isPlaying ? "Pause" : "Play")

            Text(playheadTimecode)
                .font(.caption.monospacedDigit())
            Text("/")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(durationTimecode)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()

            if let location = playback.location,
               let clipNumber = project.clips.firstIndex(where: { $0.id == location.clipID }) {
                Text("Clip \(clipNumber + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
    }

    private var playheadTimecode: String {
        guard let rate = project.timelineFormat?.frameRate else { return "00:00:00:00" }
        return (try? rate.timecode(forFrame: document.playheadFrame)) ?? "00:00:00:00"
    }

    private var durationTimecode: String {
        guard let rate = project.timelineFormat?.frameRate,
              let index = try? TimelineIndex(project: project) else { return "00:00:00:00" }
        return (try? rate.timecode(forFrame: index.totalFrames)) ?? "00:00:00:00"
    }
}

private struct ProjectInspectorView: View {
    @ObservedObject var document: ProjectDocumentViewModel
    let project: ProjectState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Inspector")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let clip = selectedClip {
                        clipDetails(clip)
                    } else if let asset = selectedAsset {
                        assetDetails(asset)
                    } else {
                        projectDetails
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
        .background(.regularMaterial)
    }

    private var selectedClip: TimelineClip? {
        project.clips.first { $0.id == document.selectedClipID }
    }

    private var selectedAsset: MediaAsset? {
        project.mediaLibrary.first { $0.id == document.selectedAssetID }
    }

    @ViewBuilder
    private func clipDetails(_ clip: TimelineClip) -> some View {
        Text("Timeline Clip")
            .font(.title3.bold())
        if let asset = project.mediaLibrary.first(where: { $0.id == clip.assetID }) {
            InspectorValue(label: "Source", value: URL(fileURLWithPath: asset.path.absoluteFallback).lastPathComponent)
        }
        InspectorValue(label: "Start", value: formatDuration(clip.sourceRange.start))
        InspectorValue(label: "Duration", value: formatDuration(clip.sourceRange.duration))
        if let location = document.playbackLocation,
           location.clipID == clip.id,
           let asset = project.mediaLibrary.first(where: { $0.id == clip.assetID }) {
            InspectorValue(
                label: "Playhead in clip",
                value: "+\(location.clipFrameOffset) timeline frames"
            )
            InspectorValue(
                label: "Source timecode",
                value: (try? asset.inspected.frameRate.timecode(for: location.sourceTime))
                    ?? formatDuration(location.sourceTime)
            )
        }
        InspectorValue(label: "Stabilization passes", value: "\(clip.stabilizationPasses.count)")
        let stabilizationStatus = document.stabilizationStatus(for: clip, in: project)
        InspectorValue(label: "Stabilization", value: stabilizationStatus.title)
        if case let .stale(reason) = stabilizationStatus {
            Text(reason.localizedDescription)
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
        Text("Audio remains linked to this clip.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func assetDetails(_ asset: MediaAsset) -> some View {
        Text("Source File")
            .font(.title3.bold())
        InspectorValue(label: "Filename", value: URL(fileURLWithPath: asset.path.absoluteFallback).lastPathComponent)
        InspectorValue(label: "Dimensions", value: "\(asset.inspected.width)×\(asset.inspected.height)")
        InspectorValue(label: "Frame rate", value: formatFrameRate(asset.inspected.frameRate))
        InspectorValue(label: "Duration", value: formatDuration(asset.inspected.duration))
        InspectorValue(label: "Video", value: asset.inspected.videoCodec.uppercased())
        InspectorValue(label: "Audio", value: asset.inspected.audioCodec?.uppercased() ?? "None")
        Text(asset.path.absoluteFallback)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
    }

    private var projectDetails: some View {
        Group {
            Text(project.name)
                .font(.title3.bold())
            InspectorValue(label: "Sources", value: "\(project.mediaLibrary.count)")
            InspectorValue(label: "Clips", value: "\(project.clips.count)")
        }
    }
}

private extension StabilizationStatus {
    var title: String {
        switch self {
        case .none: "Not stabilized"
        case .valid: "Current"
        case .stale: "Needs update"
        }
    }
}

private struct InspectorValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}

struct ThumbnailArtwork: View {
    let service: ThumbnailService
    let projectID: ProjectState.ID
    let request: ThumbnailRequest?

    @State private var image: NSImage?
    @State private var failed = false
    @State private var consumerID = UUID()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.black.opacity(0.78))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                Image(systemName: failed ? "photo.badge.exclamationmark" : "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: request) {
            image = nil
            failed = false
            guard let request else {
                failed = true
                return
            }
            let currentConsumer = UUID()
            consumerID = currentConsumer
            do {
                let url = try await withTaskCancellationHandler {
                    try await service.thumbnail(
                        for: request,
                        projectID: projectID,
                        consumerID: currentConsumer
                    )
                } onCancel: {
                    Task {
                        await service.cancel(
                            request: request,
                            projectID: projectID,
                            consumerID: currentConsumer
                        )
                    }
                }
                try Task.checkCancellation()
                image = NSImage(contentsOf: url)
                failed = image == nil
            } catch is CancellationError {
                // Lazy cells cancel work when they leave the visible/prefetch region.
            } catch {
                failed = true
            }
        }
        .onDisappear {
            guard let request else { return }
            let currentConsumer = consumerID
            Task {
                await service.cancel(
                    request: request,
                    projectID: projectID,
                    consumerID: currentConsumer
                )
            }
        }
        .accessibilityLabel(failed ? "Thumbnail unavailable" : "Video thumbnail")
    }
}

private func formatDuration(_ time: MediaTime) -> String {
    let seconds = max(0, Double(time.value) / Double(time.timescale))
    let totalSeconds = Int(seconds.rounded(.down))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let remainder = totalSeconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }
    return String(format: "%d:%02d", minutes, remainder)
}

private func formatFrameRate(_ rate: FrameRate) -> String {
    let value = Double(rate.numerator) / Double(rate.denominator)
    return value.rounded() == value
        ? "\(Int(value)) fps"
        : String(format: "%.2f fps", value)
}
