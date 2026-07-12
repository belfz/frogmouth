@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public protocol MediaInspecting: Sendable {
    func inspect(url: URL) async throws -> MediaInfo
}

public struct MediaInspector: MediaInspecting {
    public init() {}

    public func inspect(url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)

        do {
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, CMTimeGetSeconds(duration) > 0 else {
                throw FrogmouthError.unsupportedMedia("The asset has no usable duration.")
            }

            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw FrogmouthError.unsupportedMedia("No video stream was found.")
            }

            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let displayedSize = naturalSize.applying(transform)
            let frameRate = Double(try await videoTrack.load(.nominalFrameRate))
            let videoBitrate = Double(try await videoTrack.load(.estimatedDataRate))
            let videoFormats = try await videoTrack.load(.formatDescriptions)
            let videoCodec = Self.fourCC(videoFormats.first.map(CMFormatDescriptionGetMediaSubType) ?? 0)

            let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            var audioCodec: String?
            var sampleRate: Double?
            var channelCount: Int?
            if let audioTrack {
                let audioFormats = try await audioTrack.load(.formatDescriptions)
                if let description = audioFormats.first {
                    audioCodec = Self.fourCC(CMFormatDescriptionGetMediaSubType(description))
                    if let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                        sampleRate = streamDescription.pointee.mSampleRate
                        channelCount = Int(streamDescription.pointee.mChannelsPerFrame)
                    }
                }
            }

            let metadataItems = try await asset.load(.metadata)
            var metadata: [String: String] = [:]
            for item in metadataItems {
                guard let key = item.commonKey?.rawValue,
                      let value = try? await item.load(.stringValue) else { continue }
                metadata[key] = value
            }

            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return MediaInfo(
                url: url,
                duration: CMTimeGetSeconds(duration),
                width: Int(abs(displayedSize.width.rounded())),
                height: Int(abs(displayedSize.height.rounded())),
                frameRate: frameRate,
                videoBitrate: videoBitrate,
                videoCodec: videoCodec,
                audioCodec: audioCodec,
                audioSampleRate: sampleRate,
                audioChannelCount: channelCount,
                fileSize: Int64(values.fileSize ?? 0),
                metadata: metadata
            )
        } catch let error as FrogmouthError {
            throw error
        } catch {
            throw FrogmouthError.unsupportedMedia(error.localizedDescription)
        }
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "unknown"
    }
}
