#!/usr/bin/env bash
# Real-device check on the shared test iPhone, under a cross-agent lock.
# Run `scripts/device-check.sh --help` for the full documentation.
# shellcheck disable=SC2329 # cleanup/on_signal/release_lock run via trap
set -uo pipefail

DEFAULT_UDID="00008110-001614E8368A601E" # KC's iPhone 13, shared by all agents
BUNDLE_ID_FALLBACK="io.github.kccarlos.wukongmind"
SCHEME="WukongMind"

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOCK_ROOT="${LOCK_ROOT:-/Volumes/Ext/dev/locks}"
LOCK_STALE_SECS="${LOCK_STALE_SECS:-2700}" # 45 minutes
LOCK_POLL_SECS="${LOCK_POLL_SECS:-20}"

usage() {
  cat <<'EOF'
device-check.sh: run a real-device check on the shared test iPhone under a lock.

Usage:
  scripts/device-check.sh [test] [options] [xcodebuild args...]
  scripts/device-check.sh launch [options] [-- app launch arguments...]
  scripts/device-check.sh --self-test

Agents must use ONLY this script to touch the physical device: never run
devicectl, xcodebuild -destination id=<udid> or Xcode against it directly.

Modes:
  test     (default) build for testing, then `xcodebuild test-without-building`
           on the device. Extra args (e.g. -only-testing:WukongMindUITests/
           PhysicalDeviceSmokeTests/testAssistantPageStatesOffline) go straight
           to xcodebuild. Runs with -parallel-testing-enabled NO.
  launch   install the built app, launch it with the arguments after `--`,
           capture the console for --seconds, then terminate the app.

Options:
  --udid <udid>          device (default: KC's iPhone 13, 00008110-001614E8368A601E)
  --out <dir>            output dir for logs and the .xcresult
                         (default: $TMPDIR/wukongmind-device-check/<timestamp>)
  --derived-data <dir>   derived data
                         (default: /Volumes/Ext/dev/build/wukongmind-dd/device-check)
  --timeout <seconds>    limit for the test run (default 1800)
  --seconds <seconds>    launch mode: how long to capture the console (default 20)
  --skip-build           reuse the build already in the derived-data dir
  --reboot               OFF by default: reboot the phone before the run (clears
                         System Data after heavy recording); it is the owner's phone
  --self-test            exercise the lock logic without the phone, then exit
  -h, --help             this text

What it does:
  1. Builds (build-for-testing, signed, -allowProvisioningUpdates) BEFORE the
     lock, against a generic iOS destination, so the phone is not touched.
     Team: $DEVELOPMENT_TEAM, else Config/DevelopmentTeam.txt, else the default.
  2. Takes the lock `mkdir $LOCK_ROOT/<udid>.lock` (LOCK_ROOT defaults to
     /Volumes/Ext/dev/locks). While it is held by another agent it retries every
     20 s and prints who holds it and since when. A lock whose mtime is older
     than 45 minutes is dead: it is removed and taken over.
  3. Inside the lock only: checks the phone is connected, paired and unlocked,
     then runs the test or launch. Fails with a clear message otherwise.
  4. Releases the lock on exit, failure, Ctrl-C or TERM (only a lock this
     script took).
  Never uninstalls the app and never erases or resets anything on the phone.

Output: <out>/build.log, <out>/test.log (or launch.log), <out>/test.xcresult
(screenshots and attachments are in it); the paths are printed at the end.

Environment: TEST_RUNNER_* variables (e.g. TEST_RUNNER_ANTHROPIC_API_KEY) reach
the tests as usual; their values are never printed. LOCK_ROOT, LOCK_STALE_SECS,
LOCK_POLL_SECS override the lock settings (used by --self-test).

Exit codes: 0 ok; 1 failed; 2 usage; 3 device unavailable; 4 timeout.
EOF
}

log() { printf '[device-check %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit "${2:-1}"; }

# ---------- lock ----------

LOCK_DIR=""
LOCK_TOKEN=""
CHILD_PID=""
TAIL_PID=""
CLEANUP_HOOK=""

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

describe_holder() {
  local dir="$1" age
  local owner="$dir/owner"
  if [[ -r "$owner" ]]; then
    sed 's/^/    /' "$owner" >&2
  else
    echo "    (no owner file yet)" >&2
  fi
  age=$(( $(date +%s) - $(mtime "$dir" || date +%s) ))
  echo "    lock age: ${age}s (dead after ${LOCK_STALE_SECS}s)" >&2
}

write_owner() {
  local branch task
  branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  task="${HERDR_BROWSER_TASK:-${TASK_ID:-unknown}}"
  {
    echo "task:    $task"
    echo "branch:  $branch"
    echo "project: $(basename "$REPO_ROOT")"
    echo "pid:     $$"
    echo "user:    $(id -un)@$(hostname -s)"
    echo "started: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "command: ${INVOCATION}"
  } >"$LOCK_DIR/owner"
  echo "$LOCK_TOKEN" >"$LOCK_DIR/token"
}

acquire_lock() {
  local udid="$1" dir="$LOCK_ROOT/$1.lock" last_report=0 now age dead
  mkdir -p "$LOCK_ROOT" || die "cannot create $LOCK_ROOT"
  while :; do
    if mkdir "$dir" 2>/dev/null; then
      LOCK_DIR="$dir"
      LOCK_TOKEN="$$.$RANDOM.$(date +%s)"
      write_owner
      log "lock taken: $dir"
      return 0
    fi
    now=$(date +%s)
    age=$(( now - $(mtime "$dir" || echo "$now") ))
    if (( age > LOCK_STALE_SECS )); then
      log "lock $dir is ${age}s old (> ${LOCK_STALE_SECS}s): treating as dead; previous holder was:"
      describe_holder "$dir"
      dead="$dir.dead.$$.$RANDOM"
      # rename is atomic: only one waiter wins the takeover
      if mv "$dir" "$dead" 2>/dev/null; then rm -rf "$dead"; fi
      continue
    fi
    if (( now - last_report >= LOCK_POLL_SECS )); then
      log "device $udid is held by another agent; retrying every ${LOCK_POLL_SECS}s. Holder:"
      describe_holder "$dir"
      last_report=$now
    fi
    sleep "$LOCK_POLL_SECS" & CHILD_PID=$!
    wait "$CHILD_PID" 2>/dev/null
    CHILD_PID=""
  done
}

release_lock() {
  if [[ -n "$LOCK_DIR" && -f "$LOCK_DIR/token" && "$(cat "$LOCK_DIR/token" 2>/dev/null)" == "$LOCK_TOKEN" ]]; then
    rm -rf "$LOCK_DIR"
    log "lock released: $LOCK_DIR"
  fi
  LOCK_DIR=""
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  [[ -n "$CHILD_PID" ]] && kill "$CHILD_PID" 2>/dev/null
  [[ -n "$TAIL_PID" ]] && kill "$TAIL_PID" 2>/dev/null
  if [[ -n "$CLEANUP_HOOK" ]]; then "$CLEANUP_HOOK" || true; fi
  release_lock
  exit "$rc"
}
on_signal() { log "interrupted ($1)"; exit "$2"; }
install_traps() {
  trap cleanup EXIT
  trap 'on_signal INT 130' INT
  trap 'on_signal TERM 143' TERM
}

# Run a command with a time limit, streaming and logging its output.
# Returns the command's status, or 124 on timeout.
run_logged() {
  local logfile="$1" limit="$2" rc
  shift 2
  : >"$logfile"
  tail -f -n 0 "$logfile" & TAIL_PID=$!
  perl -e 'alarm shift; exec @ARGV or exit 127' "$limit" "$@" >>"$logfile" 2>&1 &
  CHILD_PID=$!
  wait "$CHILD_PID"; rc=$?
  CHILD_PID=""
  sleep 1; kill "$TAIL_PID" 2>/dev/null; TAIL_PID=""
  if (( rc == 142 )); then return 124; fi # SIGALRM
  return "$rc"
}

# ---------- device ----------

json_get() { # json_get <file> <python expr over d>
  python3 -I - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
try:
    print(eval(sys.argv[2]))
except Exception:
    print("")
PY
}

preflight_device() {
  local udid="$1" out="$2"
  local f="$out/lockstate.json" err="$out/preflight.log"
  log "checking device $udid"
  if ! xcrun devicectl device info lockState --device "$udid" --json-output "$f" >"$err" 2>&1; then
    {
      echo "Device $udid is not usable: not connected, not paired, or unreachable."
      echo "  - Plug the phone into this Mac and unlock it."
      echo "  - 'The device must be paired before it can be connected': run"
      echo "      xcrun devicectl manage pair --device $udid"
      echo "    and tap Trust on the phone (wiki: projects/apple/lessons.md, pairing note)."
      echo "  Details: $err"
      tail -n 5 "$err" | sed 's/^/    /'
    } >&2
    return 3
  fi
  if [[ "$(json_get "$f" 'str(d["result"].get("passcodeRequired")).lower()')" == "true" ]]; then
    log "ERROR: device $udid is locked (passcode required). Unlock the phone and run again."
    return 3
  fi
  return 0
}

reboot_device() { # adapted from Forumind's gate.sh; only with --reboot
  local udid="$1" out="$2" _n
  log "rebooting the phone (--reboot)"
  xcrun devicectl device reboot --device "$udid" >"$out/reboot.log" 2>&1 || log "reboot command failed; see $out/reboot.log"
  sleep 60
  for _n in $(seq 1 60); do
    if xcrun devicectl device info lockState --device "$udid" >/dev/null 2>&1 \
      && xcrun devicectl list devices 2>/dev/null | grep "$udid" | grep -q " connected"; then break; fi
    sleep 10
  done
  sleep 20
  preflight_device "$udid" "$out"
}

# ---------- build ----------

resolve_team() {
  local team="${DEVELOPMENT_TEAM:-}" f="$REPO_ROOT/Config/DevelopmentTeam.txt"
  if [[ -z "$team" && -f "$f" ]]; then
    team="$(grep -v '^[[:space:]]*#' "$f" | grep -v '^[[:space:]]*$' | head -n1 | tr -d '[:space:]')"
  fi
  # same default as scripts/generate_project.rb
  echo "${team:-GV776BZVA8}"
}

build_for_testing() {
  local out="$1" dd="$2" team
  team="$(resolve_team)"
  log "building for testing (team $team, derived data $dd); log: $out/build.log"
  run_logged "$out/build.log" 3000 xcodebuild build-for-testing \
    -project "$REPO_ROOT/WukongMind.xcodeproj" -scheme "$SCHEME" \
    -destination 'generic/platform=iOS' -derivedDataPath "$dd" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$team"
  local rc=$?
  if (( rc != 0 )); then
    tail -n 25 "$out/build.log" >&2
    die "build failed (exit $rc); see $out/build.log" 1
  fi
}

find_app() {
  find "$1/Build/Products" -maxdepth 2 -name 'WukongMind.app' -path '*iphoneos*' 2>/dev/null | head -n1
}

# ---------- modes ----------

LAUNCHED=0
APP_BUNDLE_ID=""
DEVICE_FOR_CLEANUP=""

terminate_app() {
  (( LAUNCHED )) || return 0
  local f pid
  f="$(mktemp -t devcheck-procs)"
  if xcrun devicectl device info processes --device "$DEVICE_FOR_CLEANUP" --json-output "$f" >/dev/null 2>&1; then
    pid="$(python3 -I - "$f" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for p in d.get("result", {}).get("runningProcesses", []):
        if "/WukongMind.app/" in p.get("executable", ""):
            print(p["processIdentifier"]); break
except Exception:
    pass
PY
)"
    if [[ -n "$pid" ]]; then
      log "terminating app (pid $pid)"
      xcrun devicectl device process terminate --device "$DEVICE_FOR_CLEANUP" --pid "$pid" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$f"
  LAUNCHED=0
}

mode_test() {
  local udid="$1" out="$2" dd="$3" limit="$4"; shift 4
  local result="$out/test.xcresult" rc
  rm -rf "$result"
  log "running tests on $udid; log: $out/test.log"
  run_logged "$out/test.log" "$limit" xcodebuild test-without-building \
    -project "$REPO_ROOT/WukongMind.xcodeproj" -scheme "$SCHEME" \
    -destination "id=$udid" -derivedDataPath "$dd" \
    -parallel-testing-enabled NO -resultBundlePath "$result" \
    -allowProvisioningUpdates "$@"
  rc=$?
  if (( rc == 124 )); then log "ERROR: test run timed out after ${limit}s"; return 4; fi
  tail -n 15 "$out/test.log" >&2
  return "$rc"
}

mode_launch() {
  local udid="$1" out="$2" dd="$3" secs="$4"; shift 4
  local app rc=0
  app="$(find_app "$dd")"
  [[ -n "$app" ]] || { log "ERROR: no built WukongMind.app in $dd"; return 1; }
  APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist" 2>/dev/null)" || APP_BUNDLE_ID=""
  APP_BUNDLE_ID="${APP_BUNDLE_ID:-$BUNDLE_ID_FALLBACK}"
  DEVICE_FOR_CLEANUP="$udid"
  CLEANUP_HOOK=terminate_app
  log "installing $app"
  xcrun devicectl device install app --device "$udid" "$app" >"$out/install.log" 2>&1 \
    || { tail -n 10 "$out/install.log" >&2; return 1; }
  log "launching $APP_BUNDLE_ID for ${secs}s; console log: $out/launch.log"
  : >"$out/launch.log"
  LAUNCHED=1
  xcrun devicectl device process launch --console --terminate-existing \
    --device "$udid" "$APP_BUNDLE_ID" "$@" >>"$out/launch.log" 2>&1 &
  CHILD_PID=$!
  sleep "$secs" & local sp=$!
  wait "$sp" 2>/dev/null
  if kill -0 "$CHILD_PID" 2>/dev/null; then
    kill "$CHILD_PID" 2>/dev/null; wait "$CHILD_PID" 2>/dev/null
  else
    wait "$CHILD_PID" || rc=$? # devicectl exited early: its failure is ours
  fi
  CHILD_PID=""
  terminate_app
  tail -n 15 "$out/launch.log" >&2
  return "$rc"
}

# ---------- self-test ----------

# Hidden mode used by --self-test: take the lock, hold it, release it.
mode_lock_hold() {
  local secs="$1" fail="${2:-}"
  install_traps
  acquire_lock "selftest"
  echo "ACQUIRED $(date +%s)"
  sleep "$secs" & CHILD_PID=$!
  wait "$CHILD_PID" 2>/dev/null; CHILD_PID=""
  [[ "$fail" == "--fail" ]] && { log "forced failure"; exit 1; }
  echo "RELEASING $(date +%s)"
}

self_test() {
  local tmp root fails=0 pa pb ts_rel ts_acq
  tmp="$(mktemp -d)"
  root="$tmp/locks"
  export LOCK_ROOT="$root" LOCK_POLL_SECS=1
  local me="$SCRIPT_PATH" lock="$root/selftest.lock"
  check() { if [[ "$2" == ok ]]; then echo "PASS: $1"; else echo "FAIL: $1"; fails=$((fails+1)); fi; }
  wait_for() { local _n; for _n in $(seq 1 100); do eval "$1" && return 0; sleep 0.1; done; return 1; }

  echo "== (a) a second holder waits while the first holds the lock"
  "$me" _lock-hold 4 >"$tmp/a.out" 2>"$tmp/a.err" & pa=$!
  wait_for "[[ -d '$lock' ]]"
  "$me" _lock-hold 0 >"$tmp/b.out" 2>"$tmp/b.err" & pb=$!
  sleep 1.5
  if grep -q ACQUIRED "$tmp/b.out"; then check "B did not acquire while A held it" no; else check "B did not acquire while A held it" ok; fi
  if grep -q 'held by another agent' "$tmp/b.err"; then check "B reported the holder" ok; else check "B reported the holder" no; fi
  if grep -q "pid:     $pa" "$tmp/b.err"; then check "B printed A's owner info (pid $pa)" ok; else check "B printed A's owner info (pid $pa)" no; fi
  wait "$pa" "$pb"
  ts_rel="$(sed -n 's/^RELEASING //p' "$tmp/a.out")"; ts_acq="$(sed -n 's/^ACQUIRED //p' "$tmp/b.out")"
  if [[ -n "$ts_rel" && -n "$ts_acq" && "$ts_acq" -ge "$ts_rel" ]]; then check "B acquired only after A released" ok; else check "B acquired only after A released" no; fi
  if [[ ! -e "$lock" ]]; then check "lock gone after both finished" ok; else check "lock gone after both finished" no; fi

  echo "== (b) a lock older than the stale limit is taken over"
  mkdir -p "$lock"; echo "task: dead-agent" >"$lock/owner"
  touch -t 202001010000 "$lock"
  "$me" _lock-hold 0 >"$tmp/c.out" 2>"$tmp/c.err"
  if grep -q 'treating as dead' "$tmp/c.err" && grep -q ACQUIRED "$tmp/c.out"; then check "stale lock taken over" ok; else check "stale lock taken over" no; fi
  if [[ ! -e "$lock" ]]; then check "lock gone after takeover run" ok; else check "lock gone after takeover run" no; fi

  echo "== (c) a fresh lock of another holder is never removed by us"
  mkdir -p "$lock"; echo "task: other" >"$lock/owner"; echo other-token >"$lock/token"
  ( "$me" _lock-hold 0 >"$tmp/d.out" 2>&1 ) & local pd=$!
  sleep 2; kill -TERM "$pd" 2>/dev/null; wait "$pd" 2>/dev/null
  if [[ -d "$lock" && "$(cat "$lock/token")" == other-token ]]; then check "foreign lock untouched" ok; else check "foreign lock untouched" no; fi
  rm -rf "$lock"

  echo "== (d) the lock is removed after a forced failure"
  "$me" _lock-hold 0 --fail >/dev/null 2>&1; local rc=$?
  if [[ $rc -ne 0 && ! -e "$lock" ]]; then check "failure exit $rc, lock removed" ok; else check "failure exit $rc, lock removed" no; fi

  echo "== (e) the lock is removed after TERM and after INT"
  local sig
  for sig in TERM INT; do
    perl -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; exec @ARGV' "$me" _lock-hold 60 >"$tmp/e.out" 2>&1 & local pe=$!
    wait_for "[[ -d '$lock' ]]"
    kill -"$sig" "$pe"; wait "$pe" 2>/dev/null; local erc=$?
  if [[ ! -e "$lock" ]]; then check "$sig: lock removed (exit $erc)" ok; else check "$sig: lock removed (exit $erc)" no; fi
  done

  rm -rf "$tmp"
  if (( fails )); then echo "SELF-TEST FAILED ($fails)"; return 1; fi
  echo "SELF-TEST PASSED"
}

# ---------- main ----------

MODE="test"; UDID="$DEFAULT_UDID"; OUT=""; DD="/Volumes/Ext/dev/build/wukongmind-dd/device-check"
TIMEOUT=1800; SECONDS_CAPTURE=20; SKIP_BUILD=0; REBOOT=0
INVOCATION="device-check.sh $*"
EXTRA=()

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  _lock-hold) shift; mode_lock_hold "$@"; exit $? ;;
  test|launch) MODE="$1"; shift ;;
