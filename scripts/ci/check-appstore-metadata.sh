#!/usr/bin/env bash
# Validate App Store metadata in appstore/ against App Store Connect limits
# and WukongMind positioning rules (docs/wukongmind/store-positioning.md).
#
# Checks:
#   - required top-level files exist and are not empty
#   - all three required locales (en-US, zh-Hans, zh-Hant) are present
#   - length limits in characters (Unicode code points, one trailing newline
#     ignored): name/subtitle <= 30, promotional text <= 170, keywords <= 100,
#     description <= 4000, release notes <= 4000, review/notes.txt <= 4000
#   - keywords: comma-separated, no empty entries, no duplicates
#   - URLs are https
#   - banned words from docs/wukongmind/store-positioning.md sections 3-4
#     (no forum-browser framing, no forum platform names, no removed digest/
#     podcast features, no competitor browser/game names, and no provider/
#     product names or "forum" in name, subtitle, or keywords)
#   - screenshots (if any, one folder per locale, at most 10 per device class
#     each): PNG/JPEG at a size App Store Connect accepts for the device class
#     their file name starts with (iphone*, ipad*), and PNGs without an alpha
#     channel (App Store Connect rejects transparency).
#
# Usage: scripts/ci/check-appstore-metadata.sh [appstore-dir]
# Needs: python3 (stdlib only). Runs on macOS and Linux.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dir="${1:-$repo_root/appstore}"

python3 - "$dir" <<'PY'
import os, re, struct, sys

root = sys.argv[1]
meta = os.path.join(root, "metadata")
errors = []
gha = bool(os.environ.get("GITHUB_ACTIONS"))


def fail(path, message):
    rel = os.path.relpath(path, os.getcwd())
    errors.append(f"{rel}: {message}")
    if gha:
        print(f"::error file={rel}::{message}")


