#!/usr/bin/env bash
# Refresh the bundled ad/tracker blocking rules.
#
#   scripts/adblock/update_rules.sh [--include-site-cosmetics] [--force]
#
# Downloads EasyList + EasyPrivacy, converts them to WebKit content-blocker
# JSON with Brave's adblock-rust (pinned in converter/Cargo.lock; built from
# crates.io, not vendored), then validates, de-duplicates and chunks the result
# into Forumind/ContentBlocking/ (manifest.json, ads-N.json,
# privacy-N.json, ATTRIBUTION.md). Leaves the directory untouched when the
# rules did not change. Extra arguments are passed to build_rules.py.
#
# Requires: curl, cargo (Rust 1.80+), python3. See docs/AD_BLOCKING.md.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
out_dir="${CONTENT_BLOCKING_DIR:-$repo_root/Forumind/ContentBlocking}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

lists=(
  "easylist https://easylist.to/easylist/easylist.txt"
  "easyprivacy https://easylist.to/easylist/easyprivacy.txt"
)

echo "==> Building converter"
cargo build --release --locked --quiet --manifest-path "$here/converter/Cargo.toml"
converter="$here/converter/target/release/dc-adblock-converter"

for entry in "${lists[@]}"; do
  read -r stem url <<<"$entry"
  echo "==> Downloading $url"
  curl --fail --silent --show-error --location --retry 3 --max-time 120 \
    --output "$work/$stem.txt" "$url"
  # Sanity check: a real list has an ABP header and tens of thousands of lines.
  if ! head -n 1 "$work/$stem.txt" | grep -q '^\[Adblock Plus'; then
    echo "error: $url does not look like an Adblock Plus list" >&2
    exit 1
  fi
  lines="$(wc -l <"$work/$stem.txt" | tr -d ' ')"
  if ((lines < 10000)); then
    echo "error: $url has only $lines lines; refusing to continue" >&2
    exit 1
  fi
  grep -E '^! (Version|Last modified):' "$work/$stem.txt" | sed 's/^/    /' || true

  echo "==> Converting $stem"
  "$converter" "$work/$stem.txt" >"$work/$stem.json"
done

echo "==> Validating and writing $out_dir"
python3 "$here/build_rules.py" --input-dir "$work" --output-dir "$out_dir" "$@"
