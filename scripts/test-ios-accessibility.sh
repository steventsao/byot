#!/usr/bin/env bash
# Run the milestone's appearance and Accessibility XXXL workflows serially.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
run_root=$(mktemp -d /tmp/byot-accessibility.XXXXXX)
simulator=
cleanup() {
  if [[ -n "$simulator" ]]; then
    xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
  fi
  echo "Accessibility evidence retained at $run_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "Accessibility run: $run_root"
simulator=$(xcrun simctl create "BYOT Accessibility" "${BYOT_UI_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}")
printf '%s\n' "$simulator" > "$run_root/simulator.txt"
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b > "$run_root/simulator.log" 2>&1
xcrun simctl ui "$simulator" appearance light
xcrun simctl status_bar "$simulator" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
cd "$repo"
xcodegen generate > "$run_root/generate.log"
set +e
xcodebuild test -project BYOT.xcodeproj -scheme BYOT \
  -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath "${BYOT_UI_DERIVED_DATA:-$run_root/DerivedData}" \
  -parallel-testing-enabled NO -resultBundlePath "$run_root/tests.xcresult" \
  -only-testing:BYOTTests/BYOTAppearanceTests \
  -only-testing:BYOTUITests/BYOTAppearanceUITests \
  -only-testing:BYOTUITests/OpenCodeAttachmentUITests \
  -only-testing:BYOTUITests/OpenCodeSessionBrowserUITests/testLargeTypeSearchAndServerBar \
  > "$run_root/tests.log" 2>&1
result=$?
set -e
xcrun xcresulttool get test-results summary --path "$run_root/tests.xcresult" --compact > "$run_root/summary.json"
xcrun xcresulttool export attachments --path "$run_root/tests.xcresult" --output-path "$run_root/screenshots" > "$run_root/attachments.log"
cat "$run_root/summary.json"
exit "$result"
