#!/usr/bin/env bash
#
# Regenerates the client-side converter (website/public/converter/converter.js)
# by compiling the Dart docx_to_markdown package to JavaScript.
#
# Run this whenever the Dart package changes. Requires the Dart SDK.
# Static hosts do NOT need Dart - the committed converter.js is what ships.
#
# Usage:  ./scripts/build-bridge.sh   (from the website/ directory or anywhere)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBSITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE_DIR="$WEBSITE_DIR/bridge"
OUT="$WEBSITE_DIR/public/converter/converter.js"

if ! command -v dart >/dev/null 2>&1; then
  echo "error: dart SDK not found on PATH. Install Dart to rebuild the converter." >&2
  exit 1
fi

echo "==> Resolving bridge dependencies"
( cd "$BRIDGE_DIR" && dart pub get )

echo "==> Compiling docx_to_markdown -> $OUT"
mkdir -p "$(dirname "$OUT")"
( cd "$BRIDGE_DIR" && dart compile js -O2 -m --no-source-maps -o "$OUT" web/converter_bridge.dart )

# dart compile js also emits a .deps sidecar we don't ship.
rm -f "$OUT.deps"

# Stamp the build with the package version so the site can display/verify it.
PKG_VERSION="$(cd "$WEBSITE_DIR/.." && grep -m1 '^version:' pubspec.yaml | awk '{print $2}')"
printf '{ "packageVersion": "%s" }\n' "$PKG_VERSION" > "$WEBSITE_DIR/public/converter/converter.meta.json"

echo "==> Done. converter.js is $(du -h "$OUT" | awk '{print $1}') (package v$PKG_VERSION)"
echo "    Remember to commit converter.js + converter.meta.json."
