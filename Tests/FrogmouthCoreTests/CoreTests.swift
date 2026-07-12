import Foundation
import Testing

@testable import FrogmouthCore

@Test func qualityPolicyUsesConservativeAutomaticBitrate() {
    #expect(QualityPolicy.targetVideoBitrate(sourceBitrate: 120_000_000) == 72_000_000)
    #expect(QualityPolicy.targetVideoBitrate(sourceBitrate: 10_000_000) == 35_000_000)
    #expect(QualityPolicy.targetVideoBitrate(sourceBitrate: 200_000_000) == 80_000_000)
}

@Test func trimRangeIsNormalized() {
    #expect(TrimRange(start: -2, end: 14).normalized(for: 10) == TrimRange(start: 0, end: 10))
    #expect(TrimRange(start: 9.98, end: 9.99).normalized(for: 10) == TrimRange(start: 9.9, end: 10))
}

@Test func editHistorySupportsUndoRedoAndInvalidatesRedo() {
    let initial = EditState(trim: TrimRange(start: 0, end: 10), stabilization: .none)
    let trimmed = EditState(trim: TrimRange(start: 1, end: 9), stabilization: .none)
    let stabilized = EditState(trim: trimmed.trim, stabilization: .steady)
    var history = EditHistory()

    history.record(previous: initial, current: trimmed)
    history.record(previous: trimmed, current: stabilized)
    #expect(history.undo(current: stabilized) == trimmed)
    #expect(history.undo(current: trimmed) == initial)
    #expect(history.redo(current: initial) == trimmed)

    history.record(previous: trimmed, current: stabilized)
    #expect(!history.canRedo)
}

@Test func stabilizationProfilesAreFixedAndDistinct() {
    #expect(StabilizationProfile.profile(for: .none) == nil)
    #expect(StabilizationProfile.profile(for: .steady)?.smoothing == 30)
    #expect(StabilizationProfile.profile(for: .naturalMotion)?.smoothing == 8)
    #expect(StabilizationProfile.profile(for: .steady)?.accuracy == 9)
    #expect(StabilizationProfile.profile(for: .steady)?.stepSize == 12)
}

@Test func ffmpegVersionParserAcceptsCommonOutputs() {
    #expect(FFmpegLocator.parseMajorVersion("ffmpeg version 8.1.2 Copyright") == 8)
    #expect(FFmpegLocator.parseMajorVersion("ffmpeg version n7.1.5-homebrew") == 7)
    #expect(FFmpegLocator.parseSemanticVersion("ffmpeg version 8.1.2 Copyright") == "8.1.2")
    #expect(FFmpegLocator.parseMajorVersion("unrelated output") == nil)
}

@Test func analysisCommandKeepsPathsAsArgumentsAndSelectsVidstab() throws {
    let input = URL(fileURLWithPath: "/tmp/Wild bird's clip.MP4")
    let transforms = URL(fileURLWithPath: "/tmp/frogmouth session/transforms.trf")
    let profile = try #require(StabilizationProfile.profile(for: .steady))
    let arguments = FFmpegCommandFactory.analysis(
        input: input,
        trim: TrimRange(start: 1.25, end: 8.75),
        transforms: transforms,
        profile: profile
    )

    #expect(arguments.contains(input.path))
    #expect(arguments.contains("7.500000"))
    let filterIndex = try #require(arguments.firstIndex(of: "-vf"))
    let filter = arguments[filterIndex + 1]
    #expect(filter.contains("vidstabdetect"))
    #expect(filter.contains("shakiness=8"))
    #expect(filter.contains("accuracy=9"))
    #expect(filter.contains("stepsize=12"))
    #expect(filter.contains("fileformat=ascii"))
    #expect(filter.contains("frogmouth session"))
}

