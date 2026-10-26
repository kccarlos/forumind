#!/usr/bin/env bash
# Write an ExportOptions.plist for an App Store Connect (TestFlight) export.
# Usage: write-export-options.sh <output.plist>
# Env:   DEVELOPMENT_TEAM (required: the Apple Developer Team ID)
#        PROFILE_APP, PROFILE_SHARE (required: App Store profile names; manual signing)
#        BUNDLE_ID_PREFIX (optional, default io.github.kccarlos.forumind)
set -euo pipefail

out="${1:?usage: write-export-options.sh <output.plist>}"
team="${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to the Apple Developer Team ID}"
profile_app="${PROFILE_APP:?set PROFILE_APP to the app App Store profile name}"
profile_share="${PROFILE_SHARE:?set PROFILE_SHARE to the share extension App Store profile name}"
prefix="${BUNDLE_ID_PREFIX:-io.github.kccarlos.forumind}"

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
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Apple Distribution</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>${prefix}</key>
    <string>${profile_app}</string>
    <key>${prefix}.share</key>
    <string>${profile_share}</string>
  </dict>
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
PLIST
plutil -lint "$out"
