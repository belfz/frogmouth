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
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            let minimumFrameDuration = try await videoTrack.load(.minFrameDuration)
            let exactFrameRate = try Self.exactFrameRate(
                minimumFrameDuration: minimumFrameDuration,
                nominalFrameRate: nominalFrameRate
            )
            let frameRate = Double(exactFrameRate.numerator) / Double(exactFrameRate.denominator)
            let videoBitrate = Double(try await videoTrack.load(.estimatedDataRate))
            let videoFormats = try await videoTrack.load(.formatDescriptions)
            let videoCodec = Self.fourCC(videoFormats.first.map(CMFormatDescriptionGetMediaSubType) ?? 0)
            let colour = videoFormats.first.map {
                Self.colourMetadata(from: $0, videoCodec: videoCodec)
            } ?? .unspecified

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

            var metadataItems = try await asset.load(.metadata)
            for format in try await asset.load(.availableMetadataFormats) {
                metadataItems.append(contentsOf: try await asset.loadMetadata(for: format))
            }
            var metadata: [String: String] = [:]
            for item in metadataItems {
                guard let key = item.commonKey?.rawValue
                        ?? item.identifier?.rawValue
                        ?? item.key.map({ String(describing: $0) }) else { continue }
                let value: String?
                if let stringValue = try? await item.load(.stringValue) {
                    value = stringValue
                } else if let dateValue = try? await item.load(.dateValue) {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    value = formatter.string(from: dateValue)
                } else if let numberValue = try? await item.load(.numberValue) {
                    value = numberValue.stringValue
                } else {
                    value = nil
                }
                guard let value else { continue }
                metadata[key] = value
            }
            if let creationItem = try await asset.load(.creationDate) {
                if let value = try? await creationItem.load(.stringValue) {
                    metadata[AVMetadataKey.commonKeyCreationDate.rawValue] = value
                } else if let date = try? await creationItem.load(.dateValue) {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    metadata[AVMetadataKey.commonKeyCreationDate.rawValue] = formatter.string(from: date)
                }
            }

            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return MediaInfo(
                url: url,
                duration: CMTimeGetSeconds(duration),
                exactDuration: try MediaTime(cmTime: duration),
                width: Int(abs(displayedSize.width.rounded())),
                height: Int(abs(displayedSize.height.rounded())),
                frameRate: frameRate,
                exactFrameRate: exactFrameRate,
                videoBitrate: videoBitrate,
                videoCodec: videoCodec,
                audioCodec: audioCodec,
                audioSampleRate: sampleRate,
                audioChannelCount: channelCount,
                fileSize: Int64(values.fileSize ?? 0),
                metadata: metadata,
                colour: colour
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

    private static func exactFrameRate(
        minimumFrameDuration: CMTime,
        nominalFrameRate: Float
    ) throws -> FrameRate {
        if minimumFrameDuration.isNumeric,
           minimumFrameDuration.value > 0 {
            let duration = try MediaTime(cmTime: minimumFrameDuration)
            if duration.value <= Int64(Int32.max) {
                return try FrameRate(
                    numerator: duration.timescale,
                    denominator: Int32(duration.value)
                )
            }
        }

        let nominal = Double(nominalFrameRate)
        let commonRates: [(Int32, Int32)] = [
            (24, 1), (25, 1), (30, 1), (50, 1), (60, 1),
            (24_000, 1_001), (30_000, 1_001), (60_000, 1_001),
        ]
        if let matched = commonRates.min(by: {
            abs(Double($0.0) / Double($0.1) - nominal)
                < abs(Double($1.0) / Double($1.1) - nominal)
        }), abs(Double(matched.0) / Double(matched.1) - nominal) < 0.01 {
            return try FrameRate(numerator: matched.0, denominator: matched.1)
        }
        throw FrogmouthError.unsupportedMedia(
            "The video frame rate could not be represented exactly."
        )
    }

    private static func colourMetadata(
        from description: CMFormatDescription,
        videoCodec: String
    ) -> VideoColourMetadata {
        guard let formatExtensions = CMFormatDescriptionGetExtensions(description) else {
            return .unspecified
        }
        let extensions = formatExtensions as NSDictionary
        func stringValue(for key: CFString) -> String? {
            extensions.object(forKey: key) as? String
        }

        let range: String?
        if let fullRange = extensions.object(
            forKey: kCMFormatDescriptionExtension_FullRangeVideo
        ) as? NSNumber {
            range = fullRange.boolValue ? "full" : "limited"
        } else if ["avc1", "avc3", "hvc1", "hev1", "mp4v"].contains(videoCodec) {
            // Core Media defines a missing FullRangeVideo extension as limited
            // for compressed YCbCr formats.
            range = "limited"
        } else {
            range = nil
        }

        return VideoColourMetadata(
            primaries: stringValue(for: kCMFormatDescriptionExtension_ColorPrimaries),
            transferFunction: stringValue(for: kCMFormatDescriptionExtension_TransferFunction),
            matrix: stringValue(for: kCMFormatDescriptionExtension_YCbCrMatrix),
            range: range
        )
    }
}
