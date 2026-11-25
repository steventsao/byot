#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="Debug"
OPEN_APP=0

for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="Release" ;;
    --open) OPEN_APP=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

echo "==> Generating BYOTDesktop.xcodeproj..."
xcodegen --spec "$ROOT_DIR/project.yml"

DERIVED="$ROOT_DIR/.build/DerivedData"
echo "==> Building BYOTDesktop ($CONFIG)..."
xcodebuild \
  -project "$ROOT_DIR/BYOTDesktop.xcodeproj" \
  -scheme BYOTDesktop \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$DERIVED/Build/Products/$CONFIG/byot.app"
echo "==> Built: $APP_PATH"
du -sh "$APP_PATH"

if [[ "$OPEN_APP" -eq 1 ]]; then
  echo "==> Launching $APP_PATH..."
  open "$APP_PATH"
fi
