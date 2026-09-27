#!/usr/bin/env bash
# Pick an available iPhone simulator and print an xcodebuild destination.
#
# Output: platform=iOS Simulator,id=<UDID>
#   - When $GITHUB_OUTPUT is set, also writes `destination=...`, `udid=...`,
#     `name=...`, `runtime=...` to it.
#
# Env:
#   SIM_EXCLUDE   Comma-separated device names to skip (e.g. "iPhone 17 Pro,iPhone 17").
#   SIM_PREFER    Comma-separated device names to prefer, in order (optional).
#
# Selection: newest iOS runtime first; within it SIM_PREFER order, then any
# non-excluded iPhone (sorted by name). UDIDs are used so renamed device
# types on new runner images don't break the job.
set -euo pipefail

json="$(xcrun simctl list -j devices available)"

result="$(SIM_JSON="$json" python3 - <<'PY'
import json, os, re, sys

data = json.loads(os.environ["SIM_JSON"])["devices"]
exclude = {s.strip() for s in os.environ.get("SIM_EXCLUDE", "").split(",") if s.strip()}
prefer = [s.strip() for s in os.environ.get("SIM_PREFER", "").split(",") if s.strip()]

def runtime_version(key):
    # com.apple.CoreSimulator.SimRuntime.iOS-27-0 -> (27, 0)
    m = re.search(r"SimRuntime\.iOS-([\d-]+)$", key)
    return tuple(int(p) for p in m.group(1).split("-")) if m else None

candidates = []
for key, devices in data.items():
    version = runtime_version(key)
    if version is None:
        continue
    for d in devices:
        if not d.get("isAvailable", False):
            continue
        name = d.get("name", "")
        if not name.startswith("iPhone") or name in exclude:
            continue
        rank = prefer.index(name) if name in prefer else len(prefer)
        candidates.append((tuple(-v for v in version), rank, name, d["udid"], ".".join(map(str, version))))

if not candidates:
    sys.exit("No available iPhone simulator found (after SIM_EXCLUDE).")

candidates.sort()
_, _, name, udid, runtime = candidates[0]
print(f"{udid}\t{name}\t{runtime}")
PY
)"

IFS=$'\t' read -r udid name runtime <<<"$result"
destination="platform=iOS Simulator,id=${udid}"

echo "Selected simulator: ${name} (iOS ${runtime}) ${udid}" >&2
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "destination=${destination}"
    echo "udid=${udid}"
    echo "name=${name}"
    echo "runtime=${runtime}"
  } >>"$GITHUB_OUTPUT"
fi
echo "$destination"
