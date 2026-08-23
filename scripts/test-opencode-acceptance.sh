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
  python3 "$fixture" "$protocol" "$port_file" opencode test-secret &
  pids+=("$!")
  for _ in {1..100}; do
    [[ -s "$port_file" ]] && break
    sleep 0.02
  done
  [[ -s "$port_file" ]] || fail "$protocol mock started"
  cat "$port_file"
}

v1_port="$(start_mock v1)"
v2_port="$(start_mock v2)"

OPENCODE_BASE_URL="http://127.0.0.1:$v1_port" \
OPENCODE_PROTOCOL=v1 \
OPENCODE_USERNAME=opencode \
OPENCODE_PASSWORD=test-secret \
OPENCODE_DIRECTORY=/repo \
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
   OPENCODE_ALLOW_LOCAL_HTTP=1 \
     "$harness" >"$acceptance_test_tmp/public-http.out" 2>&1; then
  fail "public HTTP must fail before a request"
fi
grep -q "local network" "$acceptance_test_tmp/public-http.out" || fail "public HTTP failure explains local policy"

echo "ok - dual-stack acceptance harness self-test"
