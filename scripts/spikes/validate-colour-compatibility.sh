#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES="$ROOT/.build/test-media-fixtures"

"$ROOT/scripts/generate-media-fixtures.sh" "$FIXTURES"

CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swift-module-cache" \
    swift test --package-path "$ROOT" --filter mediaInspectorReadsGeneratedColourFixtures

echo "Validated matching BT.709/full-range fixtures and rejected the BT.2020/PQ/limited-range fixture."
