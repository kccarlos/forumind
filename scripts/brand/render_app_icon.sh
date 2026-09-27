#!/usr/bin/env bash
# Render the app icon PNGs from the brand mark code. See render_app_icon.swift.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

xcrun swiftc -parse-as-library -O \
  "$repo_root/Forumind/BrandMarkShapes.swift" \
  "$repo_root/Forumind/BrandMark.swift" \
  "$repo_root/scripts/brand/render_app_icon.swift" \
  -o "$work/render_app_icon"
"$work/render_app_icon" "$repo_root"
