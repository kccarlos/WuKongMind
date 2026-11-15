#!/usr/bin/env bash
# Simulator builds and tests on the owner's Mac mini, under a per-simulator lock.
# Run `scripts/remote-test.sh --help` for the full documentation.
# shellcheck disable=SC2016,SC2029,SC2087,SC2329 # remote script generation; cleanup/on_signal run via trap
set -uo pipefail

REMOTE_HOST="${REMOTE_TEST_HOST:-kechengs-mac-mini-2}"
REMOTE_BASE="remote-test" # relative to the mini's home directory
SCHEME="WukongMind"
SIM_IPHONE="16A99B26-BFFC-49B4-B068-EA0FE058AFA5" # iPhone 18 Pro
SIM_IPAD="F0750EC3-8319-4183-B43E-BE6E6BE694F3"   # iPad Air 11-inch (M4)

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WT_NAME="$(basename "$REPO_ROOT" | tr -c 'A-Za-z0-9._-\n' '_')"

LOCK_STALE_SECS="${LOCK_STALE_SECS:-2700}" # 45 minutes
LOCK_POLL_SECS="${LOCK_POLL_SECS:-20}"
OUT_ROOT="${REMOTE_TEST_OUT_ROOT:-/Volumes/Ext/dev/build/wukongmind-remote-test}"

EX_UNAVAILABLE=69 # the mini cannot be reached: callers fall back to local xcodebuild

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=6)