@Test func exportCommandPreservesAudioAndMetadataWithoutScaling() throws {
    let profile = try #require(StabilizationProfile.profile(for: .naturalMotion))
    let arguments = FFmpegCommandFactory.export(
        input: URL(fileURLWithPath: "/tmp/input.MP4"),
        trim: TrimRange(start: 0, end: 9),
        transforms: URL(fileURLWithPath: "/tmp/transforms.trf"),
        output: URL(fileURLWithPath: "/tmp/output.mp4"),
        profile: profile,
        targetVideoBitrate: 72_000_000
    )

    #expect(arguments.contains("hevc_videotoolbox"))
    #expect(arguments.contains("72000000"))
    #expect(arguments.contains("0:a?"))
    #expect(arguments.contains("-map_metadata"))
    #expect(arguments.contains("copy"))
    #expect(!arguments.contains("-s"))
}

@Test func sessionWorkspaceOwnsAndCleansItsFiles() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let workspace = try SessionWorkspace(baseDirectory: base)
    #expect(FileManager.default.fileExists(atPath: workspace.directory.path))
    try Data("test".utf8).write(to: workspace.previewURL)
    workspace.removeGeneratedMedia()
    #expect(!FileManager.default.fileExists(atPath: workspace.previewURL.path))
    workspace.removeAll()
    #expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
    try? FileManager.default.removeItem(at: base)
}

@Test func suppliedCanonSampleCanBeInspected() async throws {
    let sample = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("EOS R5 example video.MP4")
    guard FileManager.default.fileExists(atPath: sample.path) else { return }

    let info = try await MediaInspector().inspect(url: sample)
    #expect(info.width == 4096)
    #expect(info.height == 2160)
    #expect(abs(info.frameRate - 24) < 0.01)
    #expect(info.videoCodec == "avc1")
    #expect(info.audioCodec == "aac")
}

@Test func installedFFmpegCanAnalyzeAndRenderAStabilizedProxy() async throws {
    let sample = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("EOS R5 example video.MP4")
    guard FileManager.default.fileExists(atPath: sample.path),
          let installation = try? await FFmpegLocator().locateAndValidate() else { return }

    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let workspace = try SessionWorkspace(baseDirectory: base)
    defer {
        workspace.removeAll()
        try? FileManager.default.removeItem(at: base)
    }

    // Natural motion uses a 17-frame smoothing window, so a one-second/24-frame
    // slice is long enough to exercise both vid.stab passes without slowing the suite excessively.
    let profile = try #require(StabilizationProfile.profile(for: .naturalMotion))
    let trim = TrimRange(start: 0, end: 1)
    let diagnostics = DiagnosticLogStore(baseDirectory: workspace.directory)
    let runner = FFmpegRunner(diagnostics: diagnostics)

    _ = try await runner.run(
        executable: installation.executableURL,
        arguments: FFmpegCommandFactory.analysis(
            input: sample,
            trim: trim,
            transforms: workspace.transformsURL,
            profile: profile
        ),
        duration: trim.duration,
        sessionID: "integration-test",
        phase: "analysis"
    ) { _ in }
    #expect(FileManager.default.fileExists(atPath: workspace.transformsURL.path))

    var previewArguments = FFmpegCommandFactory.preview(
        input: sample,
        trim: trim,
        transforms: workspace.transformsURL,
        output: workspace.previewURL,
        profile: profile
    )
    // VideoToolbox is denied inside the Codex command sandbox. The shipping
    // command still requires it; this substitution validates the filter chain.
    if let encoderIndex = previewArguments.firstIndex(of: "hevc_videotoolbox") {
        previewArguments[encoderIndex] = "libx265"
    }
    _ = try await runner.run(
        executable: installation.executableURL,
        arguments: previewArguments,
        duration: trim.duration,
        sessionID: "integration-test",
        phase: "preview"
    ) { _ in }

    let previewInfo = try await MediaInspector().inspect(url: workspace.previewURL)
    #expect(previewInfo.videoCodec == "hvc1")
    #expect(previewInfo.width == 1024)
    #expect(previewInfo.height == 540)
}
