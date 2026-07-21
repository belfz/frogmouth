# Editor performance and accessibility benchmark

Measured on 2026-07-20 with a release build on Apple silicon, macOS 15.7.7,
10 CPU cores, and 68.72 GB physical memory.

Run the repeatable benchmark with:

```sh
scripts/generate-media-fixtures.sh
swift run -c release frogmouth-benchmark \
  --fixture "$PWD/EOS R5 example video.MP4"
```

Omit `--fixture` to run the portable deterministic 320×180 AV profile when the ignored local
Canon sample is unavailable.

The structural workload uses 25 distinct source paths with persisted 4096×2160 H.264/AAC
facts, 50 gapless clips, and an exact 30-minute 24 fps timeline. APFS hard links avoid
duplicating the 133 MB sample while exercising distinct project paths and media IDs.

AVFoundation composition and thumbnail measurements use 25 distinct paths hard-linked to the
real `EOS R5 example video.MP4` sample at 4096×2160. The 50-clip AV sequence is 231.25 seconds;
composition building loads its real tracks and timing, and the uncached sweep performs 25
actual 4K thumbnail decodes. This still does not substitute for watching playback and a full
export of real wildlife edits.

## Results

| Measurement | Iterations | Median | p95 | Maximum |
|---|---:|---:|---:|---:|
| JSON encode | 250 | 0.836 ms | 1.21 ms | 1.57 ms |
| JSON decode | 250 | 0.900 ms | 1.01 ms | 1.13 ms |
| Timeline index | 2,000 | 0.026 ms | 0.027 ms | 0.170 ms |
| Project open | 30 | 2.86 ms | 3.63 ms | 4.48 ms |
| Autosave edit and flush | 30 | 1.77 ms | 5.58 ms | 7.91 ms |
| Scroll/zoom math, 100 operations | 300 | 0.031 ms | 0.033 ms | 0.105 ms |
| Trim feedback, 100 updates | 300 | 0.004 ms | 0.004 ms | 0.026 ms |
| Render-plan build | 500 | 0.069 ms | 0.077 ms | 0.150 ms |
| AV composition rebuild | 4 | 78.91 ms | 102.68 ms | 102.68 ms |
| Uncached 4K thumbnail sweep, 25 items | 1 | 1,206.40 ms | 1,206.40 ms | 1,206.40 ms |
| Cached 4K thumbnail sweep, 25 items | 20 | 11.81 ms | 16.81 ms | 21.87 ms |

- Project JSON: 42 KB.
- Thumbnail disk cache after 25 real 4K-derived entries: 636 KB.
- Resident memory: 4 MB before and 21 MB after the full benchmark.

These results satisfy the local guardrails: p95 below 20 ms for project open and autosave,
below 1 ms for pure timeline interactions, below 150 ms for the 50-clip composition build,
below 50 ms for a cached 25-thumbnail sweep, less than 5 MB for those cache entries, and less
than 100 MB additional resident memory. These are regression signals, not promises about
rendering or decoding time on every Mac.

## Main-actor audit and changes

- Project persistence, path resolution, cache access, media inspection, composition building,
  stabilization, and export already execute through actors or asynchronous services.
- Source fingerprinting during import now runs in a detached utility task.
- Export source-availability checks now run outside the main actor and publish a cached
  readiness result to SwiftUI.
- Thumbnail JPEG file reading and decoding now happen outside the main actor.
- Diagnostic file appends and Copy Diagnostics reads now use a serial utility queue; the
  pasteboard is updated on the main actor only after the asynchronous read finishes.
- Live trim feedback now uses the already-bounded rational trim mapper directly instead of
  constructing and validating a temporary full project editor for every pointer update.
- Timeline clip/media lookup avoids repeated linear scans, and a presented trim project is
  produced once per editor render.
- Timeline thumbnail widths use stable 160/320/640 Retina buckets, preventing fractional zoom
  changes from creating effectively unbounded cache identities and decode work.
- A project document publishes its UI snapshot in one actor hop, keeping project, path,
  resolved URLs, and undo/redo state mutually consistent.

AppKit panels, `AVPlayerItem` installation, SwiftUI state publication, and final `NSImage`
construction intentionally remain on the main actor. They are UI work; moving them would be
incorrect rather than an optimization.

## Accessibility and manual acceptance

The editor now exposes named sidebars and processing states, selectable timeline clips,
adjustable trim handles and playhead, stabilization state, timeline zoom, playback controls,
and explicit selection actions. Timeline clips and trim handles participate in keyboard focus;
Return selects a focused clip and the arrow keys adjust a focused trim handle by one frame.

For release acceptance, manually verify:

1. Enable VoiceOver and navigate Media Library, timeline, viewer, Inspector, and the processing
   modal. Confirm clip number/name/state, playhead timecode, and trim-handle values are spoken.
2. Enable macOS Keyboard navigation. Tab through toolbar controls, Media Library actions,
   timeline clips, selected trim handles, playback, and Inspector stabilization controls.
3. With the 50-clip target or a similarly dense project, scroll before and after thumbnails
   populate, zoom around the playhead, and drag both trim handles. Look for visible stalls or
   wrong clip geometry.
4. Play across several hard cuts in real 4K wildlife footage, including clips with audio, then
   export the complete timeline and inspect picture, audio, duration, colour, and metadata.
5. Start stabilization, verify that the editor is intentionally blocked, cancel once, then run
   it to completion and confirm playback/export use the current result.

Blocking, cancellable stabilization is a known first-release limitation. Background per-clip
processing is deferred; this performance work does not disguise that workflow constraint.
