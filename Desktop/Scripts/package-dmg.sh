#!/usr/bin/env bash
set -euo pipefail

# Packages a small, direct-download macOS .dmg for BYOT Desktop.
#
# Usage:
#   ./Scripts/package-dmg.sh [--version 0.1.0-beta.1] [--sign] [--notarize]
#
# Environment overrides:
#   DEVELOPER_ID_APP="Developer ID Application: Name (TEAMID)"
#   NOTARYTOOL_PROFILE="byot-notary"
#   ASC_PRIVATE_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID (auto-read from ~/.asc/config.json when --notarize is passed)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="0.1.0-beta.1"
WANT_SIGN=0
WANT_NOTARIZE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --sign) WANT_SIGN=1; shift ;;
    --notarize) WANT_SIGN=1; WANT_NOTARIZE=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
  WANT_SIGN=1
fi
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  WANT_SIGN=1
  WANT_NOTARIZE=1
fi

if [[ "$WANT_SIGN" -eq 1 && -z "${DEVELOPER_ID_APP:-}" ]]; then
  DEVELOPER_ID_APP="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
  if [[ -z "$DEVELOPER_ID_APP" ]]; then
    echo "error: --sign requested but no Developer ID Application identity found in keychain." >&2
    exit 1
  fi
fi

echo "==> Generating BYOTDesktop.xcodeproj..."
xcodegen --spec "$ROOT_DIR/project.yml"

DERIVED="$ROOT_DIR/.build/DerivedData"
DIST="$ROOT_DIR/.build/dist"
rm -rf "$DIST"
mkdir -p "$DIST/stage"

SIGN_FLAGS=(CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO)
if [[ "$WANT_SIGN" -eq 1 ]]; then
  echo "==> Signing with: $DEVELOPER_ID_APP"
  SIGN_FLAGS=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APP"
    ENABLE_HARDENED_RUNTIME=YES
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"
  )
fi

xcodebuild \
  -project "$ROOT_DIR/BYOTDesktop.xcodeproj" \
  -scheme BYOTDesktop \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  "${SIGN_FLAGS[@]}" \
  build

APP_PATH="$DERIVED/Build/Products/Release/byot.app"
cp -R "$APP_PATH" "$DIST/stage/byot.app"

if [[ "$WANT_SIGN" -eq 1 ]]; then
  echo "==> Re-signing app bundle with Hardened Runtime + entitlements..."
  codesign \
    --force \
    --deep \
    --timestamp \
    --options runtime \
    --entitlements "$ROOT_DIR/Resources/BYOTDesktop.entitlements" \
    --sign "$DEVELOPER_ID_APP" \
    "$DIST/stage/byot.app"
  codesign --verify --deep --strict --verbose=2 "$DIST/stage/byot.app"
fi

ln -s /Applications "$DIST/stage/Applications"

DMG_NAME="BYOT-Desktop-${VERSION}-arm64.dmg"
DMG_PATH="$DIST/$DMG_NAME"
hdiutil create \
  -volname "byot" \
  -srcfolder "$DIST/stage" \
  -ov \
  -format ULFO \
  "$DMG_PATH"

if [[ "$WANT_SIGN" -eq 1 ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$DMG_PATH"
fi

if [[ "$WANT_NOTARIZE" -eq 1 ]]; then
  echo "==> Submitting $DMG_NAME to Apple Notary Service..."
  if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  elif command -v asc >/dev/null 2>&1; then
    asc notarization submit --file "$DMG_PATH" --wait
  else
    KEY_PATH="${ASC_PRIVATE_KEY_PATH:-}"
    KEY_PATH="${KEY_PATH/#\~/$HOME}"
    if [[ -z "$KEY_PATH" || ! -f "$KEY_PATH" || -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
      echo "error: --notarize requires asc, NOTARYTOOL_PROFILE, or ASC_PRIVATE_KEY_PATH + ASC_KEY_ID + ASC_ISSUER_ID." >&2
      exit 1
    fi
    xcrun notarytool submit "$DMG_PATH" --key "$KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
  fi
  echo "==> Stapling notarization ticket..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

(cd "$DIST" && shasum -a 256 "$DMG_NAME" > "${DMG_NAME}.sha256")

echo "==> Packaged DMG:"
ls -lh "$DMG_PATH" "${DMG_PATH}.sha256"
cat "${DMG_PATH}.sha256"
