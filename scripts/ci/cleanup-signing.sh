#!/usr/bin/env bash
# Remove signing material created by import-signing.sh. Safe to run always.
set -euo pipefail

if [[ -n "${CI_KEYCHAIN:-}" && -f "$CI_KEYCHAIN" ]]; then
  security delete-keychain "$CI_KEYCHAIN" || true
fi
rm -rf "$HOME/.appstoreconnect/private_keys"
rm -f "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision \
      "$HOME/Library/MobileDevice/Provisioning Profiles/"*.mobileprovision 2>/dev/null || true
echo "Signing material cleaned up."