usage() {
  cat <<'EOF'
remote-test.sh: run simulator builds and tests on the Mac mini, not on this Mac.

Usage:
  scripts/remote-test.sh [test|build] [options] [xcodebuild args...]

Modes:
  test    (default) `xcodebuild test` on a simulator on the mini. Extra args
          (e.g. -only-testing:WukongMindTests) go straight to xcodebuild. Runs
          with -parallel-testing-enabled NO and CODE_SIGNING_ALLOWED=NO.
  build   `xcodebuild build` for a generic simulator. No simulator, so no lock.

Options:
  --sim iphone|ipad|<udid>  simulator (default iphone). Only the two simulators
                            set up for this on the mini are allowed:
                            iphone = iPhone 18 Pro  16A99B26-BFFC-49B4-B068-EA0FE058AFA5
                            ipad   = iPad Air 11-inch (M4)  F0750EC3-8319-4183-B43E-BE6E6BE694F3
  --out <dir>               where results are copied back (default:
                            /Volumes/Ext/dev/build/wukongmind-remote-test/<worktree>-<timestamp>)
  --timeout <seconds>       limit for the xcodebuild step (default 1800)
  -h, --help                this text

What it does:
  1. Checks the mini is reachable over SSH (Tailscale). If not it prints
     "REMOTE-TEST UNAVAILABLE" and exits 69: run local xcodebuild instead.
  2. test mode: takes the lock `mkdir ~/remote-test/locks/<udid>.lock` ON THE
     MINI. While another agent holds it, retries every 20 s and prints the holder.
     A lock older than 45 minutes is dead and is taken over. The lock is released
     on exit, failure, Ctrl-C and TERM (only a lock this script took), and
     releasing also stops this run's xcodebuild and shuts the simulator down if
     this script booted it.
  3. rsyncs this worktree to ~/remote-test/<worktree>/ on the mini (excludes
     .git, DerivedData, build output; files deleted locally are deleted there).
  4. Regenerates the Xcode project there (ruby scripts/generate_project.rb).
  5. Runs xcodebuild with a per-worktree DerivedData (~/remote-test/<worktree>.dd)
     so reruns are incremental.
  6. Copies results back into --out: exit-status, failing-tests.txt, log-tail.txt,
     run.log, timings.txt and test.xcresult (screenshots and attachments are in it).
  Run one remote-test per worktree at a time (they share the mini's copy of it).

Secrets for live checks:
  --secret NAME=TEST_RUNNER_NAME  pass the local environment variable NAME to the
                            tests as TEST_RUNNER_NAME. Use with herdr-secret:
        herdr-secret run ANTHROPIC_API_KEY -- scripts/remote-test.sh \
          --secret ANTHROPIC_API_KEY=TEST_RUNNER_ANTHROPIC_API_KEY -only-testing:...
  The value is read from this shell's environment only, sent over the SSH stdin,
  kept in a 0600 file in a fresh mktemp dir under ~/remote-test that a trap
  deletes on every exit path, and exported only for the xcodebuild process. It
  is never in a command line on either Mac. Before anything is copied back, the
  results and the log are searched for each value; on a hit nothing is copied,
  run.log is deleted and the exit status is 70 (or xcodebuild's). An argument
  like TEST_RUNNER_KEY=value is refused. TEST_RUNNER_* variables are NOT
  forwarded implicitly. Anthropic keys: claude-haiku-5-5 tests only.
  Live Gemini checks use Vertex first (VERTEX_API_KEY, optional VERTEX_MODEL):
        herdr-secret run VERTEX_API_KEY -- scripts/remote-test.sh \
          --secret VERTEX_API_KEY=TEST_RUNNER_VERTEX_API_KEY \
          -only-testing:WukongMindTests/CoreTests/testVertexAIProviderLiveConnectionAndStreaming
  and fall back to AI Studio (GEMINI_LIVE_KEY) only if Vertex fails.

Environment: REMOTE_TEST_HOST, LOCK_STALE_SECS,
LOCK_POLL_SECS, REMOTE_TEST_OUT_ROOT override the defaults.

Exit codes: xcodebuild's own status (0 ok, 65 test failures, ...); 2 usage;
69 the mini is unreachable; 70 a secret leaked into the results; 124 timeout.
EOF
}

log() { printf '[remote-test %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit "${2:-1}"; }

# ---------- ssh helpers ----------

ssh_mini() { ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "$@"; }

# Run a bash script (given on stdin) on the mini with a sane PATH.
mini_bash() { ssh_mini 'export PATH=/opt/homebrew/bin:$PATH; bash -s'; }

unavailable() {
  {
    echo "REMOTE-TEST UNAVAILABLE: $*"
    echo "  The Mac mini ($REMOTE_HOST) cannot be used right now."
    echo "  Fall back to local xcodebuild (see docs/DEVELOPMENT.md, Tests)."
  } >&2
  exit "$EX_UNAVAILABLE"
}

# ---------- cleanup, signals ----------

LOCK_UDID=""
LOCK_TOKEN=""
LOCK_HELD=0
CHILD_PID=""
TAIL_PID=""
REMOTE_DD=""
OUT=""
LEAK_CHECKED=0 # 0 until the results were searched for secret values
SECRET_VALUES=()

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  [[ -n "$CHILD_PID" ]] && kill "$CHILD_PID" 2>/dev/null
  [[ -n "$TAIL_PID" ]] && kill "$TAIL_PID" 2>/dev/null
  # interrupted before the leak check: never leave unchecked output on disk
  if (( ${#SECRET_VALUES[@]} && ! LEAK_CHECKED )) && [[ -n "$OUT" ]]; then
    rm -rf "$OUT/run.log" "$OUT/.staging" "$OUT/log-tail.txt" "$OUT/failing-tests.txt"
  fi
  [[ -n "$OUT" ]] && rm -f "$OUT/remote-run.sh"
  release_lock
  exit "$rc"
}
on_signal() { log "interrupted ($1)"; exit "$2"; }
install_traps() {
  trap cleanup EXIT
  trap 'on_signal INT 130' INT
  trap 'on_signal TERM 143' TERM
}

# ---------- lock (on the mini) ----------

# One attempt. Prints ACQUIRED, STALE, or HELD plus the holder's details.
try_lock_remote() {
  local udid="$1" token="$2" task="$3" cmd="${4//[^A-Za-z0-9 ._:=\/@,-]/?}"
  mini_bash <<EOF
base="\$HOME/$REMOTE_BASE"; d="\$base/locks/$udid.lock"
mkdir -p "\$base/locks"
if mkdir "\$d" 2>/dev/null; then
  { echo "task:    $task"; echo "host:    \$(hostname -s)"; echo "caller:  $(id -un)@$(hostname -s) pid $$"
    echo "worktree: $WT_NAME"; echo "started: \$(date '+%Y-%m-%d %H:%M:%S %z')"; echo "command: $cmd"; } >"\$d/owner"
  echo "$token" >"\$d/token"
  echo ACQUIRED; exit 0
fi
now=\$(date +%s); mt=\$(stat -f %m "\$d" 2>/dev/null || echo "\$now"); age=\$((now - mt))
if [ "\$age" -gt $LOCK_STALE_SECS ]; then
  echo "STALE age=\${age}s"; sed 's/^/    /' "\$d/owner" 2>/dev/null
  mv "\$d" "\$d.dead.\$\$" 2>/dev/null && rm -rf "\$d.dead.\$\$"
  exit 0
fi
echo "HELD age=\${age}s (dead after ${LOCK_STALE_SECS}s)"
if [ -r "\$d/owner" ]; then sed 's/^/    /' "\$d/owner"; else echo "    (no owner file yet)"; fi
EOF
}

acquire_lock() {
  local udid="$1" token="$2" task out first rc
  task="${HERDR_BROWSER_TASK:-${TASK_ID:-unknown}}"
  task="${task//[^A-Za-z0-9._-]/?}"
  LOCK_UDID="$udid"
  LOCK_TOKEN="$token"
  # Set before the first attempt: if a signal lands mid-attempt, release_lock
  # still runs and (token-checked on the mini) removes only a lock we created.
  LOCK_HELD=1
  while :; do
    out="$(try_lock_remote "$udid" "$token" "$task" "$INVOCATION")"; rc=$?
    if (( rc == 255 )); then LOCK_HELD=0; unavailable "SSH to $REMOTE_HOST failed while taking the lock"; fi
    first="${out%%$'\n'*}"
    case "$first" in
      ACQUIRED) log "lock taken on the mini: ~/$REMOTE_BASE/locks/$udid.lock"; return 0 ;;
      STALE*) log "lock for $udid is stale; previous holder was:"; printf '%s\n' "${out#*$'\n'}" >&2; continue ;;
      HELD*)
        log "simulator $udid is held by another agent; retrying every ${LOCK_POLL_SECS}s. Holder: ${first#HELD }"
        printf '%s\n' "${out#*$'\n'}" >&2
        ;;
      *) LOCK_HELD=0; die "unexpected lock reply: $out" 1 ;;
    esac
    sleep "$LOCK_POLL_SECS" & CHILD_PID=$!
    wait "$CHILD_PID" 2>/dev/null
    CHILD_PID=""
  done
}

# Releases only a lock carrying our token; also stops this run's xcodebuild and
# shuts the simulator down if this script booted it (marker inside the lock dir).
release_lock() {
  (( LOCK_HELD )) || return 0
  LOCK_HELD=0
  local udid="$LOCK_UDID" token="$LOCK_TOKEN" dd="$REMOTE_DD"
  ssh "${SSH_OPTS[@]}" -o ConnectTimeout=15 "$REMOTE_HOST" 'export PATH=/opt/homebrew/bin:$PATH; bash -s' >&2 2>&1 <<EOF
d="\$HOME/$REMOTE_BASE/locks/$udid.lock"
if [ -f "\$d/token" ] && [ "\$(cat "\$d/token")" = "$token" ]; then
  if [ -n "$dd" ]; then pkill -f "[x]codebuild.*-derivedDataPath \$HOME/$REMOTE_BASE/$dd" 2>/dev/null; sleep 2; fi
  if [ -f "\$d/booted" ]; then xcrun simctl shutdown "$udid" 2>/dev/null; echo "simulator $udid shut down"; fi
  rm -rf "\$d"; echo "lock released: \$d"
else
  echo "lock not ours or already gone; left alone"
fi
EOF
}

# ---------- logged, time-limited ssh run ----------

leak_check() { # leak_check <dir...>: any secret value in these files or the run log?
  local d
  ((${#SECRET_VALUES[@]})) || return 1
  for d in "$@"; do
    # patterns come from a process substitution: never in a command line
    if grep -rqF -f <(printf '%s\n' "${SECRET_VALUES[@]}") "$d" 2>/dev/null; then return 0; fi
  done
  return 1
}

# run_logged <logfile> <limit-secs> <stdin-producer-function> <cmd...>; returns the status, or 124.
run_logged() {
  local logfile="$1" limit="$2" input="$3" rc
  shift 3
  : >"$logfile"
  # With secrets nothing is streamed: output is shown only after the leak check.
  if (( ${#SECRET_VALUES[@]} == 0 )); then tail -f -n 0 "$logfile" & TAIL_PID=$!; fi
  "$input" | perl -e 'alarm shift; exec @ARGV or exit 127' "$limit" "$@" >>"$logfile" 2>&1 &
  CHILD_PID=$!
  wait "$CHILD_PID"; rc=$?
  CHILD_PID=""
  sleep 1; [[ -n "$TAIL_PID" ]] && kill "$TAIL_PID" 2>/dev/null; TAIL_PID=""
  if (( rc == 142 )); then return 124; fi # SIGALRM
  return "$rc"
}

# ---------- hidden modes for demonstrating the lock ----------

mode_lock_hold() { # _lock-hold <secs> [--fail]: take the sim lock, hold it, release it
  local secs="$1" fail="${2:-}" udid="$SIM_IPHONE"
  [[ -n "${REMOTE_TEST_UDID:-}" ]] && udid="$REMOTE_TEST_UDID"
  install_traps
  ssh_mini true || unavailable "SSH to $REMOTE_HOST failed"
  acquire_lock "$udid" "$$.$RANDOM.$(date +%s)"
  echo "ACQUIRED $(date +%s)"
  sleep "$secs" & CHILD_PID=$!
  wait "$CHILD_PID" 2>/dev/null; CHILD_PID=""
  [[ "$fail" == "--fail" ]] && { log "forced failure"; exit 1; }
  echo "RELEASING $(date +%s)"
}

# ---------- main ----------

MODE="test"; SIM="iphone"; OUT=""; TIMEOUT=1800
SECRET_NAMES=(); SECRET_TARGETS=(); DEBUG_PRINT_SECRETS=0
INVOCATION="remote-test.sh $*"
EXTRA=()

case "${1:-}" in
  _lock-hold) shift; mode_lock_hold "$@"; exit $? ;;
  test|build) MODE="$1"; shift ;;
esac

while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --sim) SIM="${2:?--sim needs a value}"; shift 2 ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --secret)
      spec="${2:?--secret needs NAME=TEST_RUNNER_NAME}"; shift 2
      [[ "$spec" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(TEST_RUNNER_[A-Za-z0-9_]+)$ ]] \
        || die "--secret takes LOCAL_ENV_NAME=TEST_RUNNER_NAME (a name, never a value)" 2
      SECRET_NAMES+=("${BASH_REMATCH[1]}"); SECRET_TARGETS+=("${BASH_REMATCH[2]}") ;;
    --debug-print-secrets) DEBUG_PRINT_SECRETS=1; shift ;; # proves the leak check; prints values into the log ON PURPOSE
    --) shift; EXTRA+=("$@"); break ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

case "$SIM" in
  iphone) UDID="$SIM_IPHONE" ;;
  ipad) UDID="$SIM_IPAD" ;;
  "$SIM_IPHONE"|"$SIM_IPAD") UDID="$SIM" ;;
  *) die "--sim must be iphone, ipad or one of the two allowed UDIDs (got: $SIM)" 2 ;;
