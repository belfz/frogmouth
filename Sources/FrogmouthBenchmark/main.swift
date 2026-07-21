import Foundation
import FrogmouthCore

@main
struct FrogmouthBenchmark {
    static func main() async throws {
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixture = argumentValue("--fixture")
            .map(URL.init(fileURLWithPath:))
            ?? workspace.appendingPathComponent(
                ".build/test-media-fixtures/base-24fps-320x180.mp4"
            )
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw BenchmarkError.missingFixture(fixture.path)
        }

        let root = workspace.appendingPathComponent(".build/t21-benchmark", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let residentBefore = residentMemoryBytes()
        let scenario = try makeTargetScenario(root: root, fixture: fixture)
        let projectURL = root.appendingPathComponent("Target.frogmouth")
        let store = ProjectDocumentStore()
        try await store.save(project: scenario.project, to: projectURL)

        var metrics: [Metric] = []
        let codec = ProjectJSONCodec()
        var byteChecksum = 0
        metrics.append(try measure("JSON encode", iterations: 250) {
            byteChecksum += try codec.encode(scenario.project).count
        })
        let encoded = try codec.encode(scenario.project)
        metrics.append(try measure("JSON decode", iterations: 250) {
            byteChecksum += try codec.decode(encoded).clips.count
        })

        var frameChecksum: Int64 = 0
        metrics.append(try measure("Timeline index", iterations: 2_000) {
            frameChecksum += try TimelineIndex(project: scenario.project).totalFrames
        })

        let openedMetric = try await measureAsync("Project open", iterations: 30) {
            let opened = try await store.open(url: projectURL)
            frameChecksum += Int64(opened.project.clips.count)
        }
        metrics.append(openedMetric)

        let session = try await ProjectDocumentSession.open(
            url: projectURL,
            store: store,
            autosaveDelay: .zero
        )
        let movingClipID = scenario.project.clips[0].id
        var moveToSecond = true
        metrics.append(try await measureAsync("Autosave edit + flush", iterations: 30) {
            try await session.apply(.moveClip(
                clipID: movingClipID,
                toIndex: moveToSecond ? 1 : 0
            ))
            moveToSecond.toggle()
            await session.flushAutosave()
        })

        let math = TimelineViewportMath()
        let timelineIndex = try TimelineIndex(project: scenario.project)
        let rate = scenario.project.timelineFormat!.frameRate
        var viewportChecksum = 0.0
        metrics.append(try measure("Scroll/zoom math (100 operations)", iterations: 300) {
            var offset = 0.0
            var scale = 0.5
            for operation in 0..<100 {
                let newScale = min(800, scale * 1.035 + 0.01)
                let contentWidth = try math.x(
                    for: timelineIndex.totalDuration,
                    pixelsPerSecond: newScale
                ) + 24
                offset = try math.zoomedOffset(
                    oldOffset: offset,
                    oldPixelsPerSecond: scale,
                    newPixelsPerSecond: newScale,
                    anchorInViewport: Double(operation % 900),
                    viewportWidth: 900,
                    newContentWidth: contentWidth
                )
                let frame = try math.frame(
                    atX: offset + Double(operation),
                    frameRate: rate,
                    pixelsPerSecond: newScale
                )
                viewportChecksum += try math.x(
                    forFrame: frame,
                    frameRate: rate,
                    pixelsPerSecond: newScale
                )
                _ = ThumbnailSizing.quantizedPixelWidth(displayWidth: newScale)
                scale = newScale
            }
        })

        let firstAsset = scenario.project.mediaLibrary[0]
        let firstClip = scenario.project.clips[0]
        let trimMapper = TimelineTrimMapper()
        metrics.append(try measure("Trim feedback (100 updates)", iterations: 300) {
            for update in 0..<100 {
                let range = try trimMapper.sourceRange(
                    originalRange: firstClip.sourceRange,
                    assetDuration: firstAsset.inspected.duration,
                    edge: update.isMultiple(of: 2) ? .leading : .trailing,
                    timelineFrameDelta: Int64((update % 19) - 9),
                    timelineRate: rate,
                    sourceRate: firstAsset.inspected.frameRate
                )
                frameChecksum += range.duration.value
            }
        })

        let renderRequest = TimelineRenderRequest(
            project: scenario.project,
            mediaURLs: scenario.mediaURLs,
            stabilizationTransforms: [:]
        )
        metrics.append(try measure("Render-plan build", iterations: 500) {
            frameChecksum += try TimelineRenderPlanner().plan(renderRequest).totalFrames
        })

        let compositionScenario = try await makeCompositionScenario(
            root: root,
            fixture: fixture
        )
        metrics.append(try await measureAsync("AV composition rebuild", iterations: 4) {
            let result = try await PlaybackCompositionBuilder().build(
                PlaybackBuildRequest(
                    project: compositionScenario.project,
                    mediaURLs: compositionScenario.mediaURLs
                )
            )
            frameChecksum += result.segmentMap.totalFrames
        })

        let cacheRoot = root.appendingPathComponent("thumbnail-cache", isDirectory: true)
        let cacheStore = ProjectCacheStore(rootURL: cacheRoot)
        let thumbnailService = ThumbnailService(cacheStore: cacheStore)
        let requests = try compositionScenario.project.mediaLibrary.map { asset in
            try ThumbnailRequest(
                assetID: asset.id,
                sourceFingerprint: asset.fingerprint,
                mediaURL: compositionScenario.mediaURLs[asset.id]!,
                frameRate: asset.inspected.frameRate,
                requestedSourceTime: .zero,
                pixelWidth: 320,
                pixelHeight: 180
            )
        }
        metrics.append(try await measureAsync("Uncached thumbnail sweep (25)", iterations: 1) {
            for request in requests {
                _ = try await thumbnailService.thumbnail(
                    for: request,
                    projectID: compositionScenario.project.id,
                    consumerID: UUID()
                )
            }
        })
        metrics.append(try await measureAsync("Cached thumbnail sweep (25)", iterations: 20) {
            for request in requests {
                _ = try await thumbnailService.thumbnail(
                    for: request,
                    projectID: compositionScenario.project.id,
                    consumerID: UUID()
                )
            }
        })

        let cacheBytes = directoryByteCount(cacheRoot)
        let residentAfter = residentMemoryBytes()
        let report = renderReport(
            fixture: fixture,
            avProject: compositionScenario.project,
            metrics: metrics,
            projectByteCount: Int64(encoded.count),
            cacheByteCount: cacheBytes,
            residentBefore: residentBefore,
            residentAfter: residentAfter,
            checksum: "\(byteChecksum)-\(frameChecksum)-\(Int(viewportChecksum))"
        )
        print(report)
    }

