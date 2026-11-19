#!/usr/bin/env bash
# Checks a built WukongMind.app for things App Review's static scan looks at
# (docs/wukongmind/app-store-code-audit.md, WUKO-168): private frameworks,
# underscore-prefixed Objective-C selectors, runtime-swizzling imports, and
# DEBUG-only strings that must not be in a Release binary.
#
#   scripts/audit-release-binary.sh <path/to/WukongMind.app> [more .app/.appex ...]
#
# An argument that is a file is checked as a Mach-O binary itself. That is how
# to see the check fail: a Debug build keeps its code in
# WukongMind.app/WukongMind.debug.dylib, which has every item below.
#
# Exit 0: clean. Exit 1: something from the "must be absent" lists was found.
# Exit 3: the binary is stripped of local symbols (an archived or exported
# app), so the selector and symbol checks cannot run; use the product of
# `xcodebuild build`.
# The lists of DEBUG launch arguments are read from the sources, so a new
# `-dc-` argument is covered without editing this script.
#
# Limits: Swift keeps string literals of 15 bytes or fewer inside the
# instruction stream, so `strings` cannot see them. Short literals are covered
# by the selector and symbol checks instead: with no `arguments` selector the
# binary never reads its launch arguments, whatever literals it holds.
# shellcheck disable=SC2001 # sed keeps the multi-line indents readable
set -uo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 <WukongMind.app> [...]" >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Selector, class and path names used only by DEBUG code (ForumBrowser's
# Screen Time swizzle for tests). None may be in a Release binary.
PRIVATE_NAMES=(
  _installScreenTimeWebpageControllerIfNeeded
  _updateScreenTimeBasedOnWindowVisibility
  _showsSystemScreenTimeBlockingView
  WKScreenTimeConfigurationObserver
  STScreenTimeWebBrowserSettingsObserver
  PrivateFrameworks
  ScreenTimeCore
)
# Runtime functions that only the DEBUG swizzle imports.
RUNTIME_IMPORTS=(_dlopen _method_setImplementation _method_exchangeImplementations
  _class_getInstanceMethod _class_replaceMethod _class_addMethod _imp_implementationWithBlock
  _NSSelectorFromString)
# Types and functions that exist only under `#if DEBUG`. A Release build that
# kept its local symbols (xcodebuild's product, before the App Store strip)
# must have none of them.
DEBUG_SYMBOLS='AssistantDebug|OnboardingDebug|swizzleWebKitScreenTime|disableWebKitScreenTimeForTesting|TabAccessibilityDebugOverlay|VoiceDebug'

# Every "-dc-..." and "-ui-test-..." literal in the app and extension sources.
DEBUG_ARGS=()
while IFS= read -r arg; do DEBUG_ARGS+=("$arg"); done < <(
  grep -rhoE '"-(dc|ui-test)-[A-Za-z0-9-]*"' "$ROOT/WukongMind" "$ROOT/WukongMindShare" --include='*.swift' | tr -d '"' | sort -u
)

