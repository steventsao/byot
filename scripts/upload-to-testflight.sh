#!/usr/bin/env bash
# Build + upload the BYOT iOS app to App Store Connect in one shot.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="${APP_NAME:-BYOT}"

if [ ! -f ~/dev/apikeys/.env ]; then
  echo "missing ~/dev/apikeys/.env — see the api-keys skill" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source ~/dev/apikeys/.env
set +a

for var in APP_STORE_CONNECT_KEY_PATH APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID; do
  if [ -z "${!var:-}" ]; then
    echo "missing $var in ~/dev/apikeys/.env" >&2
    exit 1
  fi
done

if [ ! -f "$APP_STORE_CONNECT_KEY_PATH" ]; then
  echo "missing key file at $APP_STORE_CONNECT_KEY_PATH" >&2
  exit 1
fi

echo "==> Archiving"
./scripts/archive-for-testflight.sh >/dev/null

ARCHIVE=$(ls -td "$HOME"/Library/Developer/Xcode/Archives/*/"${APP_NAME}"*.xcarchive | head -1)
echo "==> Archive: $ARCHIVE"

echo "==> Uploading to App Store Connect"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -authenticationKeyPath "$APP_STORE_CONNECT_KEY_PATH" \
  -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID" \
  -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID" \
  -allowProvisioningUpdates | tail -10

echo
echo "==> Done."
echo "    Next: appstoreconnect.apple.com → ${APP_NAME} → TestFlight"
echo "    Wait ~5-15 min for Apple to process the build, then add testers."