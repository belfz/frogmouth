import Foundation
import Testing

@testable import FrogmouthCore

@Test func renderPlannerMapsUniqueInputsExactFramesAudioPolicyAndBitrate() throws {
    let fixture = try makeSyntheticRenderFixture()
    let plan = try TimelineRenderPlanner().plan(fixture.request)

    #expect(plan.inputs.map(\.assetID) == [fixture.audioAsset.id, fixture.silentAsset.id])
    #expect(plan.inputs.map(\.index) == [0, 1])
    #expect(plan.clips.map(\.inputIndex) == [0, 0, 1, 0])
    #expect(plan.clips.map(\.sourceStartFrame) == [0, 24, 0, 48])
    #expect(plan.clips.map(\.sourceEndFrame) == [24, 48, 30, 72])
    #expect(plan.clips.map(\.timelineFrameCount) == [24, 24, 24, 24])
    #expect(plan.totalFrames == 96)
    #expect(plan.hasAudio)
    #expect(plan.targetVideoBitrate == 72_000_000)

    #expect(plan.clips[0].audioFadeOutDuration == 0)
    #expect(plan.clips[1].audioFadeInDuration == 0)
    #expect(plan.clips[1].audioFadeOutDuration == TimelineRenderPlanner.audioFadeDuration)
    #expect(plan.clips[2].audioFadeInDuration == TimelineRenderPlanner.audioFadeDuration)
    #expect(plan.clips[2].audioFadeOutDuration == TimelineRenderPlanner.audioFadeDuration)
    #expect(plan.clips[3].audioFadeInDuration == TimelineRenderPlanner.audioFadeDuration)
    #expect(plan.clips[3].stabilizationPasses.map(\.effectID) == fixture.effects.map(\.id))
}

@Test func renderPlannerScalesTheFourKBitrateFloorForFullHDMovSources() throws {
    let rate = try FrameRate(numerator: 30, denominator: 1)
    let colour = VideoColourMetadata(
        primaries: nil,
        transferFunction: nil,
        matrix: nil,
        range: nil
    )
    let url = URL(fileURLWithPath: "/tmp/trail camera.mov")
    let asset = syntheticAsset(
        url: url,
        rate: rate,
        frames: 900,
        width: 1_920,
        height: 1_080,
        bitrate: 14_844_567,
        hasAudio: true,
        colour: colour
    )
    let project = ProjectState(
        name: "Trail camera",
        mediaLibrary: [asset],
        timelineFormat: TimelineFormat(
            width: 1_920,
            height: 1_080,
            frameRate: rate,
            colour: colour,
            audioSampleRate: 32_000,
            audioChannelCount: 1
        ),
        clips: [TimelineClip(
            assetID: asset.id,
            sourceRange: try frameRange(rate, start: 0, count: 900)
        )]
    )

    let plan = try TimelineRenderPlanner().plan(TimelineRenderRequest(
        project: project,
        mediaURLs: [asset.id: url]
    ))

    #expect(plan.targetVideoBitrate == 10_253_906)
}

@Test func timelineFFmpegSnapshotCoversSpecialPathsRepeatedAssetsSilenceAndStackedPasses() throws {
    let fixture = try makeSyntheticRenderFixture()
    let plan = try TimelineRenderPlanner().plan(fixture.request)
    let output = URL(fileURLWithPath: "/tmp/Exports/Bird sequence — final.mov")
    let arguments = try TimelineFFmpegCommandFactory.arguments(
        for: plan,
        output: output,
        encoding: .verification
    )

    #expect(arguments.filter { $0 == fixture.audioURL.path }.count == 1)
    #expect(arguments.filter { $0 == fixture.silentURL.path }.count == 1)
    #expect(arguments.last == output.path)
    #expect(arguments.contains("24/1"))
    #expect(arguments.contains("cfr"))
    #expect(arguments.contains("prores_ks"))
    #expect(arguments.contains("pcm_s16le"))

    let graphIndex = try #require(arguments.firstIndex(of: "-filter_complex"))
    let graph = arguments[graphIndex + 1]
    #expect(graph.contains("[0:v]split=3[vsrc0_0][vsrc0_1][vsrc0_2]"))
    #expect(graph.contains("[0:a]asplit=3[asrc0_0][asrc0_1][asrc0_2]"))
    #expect(graph.contains("anullsrc=r=48000:cl=stereo"))
    #expect(graph.contains("concat=n=4:v=1:a=1[vout][aout]"))
    #expect(graph.contains("afade=t=out"))
    #expect(graph.contains("afade=t=in"))
    #expect(graph.contains("trim=start_frame=36:end_frame=84"))
    #expect(graph.contains("trim=start_frame=6:end_frame=42"))
    #expect(graph.contains("trim=start_frame=6:end_frame=30"))
    let firstTransform = graph.range(of: "first bird\\'s pass.trf")
    let secondTransform = graph.range(of: "żółw second.trf")
    #expect(firstTransform != nil)
    #expect(secondTransform != nil)
    if let firstTransform, let secondTransform {
        #expect(firstTransform.lowerBound < secondTransform.lowerBound)
    }
}

