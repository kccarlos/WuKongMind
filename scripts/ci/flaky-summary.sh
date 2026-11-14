#!/usr/bin/env bash
# Prints a Markdown section listing tests that failed an attempt but passed on
# retry, read from an .xcresult bundle. Always exits 0.
set -u
bundle="${1:-TestResults.xcresult}"
echo "## Flaky tests (passed on retry)"
echo
if [ ! -d "$bundle" ]; then
  echo "No $bundle found; nothing to report."
  exit 0
fi
json="$(mktemp)"
if ! xcrun xcresulttool get test-results tests --path "$bundle" >"$json" 2>/dev/null; then
  echo "Could not read $bundle with xcresulttool."
  rm -f "$json"
  exit 0
fi
python3 - "$json" <<'PY' || echo "Could not parse the test results."
import json, sys

data = json.load(open(sys.argv[1]))
flaky = []

def walk(node, path):
    name = node.get("name", "")
    kids = node.get("children", [])
    if node.get("nodeType") == "Test Case":
        # Retries appear as Repetition / Test Case Run descendants of the case.
        runs = []
        def collect(n):
            for c in n.get("children", []):
                if c.get("nodeType") in ("Repetition", "Test Case Run"):
                    runs.append(c.get("result"))
                else:
                    collect(c)
        collect(node)
        if node.get("result") == "Passed" and "Failed" in runs:
            flaky.append((".".join(path + [name]), runs.count("Failed"), len(runs)))
        return
    for c in kids:
        walk(c, path + ([name] if node.get("nodeType") in ("Test Suite", "Unit test bundle") else []))

for n in data.get("testNodes", []):
    walk(n, [])

if not flaky:
    print("None: no test needed a retry.")
else:
    print("| Test | Failed attempts | Attempts |")
    print("| --- | --- | --- |")
    for t, f, a in sorted(flaky):
        print(f"| `{t}` | {f} | {a} |")
PY
rm -f "$json"
exit 0