esac

while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --self-test) self_test; exit $? ;;
    --udid) UDID="${2:?--udid needs a value}"; shift 2 ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    --derived-data) DD="${2:?--derived-data needs a value}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --seconds) SECONDS_CAPTURE="${2:?--seconds needs a value}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --reboot) REBOOT=1; shift ;;
    --) shift; EXTRA+=("$@"); break ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

[[ "$UDID" =~ ^[0-9A-Fa-f-]+$ ]] || die "bad --udid: $UDID" 2
[[ "$TIMEOUT" =~ ^[0-9]+$ && "$SECONDS_CAPTURE" =~ ^[0-9]+$ ]] || die "--timeout/--seconds must be numbers" 2
command -v xcodebuild >/dev/null || die "xcodebuild not found" 2
[[ -f "$REPO_ROOT/WukongMind.xcodeproj/project.pbxproj" ]] || die "WukongMind.xcodeproj not found in $REPO_ROOT" 2
[[ -d /Volumes/Ext/dev || "$LOCK_ROOT" != /Volumes/Ext/dev/* ]] || die "external drive /Volumes/Ext/dev not mounted" 2
free_gb="$(df -g /System/Volumes/Data | awk 'NR==2 {print $4}')"
(( free_gb >= 10 )) || die "only ${free_gb} GB free on the internal disk" 2

[[ -n "$OUT" ]] || OUT="${TMPDIR:-/tmp}/wukongmind-device-check/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT" "$DD" || die "cannot create output/derived-data dirs" 2
OUT="$(cd "$OUT" && pwd)"
log "output dir: $OUT"

install_traps

if (( ! SKIP_BUILD )); then
  build_for_testing "$OUT" "$DD"
fi

acquire_lock "$UDID"

rc=0
preflight_device "$UDID" "$OUT" || rc=$?
if (( rc == 0 && REBOOT )); then
  reboot_device "$UDID" "$OUT" || rc=$?
fi
if (( rc == 0 )); then
  case "$MODE" in
    test)   mode_test "$UDID" "$OUT" "$DD" "$TIMEOUT" "${EXTRA[@]+"${EXTRA[@]}"}" || rc=$? ;;
    launch) mode_launch "$UDID" "$OUT" "$DD" "$SECONDS_CAPTURE" "${EXTRA[@]+"${EXTRA[@]}"}" || rc=$? ;;
  esac
fi

echo "---- device-check result: exit $rc ----"
echo "output dir: $OUT"
for f in build.log test.log launch.log test.xcresult; do
  [[ -e "$OUT/$f" ]] && echo "  $OUT/$f"
done
exit "$rc"
