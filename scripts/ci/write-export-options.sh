#!/usr/bin/env bash
# Write an ExportOptions.plist for an App Store Connect (TestFlight) export.
# Usage: write-export-options.sh <output.plist>
# Env:   DEVELOPMENT_TEAM (required: the Apple Developer Team ID)
set -euo pipefail

out="${1:?usage: write-export-options.sh <output.plist>}"
team="${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to the Apple Developer Team ID}"

cat >"$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>teamID</key>
  <string>${team}</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
PLIST
plutil -lint "$out"
