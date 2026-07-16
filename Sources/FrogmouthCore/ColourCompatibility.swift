import Foundation

public enum ColourMetadataValue: Equatable, Hashable, Sendable {
    case unspecified
    case known(String)
    case unknown(String)
}

public enum ColourProperty: String, CaseIterable, Equatable, Hashable, Sendable {
    case primaries
    case transferFunction
    case matrix
    case range

    public var displayName: String {
        switch self {
        case .primaries: "primaries"
        case .transferFunction: "transfer function"
        case .matrix: "matrix"
        case .range: "range"
        }
    }

    public func normalize(_ rawValue: String?) -> ColourMetadataValue {
        guard let rawValue else { return .unspecified }
        let token = Self.normalizedToken(rawValue)
        let isUnspecified = ["unknown", "unspecified", "reserved", "0"].contains(token)
            || (token == "2" && self != .range)
        guard !token.isEmpty, !isUnspecified else {
            return .unspecified
        }
        if let canonicalValue = aliases[token] {
            return .known(canonicalValue)
        }
        return .unknown(token)
    }

    public func describe(_ value: ColourMetadataValue) -> String {
        switch value {
        case .unspecified:
            "unspecified"
        case let .known(identifier):
            knownLabels[identifier] ?? identifier
        case let .unknown(identifier):
            "unknown tag \(identifier)"
        }
    }

    private var aliases: [String: String] {
        switch self {
        case .primaries:
            [
                "1": "bt709", "bt709": "bt709", "itu-r-709-2": "bt709",
                "4": "bt470m", "bt470m": "bt470m",
                "5": "bt470bg", "bt470bg": "bt470bg",
                "6": "smpte170m", "smpte170m": "smpte170m", "smpte-c": "smpte170m",
                "7": "smpte240m", "smpte240m": "smpte240m",
                "8": "film", "film": "film",
                "9": "bt2020", "bt2020": "bt2020", "itu-r-2020": "bt2020",
                "10": "smpte428", "smpte428": "smpte428",
                "11": "dci-p3", "dci-p3": "dci-p3", "smpte431": "dci-p3",
                "12": "display-p3", "display-p3": "display-p3", "p3-d65": "display-p3", "smpte432": "display-p3",
                "22": "ebu3213", "ebu3213": "ebu3213", "ebu-3213": "ebu3213",
                "p22": "p22",
            ]
        case .transferFunction:
            [
                // Core Media documents ITU-R 2020 as semantically equivalent to
                // ITU-R 709 for transfer-function purposes.
                "1": "bt709", "14": "bt709", "15": "bt709",
                "bt709": "bt709", "itu-r-709-2": "bt709", "itu-r-2020": "bt709",
                "bt2020-10": "bt709", "bt2020-12": "bt709",
                "4": "gamma22", "gamma22": "gamma22",
                "5": "gamma28", "gamma28": "gamma28",
                "6": "smpte170m", "smpte170m": "smpte170m",
                "7": "smpte240m", "smpte240m": "smpte240m", "smpte-240m-1995": "smpte240m",
                "8": "linear", "linear": "linear",
                "9": "log100", "log100": "log100",
                "10": "log316", "log316": "log316",
                "11": "xvycc", "xvycc": "xvycc",
                "12": "bt1361e", "bt1361e": "bt1361e",
                "13": "srgb", "srgb": "srgb", "iec61966-2-1": "srgb",
                "16": "pq", "pq": "pq", "smpte2084": "pq", "smpte-st-2084-pq": "pq",
                "17": "smpte428", "smpte428": "smpte428", "smpte-st-428-1": "smpte428",
                "18": "hlg", "hlg": "hlg", "arib-std-b67": "hlg", "itu-r-2100-hlg": "hlg",
            ]
        case .matrix:
            [
                "0": "rgb", "rgb": "rgb", "identity": "rgb",
                "1": "bt709", "bt709": "bt709", "itu-r-709-2": "bt709",
                "4": "fcc", "fcc": "fcc",
                "5": "bt470bg", "bt470bg": "bt470bg",
                "6": "smpte170m", "smpte170m": "smpte170m", "itu-r-601-4": "smpte170m",
                "7": "smpte240m", "smpte240m": "smpte240m", "smpte-240m-1995": "smpte240m",
                "8": "ycgco", "ycgco": "ycgco",
                "9": "bt2020nc", "bt2020nc": "bt2020nc", "itu-r-2020": "bt2020nc",
                "10": "bt2020c", "bt2020c": "bt2020c",
                "11": "smpte2085", "smpte2085": "smpte2085",
                "12": "chroma-derived-nc", "chroma-derived-nc": "chroma-derived-nc",
                "13": "chroma-derived-c", "chroma-derived-c": "chroma-derived-c",
                "14": "ictcp", "ictcp": "ictcp",
            ]
        case .range:
            [
                "1": "limited", "false": "limited", "limited": "limited", "mpeg": "limited", "tv": "limited",
                "2": "full", "true": "full", "full": "full", "jpeg": "full", "pc": "full",
            ]
        }
    }

