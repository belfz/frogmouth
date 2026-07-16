# T03 — Colour compatibility detection

Date: 2026-07-16  
Environment: Apple Silicon, macOS 15+, Swift 6.2.1, FFmpeg 7.1.1

## Policy

The first timeline clip establishes four normalized values: primaries, transfer function, YCbCr matrix, and full/limited range. Every later clip must match all four.

Known Core Media, FFmpeg, numeric-code-point, punctuation, and case aliases normalize to one canonical value. In particular, Core Media documents its `ITU_R_2020` transfer tag as semantically equivalent to `ITU_R_709_2`, so FFmpeg's BT.2020 10/12-bit spellings normalize to the same transfer value. This affects only the transfer tag; BT.2020 primaries and matrix remain distinct from BT.709.

The missing and unknown rules are deliberately explicit:

- missing/unspecified matches only missing/unspecified;
- the same normalized unrecognized tag matches itself;
- a known tag never matches a missing or unrecognized tag; and
- different unrecognized tags do not match.

Accepting two identically missing or unrecognized values is a pragmatic assumption: without decoding and colour-managing pixels, frogmouth cannot prove that their real characteristics match. The app records the values and refuses any observable conflict. Proper colour conversion remains deferred.

For H.264, HEVC, and MPEG-4 YCbCr formats, a missing Core Media `FullRangeVideo` flag means limited range according to the framework contract. Primaries, transfer, and matrix are never inferred from resolution or camera model.

## Validation

[`validate-colour-compatibility.sh`](../../scripts/spikes/validate-colour-compatibility.sh) regenerates the deterministic fixtures and runs the AVFoundation inspection test. It proves that the BT.709/full-range base and mixed-format fixtures match while the BT.2020/PQ/limited-range fixture reports all four conflicts.

Pure unit tests also cover Apple/FFmpeg alias normalization, missing values, Canon Log-style unrecognized tags, HDR/SDR conflict reporting, and the complete actionable error:

> This clip cannot be added because its colour metadata does not match the timeline: [property details]. frogmouth does not convert colour spaces yet. Choose a clip with matching colour metadata.

The actual message lists every differing property and both the timeline and clip values.
