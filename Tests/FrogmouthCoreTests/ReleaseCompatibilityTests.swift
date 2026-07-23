import Testing

@testable import FrogmouthCore

@Test func firstTimelineReleaseCompatibilityRevisionsAreStable() {
    #expect(ProjectState.currentSchemaVersion == 2)
    #expect(CacheManifest.currentSchemaVersion == 1)
    #expect(StabilizationCacheIdentityBuilder.currentProcessingRevision == 1)
    #expect(ThumbnailRequest.processingRevision == 1)
}