def read(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    return text[:-1] if text.endswith("\n") else text


if not os.path.isdir(meta):
    sys.exit(f"No metadata directory at {meta}")

# Top-level files (apply to every locale).
for name in ["copyright.txt", "primary_category.txt", "secondary_category.txt"]:
    path = os.path.join(meta, name)
    if not os.path.isfile(path) or not read(path).strip():
        fail(path, "required file is missing or empty")

limits = {
    "name.txt": (30, True),
    "subtitle.txt": (30, True),
    "promotional_text.txt": (170, True),
    "keywords.txt": (100, True),
    "description.txt": (4000, True),
    "release_notes.txt": (4000, True),
    "privacy_url.txt": (255, True),
    "support_url.txt": (255, True),
    "marketing_url.txt": (255, True),
}

REQUIRED_LOCALES = ["en-US", "zh-Hans", "zh-Hant"]

locales = sorted(
    d for d in os.listdir(meta)
    if os.path.isdir(os.path.join(meta, d)) and d != "review_information"
)
for req in REQUIRED_LOCALES:
    if req not in locales:
        fail(os.path.join(meta, req), f"required locale {req!r} is missing")

# Banned terms from docs/wukongmind/store-positioning.md sections 3-4 and
# docs/wukongmind/app-store-review.md.
# Patterns are (compiled_regex, human_label).
def word_pattern(term):
    if re.search(r"[A-Za-z0-9]", term):
        return (re.compile(r"(?<![A-Za-z0-9])" + re.escape(term) + r"(?![A-Za-z0-9])", re.IGNORECASE), term)
    return (re.compile(re.escape(term)), term)


BANNED_ALL_TEXT = [
    word_pattern(t) for t in [
        "悟空浏览器", "悟空瀏覽器",
        "black myth", "黑神话", "黑神話",
        "forum browser", "论坛浏览器", "論壇瀏覽器",
        "ask the forum", "问论坛", "問論壇",
        "discourse", "wordpress", "hacker news",
        "daily digest", "每日摘要",
        "podcast", "播客",
        "ad-free", "无广告网页", "無廣告網頁",
        "downloader",
    ]
]

BANNED_DISCOVERY = [
    word_pattern(t) for t in [
        "openai", "anthropic", "claude", "gemini", "google", "deepseek",
        "groq", "xai", "ollama", "lm studio", "openrouter", "nvidia", "vertex",
        "safari", "chrome", "tampermonkey", "apple intelligence", "chatgpt", "gpt",
        "forumind", "forum", "论坛", "論壇", "悟空",
    ]
]

TEXT_FIELDS = {
    "name.txt", "subtitle.txt", "keywords.txt",
    "promotional_text.txt", "description.txt", "release_notes.txt",
}
DISCOVERY_FIELDS = {"name.txt", "subtitle.txt", "keywords.txt"}

for locale in locales:
    for name, (limit, required) in limits.items():
        path = os.path.join(meta, locale, name)
        if not os.path.isfile(path):
            if required:
                fail(path, "required file is missing")
            continue
        text = read(path)
        length = len(text)
        if required and not text.strip():
            fail(path, "is empty")
        if length > limit:
            fail(path, f"{length} characters, limit is {limit}")
        if "\n" in text and name not in ("description.txt", "release_notes.txt", "promotional_text.txt"):
            fail(path, "must be a single line")
        if name.endswith("_url.txt") and text and not text.startswith("https://"):
            fail(path, "URL must start with https://")
        if name == "keywords.txt":
            words = [w.strip() for w in text.split(",")]
            if any(not w for w in words):
                fail(path, "empty keyword (check for doubled or trailing commas)")
            lowered = [w.lower() for w in words if w]
            if len(set(lowered)) != len(lowered):
                fail(path, "duplicate keywords")
        if name in TEXT_FIELDS:
            for pattern, label in BANNED_ALL_TEXT:
                if pattern.search(text):
                    fail(path, f"contains banned term {label!r}")
        if name in DISCOVERY_FIELDS:
            for pattern, label in BANNED_DISCOVERY:
                if pattern.search(text):
                    fail(path, f"contains banned name/subtitle/keyword term {label!r}")
        print(f"{locale}/{name}: {length}/{limit}")

# App Review notes length limit (App Store Connect allows 4000 characters).
review_notes = os.path.join(root, "review", "notes.txt")
if os.path.isfile(review_notes):
    notes_text = read(review_notes)
    notes_len = len(notes_text)
    if not notes_text.strip():
        fail(review_notes, "is empty")
    if notes_len > 4000:
        fail(review_notes, f"{notes_len} characters, limit is 4000")
    print(f"review/notes.txt: {notes_len}/4000")

# Screenshots: accepted pixel sizes by device class (portrait; landscape is
# the same pair swapped). 6.9"/6.7" iPhone and 13"/12.9" iPad.
SIZES = {
    "iphone": {(1320, 2868), (1290, 2796), (1284, 2778), (1242, 2688)},
    "ipad": {(2064, 2752), (2048, 2732)},
}


def png_has_alpha(path):
    # IHDR color type: 4 = gray + alpha, 6 = RGB + alpha.
    with open(path, "rb") as fh:
        head = fh.read(26)
    return head[:8] == b"\x89PNG\r\n\x1a\n" and head[25] in (4, 6)


def image_size(path):
    with open(path, "rb") as fh:
        head = fh.read(26)
        if head[:8] == b"\x89PNG\r\n\x1a\n":
            return struct.unpack(">II", head[16:24])
        if head[:2] == b"\xff\xd8":
            fh.seek(2)
            while True:
                marker = fh.read(2)
                if len(marker) < 2 or marker[0] != 0xFF:
                    return None
                length = struct.unpack(">H", fh.read(2))[0]
                if marker[1] in (0xC0, 0xC1, 0xC2):
                    fh.read(1)
                    h, w = struct.unpack(">HH", fh.read(4))
                    return (w, h)
                fh.seek(length - 2, 1)
    return None


shots = os.path.join(root, "screenshots")
count = 0


def screenshot_kind(path, locale_root):
    rel = os.path.relpath(path, locale_root)
    parts = rel.split(os.sep)
    if len(parts) >= 2 and parts[0].lower() in SIZES:
        return parts[0].lower()
    name = os.path.basename(path)
    return next((k for k in SIZES if name.lower().startswith(k)), None)


if os.path.isdir(shots):
    for locale in sorted(os.listdir(shots)):
        folder = os.path.join(shots, locale)
        if not os.path.isdir(folder):
            continue
        if locale not in locales:
            fail(folder, f"screenshot locale {locale!r} has no metadata/{locale}/ folder")
        per_kind = {k: 0 for k in SIZES}
        for dirpath, _, files in os.walk(folder):
            for name in sorted(files):
                if name.startswith(".") or name.endswith((".md", ".txt")):
                    continue
                path = os.path.join(dirpath, name)
                size = image_size(path)
                if size is None:
                    fail(path, "not a PNG or JPEG")
                    continue
                kind = screenshot_kind(path, folder)
                if kind is None:
                    fail(path, "place under iphone/ or ipad/ subfolder, or prefix file name with 'iphone' or 'ipad'")
                    continue
                w, h = size
                if (w, h) not in SIZES[kind] and (h, w) not in SIZES[kind]:
                    fail(path, f"{w}x{h} is not an accepted {kind} screenshot size")
                if png_has_alpha(path):
                    fail(path, "PNG has an alpha channel; screenshots must be opaque")
                per_kind[kind] += 1
                count += 1
        for kind, n in per_kind.items():
            if n > 10:
                fail(folder, f"{n} {kind} screenshots; the limit is 10 per locale")
        print(f"screenshots/{locale}: " + ", ".join(f"{per_kind[k]} {k}" for k in SIZES))
print(f"screenshots checked: {count}")

if errors:
    print("\nApp Store metadata problems:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
print("App Store metadata OK")
PY