@Test func renderPlannerRejectsMissingTransformsAndNonFrameAlignedSourceBoundaries() throws {
    let fixture = try makeSyntheticRenderFixture()
    let missingTransforms = TimelineRenderRequest(
        project: fixture.project,
        mediaURLs: fixture.request.mediaURLs
    )
    #expect(throws: TimelineRenderPlanningError.missingStabilizationTransforms(
        fixture.effects[0].id
    )) {
        _ = try TimelineRenderPlanner().plan(missingTransforms)
    }

    var project = fixture.project
    project.clips[0] = TimelineClip(
        id: project.clips[0].id,
        assetID: fixture.audioAsset.id,
        sourceRange: try MediaTimeRange(
            start: MediaTime(value: 1, timescale: 100),
            duration: MediaTime(value: 1, timescale: 1)
        )
    )
    #expect(throws: TimelineRenderPlanningError.self) {
        _ = try TimelineRenderPlanner().plan(TimelineRenderRequest(
            project: project,
            mediaURLs: fixture.request.mediaURLs
        ))
    }
}

@Test func allSilentTimelineOmitsAudioBranchesAndOutputMapping() throws {
    let fixture = try makeSyntheticRenderFixture()
    let clip = TimelineClip(
        assetID: fixture.silentAsset.id,
        sourceRange: try MediaTimeRange(
            start: .zero,
            duration: fixture.silentAsset.inspected.frameRate.time(forFrame: 24)
        )
    )
    let project = ProjectState(
        name: "Silent",
        mediaLibrary: [fixture.silentAsset],
        timelineFormat: fixture.project.timelineFormat,
        clips: [clip]
    )
    let plan = try TimelineRenderPlanner().plan(TimelineRenderRequest(
        project: project,
        mediaURLs: [fixture.silentAsset.id: fixture.silentURL]
    ))
    let arguments = try TimelineFFmpegCommandFactory.arguments(
        for: plan,
        output: URL(fileURLWithPath: "/tmp/silent.mov"),
        encoding: .verification
    )
    let graphIndex = try #require(arguments.firstIndex(of: "-filter_complex"))
    #expect(!plan.hasAudio)
    #expect(arguments[graphIndex + 1].contains("concat=n=1:v=1:a=0[vout]"))
    #expect(!arguments.contains("[aout]"))
    #expect(!arguments.contains("pcm_s16le"))
}

