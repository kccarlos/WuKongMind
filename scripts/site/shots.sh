#!/bin/sh
# Make the home page's app screenshots (site/assets/shots/<lang>/NN.webp) from the App Store
# screenshots in appstore/screenshots/ (WUKO-199). Run after those change, then commit the result.
#   sh scripts/site/shots.sh        (needs cwebp: brew install webp)
set -eu
cd "$(dirname "$0")/../.."
for pair in en-US:en zh-Hans:zh-Hans zh-Hant:zh-Hant; do
  src="appstore/screenshots/${pair%%:*}/iphone"
  out="site/assets/shots/${pair##*:}"
  mkdir -p "$out"
  n=1
  for name in 01-change-page 02-agent-steps 03-script-approval 04-tabs-navigation 05-summarize-read-aloud; do
    cwebp -quiet -q 70 -resize 440 0 "$src/$name.png" -o "$out/0$n.webp"
    n=$((n + 1))
  done
done
ls -l site/assets/shots/*/
