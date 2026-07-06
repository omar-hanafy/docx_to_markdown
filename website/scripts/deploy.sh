#!/usr/bin/env bash
#
# Build the site for the GitHub Pages subpath and sync it into the
# omar-hanafy.github.io repo. Does NOT touch git - review, commit and push the
# Pages repo yourself after running this.
#
#   npm run deploy
#
# Overridable via env:
#   PAGES_DIR   path to the omar-hanafy.github.io checkout
#   SUBDIR      subfolder / URL segment (default: docx-to-markdown)
#   SITE_URL    origin used for canonical/OG/sitemap (default: https://omar-hanafy.github.io)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"                 # website/
PAGES_DIR="${PAGES_DIR:-/Users/omarhanafy/Development/MyProjects/omar-hanafy.github.io}"
SUBDIR="${SUBDIR:-docx-to-markdown}"
export SITE_URL="${SITE_URL:-https://omar-hanafy.github.io}"
export BASE_PATH="/$SUBDIR"

DEST="$PAGES_DIR/$SUBDIR"

if [ ! -d "$PAGES_DIR/.git" ]; then
  echo "error: $PAGES_DIR is not a git checkout of the Pages repo" >&2
  exit 1
fi

echo "→ Building with SITE_URL=$SITE_URL BASE_PATH=$BASE_PATH"
cd "$HERE"
npm run build

echo "→ Syncing dist/ → $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R dist/. "$DEST/"

COUNT="$(cd "$DEST" && find . -type f | wc -l | tr -d ' ')"
echo "✓ Deployed $COUNT files to $DEST"
echo "  Live (after commit+push) at: $SITE_URL$BASE_PATH/"
