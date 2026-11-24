#!/usr/bin/env bash
# Render docs/brand/social-preview.png (1280x640) from docs/brand/social-preview.html.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
html="$repo_root/docs/brand/social-preview.html"
out="$repo_root/docs/brand/social-preview.png"

chrome=""
for candidate in \
  "${CHROME_BIN:-}" \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "$(command -v google-chrome 2>/dev/null || true)" \
  "$(command -v chromium 2>/dev/null || true)" \
  "$(command -v chromium-browser 2>/dev/null || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    chrome="$candidate"
    break
  fi
done

if [[ -z "$chrome" ]]; then
  echo "error: Chrome or Chromium not found (set CHROME_BIN to override)" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$chrome" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --user-data-dir="$work/profile" \
  --window-size=1280,640 \
  --force-device-scale-factor=1 \
  --hide-scrollbars \
  --screenshot="$work/out.png" \
  "file://$html" >/dev/null 2>&1

cp "$work/out.png" "$out"
