#!/usr/bin/env bash
set -euo pipefail

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "not ok - required command is missing: $1" >&2
    exit 2
  }
}

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || {
    echo "not ok - required environment variable is missing: $name" >&2
    exit 2
  }
}

require_command curl
require_command python3
require_value OPENCODE_BASE_URL
require_value OPENCODE_PROTOCOL
require_value OPENCODE_PASSWORD
require_value OPENCODE_DIRECTORY

case "$OPENCODE_PROTOCOL" in
  v1|v2) ;;
  *)
    echo "not ok - OPENCODE_PROTOCOL must be v1 or v2" >&2
    exit 2
    ;;
esac

opencode_username="${OPENCODE_USERNAME:-opencode}"
opencode_allow_local_http="${OPENCODE_ALLOW_LOCAL_HTTP:-0}"
opencode_workspace="${OPENCODE_WORKSPACE:-}"

validated_base_url="$(python3 - "$OPENCODE_BASE_URL" "$opencode_allow_local_http" <<'PY'
import ipaddress
import sys
from urllib.parse import urlsplit, urlunsplit

raw, allow_local_http = sys.argv[1:3]
parts = urlsplit(raw.strip())
if not parts.scheme or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
    print("not ok - OPENCODE_BASE_URL must be an origin URL without credentials, query, or fragment", file=sys.stderr)
    raise SystemExit(2)

scheme = parts.scheme.lower()
host = parts.hostname.rstrip(".").lower()

def is_local(value):
    try:
        address = ipaddress.ip_address(value.split("%", 1)[0])
    except ValueError:
        return False
    packed = address.packed
    if address.version == 4:
        return (
            packed[0] == 10
            or packed[0] == 127
            or (packed[0] == 169 and packed[1] == 254)
            or (packed[0] == 172 and 16 <= packed[1] <= 31)
            or (packed[0] == 192 and packed[1] == 168)
        )
    is_loopback = packed[:-1] == bytes(15) and packed[-1] == 1
    is_link_local = packed[0] == 0xFE and packed[1] & 0xC0 == 0x80
    is_unique_local = packed[0] & 0xFE == 0xFC
    return is_loopback or is_link_local or is_unique_local

if scheme == "https":
    pass
elif scheme == "http" and allow_local_http == "1" and is_local(host):
    pass
elif scheme == "http" and allow_local_http == "1":
    print("not ok - plain HTTP is limited to a numeric local network address", file=sys.stderr)
    raise SystemExit(2)
else:
    print("not ok - use HTTPS, or explicitly allow HTTP for a numeric local network address", file=sys.stderr)
    raise SystemExit(2)

path = parts.path.rstrip("/")
print(urlunsplit((scheme, parts.netloc, path, "", "")))
PY
)"

urlencode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

acceptance_tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$acceptance_tmp"
}
trap cleanup EXIT

authorization="$(python3 - "$opencode_username" "$OPENCODE_PASSWORD" <<'PY'
import base64
import sys
print(base64.b64encode(f"{sys.argv[1]}:{sys.argv[2]}".encode()).decode())
PY
)"
curl_config="$acceptance_tmp/curl.conf"
{
  printf '%s\n' 'silent' 'show-error' 'globoff' 'connect-timeout = 10' 'max-time = 30'
  printf 'header = "Authorization: Basic %s"\n' "$authorization"
  printf '%s\n' 'header = "Accept: application/json"'
} >"$curl_config"
chmod 600 "$curl_config"
unset authorization

assert_json_shape() {
  local label="$1"
  local body_file="$2"
  local shape="$3"
  python3 - "$label" "$body_file" "$shape" <<'PY'
import json
import sys

label, path, shape = sys.argv[1:4]
try:
    with open(path, "rb") as body:
        value = json.load(body)
except Exception:
    print(f"not ok - {label} returned invalid JSON", file=sys.stderr)
    raise SystemExit(1)

valid = False
if shape == "v1_health":
    valid = (
        isinstance(value, dict)
        and value.get("healthy") is True
        and isinstance(value.get("version"), str)
        and bool(value["version"])
    )
elif shape == "health":
    valid = isinstance(value, dict) and value.get("healthy") is True
elif shape == "array":
    valid = isinstance(value, list)
elif shape == "v2_location":
    valid = (
        isinstance(value, dict)
        and isinstance(value.get("directory"), str)
        and isinstance(value.get("project"), dict)
        and isinstance(value["project"].get("id"), str)
        and isinstance(value["project"].get("directory"), str)
    )
elif shape == "v2_sessions":
    valid = (
        isinstance(value, dict)
        and isinstance(value.get("data"), list)
        and isinstance(value.get("cursor"), dict)
    )

if not valid:
    print(f"not ok - {label} returned an unexpected {shape} shape", file=sys.stderr)
    raise SystemExit(1)
PY
}

request_json() {
  local label="$1"
  local url="$2"
  local shape="$3"
  local body_file="$acceptance_tmp/response.json"
  local error_file="$acceptance_tmp/curl-error.log"
  local http_code
  if ! http_code="$(curl --config "$curl_config" --output "$body_file" --write-out '%{http_code}' "$url" 2>"$error_file")"; then
    echo "not ok - $label request failed" >&2
    return 1
  fi
  case "$http_code" in
    2??) ;;
    *)
      echo "not ok - $label returned HTTP $http_code" >&2
      return 1
      ;;
  esac
  assert_json_shape "$label" "$body_file" "$shape"
  echo "ok - $label"
}

encoded_directory="$(urlencode "$OPENCODE_DIRECTORY")"
encoded_workspace=""
if [[ -n "$opencode_workspace" ]]; then
  encoded_workspace="$(urlencode "$opencode_workspace")"
fi

if [[ "$OPENCODE_PROTOCOL" == "v1" ]]; then
  location_query="directory=$encoded_directory"
  request_json "v1 health" "$validated_base_url/global/health" v1_health
  request_json "v1 project list" "$validated_base_url/project?$location_query" array
  request_json "v1 session list" "$validated_base_url/session?$location_query&scope=project&roots=true&limit=100" array
else
  location_query="location%5Bdirectory%5D=$encoded_directory"
  if [[ -n "$encoded_workspace" ]]; then
    location_query="$location_query&location%5Bworkspace%5D=$encoded_workspace"
  fi
  request_json "v2 health" "$validated_base_url/api/health" health
  request_json "v2 location" "$validated_base_url/api/location?$location_query" v2_location
  request_json "v2 session list" "$validated_base_url/api/session?directory=$encoded_directory&limit=100&order=desc" v2_sessions
fi

echo "ok - $OPENCODE_PROTOCOL read-only acceptance complete"