    private static func argumentValue(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
}

private struct Scenario {
    let project: ProjectState
    let mediaURLs: [MediaAsset.ID: URL]
}

private struct Metric {
    let name: String
    let iterations: Int
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
}

private enum BenchmarkError: LocalizedError {
    case missingFixture(String)

    var errorDescription: String? {
        switch self {
        case let .missingFixture(path):
            "Missing benchmark fixture at \(path). Run scripts/generate-media-fixtures.sh first."
        }
    }
}

private func makeTargetScenario(root: URL, fixture: URL) throws -> Scenario {
    let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let colour = VideoColourMetadata(
        primaries: "bt709",
        transferFunction: "bt709",
        matrix: "bt709",
        range: "limited"
    )
    let sourceDuration = try rate.time(forFrame: 72 * 24)
    let halfDuration = try rate.time(forFrame: 36 * 24)
    var assets: [MediaAsset] = []
    var mediaURLs: [MediaAsset.ID: URL] = [:]
    for index in 0..<25 {
        let url = mediaDirectory.appendingPathComponent(
            String(format: "source-%02d.mp4", index)
        )
        try linkOrCopy(fixture, to: url)
        let asset = MediaAsset(
            path: MediaPathReference(
                relativeToProject: "media/\(url.lastPathComponent)",
                absoluteFallback: url.path
            ),
            fingerprint: try MediaFingerprinter().fingerprint(url: url),
            inspected: PersistedMediaFacts(
                duration: sourceDuration,
                width: 4_096,
                height: 2_160,
                frameRate: rate,
                videoBitrate: 120_000_000,
                videoCodec: "avc1",
                audioCodec: "aac",
                audioSampleRate: 48_000,
                audioChannelCount: 2,
                colour: colour
            )
        )
        assets.append(asset)
        mediaURLs[asset.id] = url
    }

    var clips: [TimelineClip] = []
    for index in 0..<50 {
        let asset = assets[index % assets.count]
        let startsInSecondHalf = index >= assets.count
        clips.append(TimelineClip(
            assetID: asset.id,
            sourceRange: try MediaTimeRange(
                start: startsInSecondHalf ? halfDuration : .zero,
                duration: halfDuration
            )
        ))
    }
    return Scenario(
        project: ProjectState(
            name: "25-source 50-clip 30-minute target",
            mediaLibrary: assets,
            timelineFormat: TimelineFormat(
                width: 4_096,
                height: 2_160,
                frameRate: rate,
                colour: colour,
                audioSampleRate: 48_000,
                audioChannelCount: 2
            ),
            clips: clips
        ),
        mediaURLs: mediaURLs
    )
}

private func makeCompositionScenario(root: URL, fixture: URL) async throws -> Scenario {
    let facts = try await AVProjectMediaFactsInspector().inspect(url: fixture)
    let mediaDirectory = root.appendingPathComponent("composition-media", isDirectory: true)
    try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    var assets: [MediaAsset] = []
    var mediaURLs: [MediaAsset.ID: URL] = [:]
    for index in 0..<25 {
        let url = mediaDirectory.appendingPathComponent(
            String(format: "fixture-%02d.mp4", index)
        )
        try linkOrCopy(fixture, to: url)
        let asset = MediaAsset(
            path: MediaPathReference(relativeToProject: nil, absoluteFallback: url.path),
            fingerprint: try MediaFingerprinter().fingerprint(url: url),
            inspected: facts
        )
        assets.append(asset)
        mediaURLs[asset.id] = url
    }
    let sourceFrames = try facts.frameRate.frameIndex(
        for: facts.duration,
        rounding: .towardNegativeInfinity
    )
    let clipFrames = max(1, sourceFrames / 2)
    let clipDuration = try facts.frameRate.time(forFrame: clipFrames)
    let secondStart = try facts.frameRate.time(forFrame: sourceFrames - clipFrames)
    let clips = try (0..<50).map { index in
        TimelineClip(
            assetID: assets[index % assets.count].id,
            sourceRange: try MediaTimeRange(
                start: index >= assets.count ? secondStart : .zero,
                duration: clipDuration
            )
        )
    }
    return Scenario(
        project: ProjectState(
            name: "Lightweight AV composition",
            mediaLibrary: assets,
            timelineFormat: TimelineFormat(
                width: facts.width,
                height: facts.height,
                frameRate: facts.frameRate,
                colour: facts.colour,
                audioSampleRate: facts.audioSampleRate ?? 48_000,
                audioChannelCount: facts.audioChannelCount ?? 2
            ),
            clips: clips
        ),
        mediaURLs: mediaURLs
    )
}

private func linkOrCopy(_ source: URL, to destination: URL) throws {
    do {
        try FileManager.default.linkItem(at: source, to: destination)
    } catch {
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

private func measure(
    _ name: String,
    iterations: Int,
    operation: () throws -> Void
) rethrows -> Metric {
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let started = DispatchTime.now().uptimeNanoseconds
        try operation()
        samples.append(milliseconds(since: started))
    }
    return metric(name: name, samples: samples)
}

@MainActor
private func measureAsync(
    _ name: String,
    iterations: Int,
    operation: () async throws -> Void
) async rethrows -> Metric {
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let started = DispatchTime.now().uptimeNanoseconds
        try await operation()
        samples.append(milliseconds(since: started))
    }
    return metric(name: name, samples: samples)
}

private func metric(name: String, samples: [Double]) -> Metric {
    let sorted = samples.sorted()
    let median = sorted[sorted.count / 2]
    let p95Index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)
    return Metric(
        name: name,
        iterations: sorted.count,
        medianMilliseconds: median,
        p95Milliseconds: sorted[p95Index],
        maximumMilliseconds: sorted.last ?? 0
    )
}

