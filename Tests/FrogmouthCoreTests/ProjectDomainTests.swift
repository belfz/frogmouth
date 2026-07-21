import Foundation
import Testing

@testable import FrogmouthCore

private let projectFixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tests/Fixtures/ProjectSchemaV1.frogmouth")

@Test func projectSchemaFixtureRoundTripsDeterministically() throws {
    let data = try Data(contentsOf: projectFixtureURL)
    let codec = ProjectJSONCodec()
    let project = try codec.decode(data)

    #expect(project.schemaVersion == 1)
    #expect(project.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    #expect(project.name == "Wildlife Morning")
    #expect(project.mediaLibrary.count == 1)
    #expect(project.clips.count == 1)
    #expect(project.clips[0].assetID == project.mediaLibrary[0].id)
    #expect(project.clips[0].stabilizationPasses[0].mode == .naturalMotion)
    let expectedFrameRate = try FrameRate(numerator: 60_000, denominator: 1_001)
    #expect(project.timelineFormat?.frameRate == expectedFrameRate)

    let encoded = try codec.encode(project)
    #expect(try codec.decode(encoded) == project)
    let encodedAgain = try codec.encode(project)
    #expect(encoded == encodedAgain)
    let fixtureText = try #require(String(data: data, encoding: .utf8))
        .trimmingCharacters(in: .newlines)
    let encodedText = try #require(String(data: encoded, encoding: .utf8))
    #expect(encodedText == fixtureText)
}

@Test func projectSchemaIgnoresUnknownFields() throws {
    let data = try Data(contentsOf: projectFixtureURL)
    let codec = ProjectJSONCodec()
    let expected = try codec.decode(data)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["futureTopLevelValue"] = ["enabled": true]
    var clips = try #require(object["clips"] as? [[String: Any]])
    clips[0]["futureClipValue"] = "ignored"
    object["clips"] = clips
    let expanded = try JSONSerialization.data(withJSONObject: object)

    #expect(try codec.decode(expanded) == expected)
}

@Test func projectSchemaRejectsFutureMissingAndInvalidVersions() throws {
    let data = try Data(contentsOf: projectFixtureURL)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 2
    let future = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ProjectSchemaError.unsupportedVersion(found: 2, supported: 1)) {
        _ = try ProjectJSONCodec().decode(future)
    }
    #expect(ProjectSchemaError.unsupportedVersion(
        found: 2,
        supported: 1
    ).errorDescription?.contains("Update frogmouth") == true)

    object.removeValue(forKey: "schemaVersion")
    let missing = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ProjectSchemaError.missingSchemaVersion) {
        _ = try ProjectJSONCodec().decode(missing)
    }

    object["schemaVersion"] = "one"
    let invalid = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ProjectSchemaError.invalidSchemaVersion) {
        _ = try ProjectJSONCodec().decode(invalid)
    }
}

@Test func projectMigrationPipelineIsEstablishedWithoutAVersionZeroMigration() throws {
    let versionZero = Data(#"{"schemaVersion":0}"#.utf8)
    #expect(throws: ProjectSchemaError.noMigration(fromVersion: 0)) {
        _ = try ProjectJSONCodec().decode(versionZero)
    }

    let fixture = try Data(contentsOf: projectFixtureURL)
    let migration = FixtureMigration(replacement: fixture)
    let migrated = try ProjectJSONCodec(migrations: [migration]).decode(versionZero)
    #expect(migrated.schemaVersion == 1)
    #expect(migrated.name == "Wildlife Morning")
}

@Test func projectJSONContainsDecisionsButNoTransientOrCacheState() throws {
    let data = try Data(contentsOf: projectFixtureURL)
    let project = try ProjectJSONCodec().decode(data)
    let encoded = try ProjectJSONCodec().encode(project)
    let text = try #require(String(data: encoded, encoding: .utf8))

    for forbidden in [
        "selection", "playhead", "undo", "redo", "playerItem",
        "transformsURL", "preview.mp4", "Library/Caches",
    ] {
        #expect(!text.contains(forbidden))
    }
}

@Test func colourMetadataPersistsCanonicalAndUnknownValuesReadably() throws {
    let colour = VideoColourMetadata(
        primaries: nil,
        transferFunction: "Canon_Log_2",
        matrix: "ITU_R_709_2",
        range: "pc"
    )
    let data = try JSONEncoder().encode(colour)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["primaries"] is NSNull)
    #expect(object["transfer"] as? String == "canon-log-2")
    #expect(object["matrix"] as? String == "bt709")
    #expect(object["range"] as? String == "full")
    #expect(try JSONDecoder().decode(VideoColourMetadata.self, from: data) == colour)
}

private struct FixtureMigration: ProjectMigration {
    let sourceVersion = 0
    let destinationVersion = 1
    let replacement: Data

    func migrate(_ projectData: Data) throws -> Data {
        replacement
    }
}
