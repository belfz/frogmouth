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
    let initial = EditState(sourceDuration: 10, pendingTrim: TrimRange(start: 1, end: 9))
    let trimmed = initial.committingPendingTrim()
    let stabilized = trimmed.appending(StabilizationPass(
        mode: .steady,
        transformsURL: URL(fileURLWithPath: "/tmp/steady.trf")
    ))
    var history = EditHistory()

    history.record(previous: initial, current: trimmed)
    history.record(previous: trimmed, current: stabilized)
    #expect(history.undo(current: stabilized) == trimmed)
    #expect(history.undo(current: trimmed) == initial)
    #expect(history.redo(current: initial) == trimmed)

    history.record(previous: trimmed, current: stabilized)
    #expect(!history.canRedo)
}

@Test func confirmedTrimsRebaseAndCanRepeatWithoutDroppingStabilization() {
    var state = EditState(sourceDuration: 10, pendingTrim: TrimRange(start: 2, end: 8))
    state = state.committingPendingTrim()
    #expect(state.duration == 6)
    #expect(state.pendingTrim == TrimRange(start: 0, end: 6))

    let pass = StabilizationPass(
        mode: .steady,
        transformsURL: URL(fileURLWithPath: "/tmp/pass.trf")
    )
    state = state.appending(pass)
    state.pendingTrim = TrimRange(start: 1, end: 4)
    state = state.committingPendingTrim()

    #expect(state.duration == 3)
    #expect(state.pendingTrim == TrimRange(start: 0, end: 3))
    #expect(state.hasStabilization)
    #expect(state.operations == [
        .trim(TrimRange(start: 2, end: 8)),
        .stabilization(pass),
        .trim(TrimRange(start: 1, end: 4)),
    ])
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
        sourceDuration: 10,
        operations: [.trim(TrimRange(start: 1.25, end: 8.75))],
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
    let pass = StabilizationPass(
        mode: .naturalMotion,
        transformsURL: URL(fileURLWithPath: "/tmp/transforms.trf")
    )
    let arguments = FFmpegCommandFactory.export(
        input: URL(fileURLWithPath: "/tmp/input.MP4"),
        sourceDuration: 10,
        operations: [.trim(TrimRange(start: 0, end: 9)), .stabilization(pass)],
        output: URL(fileURLWithPath: "/tmp/output.mp4"),
        targetVideoBitrate: 72_000_000
    )

    #expect(arguments.contains("hevc_videotoolbox"))
    #expect(arguments.contains("72000000"))
    #expect(arguments.contains("0:a?"))
    #expect(arguments.contains("-map_metadata"))
    #expect(arguments.contains("copy"))
    #expect(!arguments.contains("-s"))
    let filterIndex = try #require(arguments.firstIndex(of: "-vf"))
    #expect(arguments[filterIndex + 1].contains("interpol=bicubic"))
}

@Test func previewUsesFasterBilinearInterpolation() throws {
    let pass = StabilizationPass(
        mode: .steady,
        transformsURL: URL(fileURLWithPath: "/tmp/transforms.trf")
    )
    let arguments = FFmpegCommandFactory.preview(
        input: URL(fileURLWithPath: "/tmp/input.MP4"),
        sourceDuration: 10,
        operations: [.stabilization(pass)],
        output: URL(fileURLWithPath: "/tmp/preview.mp4")
    )

    let filterIndex = try #require(arguments.firstIndex(of: "-vf"))
    let filter = arguments[filterIndex + 1]
    #expect(filter.contains("interpol=bilinear"))
    #expect(filter.contains("scale=1024:-2"))
    #expect(arguments.contains("0:a?"))
    #expect(arguments.contains("copy"))
    #expect(!arguments.contains("-an"))
}

@Test func previewKeepsAudioAlignedAfterPostStabilizationTrim() {
    let pass = StabilizationPass(
        mode: .steady,
        transformsURL: URL(fileURLWithPath: "/tmp/transforms.trf")
    )
    let input = URL(fileURLWithPath: "/tmp/input.MP4")
    let arguments = FFmpegCommandFactory.preview(
        input: input,
        sourceDuration: 10,
        operations: [
            .trim(TrimRange(start: 2, end: 8)),
            .stabilization(pass),
            .trim(TrimRange(start: 1, end: 4)),
        ],
        output: URL(fileURLWithPath: "/tmp/preview.mp4")
    )

    #expect(arguments.filter { $0 == input.path }.count == 2)
    #expect(arguments.contains("1:a?"))
    #expect(arguments.contains("3.000000"))
}

@Test func operationPipelinePreservesOrderingAndScopesLaterTrims() throws {
    let first = StabilizationPass(
        mode: .steady,
        transformsURL: URL(fileURLWithPath: "/tmp/first.trf")
    )
    let second = StabilizationPass(
        mode: .naturalMotion,
        transformsURL: URL(fileURLWithPath: "/tmp/second.trf")
    )
    let operations: [EditOperation] = [
        .trim(TrimRange(start: 2, end: 8)),
        .stabilization(first),
        .trim(TrimRange(start: 1, end: 4)),
        .stabilization(second),
    ]

    let plan = FFmpegCommandFactory.pipeline(sourceDuration: 10, operations: operations)
    #expect(plan.inputStart == 2)
    #expect(plan.absoluteSourceStart == 3)
    #expect(plan.duration == 3)
    #expect(plan.filters.count == 4)
    #expect(plan.filters[0].contains("first.trf"))
    #expect(plan.filters[1].contains("trim=start=1.000000:end=4.000000"))
    #expect(plan.filters[2] == "setpts=PTS-STARTPTS")
    #expect(plan.filters[3].contains("second.trf"))

    let export = FFmpegCommandFactory.export(
        input: URL(fileURLWithPath: "/tmp/input.MP4"),
        sourceDuration: 10,
        operations: operations,
        output: URL(fileURLWithPath: "/tmp/output.mp4"),
        targetVideoBitrate: 50_000_000
    )
    #expect(export.filter { $0 == "/tmp/input.MP4" }.count == 2)
    #expect(export.contains("1:a?"))
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