@Test func highRateTimelineUsesExplicitRationalCadenceAndDeliveryPolicy() throws {
    let rate = try FrameRate(numerator: 60_000, denominator: 1_001)
    let colour = VideoColourMetadata(
        primaries: "bt709",
        transferFunction: "bt709",
        matrix: "bt709",
        range: "full"
    )
    let url = URL(fileURLWithPath: "/tmp/high rate bird.mp4")
    let asset = syntheticAsset(
        url: url,
        rate: rate,
        frames: 60,
        width: 320,
        bitrate: 40_000_000,
        hasAudio: true,
        colour: colour
    )
    let project = ProjectState(
        name: "High rate",
        mediaLibrary: [asset],
        timelineFormat: TimelineFormat(
            width: 320,
            height: 180,
            frameRate: rate,
            colour: colour,
            audioSampleRate: 48_000,
            audioChannelCount: 2
        ),
        clips: [TimelineClip(
            assetID: asset.id,
            sourceRange: try frameRange(rate, start: 0, count: 40)
        )]
    )
    let plan = try TimelineRenderPlanner().plan(TimelineRenderRequest(
        project: project,
        mediaURLs: [asset.id: url]
    ))
    let arguments = try TimelineFFmpegCommandFactory.arguments(
        for: plan,
        output: URL(fileURLWithPath: "/tmp/high-rate-export.mp4")
    )
    let graphIndex = try #require(arguments.firstIndex(of: "-filter_complex"))
    let graph = arguments[graphIndex + 1]
    #expect(plan.totalFrames == 40)
    #expect(arguments.contains("60000/1001"))
    #expect(graph.contains("fps=fps=60000/1001:round=near"))
    #expect(graph.contains("setpts=N*1001/(60000*TB)"))
    #expect(arguments.contains("hevc_videotoolbox"))
    let constantBitrateIndex = try #require(arguments.firstIndex(of: "-constant_bit_rate"))
    #expect(arguments[constantBitrateIndex + 1] == "true")
    #expect(arguments.contains("hvc1"))
    #expect(arguments.contains("aac"))
    #expect(arguments.contains("+faststart"))
    #expect(arguments.contains(String(plan.targetVideoBitrate)))
}

@Test func generatedFixturesRenderExactOrderedCutsWithSynchronizedAudio() async throws {
    guard let installation = try? await FFmpegLocator().locateAndValidate() else { return }
    let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/test-media-fixtures", isDirectory: true)
    let baseURL = fixtures.appendingPathComponent("base-24fps-320x180.mp4")
    let wideURL = fixtures.appendingPathComponent("wide-30000-1001-426x180.mp4")
    let silentURL = fixtures.appendingPathComponent("silent-24fps-320x180.mp4")
    guard FileManager.default.fileExists(atPath: baseURL.path),
          FileManager.default.fileExists(atPath: wideURL.path),
          FileManager.default.fileExists(atPath: silentURL.path) else { return }

    let inspector = AVProjectMediaFactsInspector()
    let base = MediaAsset(
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: baseURL.path),
        fingerprint: MediaFingerprint(fileSize: 1, modificationTimeNanoseconds: 1),
        inspected: try await inspector.inspect(url: baseURL)
    )
    let wide = MediaAsset(
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: wideURL.path),
        fingerprint: MediaFingerprint(fileSize: 2, modificationTimeNanoseconds: 2),
        inspected: try await inspector.inspect(url: wideURL)
    )
    let silent = MediaAsset(
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: silentURL.path),
        fingerprint: MediaFingerprint(fileSize: 3, modificationTimeNanoseconds: 3),
        inspected: try await inspector.inspect(url: silentURL)
    )
    let rate24 = try FrameRate(numerator: 24, denominator: 1)
    let rateWide = try FrameRate(numerator: 30_000, denominator: 1_001)
    let project = ProjectState(
        name: "Render fixture",
        mediaLibrary: [base, wide, silent],
        timelineFormat: TimelineFormat(
            width: 320,
            height: 180,
            frameRate: rate24,
            colour: base.inspected.colour,
            audioSampleRate: 48_000,
            audioChannelCount: 2
        ),
        clips: [
            TimelineClip(
                assetID: base.id,
                sourceRange: try frameRange(rate24, start: 0, count: 12)
            ),
            TimelineClip(
                assetID: base.id,
                sourceRange: try frameRange(rate24, start: 12, count: 12)
            ),
            TimelineClip(
                assetID: wide.id,
                sourceRange: try frameRange(rateWide, start: 15, count: 30)
            ),
            TimelineClip(
                assetID: silent.id,
                sourceRange: try frameRange(rate24, start: 0, count: 12)
            ),
            TimelineClip(
                assetID: base.id,
                sourceRange: try frameRange(rate24, start: 24, count: 12)
            ),
        ]
    )
    let plan = try TimelineRenderPlanner().plan(TimelineRenderRequest(
        project: project,
        mediaURLs: [base.id: baseURL, wide.id: wideURL, silent.id: silentURL]
    ))
    #expect(plan.totalFrames == 72)

    let workspace = try SessionWorkspace()
    defer { workspace.removeAll() }
    let output = workspace.directory.appendingPathComponent("timeline-verification.mov")
    let runner = FFmpegRunner(diagnostics: DiagnosticLogStore(baseDirectory: workspace.directory))
    _ = try await runner.run(
        executable: installation.executableURL,
        arguments: try TimelineFFmpegCommandFactory.arguments(
            for: plan,
            output: output,
            encoding: .verification
        ),
        duration: 3,
        sessionID: "timeline-render-integration",
        phase: "render"
    ) { _ in }

    let probe = try probeOutput(
        output,
        ffprobe: installation.executableURL.deletingLastPathComponent()
            .appendingPathComponent("ffprobe")
    )
    let video = try #require(probe.streams.first { $0.codecType == "video" })
    let audio = try #require(probe.streams.first { $0.codecType == "audio" })
    #expect(video.width == 320)
    #expect(video.height == 180)
    #expect(video.averageFrameRate == "24/1")
    #expect(video.readFrames == "72")
    #expect(audio.sampleRate == "48000")
    #expect(audio.channels == 2)
    #expect(abs((Double(probe.format.duration) ?? 0) - 3) < 0.001)

    let first440 = try zeroCrossingRate(output, start: 0.25, ffmpeg: installation.executableURL)
    let second440 = try zeroCrossingRate(output, start: 0.75, ffmpeg: installation.executableURL)
    let middle550 = try zeroCrossingRate(output, start: 1.25, ffmpeg: installation.executableURL)
    let silence = try zeroCrossingRate(output, start: 2.25, ffmpeg: installation.executableURL)
    let final440 = try zeroCrossingRate(output, start: 2.75, ffmpeg: installation.executableURL)
    #expect((0.017...0.020).contains(first440))
    #expect((0.017...0.020).contains(second440))
    #expect((0.021...0.025).contains(middle550))
    #expect(silence < 0.001)
    #expect((0.017...0.020).contains(final440))
}

