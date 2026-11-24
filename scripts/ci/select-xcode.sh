#!/usr/bin/env bash
# Select the Xcode given by $XCODE_APP (e.g. /Applications/Xcode_27.2.app).
# Falls back to the image default (/Applications/Xcode.app) with a warning
# so a runner image refresh doesn't hard-fail the job.
set -euo pipefail

xcode_app="${XCODE_APP:-/Applications/Xcode.app}"
if [[ ! -d "$xcode_app" ]]; then
  echo "::warning::${xcode_app} not found on this runner; using image default /Applications/Xcode.app"
  echo "Installed Xcodes:"
  ls -d /Applications/Xcode*.app || true
  xcode_app="/Applications/Xcode.app"
fi

# DEVELOPER_DIR instead of `sudo xcode-select -s`: the self-hosted runner
# has no passwordless sudo, and this leaves the machine's global choice alone.
export DEVELOPER_DIR="${xcode_app}/Contents/Developer"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "DEVELOPER_DIR=${DEVELOPER_DIR}" >>"$GITHUB_ENV"
fi
xcodebuild -version
xcrun --sdk iphonesimulator --show-sdk-version