fail=0
for bundle in "$@"; do
  if [[ -f "$bundle" ]]; then
    bin="$bundle" # a Mach-O file given directly
  else
    name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist" 2>/dev/null)"
    bin="$bundle/$name"
  fi
  [[ -f "$bin" ]] || { echo "no executable in $bundle" >&2; exit 2; }
  echo "== $bin"
  echo "   $(file -b "$bin" | head -1), $(stat -f %z "$bin") bytes"
  strings_file="$(mktemp)"; trap 'rm -f "$strings_file"' EXIT
  strings -a - "$bin" > "$strings_file"
  echo "   strings: $(wc -l < "$strings_file" | tr -d ' ') lines"

  echo "-- linked libraries outside /System/Library/Frameworks, /usr/lib (expect none)"
  odd="$(otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -vE '^(/System/Library/Frameworks/|/usr/lib/|@rpath/libswift)' || true)"
  if [[ -n "$odd" ]]; then echo "$odd" | sed 's/^/   FOUND /'; fail=1; else echo "   none"; fi
  priv="$(otool -L "$bin" | grep -c PrivateFrameworks || true)"
  echo "   PrivateFrameworks linked: $priv"; [[ "$priv" == 0 ]] || fail=1

  echo "-- private names (expect 0 each)"
  for n in "${PRIVATE_NAMES[@]}"; do
    c="$(grep -c -F -- "$n" "$strings_file" || true)"
    printf '   %-48s %s\n' "$n" "$c"; [[ "$c" == 0 ]] || fail=1
  done

  echo "-- runtime imports (expect 0 each; nm -u)"
  undefined="$(nm -u "$bin" 2>/dev/null | awk '{print $NF}')"
  for n in "${RUNTIME_IMPORTS[@]}"; do
    c="$(grep -c -x -F -- "$n" <<<"$undefined" || true)"
    printf '   %-48s %s\n' "$n" "$c"; [[ "$c" == 0 ]] || fail=1
  done
  echo "   all objc runtime / dl imports: $(grep -E '^_(objc_|class_|method_|object_|sel_|imp_|dl|NSSelectorFrom|NSClassFrom)' <<<"$undefined" | sort -u | tr '\n' ' ')"

  # Every Objective-C message the binary sends has a stub named objc_msgSend$<selector>.
  symbols="$(nm "$bin" 2>/dev/null)"
  sent="$(sed -n 's/.*objc_msgSend\$//p' <<<"$symbols" | sort -u)"
  sent_count="$(grep -c . <<<"$sent" | tr -d ' ')"
  if [[ "$sent_count" == 0 ]]; then
    echo "   no objc_msgSend\$ symbols: a stripped binary. The selector and symbol checks" >&2
    echo "   cannot run on it; use the unstripped product of xcodebuild build." >&2
    exit 3
  fi
  echo "-- Objective-C selectors sent: $sent_count"
  echo "   starting with an underscore (expect none):"
  # (__swift_* are the Swift runtime's own bridging selectors.)
  sels="$(grep -E '^_' <<<"$sent" | grep -v -E '^__swift_' || true)"
  if [[ -n "$sels" ]]; then echo "$sels" | sed 's/^/   FOUND /'; fail=1; else echo "   none"; fi
  echo "   string-selector and key-value calls (expect none):"
  sels="$(grep -E '^(performSelector|valueForKey|setValue:forKey|valueForKeyPath|setValue:forKeyPath)' <<<"$sent" || true)"
  if [[ -n "$sels" ]]; then echo "$sels" | sed 's/^/   FOUND /'; fail=1; else echo "   none"; fi
  c="$(grep -c -x -F arguments <<<"$sent" || true)"
  echo "   'arguments' (ProcessInfo launch arguments; expect 0): $c"; [[ "$c" == 0 ]] || fail=1

  c="$(grep -c -E "$DEBUG_SYMBOLS" <<<"$symbols" || true)"
  echo "-- DEBUG-only symbols among $(grep -c . <<<"$symbols" | tr -d ' ') (expect 0): $c"; [[ "$c" == 0 ]] || fail=1

  # dlsym is imported by the compiler's own #available support
  # (__isPlatformVersionAtLeast). Any other caller is a finding.
  if grep -q -x -F _dlsym <<<"$undefined"; then
    callers="$(xcrun llvm-objdump -d --macho "$bin" 2>/dev/null \
      | awk '/^[_A-Za-z$.][^ ]*:$/ {lab=$0} /bl\t.*_dlsym/ {print lab}' | sort | uniq -c)"
    echo "-- dlsym callers (expect only the compiler's availability check):"
    echo "$callers" | sed 's/^ */   /'
    other="$(grep -v -E '(initializeAvailabilityCheck|isPlatformVersionAtLeast)' <<<"$callers" || true)"
    [[ -z "$other" ]] || fail=1
  else
    echo "-- dlsym: not imported"
  fi

  echo "-- DEBUG launch arguments (${#DEBUG_ARGS[@]} literals from the sources; expect 0 found)"
  found=0
  for a in "${DEBUG_ARGS[@]}"; do
    if grep -q -F -- "$a" "$strings_file"; then echo "   FOUND $a"; found=$((found + 1)); fi
  done
  echo "   found: $found"; [[ "$found" == 0 ]] || fail=1

  echo "-- for the record (not failures)"
  echo "   NSClassFromString imported: $(grep -c -x -F _NSClassFromString <<<"$undefined" || true)"
  echo "   'environment' selector sent: $(grep -c -x -F environment <<<"$sent" || true)"
  echo "   'shareddocuments' strings:  $(grep -c -F shareddocuments "$strings_file" || true)"
  echo "   'GEMINI_LIVE_BUDGET':       $(grep -c -F GEMINI_LIVE_BUDGET "$strings_file" || true)"
  rm -f "$strings_file"
done

if (( fail )); then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: clean"
