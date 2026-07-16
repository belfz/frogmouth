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

                TimelineViewerPlaceholder(project: project)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

                if showsInspector {
                    ProjectInspectorView(document: document, project: project)
                        .frame(minWidth: 220, idealWidth: 270, maxWidth: 360)
                }
            }

            Divider()

            TimelineAssemblyStrip(document: document, project: project)
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
    let asset: MediaAsset
    let usageCount: Int
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.78))
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
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
        .draggable(asset.id.uuidString)
    }

    private var filename: String {
        URL(fileURLWithPath: asset.path.absoluteFallback).lastPathComponent
    }
}

private struct TimelineViewerPlaceholder: View {
    let project: ProjectState

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: project.clips.isEmpty ? "rectangle.stack.badge.plus" : "play.rectangle")
                    .font(.system(size: 42))
                Text(project.clips.isEmpty ? "Build the timeline" : "Timeline Viewer")
                    .font(.title2.bold())
                Text(project.clips.isEmpty
                     ? "Append or drag a source from the Media Library."
                     : "\(project.clips.count) gapless clip\(project.clips.count == 1 ? "" : "s") ready for timeline playback.")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Timeline viewer")
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
        InspectorValue(label: "Stabilization passes", value: "\(clip.stabilizationPasses.count)")
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

private struct TimelineAssemblyStrip: View {
    @ObservedObject var document: ProjectDocumentViewModel
    let project: ProjectState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Timeline")
                    .font(.headline)
                Text("Gapless · hard cuts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(project.clips.count) clip\(project.clips.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)

            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(project.clips.enumerated()), id: \.element.id) { index, clip in
                        TimelineInsertionBoundary(document: document, index: index)
                        TimelineAssemblyClip(
                            document: document,
                            clip: clip,
                            filename: filename(for: clip.assetID),
                            isSelected: document.selectedClipID == clip.id
                        )
                    }
                    TimelineInsertionBoundary(document: document, index: project.clips.count)

                    if project.clips.isEmpty {
                        Text("Drag a Media Library source here")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 260, height: 90)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func filename(for assetID: MediaAsset.ID) -> String {
        guard let asset = project.mediaLibrary.first(where: { $0.id == assetID }) else {
            return "Missing source"
        }
        return URL(fileURLWithPath: asset.path.absoluteFallback).lastPathComponent
    }
}

private struct TimelineAssemblyClip: View {
    @ObservedObject var document: ProjectDocumentViewModel
    let clip: TimelineClip
    let filename: String
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.76))
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
            }
            .frame(height: 50)
            Text(filename)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(formatDuration(clip.sourceRange.duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(7)
        .frame(width: 150, height: 108, alignment: .topLeading)
        .background(
            isSelected ? Color.accentColor.opacity(0.30) : Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { document.selectClip(clip.id) }
    }
}

private struct TimelineInsertionBoundary: View {
    @ObservedObject var document: ProjectDocumentViewModel
    let index: Int
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isTargeted ? Color.accentColor : Color.clear)
                .frame(width: 3, height: 104)
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(Color.accentColor)
                .opacity(isTargeted ? 1 : 0)
        }
        .frame(width: 18, height: 108)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let assetID = UUID(uuidString: value) else {
                return false
            }
            document.insertAssetOnTimeline(assetID, at: index)
            return true
        } isTargeted: {
            isTargeted = $0
        }
        .accessibilityLabel("Insert clip at boundary \(index + 1)")
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
