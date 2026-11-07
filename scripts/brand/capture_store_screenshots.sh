#!/usr/bin/env bash
# Take the raw App Store captures (appstore/screenshots-raw/<locale>/) and the
# README images (docs/screenshots/) from the DEBUG sample data, by running
# ForumindUITests/StoreScreenshotTests on a 6.9" iPhone and a 13" iPad
# simulator in each store language. Then render the store images with
# scripts/brand/render_store_screenshots.sh.
#
# Usage: scripts/brand/capture_store_screenshots.sh [locale ...]   (default: en-US zh-Hans zh-Hant)
# Environment: IPHONE_SIM, IPAD_SIM (simulator names; set one to "" to skip
# that device), DERIVED_DATA.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
iphone="${IPHONE_SIM-iPhone 17 Pro Max}"
ipad="${IPAD_SIM-iPad Pro 13-inch (M5)}"
derived="${DERIVED_DATA:-${TMPDIR:-/tmp}/forumind-screenshots-dd}"
locales=("$@")
[ ${#locales[@]} -gt 0 ] || locales=(en-US zh-Hans zh-Hant)

udid_of() {
  xcrun simctl list devices available | grep -F "    $1 (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

cd "$repo_root"
xcodebuild build-for-testing -project Forumind.xcodeproj -scheme Forumind \
  -destination "platform=iOS Simulator,name=${iphone:-$ipad}" CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath "$derived" -quiet

for sim in "$iphone" "$ipad"; do
  [ -n "$sim" ] || continue
  udid="$(udid_of "$sim")"
  # None yet: create one of that device type (the name is the type's name).
  [ -n "$udid" ] || udid="$(xcrun simctl create "$sim" "$sim")"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl ui "$udid" appearance light
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged \
    --batteryLevel 100 --cellularBars 4 --wifiBars 3
  for locale in "${locales[@]}"; do
    case "$locale" in en-US) language=en; suffix="" ;; *) language="$locale"; suffix="-$locale" ;; esac
    out="$(mktemp -d)"
    xcrun simctl uninstall "$udid" io.github.kccarlos.forumind 2>/dev/null || true
    TEST_RUNNER_DC_SCREENSHOT_DIR="$out" TEST_RUNNER_DC_SHOT_LANGUAGE="$language" \
      xcodebuild test-without-building -project Forumind.xcodeproj -scheme Forumind \
      -destination "id=$udid" -derivedDataPath "$derived" -quiet \
      -only-testing:ForumindUITests/StoreScreenshotTests
    mkdir -p "appstore/screenshots-raw/$locale"
    for shot in "$out"/iphone-69-*.png "$out"/ipad-13-*.png; do
      [ -e "$shot" ] || continue
      cp "$shot" "appstore/screenshots-raw/$locale/"
      pngquant --quality=80-98 --speed 1 --strip --force --skip-if-larger --ext .png \
        -- "appstore/screenshots-raw/$locale/$(basename "$shot")" || true
    done
    # README images: 720 px high, quantized (from the full-size capture).
    for pair in home:iphone-69-1-home summary:iphone-69-2-summary ask:iphone-69-4-agent page:iphone-page; do
      shot="$out/${pair#*:}.png"
      [ -e "$shot" ] || continue
      target="docs/screenshots/iphone-${pair%%:*}$suffix.png"
      sips -Z 720 "$shot" --out "$target" >/dev/null
      pngquant --force --skip-if-larger --output "$target" -- "$target" || true
    done
    rm -rf "$out"
  done
done
echo "Captured. Now run scripts/brand/render_store_screenshots.sh"
