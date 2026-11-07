#!/usr/bin/env bash
# Render the App Store marketing screenshots from the raw captures in
# appstore/screenshots-raw/<locale>/ into appstore/screenshots/<locale>/ for
# every store locale (en-US, zh-Hans, zh-Hant). See render_store_screenshots.swift.
#
# Usage: scripts/brand/render_store_screenshots.sh [--preview <dir>]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

xcrun swiftc -parse-as-library -O \
  "$repo_root/Forumind/BrandMarkShapes.swift" \
  "$repo_root/Forumind/BrandMark.swift" \
  "$repo_root/scripts/brand/render_store_screenshots.swift" \
  -o "$work/render_store_screenshots"
"$work/render_store_screenshots" "$repo_root" "$@"

# Keep the committed PNGs small (opaque palette PNGs: no alpha, which App
# Store Connect rejects). brew install pngquant.
if command -v pngquant >/dev/null; then
  for file in "$repo_root"/appstore/screenshots/*/iphone*.png "$repo_root"/appstore/screenshots/*/ipad*.png; do
    pngquant --quality=80-98 --speed 1 --strip --force --skip-if-larger --ext .png -- "$file" || true
  done
else
  echo "pngquant not found; the screenshots are not compressed (brew install pngquant)" >&2
fi