private func milliseconds(since started: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
}

private func directoryByteCount(_ url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return 0 }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
    }
    return total
}

private func residentMemoryBytes() -> Int64? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let kibibytes = Int64(value) else { return nil }
        return kibibytes * 1_024
    } catch {
        return nil
    }
}

private func renderReport(
    fixture: URL,
    avProject: ProjectState,
    metrics: [Metric],
    projectByteCount: Int64,
    cacheByteCount: Int64,
    residentBefore: Int64?,
    residentAfter: Int64?,
    checksum: String
) -> String {
    let avFormat = avProject.timelineFormat
    let avDuration = (try? TimelineIndex(project: avProject).totalDuration).map {
        Double($0.value) / Double($0.timescale)
    } ?? 0
    let avWorkload = "25 hard-linked \(avFormat?.width ?? 0)×\(avFormat?.height ?? 0) source paths, \(avProject.clips.count) clips, \(String(format: "%.2f", avDuration))-second sequence"
    var lines = [
        "# frogmouth editor benchmark",
        "",
        "- Date: \(ISO8601DateFormatter().string(from: Date()))",
        "- System: \(ProcessInfo.processInfo.operatingSystemVersionString)",
        "- CPU cores: \(ProcessInfo.processInfo.processorCount)",
        "- Physical memory: \(formatBytes(Int64(ProcessInfo.processInfo.physicalMemory)))",
        "- Fixture: \(fixture.path)",
        "- Structural target: 25 distinct source paths, 50 clips, 30:00 timeline, 4096×2160 at 24 fps",
        "- AV workload: \(avWorkload)",
        "",
        "| Measurement | Iterations | Median | p95 | Maximum |",
        "|---|---:|---:|---:|---:|",
    ]
    lines += metrics.map {
        "| \($0.name) | \($0.iterations) | \(formatMilliseconds($0.medianMilliseconds)) | \(formatMilliseconds($0.p95Milliseconds)) | \(formatMilliseconds($0.maximumMilliseconds)) |"
    }
    lines += [
        "",
        "- Project JSON size: \(formatBytes(projectByteCount))",
        "- Thumbnail disk cache after 25 entries: \(formatBytes(cacheByteCount))",
        "- Resident memory before: \(residentBefore.map(formatBytes) ?? "unavailable")",
        "- Resident memory after: \(residentAfter.map(formatBytes) ?? "unavailable")",
        "- Optimizer checksum: \(checksum)",
        "",
        "The structural benchmark deliberately separates model/UI scale from pixel decoding. The AV workload uses the selected fixture at its real resolution: composition building loads tracks and timing without rendering every output frame, while the uncached thumbnail sweep performs actual source-frame decoding. Real-time playback and complete export remain human acceptance checks.",
    ]
    return lines.joined(separator: "\n")
}

private func formatMilliseconds(_ value: Double) -> String {
    value < 1 ? String(format: "%.3f ms", value) : String(format: "%.2f ms", value)
}

private func formatBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}
