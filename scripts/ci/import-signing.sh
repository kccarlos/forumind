#!/usr/bin/env bash
# Prepare code-signing material on a CI runner.
#
# Always (required):
#   APP_STORE_CONNECT_API_KEY_ID, APP_STORE_CONNECT_API_KEY_P8_BASE64
#     -> writes ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8 (the location
#        altool searches) and exports ASC_KEY_PATH to $GITHUB_ENV.
# Optional:
#   APPLE_CERTIFICATE_P12_BASE64 + APPLE_CERTIFICATE_PASSWORD
#     -> imported into a temporary keychain that is added to the search list.
#   APPLE_PROVISIONING_PROFILES_BASE64
#     -> base64 of a single .mobileprovision, or of a .zip / .tar.gz of them;
#        installed where Xcode looks for profiles.
#
# Cleanup: scripts/ci/cleanup-signing.sh (run with `if: always()`).
set -euo pipefail

: "${APP_STORE_CONNECT_API_KEY_ID:?missing}"
: "${APP_STORE_CONNECT_API_KEY_P8_BASE64:?missing}"
runner_temp="${RUNNER_TEMP:-$(mktemp -d)}"

# --- App Store Connect API key -------------------------------------------
key_dir="$HOME/.appstoreconnect/private_keys"
mkdir -p "$key_dir"
key_path="$key_dir/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
printf '%s' "$APP_STORE_CONNECT_API_KEY_P8_BASE64" | base64 --decode >"$key_path"
chmod 600 "$key_path"
echo "App Store Connect API key written to $key_path"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "ASC_KEY_PATH=$key_path" >>"$GITHUB_ENV"
fi

# --- Distribution certificate (optional) ---------------------------------
if [[ -n "${APPLE_CERTIFICATE_P12_BASE64:-}" ]]; then
  keychain="$runner_temp/ci-signing.keychain-db"
  keychain_password="$(uuidgen)"
  p12="$runner_temp/cert.p12"
  printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode >"$p12"

  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  security import "$p12" -P "${APPLE_CERTIFICATE_PASSWORD:-}" -A -t cert -f pkcs12 -k "$keychain"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
  # Prepend to the user search list so codesign/xcodebuild find the identity.
  # shellcheck disable=SC2046
  security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
  rm -f "$p12"
  echo "Imported signing identities:"
  security find-identity -v -p codesigning "$keychain"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "CI_KEYCHAIN=$keychain" >>"$GITHUB_ENV"
  fi
else
  echo "::notice::APPLE_CERTIFICATE_P12_BASE64 not set; relying on automatic signing to supply a distribution certificate."
fi

# --- Provisioning profiles (optional) ------------------------------------
if [[ -n "${APPLE_PROVISIONING_PROFILES_BASE64:-}" ]]; then
  blob="$runner_temp/profiles.bin"
  unpack="$runner_temp/profiles"
  mkdir -p "$unpack"
  printf '%s' "$APPLE_PROVISIONING_PROFILES_BASE64" | base64 --decode >"$blob"
  case "$(file -b "$blob")" in
    Zip*) unzip -q -o "$blob" -d "$unpack" ;;
    gzip*|POSIX\ tar*) tar -xzf "$blob" -C "$unpack" 2>/dev/null || tar -xf "$blob" -C "$unpack" ;;
    *) cp "$blob" "$unpack/profile.mobileprovision" ;;
  esac
  # Xcode 16+ reads UserData; older tooling reads MobileDevice. Install to both.
  for dest in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
              "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    mkdir -p "$dest"
    find "$unpack" -name '*.mobileprovision' -print0 |
      while IFS= read -r -d '' profile; do
        uuid="$(security cms -D -i "$profile" | plutil -extract UUID raw -)"
        cp "$profile" "$dest/$uuid.mobileprovision"
        echo "Installed profile $uuid -> $dest"
      done
  done
  rm -rf "$blob" "$unpack"
fi
