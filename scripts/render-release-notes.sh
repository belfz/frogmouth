#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$("$ROOT/scripts/validate-version.sh" "${1:-v$(tr -d '[:space:]' < "$ROOT/VERSION")}")"
CHANGELOG="$ROOT/CHANGELOG.md"

if [[ ! -f "$CHANGELOG" ]]; then
    echo "Missing changelog: $CHANGELOG" >&2
    exit 1
fi

cat <<EOF
> [!WARNING]
> This release is intentionally unsigned and not notarized. macOS will require
> explicit approval in System Settings → Privacy & Security before first launch.

**Requirements:** Apple-silicon Mac, macOS 15 or newer, and a supported external
FFmpeg installation containing libvidstab and the VideoToolbox HEVC encoder.

## Changes

EOF

awk -v version="$VERSION" '
    index($0, "## [" version "]") == 1 {
        found = 1
        next
    }
    found && /^## \[/ {
        exit
    }
    found && /^\[[^]]+\]:/ {
        exit
    }
    found {
        print
    }
    END {
        if (!found) {
            exit 42
        }
    }
' "$CHANGELOG" || {
    echo "CHANGELOG.md has no section for $VERSION." >&2
    exit 1
}
