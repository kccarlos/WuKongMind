#!/usr/bin/env bash
# Resolve and validate the release marketing version and CI build number.
#
# Reads marketing_version from scripts/generate_project.rb and checks that the
# committed WukongMind.xcodeproj agrees with it. On tag builds (REF_TYPE=tag),
# fails unless the tag's numeric version matches MARKETING_VERSION (for example,
# pushing v1.1.0 while MARKETING_VERSION is 1.0.0 fails immediately).
#
# Env:
#   REF_TYPE           Git ref type ('tag' or 'branch'; defaults to $GITHUB_REF_TYPE).
#   REF_NAME           Git ref name (e.g. 'v1.1.0' or 'main'; defaults to $GITHUB_REF_NAME).
#   INPUT_VERSION      Optional manual override from workflow_dispatch inputs.version.
#   BUILD_BASE         Base offset added to GITHUB_RUN_NUMBER (default: 100).
#   GITHUB_RUN_NUMBER  Monotonic workflow run number (required in GitHub Actions).
#   MIN_BUILD          Minimum build number that computed build must strictly exceed
#                      (defaults to 105 on kccarlos/WuKongMind, where M1 shipped 104
#                      and 105; 0 elsewhere).
#   PROJECT_ROOT       Optional repository root override (defaults to this repo).
set -euo pipefail

repo_root="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
generator="$repo_root/scripts/generate_project.rb"
pbxproj="$repo_root/WukongMind.xcodeproj/project.pbxproj"

if [[ ! -f "$generator" ]]; then
  echo "::error::Generator script not found at $generator" >&2
  exit 1
fi
if [[ ! -f "$pbxproj" ]]; then
  echo "::error::Xcode project not found at $pbxproj" >&2
  exit 1
fi

gen_versions=()
while IFS= read -r line; do
  [[ -n "$line" ]] && gen_versions+=("$line")
done < <(sed -nE 's/^[[:space:]]*marketing_version[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' "$generator")

if [[ ${#gen_versions[@]} -ne 1 ]]; then
  echo "::error file=scripts/generate_project.rb::Expected exactly one marketing_version in scripts/generate_project.rb (found ${#gen_versions[@]})." >&2
  exit 1
fi
generator_version="${gen_versions[0]}"

if [[ ! "$generator_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "::error file=scripts/generate_project.rb::Invalid marketing_version '$generator_version' in scripts/generate_project.rb." >&2
  exit 1
fi

pbx_versions=()
while IFS= read -r line; do
  [[ -n "$line" ]] && pbx_versions+=("$line")
done < <(sed -nE 's/^[[:space:]]*MARKETING_VERSION = "?([^";]+)"?;$/\1/p' "$pbxproj" | LC_ALL=C sort -u)

if [[ ${#pbx_versions[@]} -eq 0 ]]; then
  echo "::error file=WukongMind.xcodeproj/project.pbxproj::No MARKETING_VERSION found in WukongMind.xcodeproj/project.pbxproj." >&2
  exit 1
fi
if [[ ${#pbx_versions[@]} -gt 1 ]]; then
  echo "::error file=WukongMind.xcodeproj/project.pbxproj::Inconsistent MARKETING_VERSION values in WukongMind.xcodeproj/project.pbxproj: ${pbx_versions[*]}" >&2
  exit 1
fi
pbx_version="${pbx_versions[0]}"

if [[ "$pbx_version" != "$generator_version" ]]; then
  echo "::error::WukongMind.xcodeproj MARKETING_VERSION ($pbx_version) does not match scripts/generate_project.rb ($generator_version). Run 'ruby scripts/generate_project.rb' and commit the result." >&2
  exit 1
fi

project_version="$generator_version"
ref_type="${REF_TYPE:-${GITHUB_REF_TYPE:-}}"
ref_name="${REF_NAME:-${GITHUB_REF_NAME:-}}"
input_version="${INPUT_VERSION:-}"

if [[ "$ref_type" == "tag" ]]; then
  # Tag v1.2.3 -> 1.2.3 (an optional pre-release suffix like -beta.1 is dropped
  # because App Store Connect CFBundleShortVersionString allows numbers only).
  if [[ ! "$ref_name" =~ ^v([0-9]+(\.[0-9]+){0,2})(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    echo "::error::Tag '$ref_name' is not a valid version tag (expected v$project_version, e.g. v1.1.0)." >&2
    exit 1
  fi
  tag_version="${BASH_REMATCH[1]}"
  if [[ "$tag_version" != "$project_version" ]]; then
    echo "::error::Tag $ref_name (version $tag_version) does not match app MARKETING_VERSION $project_version (expected tag v$project_version). Bump marketing_version in scripts/generate_project.rb and regenerate WukongMind.xcodeproj first." >&2
    exit 1
  fi
  if [[ -n "$input_version" && "$input_version" != "$tag_version" ]]; then
    echo "::error::workflow_dispatch version '$input_version' does not match tag $ref_name ($tag_version)." >&2
    exit 1
  fi
  version="$project_version"
elif [[ -n "$input_version" ]]; then
  if [[ ! "$input_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "::error::version must look like 1.2.3 (got '$input_version')" >&2
    exit 1
  fi
  version="$input_version"
else
  version="$project_version"
fi

build_base="${BUILD_BASE:-100}"
if [[ ! "$build_base" =~ ^[0-9]+$ ]]; then
  echo "::error::BUILD_BASE must be a non-negative integer (got '$build_base')." >&2
  exit 1
fi

run_number="${GITHUB_RUN_NUMBER:-}"
if [[ -z "$run_number" ]]; then
  if [[ "${GITHUB_ACTIONS:-false}" == "true" || -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "::error::GITHUB_RUN_NUMBER is not set." >&2
    exit 1
  fi
  echo "Marketing version: $version (app MARKETING_VERSION=$project_version)"
  exit 0
fi

if [[ ! "$run_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::GITHUB_RUN_NUMBER must be a positive integer (got '$run_number')." >&2
  exit 1
fi

if [[ -n "${MIN_BUILD:-}" ]]; then
  min_build="$MIN_BUILD"
elif [[ "${GITHUB_REPOSITORY:-kccarlos/WuKongMind}" =~ ^[Kk]ccarlos/[Ww]u[Kk]ong[Mm]ind$ ]]; then
  min_build=105
else
  min_build=0
fi

if [[ ! "$min_build" =~ ^[0-9]+$ ]]; then
  echo "::error::MIN_BUILD must be a non-negative integer (got '$min_build')." >&2
  exit 1
fi

build=$((10#$build_base + 10#$run_number))
if (( build <= 10#$min_build )); then
  echo "::error::Computed build number $build (BUILD_BASE=$build_base + GITHUB_RUN_NUMBER=$run_number) must be greater than $min_build." >&2
  exit 1
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "version=$version"
    echo "build=$build"
  } >>"$GITHUB_OUTPUT"
fi
echo "Marketing version: $version, build number: $build"
