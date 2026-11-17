#!/usr/bin/env bash
# Decide what a CI run does: which tier, whether code changed, and the test
# matrix. Used by the `changes` job in .github/workflows/ci.yml; also runs
# locally (prints the outputs).
#
# Env:
#   EVENT        github.event_name (pull_request, push, schedule, workflow_dispatch)
#   BASE         pull_request: the PR base SHA (diffed against HEAD)
#   TIER_INPUT   workflow_dispatch: "pr" or "full" (default full)
#
# Outputs (to $GITHUB_OUTPUT when set, always to stdout):
#   tier=pr|full
#   code=true|false   false only for a pull request that touches docs/images only
#   release=true|false  run the Release (device) build
#   matrix=<JSON>     {"include":[{"shard":..,"name":..,"timeout":..}]}
#
# Tiers (see docs/CI.md):
#   pr    unit tests split in two jobs; the UI smoke set rides with the lighter
#         half. 3 macOS jobs in total with the build (GitHub's free plan runs
#         5 macOS jobs at once; wider PR runs make queueing worse).
#   full  push to main, tags v*, nightly, manual: the whole unit suite, the CI
#         UI suites in two shards, and the Release build.
set -euo pipefail

event="${EVENT:-workflow_dispatch}"
tier="full"
code=true

case "$event" in
  pull_request)
    tier="pr"
    # Docs-only pull requests skip the macOS jobs. Only on pull requests: on
    # main a newer run can replace a queued one, so every push tests code.
    if [[ -n "${BASE:-}" ]] && git cat-file -e "${BASE}^{commit}" 2>/dev/null; then
      changed="$(git diff --name-only "$BASE" HEAD)"
      if [[ -n "$changed" ]] && ! grep -qvE '(\.md$|^docs/|\.(png|jpe?g|gif|svg|webp)$)' <<<"$changed"; then
        code=false
      fi
    fi
    ;;
  workflow_dispatch)
    tier="${TIER_INPUT:-full}"
    [[ "$tier" == pr || "$tier" == full ]] || { echo "TIER_INPUT must be pr or full, got '$tier'" >&2; exit 2; }
    ;;
esac

release=false
[[ "$tier" == full && "$code" == true ]] && release=true

# Shard ids are defined in scripts/ci/run-tests.sh. Timeouts: a normal run
# takes under half of them (job times in docs/CI.md).
if [[ "$tier" == pr ]]; then
  matrix='{"include":[
    {"shard":"unit-a","name":"Unit tests (1/2)","timeout":40},
    {"shard":"unit-b+ui-smoke","name":"Unit tests (2/2) + UI smoke","timeout":40}]}'
else
  matrix='{"include":[
    {"shard":"unit","name":"Unit tests","timeout":50},
    {"shard":"ui-1","name":"UI tests (1/2)","timeout":45},
    {"shard":"ui-2","name":"UI tests (2/2)","timeout":45}]}'
fi
matrix="$(tr -d '\n' <<<"$matrix" | tr -s ' ')"

out() {
  echo "$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >>"$GITHUB_OUTPUT"; fi
}
out "tier=$tier"
out "code=$code"
out "release=$release"
out "matrix=$matrix"