    private var knownLabels: [String: String] {
        [
            "bt709": "BT.709", "bt2020": "BT.2020", "bt2020nc": "BT.2020 non-constant luminance",
            "bt2020c": "BT.2020 constant luminance", "dci-p3": "DCI-P3", "display-p3": "Display P3",
            "pq": "PQ (SMPTE ST 2084)", "hlg": "HLG", "srgb": "sRGB", "linear": "linear",
            "full": "full", "limited": "limited", "rgb": "RGB",
            "smpte170m": "SMPTE 170M", "smpte240m": "SMPTE 240M",
        ]
    }

    private static func normalizedToken(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

public struct VideoColourMetadata: Codable, Equatable, Hashable, Sendable {
    public let primaries: ColourMetadataValue
    public let transferFunction: ColourMetadataValue
    public let matrix: ColourMetadataValue
    public let range: ColourMetadataValue

    public init(
        primaries: String?,
        transferFunction: String?,
        matrix: String?,
        range: String?
    ) {
        self.primaries = ColourProperty.primaries.normalize(primaries)
        self.transferFunction = ColourProperty.transferFunction.normalize(transferFunction)
        self.matrix = ColourProperty.matrix.normalize(matrix)
        self.range = ColourProperty.range.normalize(range)
    }

    public static let unspecified = VideoColourMetadata(
        primaries: nil,
        transferFunction: nil,
        matrix: nil,
        range: nil
    )

    fileprivate func value(for property: ColourProperty) -> ColourMetadataValue {
        switch property {
        case .primaries: primaries
        case .transferFunction: transferFunction
        case .matrix: matrix
        case .range: range
        }
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case primaries
        case transfer
        case matrix
        case range
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            primaries: try container.decodeIfPresent(String.self, forKey: .primaries),
            transferFunction: try container.decodeIfPresent(String.self, forKey: .transfer),
            matrix: try container.decodeIfPresent(String.self, forKey: .matrix),
            range: try container.decodeIfPresent(String.self, forKey: .range)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeCanonical(primaries, forKey: .primaries)
        try container.encodeCanonical(transferFunction, forKey: .transfer)
        try container.encodeCanonical(matrix, forKey: .matrix)
        try container.encodeCanonical(range, forKey: .range)
    }
}

private extension KeyedEncodingContainer where Key == VideoColourMetadata.CodingKeys {
    mutating func encodeCanonical(
        _ value: ColourMetadataValue,
        forKey key: Key
    ) throws {
        switch value {
        case .unspecified:
            try encodeNil(forKey: key)
        case let .known(identifier), let .unknown(identifier):
            try encode(identifier, forKey: key)
        }
    }
}

public struct ColourMismatch: Equatable, Hashable, Sendable {
    public let property: ColourProperty
    public let timelineValue: ColourMetadataValue
    public let clipValue: ColourMetadataValue
}

public enum ColourCompatibility {
    public static func mismatches(
        timeline: VideoColourMetadata,
        clip: VideoColourMetadata
    ) -> [ColourMismatch] {
        ColourProperty.allCases.compactMap { property in
            let timelineValue = timeline.value(for: property)
            let clipValue = clip.value(for: property)
            guard timelineValue != clipValue else { return nil }
            return ColourMismatch(
                property: property,
                timelineValue: timelineValue,
                clipValue: clipValue
            )
        }
    }

    public static func incompatibilityMessage(
        timeline: VideoColourMetadata,
        clip: VideoColourMetadata
    ) -> String? {
        let mismatches = mismatches(timeline: timeline, clip: clip)
        guard !mismatches.isEmpty else { return nil }
        let details = mismatches.map { mismatch in
            let property = mismatch.property
            return "\(property.displayName) (timeline: \(property.describe(mismatch.timelineValue)); clip: \(property.describe(mismatch.clipValue)))"
        }.joined(separator: ", ")
        return "This clip cannot be added because its colour metadata does not match the timeline: \(details). frogmouth does not convert colour spaces yet. Choose a clip with matching colour metadata."
    }

    public static func validate(
        timeline: VideoColourMetadata,
        clip: VideoColourMetadata
    ) throws {
        if let message = incompatibilityMessage(timeline: timeline, clip: clip) {
            throw FrogmouthError.incompatibleColour(message)
        }
    }
}