esac
for a in "${EXTRA[@]+"${EXTRA[@]}"}"; do
  [[ "$a" =~ ^TEST_RUNNER_[A-Za-z0-9_]*= ]] && die "refusing '${a%%=*}=...': never put a secret value on the command line; use --secret NAME=TEST_RUNNER_NAME with NAME set in this shell's environment (herdr-secret run NAME -- ...)" 2
done
SECRET_VALUES=()
for ((i = 0; i < ${#SECRET_NAMES[@]}; i++)); do
  n="${SECRET_NAMES[$i]}"; v="${!n-}"
  [[ -n "$v" ]] || die "--secret: \$$n is not set (or empty) in this shell's environment" 2
  [[ "$v" != *$'\n'* ]] || die "--secret: \$$n contains a newline; not supported" 2
  SECRET_VALUES+=("$v")
done
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be a number" 2
[[ -f "$REPO_ROOT/scripts/generate_project.rb" ]] || die "scripts/generate_project.rb not found in $REPO_ROOT" 2
command -v rsync >/dev/null || die "rsync not found" 2

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
[[ -n "$OUT" ]] || OUT="$OUT_ROOT/$WT_NAME-$RUN_ID"
mkdir -p "$OUT" || die "cannot create $OUT" 2
OUT="$(cd "$OUT" && pwd)"
log "output dir: $OUT"

install_traps
T0=$SECONDS
: >"$OUT/timings.txt"
stage() { printf '%-22s %4ss\n' "$1" "$2" | tee -a "$OUT/timings.txt" >&2; }

# 1. reachable?
ssh_mini true >"$OUT/ssh-check.log" 2>&1 || {
  tail -n 3 "$OUT/ssh-check.log" >&2
  echo 69 >"$OUT/exit-status"
  unavailable "SSH to $REMOTE_HOST failed"
}

REMOTE_SRC="$REMOTE_BASE/$WT_NAME"
REMOTE_DD="$WT_NAME.dd"
RESULT_REL="$REMOTE_BASE/$WT_NAME.results/$RUN_ID"

# 2. lock (test mode only: build uses no simulator)
if [[ "$MODE" == "test" ]]; then
  t=$SECONDS
  acquire_lock "$UDID" "$$.$RANDOM.$(date +%s)"
  stage "lock wait" $((SECONDS - t))
fi

# 3. rsync
t=$SECONDS
ssh_mini "mkdir -p ~/$REMOTE_SRC ~/$REMOTE_BASE/$REMOTE_DD ~/$RESULT_REL" || { echo 69 >"$OUT/exit-status"; unavailable "cannot create ~/$REMOTE_BASE directories"; }
log "syncing $REPO_ROOT to $REMOTE_HOST:~/$REMOTE_SRC/"
rsync -az --delete \
  --exclude='.git' --exclude='DerivedData/' --exclude='build/' --exclude='.build/' \
  --exclude='*.xcresult' --exclude='xcuserdata/' --exclude='.DS_Store' --exclude='.claude/' \
  --exclude='scripts/adblock/converter/target/' \
  -e "ssh ${SSH_OPTS[*]}" "$REPO_ROOT/" "$REMOTE_HOST:$REMOTE_SRC/" >"$OUT/rsync.log" 2>&1 || {
  tail -n 10 "$OUT/rsync.log" >&2
  echo 1 >"$OUT/exit-status"
  die "rsync failed; see $OUT/rsync.log" 1
}
stage rsync $((SECONDS - t))

# 4-5. generate, boot, xcodebuild (one ssh session, streamed to run.log)
if [[ "$MODE" == "test" ]]; then
  DEST="id=$UDID"
  XCB=(test -parallel-testing-enabled NO -resultBundlePath "../$WT_NAME.results/$RUN_ID/test.xcresult")
else
  DEST="generic/platform=iOS Simulator"
  XCB=(build)
fi

REMOTE_SCRIPT="$OUT/remote-run.sh"
{
  echo 'export PATH=/opt/homebrew/bin:$PATH'
  echo "UDID=$UDID; MODE=$MODE; LOCKDIR=\"\$HOME/$REMOTE_BASE/locks/$UDID.lock\""
  echo "cd \"\$HOME/$REMOTE_SRC\" || { echo REMOTE_XCODEBUILD_RC=1; exit 1; }"
  cat <<'EOS'
echo "== generate project"
ts=$(date +%s)
ruby scripts/generate_project.rb || { echo "generate_project.rb failed"; echo REMOTE_XCODEBUILD_RC=1; exit 1; }
echo "STAGE generate $(( $(date +%s) - ts ))"
if [ "$MODE" = test ]; then
  state=$(xcrun simctl list devices | grep "$UDID" | sed -E 's/.*\(([A-Za-z]+)\) *$/\1/')
  if [ "$state" != "Booted" ]; then
    echo "== booting simulator $UDID (was $state)"
    xcrun simctl boot "$UDID" && touch "$LOCKDIR/booted"
    xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
  fi
  # keep the lock fresh so a long run is never taken for a dead one
  ( while sleep 300; do touch "$LOCKDIR"; done ) & HB=$!
fi
echo "== xcodebuild"
ts=$(date +%s)
EOS
  if (( DEBUG_PRINT_SECRETS )); then echo '[ -n "$SD" ] && echo "LEAK-DEMO: $(cat "$SD/env")"'; fi
  printf '( [ -n "$SD" ] && . "$SD/env"; xcodebuild'
  printf ' %q' "${XCB[@]}"
  printf ' -project WukongMind.xcodeproj -scheme %q -destination %q -derivedDataPath "$HOME/%s/%s" CODE_SIGNING_ALLOWED=NO' \
    "$SCHEME" "$DEST" "$REMOTE_BASE" "$REMOTE_DD"
  # the caller's extra args pass through untouched (re-quoted for the remote shell)
  for a in "${EXTRA[@]+"${EXTRA[@]}"}"; do printf ' %q' "$a"; done
  echo ' </dev/null )'
  cat <<'EOS'
rc=$?
[ -n "$SD" ] && rm -rf "$SD"; SD=""
echo "STAGE xcodebuild $(( $(date +%s) - ts ))"
echo "REMOTE_XCODEBUILD_RC=$rc"
exit "$rc"
EOS
} >"$REMOTE_SCRIPT"

log "running xcodebuild $MODE on the mini ($DEST); log: $OUT/run.log"
t=$SECONDS
emit_stdin() {
  # Prologue: private temp dir for secrets, removed by a trap on every exit path.
  cat <<'EOS'
umask 077
HB=""; SD=""
trap 'kill $HB 2>/dev/null; [ -n "$SD" ] && rm -rf "$SD"' EXIT
trap 'exit 143' HUP INT TERM
EOS
  if (( ${#SECRET_NAMES[@]} )); then
    local term="WUKO72_END_$RANDOM$RANDOM$RANDOM" i
    printf 'SD=$(mktemp -d "$HOME/%s/.secrets.XXXXXX") || exit 1\n' "$REMOTE_BASE"
    printf 'cat >"$SD/env" <<'"'"'%s'"'"'\n' "$term"
    for ((i = 0; i < ${#SECRET_NAMES[@]}; i++)); do
      printf 'export %s=%q\n' "${SECRET_TARGETS[$i]}" "${SECRET_VALUES[$i]}"
    done
    printf '%s\nchmod 600 "$SD/env"\n' "$term"
  fi
  cat "$REMOTE_SCRIPT"
}
run_logged "$OUT/run.log" "$TIMEOUT" emit_stdin \
  ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" 'bash -s'
rc=$?
stage "generate+build+run" $((SECONDS - t))
LEAK=0
if leak_check "$OUT/run.log"; then
  LEAK=1; rm -f "$OUT/run.log"
  log "ERROR: a secret value was found in the log; it was deleted."
elif (( ${#SECRET_VALUES[@]} )); then
  tail -n 40 "$OUT/run.log" >&2 # withheld until now
fi
# The mini's SSH daemon reports exit status 0 whatever the remote command
# returned, so the real status travels in the log (REMOTE_XCODEBUILD_RC=<n>).
if (( rc == 0 && ! LEAK )); then
  marker="$(sed -n 's/^REMOTE_XCODEBUILD_RC=\([0-9]*\)$/\1/p' "$OUT/run.log" | tail -n1)"
  if [[ -n "$marker" ]]; then rc="$marker"
  else rc=1; log "ERROR: the remote run ended without reporting a status (connection lost?)"; fi
fi
[[ -f "$OUT/run.log" ]] && grep -E '^STAGE ' "$OUT/run.log" | sed 's/^STAGE /  remote: /' | tee -a "$OUT/timings.txt" >&2
rm -f "$REMOTE_SCRIPT"

if (( rc == 124 )); then
  log "ERROR: xcodebuild timed out after ${TIMEOUT}s"
elif (( rc == 255 )); then
  log "ERROR: the SSH connection to the mini dropped during the run"
fi

# 6. release the lock (stops a stray xcodebuild, shuts a simulator we booted), then fetch
release_lock

if (( rc != 255 )); then
  if [[ "$MODE" == "test" ]] && (( ! LEAK )); then
    STAGING="$OUT/.staging"; mkdir -p "$STAGING"
    rsync -az -e "ssh ${SSH_OPTS[*]}" "$REMOTE_HOST:$RESULT_REL/" "$STAGING/" >"$OUT/fetch.log" 2>&1 \
      || log "could not copy results back; see $OUT/fetch.log"
    if leak_check "$STAGING"; then
      LEAK=1
      rm -rf "$STAGING" "$OUT/run.log"
      log "ERROR: a secret value was found in the results. Nothing was copied back and run.log was deleted."
    else
      cp -R "$STAGING/." "$OUT/" && rm -rf "$STAGING"
    fi
  fi
  # keep the mini's result folders for a day only
  ssh_mini "find ~/$REMOTE_BASE/$WT_NAME.results -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec rm -rf {} + 2>/dev/null; true" >/dev/null 2>&1
fi
LEAK_CHECKED=1
if (( LEAK )); then
  rm -f "$OUT/log-tail.txt" "$OUT/failing-tests.txt"
  echo "SECRET LEAK DETECTED: results withheld" >"$OUT/LEAK"
  (( rc == 0 )) && rc=70
  echo "$rc" >"$OUT/exit-status"
  echo "---- remote-test result: exit $rc (secret leak: results withheld) ----"
  exit "$rc"
fi

echo "$rc" >"$OUT/exit-status"
grep -E "Test [Cc]ase '.*' failed|^✘ Test|^Test [Cc]ase .* failed" "$OUT/run.log" | sed 's/ (.* seconds)\.*$//' | sort -u >"$OUT/failing-tests.txt"
tail -n 60 "$OUT/run.log" >"$OUT/log-tail.txt"
stage total $((SECONDS - T0))

echo "---- remote-test result: exit $rc ----"
echo "output dir: $OUT"
for f in exit-status failing-tests.txt log-tail.txt run.log timings.txt test.xcresult; do
  [[ -e "$OUT/$f" ]] && echo "  $OUT/$f"
done
if [[ -s "$OUT/failing-tests.txt" ]]; then echo "failing tests:"; sed 's/^/  /' "$OUT/failing-tests.txt"; fi
(( rc == 255 )) && unavailable "the SSH connection dropped during the run"
exit "$rc"
