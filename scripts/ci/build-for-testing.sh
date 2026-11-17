#!/usr/bin/env bash
# Build the app and both test bundles once (unsigned, Debug, simulator) and
# pack what `xcodebuild test-without-building -xctestrun` needs into
# test-products.zip: Debug-iphonesimulator/ and the .xctestrun file.
#
# Env:
#   DESTINATION   xcodebuild destination on THIS runner (from pick-simulator.sh;
#                 a concrete simulator builds only the runner's arch). The test
#                 jobs pick their own simulator: UDIDs differ per runner and the
#                 .xctestrun is not tied to one.
#   PROJECT, SCHEME  (defaults WukongMind.xcodeproj / WukongMind)
#   DERIVED_DATA  (default DerivedData)
#   OUT           zip path (default test-products.zip)
set -euo pipefail

project="${PROJECT:-WukongMind.xcodeproj}"
scheme="${SCHEME:-WukongMind}"
dd="${DERIVED_DATA:-DerivedData}"
out="${OUT:-test-products.zip}"
: "${DESTINATION:?set DESTINATION (scripts/ci/pick-simulator.sh)}"

formatter=(cat)
if command -v xcbeautify >/dev/null; then formatter=(xcbeautify --renderer github-actions); fi

set -o pipefail
xcodebuild build-for-testing \
  -project "$project" \
  -scheme "$scheme" \
  -destination "$DESTINATION" \
  -derivedDataPath "$dd" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee build.log | "${formatter[@]}"

products="$dd/Build/Products"
shopt -s nullglob
runs=("$products"/*.xctestrun)
if [[ ${#runs[@]} -ne 1 ]]; then
  echo "Expected one .xctestrun in $products, found ${#runs[@]}" >&2
  ls -la "$products" >&2 || true
  exit 1
fi

out_abs="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
rm -f "$out_abs"
# -y keeps framework symlinks; dSYMs are not needed to run tests.
(cd "$products" && zip -q -r -y -1 "$out_abs" Debug-iphonesimulator "$(basename "${runs[0]}")" -x '*.dSYM/*')
echo "Packed $(du -h "$out_abs" | cut -f1) into $out ($(basename "${runs[0]}"))"
