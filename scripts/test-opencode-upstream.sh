#!/bin/bash
# Run from any directory. Requires Xcode, XcodeGen, npm, Python 3, and OpenSSL.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
run_root=$(mktemp -d /tmp/byot-upstream-e2e.XXXXXX)
tools_root=${BYOT_E2E_TOOLS:-/tmp/byot-upstream-e2e-tools}
derived_data=${BYOT_E2E_DERIVED_DATA:-$run_root/DerivedData}
fixture_pid=
simulator=
cleanup() {
  if [ -n "$fixture_pid" ]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  if [ -n "$simulator" ]; then
    xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
  fi
  echo "E2E evidence retained at $run_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "E2E run: $run_root"
mkdir -p "$tools_root"
if ! cmp -s "$repo/scripts/e2e/package-lock.json" "$tools_root/package-lock.json" ||
   [ ! -x "$tools_root/node_modules/.bin/opencode" ] || [ ! -x "$tools_root/node_modules/.bin/opencode2" ]; then
  cp "$repo/scripts/e2e/package.json" "$repo/scripts/e2e/package-lock.json" "$tools_root/"
  npm ci --prefix "$tools_root" --no-audit --no-fund
fi
python3 "$repo/scripts/e2e/fixtures.py" --root "$run_root" --tools "$tools_root" >"$run_root/fixtures.log" 2>&1 &
fixture_pid=$!
for ((attempt=0; attempt<180; attempt++)); do
  if [ -f "$run_root/ready.json" ]; then break; fi
  if ! kill -0 "$fixture_pid" 2>/dev/null; then cat "$run_root/fixtures.log"; exit 1; fi
  sleep 1
done
if [ ! -f "$run_root/ready.json" ]; then cat "$run_root/fixtures.log"; exit 1; fi
cat "$run_root/ready.json"
simulator=$(xcrun simctl create "BYOT Upstream E2E" "${BYOT_E2E_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}")
printf '%s\n' "$simulator" > "$run_root/simulator.txt"
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b >"$run_root/simulator.log" 2>&1
xcrun simctl keychain "$simulator" add-root-cert "$run_root/tls.crt"
xcrun simctl status_bar "$simulator" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl ui "$simulator" appearance light
cd "$repo"
xcodegen generate >"$run_root/generate.log"
# Keep signing enabled: the normal server editor saves passwords in Keychain.
xcodebuild build-for-testing -project BYOT.xcodeproj -scheme BYOT \
  -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "$derived_data" \
  >"$run_root/build.log" 2>&1
python3 - "$run_root" "$derived_data" <<'PY'
import json, plistlib, sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
products = Path(sys.argv[2]).resolve() / 'Build/Products'
source = next(products.glob('BYOT_*.xctestrun'))
data = plistlib.loads(source.read_bytes())
environment = {'BYOT_LIVE_ACCEPTANCE': '1', 'BYOT_LIVE_ROOT': str(root)}
versions = json.loads((root / 'ready.json').read_text())
environment.update({'BYOT_LIVE_V1_VERSION': versions['v1'], 'BYOT_LIVE_V2_VERSION': versions['v2']})
targets = [t for k, t in data.items() if k != '__xctestrun_metadata__']
if 'TestConfigurations' in data:
    targets = [t for config in data['TestConfigurations'] for t in config['TestTargets']]
for target in targets:
    target.setdefault('EnvironmentVariables', {}).update(environment)
(products / 'BYOT-live.xctestrun').write_bytes(plistlib.dumps(data))
PY
test_selection=("$@")
if [ ${#test_selection[@]} -eq 0 ]; then
  test_selection=(-only-testing:BYOTTests -only-testing:BYOTUITests/OpenCodeUpstreamLiveUITests)
fi
set +e
xcodebuild test-without-building -xctestrun "$derived_data/Build/Products/BYOT-live.xctestrun" \
  -destination "platform=iOS Simulator,id=$simulator" -parallel-testing-enabled NO \
  -resultBundlePath "$run_root/tests.xcresult" \
  "${test_selection[@]}" \
  >"$run_root/tests.log" 2>&1
test_status=$?
set -e
xcrun xcresulttool get test-results summary --path "$run_root/tests.xcresult" --compact >"$run_root/summary.json"
xcrun xcresulttool export attachments --path "$run_root/tests.xcresult" --output-path "$run_root/screenshots" >"$run_root/attachments.log"
cat "$run_root/summary.json"
python3 - "$run_root/summary.json" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
if summary.get('skippedTests', 0):
    sys.exit('Live acceptance requires zero skipped tests')
PY
exit "$test_status"
