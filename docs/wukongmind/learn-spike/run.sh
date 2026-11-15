#!/usr/bin/env bash
# Runs the Learn on ask spike (Q1–Q9) on the Mac mini simulator under its lock
# (local xcodebuild fallback only when the mini is unreachable) -> results/*.json.
# shellcheck disable=SC2016,SC2029,SC2087,SC2329
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WT_NAME="$(basename "$REPO_ROOT" | tr -c 'A-Za-z0-9._-\n' '_')"
REMOTE_HOST="${REMOTE_TEST_HOST:-kechengs-mac-mini-2}"
SIM="${SIM:-iphone}"
OUT="${OUT:-$SCRIPT_DIR/results}"
TIMEOUT="${SPIKE_TIMEOUT:-1800}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=6)

if [[ "$SIM" == "ipad" ]]; then
  REMOTE_UDID="F0750EC3-8319-4183-B43E-BE6E6BE694F3"
  LOCAL_DEST="platform=iOS Simulator,name=iPad Air 11-inch (M4)"
else
  REMOTE_UDID="16A99B26-BFFC-49B4-B068-EA0FE058AFA5"
  LOCAL_DEST="id=E0CEECF1-202B-497F-AD1D-B0B90193D1C0"
fi
mkdir -p "$OUT" && OUT="$(cd "$OUT" && pwd)"
ONLY=(); for t in "$@"; do ONLY+=("-only-testing:SpikeTests/LearnSpikeTests/$t"); done
SECRETS=(); for k in ANTHROPIC_API_KEY VERTEX_API_KEY GEMINI_LIVE_KEY; do [[ -n "${!k-}" ]] && SECRETS+=("${!k}"); done
leak_check() { ((${#SECRETS[@]})) && grep -rqF -f <(printf '%s\n' "${SECRETS[@]}") "$@" 2>/dev/null; }

LOCK_TOKEN="$$.$RANDOM.$(date +%s)"; LOCK_HELD=0
cleanup() {
  local rc=$?; trap - EXIT INT TERM
  if (( LOCK_HELD )); then
    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "export PATH=/opt/homebrew/bin:\$PATH; d=~/remote-test/locks/$REMOTE_UDID.lock; if [ -f \"\$d/token\" ] && [ \"\$(cat \"\$d/token\")\" = '$LOCK_TOKEN' ]; then pkill -f '[x]codebuild.*$WT_NAME-learn-spike.dd' 2>/dev/null; [ -f \"\$d/booted\" ] && xcrun simctl shutdown '$REMOTE_UDID' 2>/dev/null; rm -rf \"\$d\"; fi" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
LOG="$OUT/xcodebuild-${1:-all}.log"; RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"

if ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" true 2>/dev/null; then
  LOCK_HELD=1
  while [[ "$(ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "mkdir -p ~/remote-test/locks; d=~/remote-test/locks/$REMOTE_UDID.lock; if mkdir \"\$d\" 2>/dev/null; then echo '$WT_NAME' >\"\$d/owner\"; echo '$LOCK_TOKEN' >\"\$d/token\"; echo ACQUIRED; else echo HELD; fi")" != "ACQUIRED" ]]; do
    echo "[learn-spike] waiting 20s for lock $REMOTE_UDID on $REMOTE_HOST..." >&2; sleep 20
  done
  R_SRC="remote-test/$WT_NAME"; R_OUT="remote-test/$WT_NAME.learn-results/$RUN_ID"
  ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "mkdir -p ~/$R_SRC ~/$R_OUT"
  rsync -az --delete --exclude='.git' --exclude='DerivedData/' --exclude='build/' --exclude='*.xcresult' \
    --exclude='docs/wukongmind/learn-spike/results/' -e "ssh ${SSH_OPTS[*]}" "$REPO_ROOT/" "$REMOTE_HOST:$R_SRC/"
  {
    echo 'umask 077; export PATH=/opt/homebrew/bin:$PATH; SD=""; HB=""'
    echo 'trap '\''kill $HB 2>/dev/null; [ -n "$SD" ] && rm -rf "$SD"'\'' EXIT'
    if ((${#SECRETS[@]})); then
      term="END_$RANDOM$RANDOM"; echo 'SD=$(mktemp -d "$HOME/remote-test/.secrets.XXXXXX") || exit 1'
      echo "cat >\"\$SD/env\" <<'$term'"
      [[ -n "${ANTHROPIC_API_KEY-}" ]] && printf 'export TEST_RUNNER_SPIKE_ANTHROPIC_KEY=%q\n' "$ANTHROPIC_API_KEY"
      [[ -n "${VERTEX_API_KEY-}" ]] && printf 'export TEST_RUNNER_SPIKE_VERTEX_KEY=%q\n' "$VERTEX_API_KEY"
      [[ -n "${GEMINI_LIVE_KEY-}" ]] && printf 'export TEST_RUNNER_SPIKE_GEMINI_KEY=%q\n' "$GEMINI_LIVE_KEY"
      printf '%s\nchmod 600 "$SD/env"\n' "$term"
    fi
    printf 'LOCKDIR="$HOME/remote-test/locks/%s.lock"\n' "$REMOTE_UDID"
    printf 'st=$(xcrun simctl list devices | grep %q | sed -E '\''s/.*\(([A-Za-z]+)\) *$/\1/'\'')\n' "$REMOTE_UDID"
    printf '[ "$st" != Booted ] && xcrun simctl boot %q && touch "$LOCKDIR/booted" && xcrun simctl bootstatus %q -b >/dev/null 2>&1\n' "$REMOTE_UDID" "$REMOTE_UDID"
    echo "( while sleep 300; do touch \"\$LOCKDIR\"; done ) & HB=\$!"
    echo "cd \"\$HOME/$R_SRC/docs/wukongmind/learn-spike\" && xcodegen generate --quiet || { echo REMOTE_XCODEBUILD_RC=1; exit 1; }"
    printf '( [ -n "$SD" ] && . "$SD/env"; TEST_RUNNER_SPIKE_OUT="$HOME/%s" xcodebuild test -project LearnSpike.xcodeproj -scheme SpikeTests -destination %q -parallel-testing-enabled NO -derivedDataPath "$HOME/remote-test/%s-learn-spike.dd" CODE_SIGNING_ALLOWED=NO' "$R_OUT" "id=$REMOTE_UDID" "$WT_NAME"
    for a in "${ONLY[@]+"${ONLY[@]}"}"; do printf ' %q' "$a"; done
    echo ' </dev/null ); rc=$?; echo "REMOTE_XCODEBUILD_RC=$rc"; exit "$rc"'
  } | perl -e 'alarm shift; exec @ARGV or exit 127' "$TIMEOUT" ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" 'bash -s' >"$LOG" 2>&1
  leak_check "$LOG" && { rm -f "$LOG"; echo "ERROR: secret leak in log" >&2; exit 70; }
  code="$(sed -n 's/^REMOTE_XCODEBUILD_RC=\([0-9]*\)$/\1/p' "$LOG" | tail -n1)"; code="${code:-1}"
  STAGING="$OUT/.staging"; rm -rf "$STAGING"; mkdir -p "$STAGING"
  rsync -az -e "ssh ${SSH_OPTS[*]}" "$REMOTE_HOST:$R_OUT/" "$STAGING/" 2>/dev/null || true
  leak_check "$STAGING" && { rm -rf "$STAGING" "$LOG"; echo "ERROR: secret leak in results" >&2; exit 70; }
  cp -R "$STAGING/." "$OUT/" 2>/dev/null || true; rm -rf "$STAGING"
else
  echo "REMOTE-TEST UNAVAILABLE: falling back to local xcodebuild" >&2
  pgrep -fl "xcodebuild test" >&2 && { echo "ERROR: local xcodebuild test running" >&2; exit 1; }
  DD="/Volumes/Ext/dev/build/wukongmind-dd/learn-spike"; mkdir -p "$DD"
  ( cd "$SCRIPT_DIR" && xcodegen generate --quiet && TEST_RUNNER_SPIKE_OUT="$OUT" TEST_RUNNER_SPIKE_ANTHROPIC_KEY="${ANTHROPIC_API_KEY-}" TEST_RUNNER_SPIKE_VERTEX_KEY="${VERTEX_API_KEY-}" TEST_RUNNER_SPIKE_GEMINI_KEY="${GEMINI_LIVE_KEY-}" xcodebuild test -project LearnSpike.xcodeproj -scheme SpikeTests -destination "$LOCAL_DEST" -parallel-testing-enabled NO -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO "${ONLY[@]+"${ONLY[@]}"}" ) >"$LOG" 2>&1
  code=$?
  leak_check "$LOG" "$OUT" && { rm -f "$LOG"; echo "ERROR: secret leak" >&2; exit 70; }
fi

grep -E "Test Case .*(passed|failed)|error:|SPIKE " "$LOG" | tail -n 50 || true
echo "xcodebuild exit $code; results in $OUT (log: $LOG)"
exit "$code"
