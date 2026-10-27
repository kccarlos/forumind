#!/usr/bin/env bash
# Layering guard for the site-adapter layer: only Forumind/Sites/ may know a
# platform (dev/docs/SITE_ADAPTERS_PLAN.md §8.4). Fails when Swift code outside
# Forumind/Sites/ names a Discourse type or kind, or builds a `/t/` route.
#
# Existing offenders are listed in scripts/ci/site-layering-allowlist.txt as
# `path|trimmed source line`. The list may only shrink: a hit that is not in
# it fails the check, and so does an entry that no longer matches anything
# (delete it when the code moves). Comment-only lines are not scanned.
#
# Usage: scripts/ci/check-site-layering.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
allowlist="scripts/ci/site-layering-allowlist.txt"

# shellcheck disable=SC2016
pattern='DiscourseRoutes|DiscourseAPI|DiscourseParsing|DiscourseDOM|SiteKind\.discourse|\.discourse([^.[:alnum:]_]|$)|isDiscourse|/t/'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# path|trimmed line for every offending line outside Forumind/Sites/.
{ grep -rnE --include='*.swift' "$pattern" Forumind ForumindShare || true; } |
  { grep -v '^Forumind/Sites/' || true; } |
  sed -E 's/^([^:]+):[0-9]+:[[:space:]]*/\1|/' |
  { grep -vE '^[^|]+\|//' || true; } |
  LC_ALL=C sort -u >"$work/hits"

{ grep -vE '^[[:space:]]*(#|$)' "$allowlist" || true; } | LC_ALL=C sort -u >"$work/allowed"

LC_ALL=C comm -23 "$work/hits" "$work/allowed" >"$work/new"
LC_ALL=C comm -13 "$work/hits" "$work/allowed" >"$work/stale"

status=0
if [[ -s "$work/new" ]]; then
  echo "::error::Platform-specific code outside Forumind/Sites/ (use the site adapter instead):"
  sed 's/^/  /' "$work/new"
  status=1
fi
if [[ -s "$work/stale" ]]; then
  echo "::error::Stale entries in $allowlist (the code moved; delete them):"
  sed 's/^/  /' "$work/stale"
  status=1
fi
if [[ $status -eq 0 ]]; then
  echo "OK: $(wc -l <"$work/allowed" | tr -d ' ') allowlisted occurrences, none new, none stale"
fi
exit $status
