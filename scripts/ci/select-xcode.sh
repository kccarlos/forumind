#!/usr/bin/env bash
# Select the Xcode given by $XCODE_APP (e.g. /Applications/Xcode_27.0.app).
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

sudo xcode-select -s "${xcode_app}/Contents/Developer"
xcodebuild -version
xcrun --sdk iphonesimulator --show-sdk-version
