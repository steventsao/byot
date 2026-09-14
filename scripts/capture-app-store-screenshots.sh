#!/usr/bin/env bash
# Render the App Store and README screenshot sets from the deterministic
# --app-store-screenshots fixture, one simulator per App Store display size.
#   scripts/capture-app-store-screenshots.sh                 # every set
#   scripts/capture-app-store-screenshots.sh iphone-6.9      # one set
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
output=${BYOT_SCREENSHOT_OUTPUT:-$repo/docs/app-store/screenshots/en-US}
appearance=${BYOT_SCREENSHOT_APPEARANCE:-dark}
run_root=$(mktemp -d /tmp/byot-app-store-screenshots.XXXXXX)
derived_data=${BYOT_UI_DERIVED_DATA:-$run_root/DerivedData}
simulator=
cleanup() {
  if [[ -n "$simulator" ]]; then
    xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
  fi
  echo "Screenshot evidence retained at $run_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# App Store Connect checks pixel size, not the simulator name.
device_for() {
  case "$1" in
    iphone-6.9) echo "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max 1320 2868" ;;
    ipad-13) echo "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB 2064 2752" ;;
    ipad-12.9) echo "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-12-9-inch-6th-generation-8GB 2048 2732" ;;
    *) echo "Unknown screenshot set: $1" >&2; return 1 ;;
  esac
}

sets=("$@")
if [[ ${#sets[@]} -eq 0 ]]; then
  sets=(iphone-6.9 ipad-13 ipad-12.9)
fi
cd "$repo"
xcodegen generate > "$run_root/generate.log"
for set in "${sets[@]}"; do
  read -r device_type width height < <(device_for "$set")
  echo "Capturing $set on $device_type"
  simulator=$(xcrun simctl create "BYOT Screenshots $set" "$device_type")
  xcrun simctl boot "$simulator"
  xcrun simctl bootstatus "$simulator" -b > "$run_root/$set-simulator.log" 2>&1
  xcrun simctl ui "$simulator" appearance "$appearance"
  xcrun simctl status_bar "$simulator" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  if ! xcodebuild test -project BYOT.xcodeproj -scheme BYOT \
    -jobs "${BYOT_XCODE_JOBS:-2}" \
    -destination "platform=iOS Simulator,id=$simulator" \
    -derivedDataPath "$derived_data" \
    -parallel-testing-enabled NO -resultBundlePath "$run_root/$set.xcresult" \
    -only-testing:BYOTUITests/AppStoreScreenshotUITests \
    > "$run_root/$set-tests.log" 2>&1; then
    tail -40 "$run_root/$set-tests.log"
    exit 1
  fi
  xcrun xcresulttool export attachments --path "$run_root/$set.xcresult" --output-path "$run_root/$set" > "$run_root/$set-attachments.log"
  python3 - "$run_root/$set" "$output/$set" "$width" "$height" <<'PY'
import json, re, shutil, subprocess, sys
from pathlib import Path
source, target, width, height = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
target.mkdir(parents=True, exist_ok=True)
for test in json.loads((source / "manifest.json").read_text()):
    for attachment in test["attachments"]:
        name = re.sub(r"_\d+_[0-9A-Fa-f-]+\.png$", ".png", attachment["suggestedHumanReadableName"])
        image = source / attachment["exportedFileName"]
        size = subprocess.check_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(image)], text=True).split()
        if [size[-3], size[-1]] != [width, height]:
            sys.exit(f"{name} is {size[-3]}x{size[-1]}, expected {width}x{height}")
        shutil.copyfile(image, target / name)
        print(target / name)
PY
  xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
  xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
  simulator=
done
