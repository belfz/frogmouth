import Foundation
import Testing

@testable import FrogmouthCore

@Test func colourMetadataNormalizesEquivalentAppleAndFFmpegTags() {
    let apple = VideoColourMetadata(
        primaries: "ITU_R_709_2",
        transferFunction: "ITU_R_2020",
        matrix: "ITU_R_709_2",
        range: "true"
    )
    let ffmpeg = VideoColourMetadata(
        primaries: "bt709",
        transferFunction: "bt2020-10",
        matrix: "bt709",
        range: "pc"
    )

    #expect(apple == ffmpeg)
    #expect(ColourCompatibility.mismatches(timeline: apple, clip: ffmpeg).isEmpty)
    #expect(ColourProperty.range.normalize("0") == .unspecified)
    #expect(ColourProperty.range.normalize("1") == .known("limited"))
    #expect(ColourProperty.range.normalize("2") == .known("full"))
}

@Test func colourCompatibilityHandlesUnspecifiedAndUnknownTagsExactly() {
    let unspecified = VideoColourMetadata.unspecified
    #expect(ColourCompatibility.mismatches(timeline: unspecified, clip: .unspecified).isEmpty)

    let partlySpecified = VideoColourMetadata(
        primaries: "bt709",
        transferFunction: nil,
        matrix: nil,
        range: nil
    )
    #expect(ColourCompatibility.mismatches(
        timeline: unspecified,
        clip: partlySpecified
    ).map(\.property) == [.primaries])

    let canonLogSpellingA = VideoColourMetadata(
        primaries: "bt709",
        transferFunction: "Canon_Log_2",
        matrix: "bt709",
        range: "full"
    )
    let canonLogSpellingB = VideoColourMetadata(
        primaries: "BT709",
        transferFunction: "canon-log-2",
        matrix: "ITU R 709 2",
        range: "PC"
    )
    #expect(canonLogSpellingA == canonLogSpellingB)
    #expect(canonLogSpellingA.transferFunction == .unknown("canon-log-2"))

    let canonLog3 = VideoColourMetadata(
        primaries: "bt709",
        transferFunction: "Canon Log 3",
        matrix: "bt709",
        range: "full"
    )
    #expect(ColourCompatibility.mismatches(
        timeline: canonLogSpellingA,
        clip: canonLog3
    ).map(\.property) == [.transferFunction])
}

@Test func colourCompatibilityNamesEveryConflictAndNextAction() throws {
    let sdr = VideoColourMetadata(
        primaries: "bt709",
        transferFunction: "bt709",
        matrix: "bt709",
        range: "full"
    )
    let hdr = VideoColourMetadata(
        primaries: "bt2020",
        transferFunction: "smpte2084",
        matrix: "bt2020nc",
        range: "limited"
    )
    let expected = "This clip cannot be added because its colour metadata does not match the timeline: primaries (timeline: BT.709; clip: BT.2020), transfer function (timeline: BT.709; clip: PQ (SMPTE ST 2084)), matrix (timeline: BT.709; clip: BT.2020 non-constant luminance), range (timeline: full; clip: limited). frogmouth does not convert colour spaces yet. Choose a clip with matching colour metadata."

    #expect(ColourCompatibility.incompatibilityMessage(timeline: sdr, clip: hdr) == expected)
    #expect(throws: FrogmouthError.incompatibleColour(expected)) {
        try ColourCompatibility.validate(timeline: sdr, clip: hdr)
    }
}

@Test func mediaInspectorReadsGeneratedColourFixtures() async throws {
    let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/test-media-fixtures", isDirectory: true)
    let baseURL = fixtures.appendingPathComponent("base-24fps-320x180.mp4")
    let wideURL = fixtures.appendingPathComponent("wide-30000-1001-426x180.mp4")
    let conflictingURL = fixtures.appendingPathComponent("incompatible-bt2020-pq.mp4")
    guard try IntegrationTestSupport.mediaFilesExist([
        baseURL, wideURL, conflictingURL,
    ]) else { return }

    let inspector = MediaInspector()
    let base = try await inspector.inspect(url: baseURL)
    let wide = try await inspector.inspect(url: wideURL)
    let conflicting = try await inspector.inspect(url: conflictingURL)
    let expectedSDR = VideoColourMetadata(
        primaries: "bt709",
        transferFunction: "bt709",
        matrix: "bt709",
        range: "full"
    )
    let expectedHDR = VideoColourMetadata(
        primaries: "bt2020",
        transferFunction: "smpte2084",
        matrix: "bt2020nc",
        range: "limited"
    )

    #expect(base.colour == expectedSDR)
    #expect(wide.colour == expectedSDR)
    #expect(conflicting.colour == expectedHDR)
    #expect(ColourCompatibility.mismatches(
        timeline: base.colour,
        clip: wide.colour
    ).isEmpty)
    #expect(ColourCompatibility.mismatches(
        timeline: base.colour,
        clip: conflicting.colour
    ).map(\.property) == ColourProperty.allCases)
}
