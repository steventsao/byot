#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
harness="$script_dir/opencode-acceptance.sh"
fixture="$script_dir/fixtures/opencode_acceptance_mock.py"
acceptance_test_tmp="$(mktemp -d)"
pids=()

cleanup() {
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$acceptance_test_tmp"
}
trap cleanup EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

[[ -x "$harness" ]] || fail "acceptance harness is executable"
[[ -f "$fixture" ]] || fail "acceptance mock fixture exists"

start_mock() {
  local protocol="$1"
  local port_file="$acceptance_test_tmp/$protocol.port"
  python3 -u "$fixture" "$protocol" "$port_file" opencode test-secret \
    >"$acceptance_test_tmp/$protocol.mock.log" 2>&1 &
  local mock_pid="$!"
  pids+=("$mock_pid")
  for _ in {1..300}; do
    [[ -s "$port_file" ]] && break
    if ! kill -0 "$mock_pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if [[ ! -s "$port_file" ]]; then
    sed 's/^/mock: /' "$acceptance_test_tmp/$protocol.mock.log" >&2 || true
    fail "$protocol mock started"
  fi
  cat "$port_file"
}

v1_port="$(start_mock v1)"
v2_port="$(start_mock v2)"
v1_no_version_port="$(start_mock v1-no-version)"

OPENCODE_BASE_URL="http://127.0.0.1:$v1_port" \
OPENCODE_PROTOCOL=v1 \
OPENCODE_USERNAME=opencode \
OPENCODE_PASSWORD=test-secret \
OPENCODE_DIRECTORY=/repo \
OPENCODE_WORKSPACE=workspace-that-v1-list-reads-must-ignore \
OPENCODE_ALLOW_LOCAL_HTTP=1 \
  "$harness" >"$acceptance_test_tmp/v1.out"
grep -q "ok - v1 health" "$acceptance_test_tmp/v1.out" || fail "v1 health was checked"
grep -q "ok - v1 session list" "$acceptance_test_tmp/v1.out" || fail "v1 sessions were checked"

OPENCODE_BASE_URL="http://127.0.0.1:$v2_port" \
OPENCODE_PROTOCOL=v2 \
OPENCODE_USERNAME=opencode \
OPENCODE_PASSWORD=test-secret \
OPENCODE_DIRECTORY=/repo \
OPENCODE_ALLOW_LOCAL_HTTP=1 \
  "$harness" >"$acceptance_test_tmp/v2.out"
grep -q "ok - v2 health" "$acceptance_test_tmp/v2.out" || fail "v2 health was checked"
grep -q "ok - v2 location" "$acceptance_test_tmp/v2.out" || fail "v2 location was checked"
grep -q "ok - v2 session list" "$acceptance_test_tmp/v2.out" || fail "v2 sessions were checked"

if OPENCODE_BASE_URL="http://127.0.0.1:$v1_port" \
   OPENCODE_PROTOCOL=v2 \
   OPENCODE_USERNAME=opencode \
   OPENCODE_PASSWORD=test-secret \
   OPENCODE_DIRECTORY=/repo \
   OPENCODE_ALLOW_LOCAL_HTTP=1 \
     "$harness" >"$acceptance_test_tmp/wrong-protocol.out" 2>&1; then
  fail "wrong protocol must fail"
fi
grep -q "v2 health" "$acceptance_test_tmp/wrong-protocol.out" || fail "wrong protocol failure is actionable"

if OPENCODE_BASE_URL=http://example.com \
   OPENCODE_PROTOCOL=v1 \
   OPENCODE_PASSWORD=test-secret \
   OPENCODE_DIRECTORY=/repo \
   OPENCODE_ALLOW_LOCAL_HTTP=1 \
     "$harness" >"$acceptance_test_tmp/public-http.out" 2>&1; then
  fail "public HTTP must fail before a request"
fi
grep -q "local network" "$acceptance_test_tmp/public-http.out" || fail "public HTTP failure explains local policy"

for spoofable_host in localhost opencode.local; do
  output_name="${spoofable_host//./-}-http.out"
  if OPENCODE_BASE_URL="http://$spoofable_host" \
     OPENCODE_PROTOCOL=v1 \
     OPENCODE_PASSWORD=test-secret \
     OPENCODE_DIRECTORY=/repo \
     OPENCODE_ALLOW_LOCAL_HTTP=1 \
       "$harness" >"$acceptance_test_tmp/$output_name" 2>&1; then
    fail "$spoofable_host HTTP must fail before a request"
  fi
  grep -q "numeric local network" "$acceptance_test_tmp/$output_name" \
    || fail "$spoofable_host failure explains the numeric-address policy"
done

if OPENCODE_BASE_URL="http://127.0.0.1:$v1_no_version_port" \
   OPENCODE_PROTOCOL=v1 \
   OPENCODE_USERNAME=opencode \
   OPENCODE_PASSWORD=test-secret \
   OPENCODE_DIRECTORY=/repo \
   OPENCODE_ALLOW_LOCAL_HTTP=1 \
     "$harness" >"$acceptance_test_tmp/v1-no-version.out" 2>&1; then
  fail "v1 health without a version must fail"
fi
grep -q "v1 health" "$acceptance_test_tmp/v1-no-version.out" || fail "missing v1 version failure is actionable"

fake_curl_dir="$acceptance_test_tmp/fake-curl"
mkdir -p "$fake_curl_dir"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "curl failed for %s\\n" "$*" >&2' \
  'exit 6' \
  >"$fake_curl_dir/curl"
chmod +x "$fake_curl_dir/curl"
sensitive_host="byot-sensitive-host.invalid"
if PATH="$fake_curl_dir:$PATH" \
   OPENCODE_BASE_URL="https://$sensitive_host" \
   OPENCODE_PROTOCOL=v1 \
   OPENCODE_PASSWORD=test-secret \
   OPENCODE_DIRECTORY=/repo \
     "$harness" >"$acceptance_test_tmp/curl-failure.out" 2>&1; then
  fail "curl connection failure must fail acceptance"
fi
if grep -q "$sensitive_host" "$acceptance_test_tmp/curl-failure.out"; then
  fail "curl connection failure must not print the server host"
fi
grep -q "v1 health request failed" "$acceptance_test_tmp/curl-failure.out" || fail "curl failure is actionable"

echo "ok - dual-stack acceptance harness self-test"
