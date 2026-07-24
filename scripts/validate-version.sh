#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"

if [[ ! -f "$VERSION_FILE" ]]; then
    echo "Missing application version file: $VERSION_FILE" >&2
    exit 1
fi

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$VERSION" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]]; then
    echo "VERSION must contain a numeric major.minor.patch value, found: $VERSION" >&2
    exit 1
fi

if [[ "$#" -gt 0 && "$1" != "v$VERSION" ]]; then
    echo "Release tag $1 does not match VERSION v$VERSION." >&2
    exit 1
fi

echo "$VERSION"
