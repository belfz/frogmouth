import Foundation
import Testing

@testable import FrogmouthCore

@Test func qualityPolicyUsesConservativeAutomaticBitrate() {
    #expect(QualityPolicy.targetVideoBitrate(sourceBitrate: 120_000_000) == 72_000_000)
    #expect(QualityPolicy.targetVideoBitrate(sourceBitrate: 10_000_000) == 35_000_000)
    #expect(QualityPolicy.targetVideoBitrate(sourceBitrate: 200_000_000) == 80_000_000)
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

@Test func installedFFmpegCanAnalyzeAndRenderAClipScopedAudioLinkedProxy() async throws {
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
    let range = try MediaTimeRange(
        start: .zero,
        duration: MediaTime(value: 1, timescale: 1)
    )
    let effect = StabilizationEffect(
        mode: .naturalMotion,
        analysisCoverage: range,
        processingRevision: StabilizationCacheIdentityBuilder.currentProcessingRevision
    )
    let clip = TimelineClip(
        assetID: UUID(),
        sourceRange: range,
        stabilizationPasses: [effect]
    )
    let diagnostics = DiagnosticLogStore(baseDirectory: workspace.directory)
    let runner = FFmpegRunner(diagnostics: diagnostics)

    _ = try await runner.run(
        executable: installation.executableURL,
        arguments: try ClipStabilizationCommandFactory.analysis(
            input: sample,
            clip: clip,
            effectIndex: 0,
            precedingTransforms: [:],
            outputTransforms: workspace.transformsURL
        ),
        duration: 1,
        sessionID: "integration-test",
        phase: "analysis"
    ) { _ in }
    #expect(FileManager.default.fileExists(atPath: workspace.transformsURL.path))

    var previewArguments = try ClipStabilizationCommandFactory.preview(
        input: sample,
        clip: clip,
        effectIndex: 0,
        transforms: [effect.id: workspace.transformsURL],
        output: workspace.previewURL
    )
    // VideoToolbox is denied inside the Codex command sandbox. The shipping
    // command still requires it; this substitution validates the filter chain.
    if let encoderIndex = previewArguments.firstIndex(of: "hevc_videotoolbox") {
        previewArguments[encoderIndex] = "libx265"
    }
    _ = try await runner.run(
        executable: installation.executableURL,
        arguments: previewArguments,
        duration: 1,
        sessionID: "integration-test",
        phase: "preview"
    ) { _ in }

    let previewInfo = try await MediaInspector().inspect(url: workspace.previewURL)
    #expect(previewInfo.videoCodec == "hvc1")
    #expect(previewInfo.audioCodec == "aac")
    #expect(previewInfo.width == 1024)
    #expect(previewInfo.height == 540)
}
