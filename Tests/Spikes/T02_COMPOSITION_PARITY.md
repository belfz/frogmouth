# T02 — AVFoundation and FFmpeg composition parity

Date: 2026-07-16  
Environment: Apple Silicon, macOS 15+, Swift 6.2.1, FFmpeg 7.1.1

## Question

Can AVFoundation provide immediate hard-cut timeline playback while FFmpeg independently renders the same edit decisions with equivalent timing, framing, and audio ordering?

## Compositions

[`scripts/spikes/validate-composition-parity.sh`](../../scripts/spikes/validate-composition-parity.sh) builds this sequence:

| Timeline range | Source | Native source range | Timeline duration |
| --- | --- | --- | --- |
| 00:00–01:00 | 320×180, 24 fps, 440 Hz | frames 12–35 | 24 frames |
| 01:00–02:00 | 426×180, 30000/1001 fps, 550 Hz | frames 15–44 (1.001 s) | 24 frames |
| 02:00–02:12 | first source again | frames 36–47 | 12 frames |

The first clip establishes a 320×180/24 fps timeline. The wide middle clip is aspect-fitted to 320×135 and centre-padded to 320×180. Its exact 1.001-second source range is snapped to 24 timeline frames/1 second; linked audio receives the same duration conformance.

The validator also builds a 60000/1001 timeline from 40 frames of the high-rate fixture, 12 frames/0.5 seconds of the 24 fps fixture conformed to 30 timeline frames/0.5005 seconds, and another 20 high-rate frames. The exact result is 90 frames over 1.5015 seconds.

[`AVCompositionParity.swift`](../../scripts/spikes/AVCompositionParity.swift) inserts and scales exact `CMTimeRange` values in an `AVMutableComposition`, applies per-segment transforms through `AVMutableVideoComposition`, and exports ProRes/PCM. Each clip's audio is inserted into an isolated composition track and an explicit `AVAudioMix` combines those tracks. The FFmpeg side applies exact trim, fps/timestamp normalization, aspect-fit scale/pad, audio tempo normalization, and concat before writing equivalent ProRes/PCM. Its output frame rate and constant-frame-rate policy are set explicitly.

## Results

| Property | AVFoundation | FFmpeg |
| --- | ---: | ---: |
| Canvas | 320×180 | 320×180 |
| Frame rate | 24/1 | 24/1 |
| Decoded frame count | 60 | 60 |
| Duration | 2.5 s | 2.5 s |
| Audio | 48 kHz stereo | 48 kHz stereo |
| Tone regions | 440 → 550 → 440 Hz | 440 → 550 → 440 Hz |

Decoded frame comparison across the entire output:

- average SSIM: 0.980392;
- minimum per-frame SSIM: 0.935113; and
- top/bottom padding in the middle clip is black and centred in both outputs.

ProRes encoder and scaling implementations prevent pixel/byte identity. The strong minimum similarity across every frame, visible fixture frame numbers, exact frame count, and matching boundary/audio regions demonstrate equivalent source-frame selection and cut timing.

The high-rate composition also matched:

| Property | AVFoundation | FFmpeg |
| --- | ---: | ---: |
| Canvas | 320×180 | 320×180 |
| Frame rate | 60000/1001 | 60000/1001 |
| Decoded frame count | 90 | 90 |
| Duration | 1.5015 s | 1.5015 s |
| Audio | 48 kHz stereo | 48 kHz stereo |
| Tone regions | 770 → 440 → 770 Hz | 770 → 440 → 770 Hz |

Its frame-by-frame comparison averaged 0.987062 SSIM with a minimum of 0.887834.

Two failures identified mandatory builder behavior:

- FFmpeg produced only 87 frames until `-r 60000/1001 -fps_mode cfr` made the output cadence explicit.
- A reused AVFoundation audio composition track produced AAC-boundary discontinuities at high rate. Isolating clip audio on separate composition tracks and supplying an explicit `AVAudioMix` preserved every tone region. A future track-pooling optimization must retain this spike as its regression gate.

The AVFoundation export must run outside Codex's restricted command sandbox because macOS media encoders are unavailable inside it. This is an execution-environment constraint, not an app requirement.

## Decision

- Keep the hybrid preview/export architecture.
- Express edit decisions once in rational domain types, then build both pipelines from that model.
- Snap each clip's timeline duration to the nearest whole timeline frame.
- Use `AVMutableComposition` plus `AVMutableVideoComposition` for interactive playback.
- Compose clip audio on isolated tracks with an explicit audio mix; do not assume one reused composition track is equivalent for AAC ranges.
- Use per-clip FFmpeg normalization followed by concat for final output.
- Set the FFmpeg output rational frame rate and constant-frame-rate mode explicitly.
- Scale linked audio to the same snapped duration.
- Maintain parity fixtures as integration gates when either builder changes.
