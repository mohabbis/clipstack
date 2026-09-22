#!/usr/bin/env bash
# Builds Clipstack.app from the Swift package: a release build of the executable, wrapped in an
# app bundle with Info.plist, then ad-hoc signed with the App Sandbox entitlement.
#
#   scripts/build-app.sh             # native architecture
#   UNIVERSAL=1 scripts/build-app.sh # arm64 + x86_64
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# Output: build/Clipstack.app
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
codesign --force --options runtime --timestamp=none \
  --entitlements "$ROOT/Resources/Clipstack.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "==> Done: $APP"
echo "    Run it with: open \"$APP\""
