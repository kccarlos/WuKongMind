#!/usr/bin/env bash
# Reruns the M4 script-worlds / execution-world spike on an iOS simulator and writes results/results.{md,json}.
# Usage: docs/wukongmind/m4-spike/run.sh            (SIM=iphone by default)
#        SIM=ipad OUT=/some/dir docs/wukongmind/m4-spike/run.sh
# Needs Xcode and xcodegen; xcsift is used for a short summary when installed.
set -euo pipefail
cd "$(dirname "$0")"
# The two fixed simulators: iphone (default) or ipad, or a UDID.
case "${SIM:-iphone}" in
  iphone) SIM_ID=E0CEECF1-202B-497F-AD1D-B0B90193D1C0 ;;
  ipad) SIM_ID=1B6602A4-C05F-4933-92F2-9D300FA6148E ;;
  *) SIM_ID="$SIM" ;;
esac
OUT="${OUT:-$PWD/results}"
DD="${DERIVED_DATA:-/Volumes/Ext/dev/build/wukongmind-dd/m4-spike}"
mkdir -p "$OUT"
xcodegen generate --quiet
LOG="$OUT/xcodebuild.log"
set +e
TEST_RUNNER_SPIKE_OUT="$OUT" xcodebuild test \
  -project M4Spike.xcodeproj -scheme SpikeTests \
  -destination "platform=iOS Simulator,id=$SIM_ID" -parallel-testing-enabled NO \
  -derivedDataPath "$DD" >"$LOG" 2>&1
code=$?
set -e
if command -v xcsift >/dev/null; then xcsift -f toon <"$LOG" || true; else tail -n 20 "$LOG"; fi
echo "xcodebuild exit $code; results in $OUT/results.md (full log: $LOG)"
exit $code
