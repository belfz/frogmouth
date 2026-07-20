@preconcurrency import AVFoundation
import FrogmouthCore
import Foundation

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published private(set) var isBuilding = false
    @Published private(set) var isPlaying = false
    @Published private(set) var location: PlaybackLocation?
    @Published private(set) var errorMessage: String?

    let player = AVPlayer()
    var playheadDidChange: ((Int64, PlaybackLocation?) -> Void)?

    private var segmentMap: PlaybackSegmentMap?
    private var buildTask: Task<Void, Never>?
    private var buildGeneration = UUID()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var desiredFrame: Int64 = 0
    private let diagnostics: DiagnosticLogStore?

    init(diagnostics: DiagnosticLogStore? = nil) {
        self.diagnostics = diagnostics
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.playerTimeChanged(time)
            }
        }
    }

    func rebuild(
        project: ProjectState?,
        mediaURLs: [MediaAsset.ID: URL],
        clipSourceOverrides: [TimelineClip.ID: PlaybackMediaSource] = [:],
        preservingFrame: Int64
    ) {
        buildTask?.cancel()
        buildGeneration = UUID()
        desiredFrame = preservingFrame
        errorMessage = nil

        guard let project, !project.clips.isEmpty else {
            diagnostics?.append(
                level: "INFO",
                sessionID: project?.id.uuidString ?? "app",
                phase: "playback-composition",
                event: "composition.cleared"
            )
            isBuilding = false
            isPlaying = false
            segmentMap = nil
            location = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            removeEndObserver()
            publish(frame: 0)
            return
        }

        let generation = buildGeneration
        let startedAt = Date()
        let shouldResume = player.timeControlStatus == .playing
        player.pause()
        isPlaying = false
        isBuilding = true
        let request = PlaybackBuildRequest(
            project: project,
            mediaURLs: mediaURLs,
            clipSourceOverrides: clipSourceOverrides
        )
        diagnostics?.append(
            level: "INFO",
            sessionID: project.id.uuidString,
            phase: "playback-composition",
            event: "composition.build-started",
            fields: [
                "generation": generation.uuidString,
                "clip_count": String(project.clips.count),
                "media_url_count": String(mediaURLs.count),
                "stabilized_override_count": String(clipSourceOverrides.count),
                "preserving_frame": String(preservingFrame),
            ]
        )

        buildTask = Task { [weak self] in
            do {
                let detachedBuild = Task.detached(priority: .userInitiated) {
                    try await PlaybackCompositionBuilder().build(request)
                }
                let built = try await withTaskCancellationHandler {
                    try await detachedBuild.value
                } onCancel: {
                    detachedBuild.cancel()
                }
                try Task.checkCancellation()
                guard let self, self.buildGeneration == generation else { return }
                let item = built.makePlayerItem()
                self.segmentMap = built.segmentMap
                self.observeEnd(of: item)
                self.player.replaceCurrentItem(with: item)
                self.isBuilding = false
                self.diagnostics?.append(
                    level: "INFO",
                    sessionID: project.id.uuidString,
                    phase: "playback-composition",
                    event: "composition.build-completed",
                    fields: [
                        "generation": generation.uuidString,
                        "segment_count": String(built.segmentMap.segments.count),
                        "total_frames": String(built.segmentMap.totalFrames),
                        "frame_rate": built.segmentMap.timelineFrameRate.diagnosticRational,
                        "elapsed_ms": String(Int(Date().timeIntervalSince(startedAt) * 1_000)),
                    ]
                )
                self.seek(toFrame: self.desiredFrame)
                if shouldResume {
                    self.player.play()
                    self.isPlaying = true
                }
            } catch is CancellationError {
                // A newer project state superseded this composition.
                self?.diagnostics?.append(
                    level: "INFO",
                    sessionID: project.id.uuidString,
                    phase: "playback-composition",
                    event: "composition.build-cancelled",
                    fields: ["generation": generation.uuidString]
                )
            } catch {
                guard let self, self.buildGeneration == generation else { return }
                self.isBuilding = false
                self.isPlaying = false
                self.segmentMap = nil
                self.location = nil
                self.removeEndObserver()
                self.player.replaceCurrentItem(with: nil)
                self.errorMessage = error.localizedDescription
                    + " If the problem continues, choose Diagnostics → Copy Diagnostics and share the result."
                self.diagnostics?.append(
                    level: "ERROR",
                    sessionID: project.id.uuidString,
                    phase: "playback-composition",
                    event: "composition.build-failed",
                    fields: [
                        "generation": generation.uuidString,
                        "error_type": String(reflecting: type(of: error)),
                        "message": error.localizedDescription,
                    ]
                )
            }
        }
    }

    func togglePlayback() {
        guard player.currentItem != nil, !isBuilding else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
            return
        }
        if let segmentMap, desiredFrame >= segmentMap.totalFrames {
            seek(toFrame: 0)
        }
        player.play()
        isPlaying = true
    }

    func seek(toFrame requestedFrame: Int64) {
        let totalFrames = segmentMap?.totalFrames ?? requestedFrame
        let frame = min(max(0, requestedFrame), max(0, totalFrames))
        desiredFrame = frame
        publish(frame: frame)
        guard let rate = segmentMap?.timelineFrameRate, player.currentItem != nil,
              let time = try? rate.time(forFrame: frame).cmTime else { return }
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func shutdown() {
        buildTask?.cancel()
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func playerTimeChanged(_ time: CMTime) {
        guard let segmentMap,
              let exactTime = try? MediaTime(cmTime: time),
              let frame = try? segmentMap.timelineFrameRate.frameIndex(
                  for: exactTime,
                  rounding: .towardNegativeInfinity
              ) else { return }
        publish(frame: min(max(0, frame), segmentMap.totalFrames))
    }

    private func observeEnd(of item: AVPlayerItem) {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.publish(frame: self.segmentMap?.totalFrames ?? 0)
            }
        }
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func publish(frame: Int64) {
        desiredFrame = frame
        location = try? segmentMap?.location(atTimelineFrame: frame)
        playheadDidChange?(frame, location)
    }
}
