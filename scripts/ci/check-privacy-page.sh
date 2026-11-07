#!/usr/bin/env bash
# The privacy page on the site is generated from PRIVACY.md. Fails when the
# committed mobile-site/privacy/index.html differs from what
# scripts/site/render_privacy.py would write (edit PRIVACY.md, then run it).
#
# Usage: scripts/ci/check-privacy-page.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

if ! python3 scripts/site/render_privacy.py --check; then
  echo "::error::mobile-site/privacy/index.html is out of date with PRIVACY.md. Run scripts/site/render_privacy.py and commit."
  exit 1
fi
