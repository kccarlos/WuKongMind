#!/usr/bin/env bash
# Write an ExportOptions.plist for an App Store Connect (TestFlight) export.
# Usage: write-export-options.sh <output.plist>
# Env:   DEVELOPMENT_TEAM (required: the Apple Developer Team ID)
#        PROFILE_APP (optional: App Store profile name for manual signing;
#                     when omitted, writes signingStyle=automatic)
#        PROFILE_SHARE (optional: share extension App Store profile name)
#        BUNDLE_ID_PREFIX (optional, default io.github.kccarlos.wukongmind)
set -euo pipefail

out="${1:?usage: write-export-options.sh <output.plist>}"
team="${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to the Apple Developer Team ID}"
profile_app="${PROFILE_APP:-}"
profile_share="${PROFILE_SHARE:-}"
prefix="${BUNDLE_ID_PREFIX:-io.github.kccarlos.wukongmind}"

if [[ -n "$profile_app" ]]; then
  share_entry=""
  if [[ -n "$profile_share" ]]; then
    share_entry="
    <key>${prefix}.share</key>
    <string>${profile_share}</string>"
  fi
  signing_block="  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Apple Distribution</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>${prefix}</key>
    <string>${profile_app}</string>${share_entry}
  </dict>"
else
  signing_block="  <key>signingStyle</key>
  <string>automatic</string>"
fi

cat >"$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>teamID</key>
  <string>${team}</string>
${signing_block}
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
PLIST
plutil -lint "$out"
