# Deterministic media fixtures

The integration fixtures are generated rather than committed as media binaries. Run:

```sh
./scripts/verify-media-fixtures.sh
```

By default the files are written under `.build/test-media-fixtures`. Pass another directory as the first argument when an isolated workspace is useful. `probe-media-fixture.sh` prints exact FFprobe JSON for one file, including decoded frame count, rational frame rate, audio facts, and colour signaling.

Every video frame contains its zero-based frame number. Audio fixtures use a distinct constant tone so concatenation and synchronization tests can identify their source. The set covers:

- a 24 fps 16:9 Rec.709/full-range baseline with 440 Hz audio;
- compatible 30000/1001 landscape, 25 fps portrait, and 60000/1001 high-rate variants with different tones;
- a silent Rec.709 clip; and
- an intentionally incompatible BT.2020/PQ/limited-range clip.

Generation is deterministic in content, timing, stream layout, and metadata for the approved FFmpeg build. Encoded bytes are not promised to remain identical across FFmpeg or codec-library versions.

GitHub Actions installs `ffmpeg-full` and requires these integration tests to run rather
than silently skipping when a prerequisite is absent. Its separately declared FFmpeg
version is a test-only allowance; it does not expand the versions accepted by the app.

## Project schema fixture

`ProjectSchemaV1.frogmouth` is the checked-in canonical, human-readable project JSON fixture. Unlike generated media, it is committed intentionally: deterministic encode/decode tests use it to lock schema version 1 and make future migrations reviewable as ordinary text diffs.

## Local app bundle

Build the local release app bundle with:

```sh
./scripts/build-app.sh
```
