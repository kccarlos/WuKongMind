#!/usr/bin/env bash
# Runs the One loop voice spike against real Gemini Live and writes results/<question>.json.
# Usage (the key comes through herdr-secret, never on the command line):
#   herdr-secret run GEMINI_LIVE_KEY -- docs/wukongmind/one-loop-spike/run.sh            # all six
#   herdr-secret run GEMINI_LIVE_KEY -- docs/wukongmind/one-loop-spike/run.sh testQ3Routing
# Uses only the fixed iPhone 18 Pro simulator, one run at a time, no parallel testing.
set -euo pipefail
cd "$(dirname "$0")"
# Vertex first: VERTEX_API_KEY with SPIKE_VERTEX_PROJECT (a project id or number); else AI Studio GEMINI_LIVE_KEY.
KEY="${VERTEX_API_KEY:-${GEMINI_LIVE_KEY:-}}"
: "${KEY:?VERTEX_API_KEY or GEMINI_LIVE_KEY is not set (run through herdr-secret)}"
if [ -z "${VERTEX_API_KEY:-}" ]; then unset SPIKE_VERTEX_PROJECT; fi
SIM_ID="${SIM_ID:-E0CEECF1-202B-497F-AD1D-B0B90193D1C0}"
OUT="${OUT:-$PWD/results}"
DD="${DERIVED_DATA:-${TMPDIR:-/tmp}/wukongmind-one-loop-spike-dd}"
mkdir -p "$OUT"
xcodegen generate --quiet
only=()
for t in "$@"; do only+=("-only-testing:SpikeTests/VoiceSpikeTests/$t"); done
LOG="$OUT/xcodebuild-${1:-all}.log"
set +e
TEST_RUNNER_SPIKE_OUT="$OUT" TEST_RUNNER_SPIKE_GEMINI_KEY="$KEY" TEST_RUNNER_SPIKE_ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}" TEST_RUNNER_SPIKE_VERTEX_PROJECT="${SPIKE_VERTEX_PROJECT:-}" xcodebuild test \
  -project OneLoopSpike.xcodeproj -scheme SpikeTests \
  -destination "id=$SIM_ID" -parallel-testing-enabled NO \
  -derivedDataPath "$DD" "${only[@]+"${only[@]}"}" >"$LOG" 2>&1
code=$?
set -e
grep -E "Test Case .*(passed|failed)|error:|SPIKE " "$LOG" | tail -n 60 || true
echo "xcodebuild exit $code; results in $OUT (full log: $LOG)"
exit $code