private struct SyntheticRenderFixture {
    let project: ProjectState
    let request: TimelineRenderRequest
    let audioAsset: MediaAsset
    let silentAsset: MediaAsset
    let audioURL: URL
    let silentURL: URL
    let effects: [StabilizationEffect]
}

private func makeSyntheticRenderFixture() throws -> SyntheticRenderFixture {
    let rate24 = try FrameRate(numerator: 24, denominator: 1)
    let rate30 = try FrameRate(numerator: 30, denominator: 1)
    let colour = VideoColourMetadata(
        primaries: "bt709",
        transferFunction: "bt709",
        matrix: "bt709",
        range: "full"
    )
    let audioURL = URL(fileURLWithPath: "/tmp/Wildlife 🐦/Heron's morning.MP4")
    let silentURL = URL(fileURLWithPath: "/tmp/Wildlife 🐦/silent pond.MP4")
    let audioAsset = syntheticAsset(
        url: audioURL,
        rate: rate24,
        frames: 120,
        width: 320,
        bitrate: 120_000_000,
        hasAudio: true,
        colour: colour
    )
    let silentAsset = syntheticAsset(
        url: silentURL,
        rate: rate30,
        frames: 120,
        width: 426,
        bitrate: 60_000_000,
        hasAudio: false,
        colour: colour
    )
    let firstCoverage = try frameRange(rate24, start: 36, count: 48)
    let secondCoverage = try frameRange(rate24, start: 42, count: 36)
    let effects = [
        StabilizationEffect(
            mode: .steady,
            analysisCoverage: firstCoverage,
            processingRevision: 1
        ),
        StabilizationEffect(
            mode: .naturalMotion,
            analysisCoverage: secondCoverage,
            processingRevision: 1
        ),
    ]
    let clips = [
        TimelineClip(
            assetID: audioAsset.id,
            sourceRange: try frameRange(rate24, start: 0, count: 24)
        ),
        TimelineClip(
            assetID: audioAsset.id,
            sourceRange: try frameRange(rate24, start: 24, count: 24)
        ),
        TimelineClip(
            assetID: silentAsset.id,
            sourceRange: try frameRange(rate30, start: 0, count: 30)
        ),
        TimelineClip(
            assetID: audioAsset.id,
            sourceRange: try frameRange(rate24, start: 48, count: 24),
            stabilizationPasses: effects
        ),
    ]
    let project = ProjectState(
        name: "Frogmouth unicode fixture",
        mediaLibrary: [audioAsset, silentAsset],
        timelineFormat: TimelineFormat(
            width: 320,
            height: 180,
            frameRate: rate24,
            colour: colour,
            audioSampleRate: 48_000,
            audioChannelCount: 2
        ),
        clips: clips
    )
    let transforms = [
        effects[0].id: URL(fileURLWithPath: "/tmp/Transforms/first bird's pass.trf"),
        effects[1].id: URL(fileURLWithPath: "/tmp/Transforms/żółw second.trf"),
    ]
    return SyntheticRenderFixture(
        project: project,
        request: TimelineRenderRequest(
            project: project,
            mediaURLs: [audioAsset.id: audioURL, silentAsset.id: silentURL],
            stabilizationTransforms: [clips[3].id: transforms]
        ),
        audioAsset: audioAsset,
        silentAsset: silentAsset,
        audioURL: audioURL,
        silentURL: silentURL,
        effects: effects
    )
}

