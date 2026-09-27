#!/usr/bin/env bash
# Verify the committed Forumind.xcodeproj matches what
# scripts/generate_project.rb produces.
#
# The generator creates random object UUIDs on every run, so a plain
# `git diff --exit-code` would always fail. Instead the object graphs are
# dumped UUID-free (scripts/ci/xcodeproj-tree.rb) and diffed; scheme files
# are compared with BlueprintIdentifier lines stripped. Runs in a temporary copy of the repo: never touches the work tree.
#
# Requires: ruby with the `xcodeproj` gem.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
proj="Forumind.xcodeproj"
scheme_rel="xcshareddata/xcschemes/Forumind.xcscheme"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Copy tracked + untracked (non-ignored) files that exist on disk, so local
# runs see work-in-progress sources the generator would glob.
mkdir -p "$work/generated" "$work/committed"
(
  cd "$repo_root"
  git ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do if [[ -f "$f" ]]; then printf '%s\0' "$f"; fi; done |
    tar -cf - --null -T -
) | tar -xf - -C "$work/generated"
cp -R "$repo_root/$proj" "$work/committed/$proj"

# The committed project is generated with the defaults (no team, so no
# CloudKit or generated entitlements; default identifiers, build 1), so
# ignore any local overrides. Config/DevelopmentTeam.txt is git-ignored, so
# it is not copied into the temporary tree.
(cd "$work/generated" &&
  env -u DEVELOPMENT_TEAM -u BUNDLE_ID_PREFIX -u BUILD_NUMBER -u DC_ENABLE_PCC -u DC_ENABLE_CLOUDKIT ruby scripts/generate_project.rb >/dev/null)

status=0
echo "== project.pbxproj (object graph, UUIDs ignored)"
tree="$repo_root/scripts/ci/xcodeproj-tree.rb"
ruby "$tree" "$work/committed/$proj" >"$work/committed.json"
ruby "$tree" "$work/generated/$proj" >"$work/generated.json"
if diff -u "$work/committed.json" "$work/generated.json" \
    --label "committed/project.pbxproj" --label "generated/project.pbxproj"; then
  echo "OK: project.pbxproj matches generator output"
else
  status=1
fi

echo "== $scheme_rel"
strip_ids() { sed -E '/BlueprintIdentifier = /d' "$1"; }
if [[ -f "$work/committed/$proj/$scheme_rel" && -f "$work/generated/$proj/$scheme_rel" ]] &&
   diff -u <(strip_ids "$work/committed/$proj/$scheme_rel") <(strip_ids "$work/generated/$proj/$scheme_rel") \
     --label "committed/scheme" --label "generated/scheme"; then
  echo "OK: scheme matches generator output"
else
  status=1
fi

if [[ $status -ne 0 ]]; then
  echo
  echo "::error::Forumind.xcodeproj is out of date. Run 'ruby scripts/generate_project.rb' and commit the result."
fi
exit $status
