#!/usr/bin/env bash
# Render the README images for every language (en-US, zh-Hans, zh-Hant):
#
#   docs/brand/forumind-banner[-<locale>].png   the banner / GitHub social
#                                               preview (1280 x 640), see
#                                               render_banner.swift
#   docs/screenshots/store/<locale>/*.png       small copies of App Store
#                                               screenshots for the README
#                                               (run render_store_screenshots.sh first)
#
# Needs pngquant (brew install pngquant): every image is compressed to a
# 256-color PNG, about a quarter of the size, so the repository stays small.
#
# Usage: scripts/brand/render_banner.sh [--preview <dir>]
set -euo pipefail

if ! command -v pngquant >/dev/null; then
  echo "pngquant not found; install it first: brew install pngquant" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

xcrun swiftc -parse-as-library -O \
  "$repo_root/Forumind/BrandMarkShapes.swift" \
  "$repo_root/Forumind/BrandMark.swift" \
  "$repo_root/scripts/brand/render_banner.swift" \
  -o "$work/render_banner"
"$work/render_banner" "$repo_root" "$@"

# README screenshot strip: the first four iPhone screenshots and the first
# iPad one, downscaled (sips keeps the aspect ratio and the missing alpha).
outputs=("$repo_root"/docs/brand/forumind-banner*.png)
for locale in en-US zh-Hans zh-Hant; do
  src="$repo_root/appstore/screenshots/$locale"
  dst="$repo_root/docs/screenshots/store/$locale"
  mkdir -p "$dst"
  for shot in iphone-69-1-summary iphone-69-2-ask iphone-69-3-chat iphone-69-4-forums; do
    sips -Z 720 "$src/$shot.png" --out "$dst/$shot.png" >/dev/null
    outputs+=("$dst/$shot.png")
  done
  sips -Z 1100 "$src/ipad-13-1-summary.png" --out "$dst/ipad-13-1-summary.png" >/dev/null
  outputs+=("$dst/ipad-13-1-summary.png")
done

for file in "${outputs[@]}"; do
  pngquant --quality=70-95 --speed 1 --strip --force --ext .png -- "$file"
done
echo "Compressed ${#outputs[@]} images with pngquant"
