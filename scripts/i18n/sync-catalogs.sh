#!/usr/bin/env bash
# Update the String Catalogs from the source code, the way Xcode does after a
# build, so the committed catalogs don't depend on anyone's Xcode session.
#
#   scripts/i18n/sync-catalogs.sh            # build, sync, report
#   scripts/i18n/sync-catalogs.sh --no-build # sync from the last build
#
# 1. Builds the app and the share extension for the simulator into a
#    dedicated derived-data folder with SWIFT_EMIT_LOC_STRINGS=YES; the
#    compiler writes one .stringsdata file per source file with every
#    localizable literal (Text("…"), String(localized:), …).
# 2. Runs `xcstringstool sync` (the tool Xcode itself uses) to add new keys
#    and mark keys no longer in the code "stale"; existing translations are
#    kept.
# 3. Prints the translation report (scripts/i18n/check-catalogs.py), which
#    exits non-zero when a key is missing a translation, stale or needs
#    review.
#
# Requires Xcode (xcodebuild, xcstringstool) and python3.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
derived="${I18N_DERIVED_DATA:-${TMPDIR:-/tmp}/forumind-i18n-dd}"
build=1
[[ "${1:-}" == "--no-build" ]] && build=0

intermediates="$derived/Build/Intermediates.noindex/Forumind.build"

if [[ $build -eq 1 ]]; then
  # Stale .stringsdata from renamed or deleted files would keep old keys alive.
  rm -rf "$intermediates"
  destination="${I18N_DESTINATION:-generic/platform=iOS Simulator}"
  xcodebuild build -project "$repo_root/Forumind.xcodeproj" -scheme Forumind \
    -configuration Debug -destination "$destination" \
    CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES \
    -derivedDataPath "$derived" -quiet
fi

sync_target() {
  local target="$1" catalog="$2"
  local files=()
  while IFS= read -r -d '' file; do files+=(--stringsdata "$file"); done < <(
    find "$intermediates" -path "*-iphonesimulator/$target.build/*" -name '*.stringsdata' -print0 | sort -z
  )
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "error: no .stringsdata for $target under $intermediates (build first)" >&2
    exit 1
  fi
  xcrun xcstringstool sync "$repo_root/$catalog" "${files[@]}"
  echo "Synced $catalog from $(( ${#files[@]} / 2 )) source files"
}

sync_target Forumind Forumind/Localizable.xcstrings
sync_target ForumindShare ForumindShare/Localizable.xcstrings

python3 "$repo_root/scripts/i18n/check-catalogs.py"
