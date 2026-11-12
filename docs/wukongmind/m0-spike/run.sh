#!/usr/bin/env bash
# Reruns the M0 CSP / execution-world spike on an iOS simulator and writes results/results.{md,json}.
# Usage: docs/wukongmind/m0-spike/run.sh            (SIM="iPhone 18 Pro" by default)
#        SIM="iPad Air 11-inch (M4)" OUT=/some/dir docs/wukongmind/m0-spike/run.sh
# Needs Xcode and xcodegen; xcsift is used for a short summary when installed.
set -euo pipefail
cd "$(dirname "$0")"
SIM="${SIM:-iPhone 18 Pro}"
OUT="${OUT:-$PWD/results}"
DD="${DERIVED_DATA:-${TMPDIR:-/tmp}/wukongmind-m0-spike-dd}"
mkdir -p "$OUT"
xcodegen generate --quiet
LOG="$OUT/xcodebuild.log"
set +e
TEST_RUNNER_SPIKE_OUT="$OUT" xcodebuild test \
  -project M0Spike.xcodeproj -scheme SpikeTests \
  -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath "$DD" >"$LOG" 2>&1
code=$?
set -e
if command -v xcsift >/dev/null; then xcsift -f toon <"$LOG" || true; else tail -n 20 "$LOG"; fi
echo "xcodebuild exit $code; results in $OUT/results.md (full log: $LOG)"
exit $code
