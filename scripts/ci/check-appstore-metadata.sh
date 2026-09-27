#!/usr/bin/env bash
# Validate App Store metadata in appstore/ (fastlane `deliver` layout) against
# App Store Connect limits, so an upload never fails halfway.
#
# Checks:
#   - required files exist and are not empty
#   - length limits in characters (Unicode code points, one trailing newline
#     ignored): name/subtitle <= 30, promotional text <= 170, keywords <= 100,
#     description <= 4000, release notes <= 4000
#   - keywords: comma-separated, no empty entries, no duplicates
#   - URLs are https
#   - screenshots (if any): PNG/JPEG at a size App Store Connect accepts for
#     the device class their file name starts with (iphone*, ipad*)
#
# Usage: scripts/ci/check-appstore-metadata.sh [appstore-dir]
# Needs: python3 (stdlib only). Runs on macOS and Linux.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dir="${1:-$repo_root/appstore}"

python3 - "$dir" <<'PY'
import os, struct, sys

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
for name in ["copyright.txt", "primary_category.txt"]:
    path = os.path.join(meta, name)
    if not os.path.isfile(path) or not read(path).strip():
        fail(path, "required file is missing or empty")

limits = {
    "name.txt": (30, True),
    "subtitle.txt": (30, False),
    "promotional_text.txt": (170, False),
    "keywords.txt": (100, True),
    "description.txt": (4000, True),
    "release_notes.txt": (4000, False),
    "privacy_url.txt": (255, True),
    "support_url.txt": (255, True),
    "marketing_url.txt": (255, False),
}

locales = sorted(
    d for d in os.listdir(meta)
    if os.path.isdir(os.path.join(meta, d)) and d != "review_information"
)
if not locales:
    fail(meta, "no locale directories (e.g. en-US)")

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
        print(f"{locale}/{name}: {length}/{limit}")

# Screenshots: accepted pixel sizes by device class (portrait; landscape is
# the same pair swapped). 6.9"/6.7" iPhone and 13"/12.9" iPad.
SIZES = {
    "iphone": {(1320, 2868), (1290, 2796), (1284, 2778), (1242, 2688)},
    "ipad": {(2064, 2752), (2048, 2732)},
}


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
if os.path.isdir(shots):
    for dirpath, _, files in os.walk(shots):
        for name in sorted(files):
            if name.startswith(".") or name.endswith((".md", ".txt")):
                continue
            path = os.path.join(dirpath, name)
            size = image_size(path)
            if size is None:
                fail(path, "not a PNG or JPEG")
                continue
            kind = next((k for k in SIZES if name.lower().startswith(k)), None)
            if kind is None:
                fail(path, "file name must start with 'iphone' or 'ipad'")
                continue
            w, h = size
            if (w, h) not in SIZES[kind] and (h, w) not in SIZES[kind]:
                fail(path, f"{w}x{h} is not an accepted {kind} screenshot size")
            count += 1
    for kind in SIZES:
        n = sum(1 for _, _, fs in os.walk(shots) for f in fs if f.lower().startswith(kind))
        if n > 10:
            fail(shots, f"{n} {kind} screenshots per locale; the limit is 10")
print(f"screenshots checked: {count}")

if errors:
    print("\nApp Store metadata problems:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
print("App Store metadata OK")
PY
