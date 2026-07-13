# Stabilization performance

Status: active engineering issue. Last updated: 2026-07-13.

## Problem

Stabilizing short Canon EOS R5 clips is currently too slow for an interactive editor. A 22.155-second 4096×2160, 59.94 fps H.264 clip required several minutes for each processing stage and roughly 16 minutes of measured FFmpeg processing in total. The observed end-to-end wait was approximately 25 minutes.

This matters because stabilization is a core frogmouth workflow, not an occasional background operation. The preview should arrive quickly enough to support experimentation and undo/redo without discouraging the user from trying another stabilization mode.

## Current pipeline and root cause

libvidstab is a two-pass CPU filter:

1. `vidstabdetect` analyzes every source frame and writes motion data.
2. `vidstabtransform` applies that data once for the preview and again for the final export.

The current preview pipeline is:

```text
4K decode → 4K vidstabtransform → scale to 1024 px → HEVC encode
```

Although the preview file is only 1024 pixels wide, the expensive transform runs at the full 4096×2160 source resolution. Merely reducing the final preview dimensions will therefore save little. FFmpeg hardware decoding was also measured and did not materially improve detection; libvidstab's motion search is the bottleneck.

Upstream references:

- [FFmpeg vidstab filter documentation](https://ffmpeg.org/ffmpeg-filters.html#vidstabdetect-1)
- [libvidstab usage and option documentation](https://github.com/georgmartius/vid.stab#usage-instructions)

## Measurements

The complete 4K60 reference run reported these final FFmpeg throughputs:

| Stage | Settings | Throughput | Approximate processing time |
| --- | --- | ---: | ---: |
| Analysis | `shakiness=8:accuracy=9:stepsize=12` | 3.0 fps / 0.0499× | 7 min 24 s |
| Preview | Full-resolution bicubic transform, then scale to 1024 | 5.2 fps / 0.0859× | 4 min 18 s |
| Export | Full-resolution bicubic transform | 5.2 fps / 0.0868× | 4 min 15 s |

One-second experiments on the same clip produced:

| Experiment | Wall time per source second | Relative result |
| --- | ---: | ---: |
| Current detection: `8/9/12` | 17.86 s | baseline |
| Balanced detection: `6/7/18` | 11.38 s | 1.6× faster |
| Fast detection: `5/5/24` | 9.20 s | 1.9× faster |
| Current detection after scaling to 2048 px | 2.47 s | 7.2× faster |
| Current detection with VideoToolbox decoding | 17.73 s | no meaningful change |
| Full-resolution bicubic transform | 12.34 s | baseline |
| Full-resolution bilinear transform | 3.42 s | 3.6× faster |

These short experiments are directional benchmarks, not quality validation or release guarantees. Any profile or resolution change must also be tested on representative wildlife clips containing handheld shake, intentional tracking pans, moving animals, foliage, water, and low-contrast backgrounds.

## Decision log

### 2026-07-13: use bilinear interpolation for previews

Accepted and implemented as the first low-risk optimization:

- preview stabilization uses `interpol=bilinear`;
- final export retains `interpol=bicubic`;
- detection settings remain unchanged; and
- preview dimensions remain 1024 pixels wide.

The preview is intentionally a responsiveness-oriented proxy. At its displayed resolution, bilinear interpolation is expected to be sufficient, while the full-resolution deliverable retains the higher-quality interpolation. Unit tests independently assert both command choices.

This decision does not address the longest stage, motion analysis. It is the first incremental improvement, not the final performance solution.

## Alternatives under consideration

### Tune detection settings

Reduce `shakiness` and `accuracy`, increase `stepsize`, or raise `mincontrast`. This is simple and delivered a 1.6–1.9× analysis improvement in the initial benchmark. The risk is missing large or subtle motion, particularly in low-contrast wildlife scenes. Presets must be compared visually before changing the fixed v1 profiles.

### Analyze a downscaled image and reanalyze for export

Create a fast, lower-resolution transform exclusively for the interactive preview, then perform full-resolution detection when the user exports. This greatly improves time-to-preview and preserves final quality, but duplicates work and may not reduce total processing time for clips that are always exported.

### Analyze at reduced resolution and scale motion data for export

Run detection at approximately 2048 pixels wide, use the resulting transforms for a proxy-resolution preview, and scale the ASCII motion data for application to the 4K export. This has the greatest measured potential for reducing both interactive and total time.

It also has the highest correctness risk. Translation, measurement-field coordinates, field sizes, and rotation data must be transformed correctly, and the result must be validated against native 4K detection. A dedicated transform-file parser should be used instead of fragile textual replacement.

### Use bilinear interpolation for final export

The benchmark showed a large speedup, but interpolation affects every transformed output pixel. Before changing the deliverable, generate matched bicubic and bilinear samples and compare fine feathers, fur, branches, and high-contrast edges at 100% scale.

### Use FFmpeg `deshake` for an approximate preview

`deshake` is a single-pass alternative and could provide a faster rough preview. Upstream libvidstab documentation describes its two-pass result as superior. A `deshake` preview would also violate the current expectation that the preview depicts the selected export result, so this is not preferred.

### Require a differently built FFmpeg/libvidstab

Investigate whether a well-supported multithreaded libvidstab build materially improves Apple-silicon performance. This could preserve the current algorithm and quality, but increases installation and supported-version complexity. frogmouth should not require another FFmpeg recipe without repeatable measurements and a maintainable installation path.

## Planned evaluation order

1. Validate bilinear preview rendering on representative clips and measure the complete preview stage.
2. Add explicit stage start/end time, frame count, effective fps, source resolution, and filter settings to diagnostics.
3. Produce matched detection-profile samples and decide whether either preset can safely use cheaper settings.
4. Prototype 2048-pixel detection and an explicit ASCII motion-data scaler.
5. Compare proxy-derived and native-4K transforms on several wildlife clips before considering the proxy path production-ready.
6. Separately compare bilinear and bicubic full-resolution exports; do not couple that decision to preview optimization.

## Acceptance criteria for the current milestone

- Generated preview commands use bilinear interpolation.
- Generated export commands continue to use bicubic interpolation.
- Preview remains 1024 pixels wide, uses the existing HEVC hardware encoder, and accurately reflects trim and stabilization ordering.
- The preview stage is at least twice as fast on the 4K60 performance clip.
- No material visual regression is visible in the app preview across at least five representative wildlife clips.
- Analysis and export quality are unchanged by this milestone.

