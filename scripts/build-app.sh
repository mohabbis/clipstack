#!/usr/bin/env bash
# Builds Clipstack.app from the Swift package: a release build of the executable, wrapped in an
# app bundle with Info.plist, then ad-hoc signed with the App Sandbox entitlement.
#
#   scripts/build-app.sh             # native architecture, ad-hoc signature
#   UNIVERSAL=1 scripts/build-app.sh # arm64 + x86_64
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# Notarize when an App Store Connect API key is set (removes the Gatekeeper
# "Not Opened" dialog for people who download the zip):
#   APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, APPLE_API_KEY_PATH
# or an Apple ID app-specific password:
#   APPLE_ID, APPLE_APP_PASSWORD, APPLE_TEAM_ID
#
# Output: build/Clipstack.app and build/Clipstack.zip
set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: Clipstack.app can only be built on macOS (needs AppKit/SwiftUI)." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> Building release binary"
swift build -c release --product Clipstack ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --product Clipstack ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="$ROOT/build/Clipstack.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Clipstack" "$APP/Contents/MacOS/Clipstack"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${SIGN_IDENTITY:--}"
echo "==> Signing (identity: $IDENTITY)"
# Ad-hoc signatures cannot take a secure timestamp. Developer ID notarization requires one.
TIMESTAMP_ARGS=(--timestamp=none)
if [[ "$IDENTITY" != "-" ]]; then
  TIMESTAMP_ARGS=(--timestamp)
fi
codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" \
  --entitlements "$ROOT/Resources/Clipstack.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

# Zip for distribution. ditto keeps the bundle's signature and extended attributes intact.
ZIP="$ROOT/build/Clipstack.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

notarize() {
  if [[ "$IDENTITY" == "-" ]]; then
    echo "error: notarization needs SIGN_IDENTITY set to a Developer ID Application certificate." >&2
    exit 1
  fi
  echo "==> Submitting for notarization"
  if [[ -n "${APPLE_API_KEY_ID:-}" ]]; then
    : "${APPLE_API_ISSUER_ID:?set APPLE_API_ISSUER_ID}"
    : "${APPLE_API_KEY_PATH:?set APPLE_API_KEY_PATH to the AuthKey .p8 file}"
    xcrun notarytool submit "$ZIP" --wait \
      --key "$APPLE_API_KEY_PATH" \
      --key-id "$APPLE_API_KEY_ID" \
      --issuer "$APPLE_API_ISSUER_ID"
  elif [[ -n "${APPLE_ID:-}" ]]; then
    : "${APPLE_APP_PASSWORD:?set APPLE_APP_PASSWORD}"
    : "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"
    xcrun notarytool submit "$ZIP" --wait \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_PASSWORD" \
      --team-id "$APPLE_TEAM_ID"
  else
    return 0
  fi
  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  echo "==> Notarized: $ZIP"
}

if [[ -n "${APPLE_API_KEY_ID:-}${APPLE_ID:-}" ]]; then
  notarize
fi

echo "==> Done: $APP"
echo "    Run it with: open \"$APP\""
echo "    Release asset: $ZIP (upload to a GitHub release as 'Clipstack.zip')"