private func syntheticAsset(
    url: URL,
    rate: FrameRate,
    frames: Int64,
    width: Int,
    height: Int = 180,
    bitrate: Int64,
    hasAudio: Bool,
    colour: VideoColourMetadata
) -> MediaAsset {
    MediaAsset(
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: url.path),
        fingerprint: MediaFingerprint(fileSize: 100, modificationTimeNanoseconds: 200),
        inspected: PersistedMediaFacts(
            duration: try! rate.time(forFrame: frames),
            width: width,
            height: height,
            frameRate: rate,
            videoBitrate: bitrate,
            videoCodec: "h264",
            audioCodec: hasAudio ? "aac" : nil,
            audioSampleRate: hasAudio ? 48_000 : nil,
            audioChannelCount: hasAudio ? 2 : nil,
            colour: colour
        )
    )
}

private func frameRange(_ rate: FrameRate, start: Int64, count: Int64) throws -> MediaTimeRange {
    try MediaTimeRange(start: rate.time(forFrame: start), duration: rate.time(forFrame: count))
}

private struct ProbeOutput: Decodable {
    struct Stream: Decodable {
        let codecType: String
        let width: Int?
        let height: Int?
        let averageFrameRate: String?
        let readFrames: String?
        let sampleRate: String?
        let channels: Int?

        enum CodingKeys: String, CodingKey {
            case codecType = "codec_type"
            case width
            case height
            case averageFrameRate = "avg_frame_rate"
            case readFrames = "nb_read_frames"
            case sampleRate = "sample_rate"
            case channels
        }
    }

    struct Format: Decodable { let duration: String }
    let streams: [Stream]
    let format: Format
}

private func probeOutput(_ url: URL, ffprobe: URL) throws -> ProbeOutput {
    let data = try runProcess(
        executable: ffprobe,
        arguments: [
            "-v", "error",
            "-count_frames",
            "-show_entries", "stream=codec_type,width,height,avg_frame_rate,nb_read_frames,sample_rate,channels:format=duration",
            "-of", "json",
            url.path,
        ]
    )
    return try JSONDecoder().decode(ProbeOutput.self, from: data)
}

private func zeroCrossingRate(_ url: URL, start: Double, ffmpeg: URL) throws -> Double {
    let data = try runProcess(
        executable: ffmpeg,
        arguments: [
            "-hide_banner",
            "-ss", String(start),
            "-t", "0.2",
            "-i", url.path,
            "-vn",
            "-af", "astats=metadata=0:reset=0",
            "-f", "null",
            "-",
        ],
        acceptsFailure: false
    )
    let output = String(decoding: data, as: UTF8.self)
    let line = output.split(separator: "\n").last { $0.contains("Zero crossings rate") }
    guard let value = line?.split(separator: ":").last,
          let result = Double(value.trimmingCharacters(in: .whitespaces)) else {
        throw FrogmouthError.outputValidationFailed("Could not read the audio zero-crossing rate.")
    }
    return result
}

private func runProcess(
    executable: URL,
    arguments: [String],
    acceptsFailure: Bool = false
) throws -> Data {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if !acceptsFailure, process.terminationStatus != 0 {
        throw FrogmouthError.outputValidationFailed(String(decoding: data, as: UTF8.self))
    }
    return data
}
