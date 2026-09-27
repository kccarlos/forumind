#!/usr/bin/env bash
# Validate every tracked .plist / .entitlements / .xcprivacy property list.
# Uses plutil on macOS, Python's plistlib elsewhere (e.g. ubuntu runners).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

files=()
while IFS= read -r -d '' f; do
  [[ -f "$f" ]] && files+=("$f")
done < <(git ls-files -z -- '*.plist' '*.entitlements' '*.xcprivacy')

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No plist files found."
  exit 0
fi

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "${files[@]}"
else
  python3 - "${files[@]}" <<'PY'
import plistlib, sys
failed = False
for path in sys.argv[1:]:
    try:
        with open(path, "rb") as fh:
            plistlib.load(fh)
        print(f"{path}: OK")
    except Exception as exc:  # noqa: BLE001
        print(f"::error file={path}::invalid property list: {exc}")
        failed = True
sys.exit(1 if failed else 0)
PY
fi
