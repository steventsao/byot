#!/usr/bin/env bash
# Archive the BYOT iOS app for TestFlight. Companion to upload-to-testflight.sh.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="${APP_NAME:-BYOT}"
PRODUCT_NAME="${PRODUCT_NAME:-byot}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-449BD89VDV}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. brew install xcodegen" >&2
  exit 1
fi

echo "==> Regenerating Xcode project from project.yml"
xcodegen generate >/dev/null

BUILD_DIR="scripts/build-out"
ARCHIVE_PATH="$BUILD_DIR/${APP_NAME}.xcarchive"
rm -rf "$ARCHIVE_PATH" "$BUILD_DIR/ipa"
mkdir -p "$BUILD_DIR"

echo "==> Archiving (Release, generic iOS, automatic signing, team ${DEVELOPMENT_TEAM})"
xcodebuild \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  CODE_SIGN_STYLE=Automatic \
  archive | tail -5

TODAY=$(date +%Y-%m-%d)
STAMP=$(date "+%Y-%m-%d %H.%M")
DEST_DIR="$HOME/Library/Developer/Xcode/Archives/$TODAY"
mkdir -p "$DEST_DIR"
BUILD_NUM=$(plutil -extract CFBundleVersion raw "$ARCHIVE_PATH/Products/Applications/${PRODUCT_NAME}.app/Info.plist")
SHORT_VER=$(plutil -extract CFBundleShortVersionString raw "$ARCHIVE_PATH/Products/Applications/${PRODUCT_NAME}.app/Info.plist")
DEST_NAME="${APP_NAME} $SHORT_VER ($BUILD_NUM) $STAMP.xcarchive"
cp -R "$ARCHIVE_PATH" "$DEST_DIR/$DEST_NAME"

echo
echo "==> Archive ready: $DEST_DIR/$DEST_NAME"
echo "    Version: $SHORT_VER ($BUILD_NUM)"