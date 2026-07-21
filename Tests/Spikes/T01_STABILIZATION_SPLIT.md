# T01 — stabilization transforms after split/trim

Date: 2026-07-16  
Environment: Apple Silicon, FFmpeg 7.1.1, libvidstab enabled

## Question

Can clips split or trimmed inward from a stabilized parent reuse its analysis without re-analysis and still preserve the exact selected visual result?

## Method

[`scripts/spikes/validate-stabilization-split.sh`](../../scripts/spikes/validate-stabilization-split.sh) generates lossless, visibly frame-numbered shaky sources and runs three approaches:

1. Stabilize the parent over its full analysis domain, then trim the stabilized result. This is the reference.
2. Slice and renumber only the child's rows from the ASCII local-motion `.trf`, trim the source first, then stabilize the child. This is the tempting lightweight approach.
3. Apply the parent transform once, branch with an FFmpeg `split`, and trim each branch to a child range. This represents a shared-prefix render DAG.

Decoded output frames are compared with FFmpeg `framemd5`, not container bytes. Tests cover 24 fps, 60000/1001 fps, first/last child frames, two adjacent children, and two stacked stabilization passes. FFV1 intermediates avoid lossy-encoder noise in the comparison.

## Results

| Case | Result |
| --- | --- |
| Full-domain transform followed by child trim | All frames match reference |
| Sliced/renumbered local-motion rows | 40 of 48 child frames differ at 24 fps |
| Shared transformed prefix followed by two child branches | Every child frame matches at both tested rates |
| Two stacked passes followed by child trim | Every child frame matches |

Illustrative tiny-fixture wall time:

| Rate | Shared prefix | Two repeated full-domain renders |
| --- | ---: | ---: |
| 24 fps | 0.37 s | 0.68 s |
| 60000/1001 fps | 0.39 s | 0.74 s |

The full 24 fps ASCII transform file was about 174 KB; its naively sliced half was about 89 KB. That space saving is irrelevant because the sliced data does not preserve the visual result. A lossless full-frame stabilized intermediate was about 1.2 MB for only four seconds at 320×180, reinforcing that a full-quality 4K intermediate is the wrong default cache strategy.

## Why row slicing fails

The `.trf` from `vidstabdetect` contains local-motion observations. `vidstabtransform` converts them into global transforms, integrates relative movement, smooths over neighboring frames, and computes adaptive zoom. Removing earlier/surrounding rows changes those calculations even if remaining rows are renumbered correctly.

## Decision

- Preserve the stabilization effect's original analysis domain and lineage.
- Apply inherited transforms before descendant trims.
- Share common stabilized prefixes inside one export filter graph, branching only where clip histories diverge.
- Map preview children into a parent-domain stabilized proxy.
- Never re-analyze merely because of split, inward trim, duplicate, or reorder.
- Mark an effect stale only when a clip extends outside its covered domain or cache compatibility changes.
- Do not slice local-motion `.trf` files for production rendering.

