#!/usr/bin/env bash
# Render the App Store marketing screenshots from the raw captures in
# appstore/screenshots-raw/<locale>/ into appstore/screenshots/<locale>/ for
# every store locale (en-US, zh-Hans, zh-Hant). See render_store_screenshots.swift.
#
# Usage: scripts/brand/render_store_screenshots.sh [--preview <dir>]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

xcrun swiftc -parse-as-library -O \
  "$repo_root/Forumind/BrandMarkShapes.swift" \
  "$repo_root/Forumind/BrandMark.swift" \
  "$repo_root/scripts/brand/render_store_screenshots.swift" \
  -o "$work/render_store_screenshots"
"$work/render_store_screenshots" "$repo_root" "$@"
