#!/usr/bin/env bash
# Run one test shard with `xcodebuild test-without-building` against the
# products from scripts/ci/build-for-testing.sh.
#
# Usage: scripts/ci/run-tests.sh <shard> [--print]
#   --print   only print the xcodebuild test selection (no run)
#
# Env:
#   DESTINATION   xcodebuild destination on this runner (pick-simulator.sh)
#   PRODUCTS      directory holding *.xctestrun and Debug-iphonesimulator/
#                 (default DerivedData/Build/Products)
#   RESULT        result bundle (default TestResults.xcresult)
#   LOG           raw xcodebuild log (default tests.log)
#
# Every shard list below is either a named list (-only-testing) or "the rest"
# (the suite with -skip-testing of that same list), so a test that is added or
# renamed still runs in some shard. Times are from GitHub's xcode-27 runners
# (runs 43957715364 and 43838760004); rebalance with real timings when a shard
# drifts. The UI set in CI is SuggestionRowUITests and ScriptManagerUITests;
# the multi-launch, perf and live suites stay manual (docs/DEVELOPMENT.md).
set -euo pipefail

shard="${1:?usage: run-tests.sh <shard> [--print]}"
print_only=false
[[ "${2:-}" == --print ]] && print_only=true

# Unit suites that take about half of the serial unit time (~600 of ~1,100 s;
# the PR shard unit-b also carries the UI smoke set, ~2.5 min). Each job's first
# suite also pays 1-2 min of warm-up.
UNIT_A=(
  BrowserTabsTests          # ~129 s
  AIViewIntentTests         # ~114 s
  AgentBridgeTests          # ~110 s
  CloudSyncTests            # ~93 s
  VoiceActivityDetectorTests # ~54 s
  StateTransitionTests      # ~39 s
  OneLoopComparisonTests    # ~38 s
  PageFeedbackTests         # ~38 s
  AgentPageCaptureTests     # ~30-86 s
  LiveReplayTests           # ~30 s
  ContentBlockerWebKitTests # ~22-35 s
  TabsToolTests             # ~18-20 s
  ScriptImportTests         # ~15-27 s
  CapabilityToolsTests      # ~12-29 s
  LearnedSiteRepairWebTests # ~14-19 s
  LookLikeThreadProbeTests  # ~15-17 s
)

UI_SUITES=(SuggestionRowUITests ScriptManagerUITests)

# The three long ScriptManager tests (~500 s together) form UI shard 1.
UI_1=(
  ScriptManagerUITests/testM4GMAiSettingsManagerAndDetailViews        # ~230 s
  ScriptManagerUITests/testSpaForumPersistReloadReopenRouteAndManagerToggleOff # ~150 s
  ScriptManagerUITests/testAutoDisabledScriptShowsReasonAndFixButtonInThisPage # ~120 s
)

# Pull request UI smoke set (~2.5 min): quick tests that cover the
# main surfaces. The suggestion row on a forum thread and on an ordinary page,
# handing a search to the agent, the page-scripts popover, and the script
# manager with its history. The slowest and most often retried tests
# (testNotifyMeFollowsTheThread, the UI_1 tests) stay out; they run on main,
# nightly and tags. testSearchThisForum... and testPageScriptsPopover... have
# needed a retry too (WUKO-126/127 own flaky tests).
UI_SMOKE=(
  SuggestionRowUITests/testForumThreadShowsFourSuggestions
  SuggestionRowUITests/testOrdinaryPageShowsPageSuggestions
  SuggestionRowUITests/testSearchThisForumFillsTheBoxThenSendsToAgent
  ScriptManagerUITests/testPageScriptsPopoverTogglesReloadAndOpensManager
  ScriptManagerUITests/testScriptManagerGroupsDetailAndHistoryRollback
)

# Plain loops, no mapfile: macOS ships bash 3.2.
args=()
only() { local target="$1" t; shift; for t in "$@"; do args+=("-only-testing:$target${t:+/$t}"); done; }
skip() { local target="$1" t; shift; for t in "$@"; do args+=("-skip-testing:$target/$t"); done; }

ui=false
case "$shard" in
  unit)
    only WukongMindTests "" ;;
  unit-a)
    only WukongMindTests "${UNIT_A[@]}" ;;
  unit-b)
    only WukongMindTests ""
    skip WukongMindTests "${UNIT_A[@]}" ;;
  unit-b+ui-smoke)
    ui=true
    only WukongMindTests ""
    skip WukongMindTests "${UNIT_A[@]}"
    only WukongMindUITests "${UI_SMOKE[@]}" ;;
  ui-smoke)
    ui=true
    only WukongMindUITests "${UI_SMOKE[@]}" ;;
  ui)
    ui=true
    only WukongMindUITests "${UI_SUITES[@]}" ;;
  ui-1)
    ui=true
    only WukongMindUITests "${UI_1[@]}" ;;
  ui-2)
    ui=true
    only WukongMindUITests "${UI_SUITES[@]}"
    skip WukongMindUITests "${UI_1[@]}" ;;
  *)
    echo "Unknown shard '$shard' (unit, unit-a, unit-b, unit-b+ui-smoke, ui-smoke, ui, ui-1, ui-2)" >&2
    exit 2 ;;
esac

# Per-test cap: 300 s for unit tests, 600 s once UI tests are in the shard
# (testM4GMAiSettingsManagerAndDetailViews took 277 s on a slow runner).
allowance=300
$ui && allowance=600

if $print_only; then
  printf '%s\n' "${args[@]}"
  echo "-maximum-test-execution-time-allowance $allowance"
  exit 0
fi

: "${DESTINATION:?set DESTINATION (scripts/ci/pick-simulator.sh)}"
products="${PRODUCTS:-DerivedData/Build/Products}"
result="${RESULT:-TestResults.xcresult}"
log="${LOG:-tests.log}"

shopt -s nullglob
runs=("$products"/*.xctestrun)
if [[ ${#runs[@]} -ne 1 ]]; then
  echo "Expected one .xctestrun in $products, found ${#runs[@]}" >&2
  exit 1
fi

formatter=(cat)
if command -v xcbeautify >/dev/null; then formatter=(xcbeautify --renderer github-actions); fi

# Raw log lines get a wall-clock prefix (the beautified output arrives in
# bursts, so its GitHub timestamps say little about where time went).
# xcbeautify gets the lines without the prefix, or it can't parse them.
stamp() { perl -MPOSIX -ne '$|=1; print strftime("%H:%M:%S ", localtime), $_'; }
unstamp() { perl -pe '$|=1; s/^\d\d:\d\d:\d\d //'; }

run_tests() {
  set -o pipefail
  # A test passes if any of 3 attempts passes; flaky-summary.sh lists every
  # test that needed a retry.
  xcodebuild test-without-building \
    -xctestrun "${runs[0]}" \
    -destination "$DESTINATION" \
    "${args[@]}" \
    -parallel-testing-enabled NO \
    -retry-tests-on-failure \
    -test-iterations 3 \
    -test-timeouts-enabled YES \
    -maximum-test-execution-time-allowance "$allowance" \
    -resultBundlePath "$result" \
    2>&1 | stamp | tee "$log" | unstamp | "${formatter[@]}"
}

# Retry the whole run once, only when the test runner never launched.
if ! run_tests; then
  grep -q "Lost pending connection to the test runner" "$log" || exit 1
  echo "::warning::Test runner never launched (Lost pending connection); retrying once"
  rm -rf "$result"
  run_tests
fi
