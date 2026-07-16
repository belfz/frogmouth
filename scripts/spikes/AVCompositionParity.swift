import AVFoundation
import CoreGraphics
import Foundation

private struct Rate {
    let numerator: Int32
    let denominator: Int32

    func time(forFrames frames: Int64) -> CMTime {
        CMTime(value: frames * Int64(denominator), timescale: numerator)
    }
}

private struct ClipSpec {
    let url: URL
    let sourceRate: Rate
    let sourceStartFrame: Int64
    let sourceFrameCount: Int64
    let timelineFrameCount: Int64
}

private struct SegmentManifest: Codable {
    let source: String
    let sourceStart: String
    let sourceDuration: String
    let timelineStart: String
    let timelineDuration: String
}

private struct CompositionManifest: Codable {
    let width: Int
    let height: Int
    let frameRate: String
    let duration: String
    let segments: [SegmentManifest]
}

@main
private struct AVCompositionParity {
    static func main() async throws {
        guard CommandLine.arguments.count == 7 else {
            throw NSError(
                domain: "AVCompositionParity",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Usage: AVCompositionParity <standard|high-rate> <base.mp4> <wide.mp4> <high-rate.mp4> <output.mov> <manifest.json>"]
            )
        }

        let scenario = CommandLine.arguments[1]
        let baseURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let wideURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let highRateURL = URL(fileURLWithPath: CommandLine.arguments[4])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[5])
        let manifestURL = URL(fileURLWithPath: CommandLine.arguments[6])
        let timelineRate: Rate
        let clips: [ClipSpec]

        switch scenario {
        case "standard":
            timelineRate = Rate(numerator: 24, denominator: 1)
            clips = [
                ClipSpec(
                    url: baseURL,
                    sourceRate: Rate(numerator: 24, denominator: 1),
                    sourceStartFrame: 12,
                    sourceFrameCount: 24,
                    timelineFrameCount: 24
                ),
                ClipSpec(
                    url: wideURL,
                    sourceRate: Rate(numerator: 30_000, denominator: 1_001),
                    sourceStartFrame: 15,
                    sourceFrameCount: 30,
                    timelineFrameCount: 24
                ),
                ClipSpec(
                    url: baseURL,
                    sourceRate: Rate(numerator: 24, denominator: 1),
                    sourceStartFrame: 36,
                    sourceFrameCount: 12,
                    timelineFrameCount: 12
                ),
            ]
        case "high-rate":
            timelineRate = Rate(numerator: 60_000, denominator: 1_001)
            clips = [
                ClipSpec(
                    url: highRateURL,
                    sourceRate: timelineRate,
                    sourceStartFrame: 0,
                    sourceFrameCount: 40,
                    timelineFrameCount: 40
                ),
                ClipSpec(
                    url: baseURL,
                    sourceRate: Rate(numerator: 24, denominator: 1),
                    sourceStartFrame: 12,
                    sourceFrameCount: 12,
                    timelineFrameCount: 30
                ),
                ClipSpec(
                    url: highRateURL,
                    sourceRate: timelineRate,
                    sourceStartFrame: 40,
                    sourceFrameCount: 20,
                    timelineFrameCount: 20
                ),
            ]
        default:
            throw NSError(
                domain: "AVCompositionParity",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Unknown scenario: \(scenario)"]
            )
        }

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(
                domain: "AVCompositionParity",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not create composition tracks."]
            )
        }

        var cursor = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var manifestSegments: [SegmentManifest] = []
        var compositionAudioTracks: [AVMutableCompositionTrack] = []

        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw NSError(
                    domain: "AVCompositionParity",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Missing video track in \(clip.url.path)"]
                )
            }

            let sourceStart = clip.sourceRate.time(forFrames: clip.sourceStartFrame)
            let sourceDuration = clip.sourceRate.time(forFrames: clip.sourceFrameCount)
            let sourceRange = CMTimeRange(start: sourceStart, duration: sourceDuration)
            let timelineDuration = timelineRate.time(forFrames: clip.timelineFrameCount)
            let insertedRange = CMTimeRange(start: cursor, duration: sourceDuration)
            let timelineRange = CMTimeRange(start: cursor, duration: timelineDuration)

            try compositionVideo.insertTimeRange(sourceRange, of: sourceVideo, at: cursor)
            if CMTimeCompare(sourceDuration, timelineDuration) != 0 {
                compositionVideo.scaleTimeRange(insertedRange, toDuration: timelineDuration)
            }

            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                guard let compositionAudio = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw NSError(
                        domain: "AVCompositionParity",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "Could not create an audio composition track."]
                    )
                }
                try compositionAudio.insertTimeRange(sourceRange, of: sourceAudio, at: cursor)
                if CMTimeCompare(sourceDuration, timelineDuration) != 0 {
                    compositionAudio.scaleTimeRange(insertedRange, toDuration: timelineDuration)
                }
                compositionAudioTracks.append(compositionAudio)
            }

            let naturalSize = try await sourceVideo.load(.naturalSize)
            let preferredTransform = try await sourceVideo.load(.preferredTransform)
            let orientedBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            let orientedSize = CGSize(width: abs(orientedBounds.width), height: abs(orientedBounds.height))
            let scale = min(320 / orientedSize.width, 180 / orientedSize.height)
            let translatedPreferred = preferredTransform.translatedBy(
                x: -orientedBounds.minX,
                y: -orientedBounds.minY
            )
            let scaled = translatedPreferred.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            let fittedSize = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
            let centered = scaled.concatenating(CGAffineTransform(
                translationX: (320 - fittedSize.width) / 2,
                y: (180 - fittedSize.height) / 2
            ))

            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideo)
            layer.setTransform(centered, at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = timelineRange
            instruction.layerInstructions = [layer]
            instructions.append(instruction)

            manifestSegments.append(SegmentManifest(
                source: clip.url.lastPathComponent,
                sourceStart: sourceStart.fraction,
                sourceDuration: sourceDuration.fraction,
                timelineStart: cursor.fraction,
                timelineDuration: timelineDuration.fraction
            ))
            cursor = CMTimeAdd(cursor, timelineDuration)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: 320, height: 180)
        videoComposition.frameDuration = timelineRate.time(forFrames: 1)
        videoComposition.instructions = instructions

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleProRes422LPCM
        ) else {
            throw NSError(
                domain: "AVCompositionParity",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Could not create ProRes export session."]
            )
        }
        export.videoComposition = videoComposition
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = compositionAudioTracks.map {
            AVMutableAudioMixInputParameters(track: $0)
        }
        export.audioMix = audioMix
        export.timeRange = CMTimeRange(start: .zero, duration: cursor)
        try await export.export(to: outputURL, as: .mov)

        let manifest = CompositionManifest(
            width: 320,
            height: 180,
            frameRate: "\(timelineRate.numerator)/\(timelineRate.denominator)",
            duration: cursor.fraction,
            segments: manifestSegments
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }
}

private extension CMTime {
    var fraction: String { "\(value)/\(timescale)" }
}
