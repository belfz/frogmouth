# Deterministic media fixtures

The phase-0 integration fixtures are generated rather than committed as media binaries. Run:

```sh
./scripts/verify-media-fixtures.sh
```

By default the files are written under `.build/test-media-fixtures`. Pass another directory as the first argument when a spike needs an isolated workspace. `probe-media-fixture.sh` prints exact FFprobe JSON for one file, including decoded frame count, rational frame rate, audio facts, and colour signaling.

Every video frame contains its zero-based frame number. Audio fixtures use a distinct constant tone so concatenation and synchronization tests can identify their source. The set covers:

- a 24 fps 16:9 Rec.709/full-range baseline with 440 Hz audio;
- compatible 30000/1001 landscape, 25 fps portrait, and 60000/1001 high-rate variants with different tones;
- a silent Rec.709 clip; and
- an intentionally incompatible BT.2020/PQ/limited-range clip.

Generation is deterministic in content, timing, stream layout, and metadata for the approved FFmpeg build. Encoded bytes are not promised to remain identical across FFmpeg or codec-library versions.

## Project schema fixture

`ProjectSchemaV1.frogmouth` is the checked-in canonical, human-readable project JSON fixture. Unlike generated media, it is committed intentionally: deterministic encode/decode tests use it to lock schema version 1 and make future migrations reviewable as ordinary text diffs.

## Baseline before timeline work

At the start of phase 0 on FFmpeg 7.1.1, frogmouth has 14 passing Swift tests, including the installed-FFmpeg stabilization integration test. The local release app bundle is built with:

```sh
./scripts/build-app.sh
```
