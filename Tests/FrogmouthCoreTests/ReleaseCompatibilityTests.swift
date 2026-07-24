import Foundation
import Testing

@testable import FrogmouthCore

@Test func firstTimelineReleaseCompatibilityRevisionsAreStable() {
    #expect(ProjectState.currentSchemaVersion == 2)
    #expect(CacheManifest.currentSchemaVersion == 1)
    #expect(StabilizationCacheIdentityBuilder.currentProcessingRevision == 1)
    #expect(ThumbnailRequest.processingRevision == 1)
    #expect(FFmpegLocator.testedVersions == ["7.1.1", "8.1.2"])
}

@Test func applicationBuildInfoKeepsUserVersionAndBuildIndependent() {
    let info = ApplicationBuildInfo(version: "1.0.0", build: "27")

    #expect(info.version == "1.0.0")
    #expect(info.build == "27")
    #expect(info.displayVersion == "1.0.0 (27)")
}
