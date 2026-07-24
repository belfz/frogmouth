# Releasing frogmouth

frogmouth uses product-oriented Semantic Versioning and distributes Apple-silicon
macOS builds through GitHub Releases.

## Compatibility contract

- `VERSION` is the authoritative user-visible application version and maps to
  `CFBundleShortVersionString`.
- `CFBundleVersion` is an independent, monotonically increasing CI build number.
- Git tags use the exact `vMAJOR.MINOR.PATCH` form.
- Project schema 2 is the stable 1.0 baseline. Every future released project
  schema must retain support or provide an explicit migration.
- Cache schemas and processing revisions are independent and may invalidate
  disposable generated artifacts.
- Supported FFmpeg versions are maintained independently of the application
  version.

Patch releases contain compatible fixes. Minor releases add compatible
functionality. Major releases may intentionally change compatibility,
requirements, or core editing behavior.

## Current distribution trade-off

Release artifacts are intentionally unsigned and not notarized. Users must
approve frogmouth in **System Settings → Privacy & Security** before first
launch. Developer ID signing and notarization should be added before broader
commercial distribution, but they are not a 1.0 requirement.

## Prepare a release

1. Update `VERSION` in a pull request.
2. Move user-facing entries from `Unreleased` into a dated version section in
   `CHANGELOG.md`.
3. Confirm the compatibility values and supported FFmpeg versions in the
   documentation.
4. Merge only after the full CI workflow passes.
5. Update local `main` and create an annotated tag:

   ```sh
   git tag -a v1.0.0 -m "frogmouth 1.0.0"
   git push origin v1.0.0
   ```

The release workflow rejects a tag that disagrees with `VERSION`. A valid tag
runs the complete media-backed suite, builds the app, creates an unsigned DMG
and ZIP, generates SHA-256 checksums, and creates or updates a **draft** GitHub
Release.

## Verify and publish

1. Download all three artifacts from the draft release.
2. Run `shasum -a 256 -c SHA256SUMS.txt`.
3. Test the DMG drag-to-Applications flow on an Apple-silicon Mac.
4. Confirm the documented Gatekeeper approval flow on a clean user account.
5. Open an existing schema-2 project, preview it, and export a short timeline.
6. Verify **Check for Updates…** opens the expected GitHub release page.
7. Review the release title, changelog, requirements, and unsigned-build
   warning.
8. Publish the draft manually.

Published release assets are immutable in practice: never replace a released
binary under the same version. Fixes receive a new patch version.
