#!/usr/bin/env bash
# Print a byot pairing QR code for an OpenCode server, to scan in the app
# (Add server > Scan pairing code) or with the iPhone Camera.
#
#   scripts/byot-pair-qr.sh https://your-mac.example.ts.net
#   scripts/byot-pair-qr.sh --lan 4096          # http://<this computer's LAN IP>:4096
#   curl -fsSL https://raw.githubusercontent.com/steventsao/byot/main/scripts/byot-pair-qr.sh | bash -s -- <url>
#
# The payload format is documented in docs/features/server-pairing.md.
# Renders with `qrencode` when installed, otherwise with Core Image through
# `swift` on macOS, otherwise prints the link only.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: byot-pair-qr.sh [options] <server-url>
       byot-pair-qr.sh [options] --lan [port]

  <server-url>          The address your iPhone uses, e.g. https://mac.tail1234.ts.net
                        Plain http:// is accepted only for a local network IP address.
  --lan [port]          Use http://<this computer's LAN IP>:<port> (default port 4096).
                        Start OpenCode with --mdns or --hostname 0.0.0.0 so it listens on the LAN.
  -u, --username NAME   Server username (default: $OPENCODE_SERVER_USERNAME or "opencode").
  -d, --directory PATH  Working directory to open (optional).
  -n, --name NAME       Name shown in byot (default: this computer's name).
      --no-password     Leave the password out; byot asks for it after scanning.
      --link            Print only the byot://pair link, without a QR code.
  -h, --help            Show this help.

The password comes from $OPENCODE_SERVER_PASSWORD, or is asked for when unset.
The QR code contains the password: don't share screenshots of it.
USAGE
}

die() { printf 'byot-pair-qr: %s\n' "$1" >&2; exit 1; }

# Percent-encodes every byte except RFC 3986 unreserved characters. Works on
# the bytes of the UTF-8 string, so it is safe with macOS's bash 3.2.
urlencode() {
  local hex out="" byte code i
  hex=$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')
  for ((i = 0; i < ${#hex}; i += 2)); do
    byte=${hex:i:2}
    code=$((16#$byte))
    if { [ "$code" -ge 48 ] && [ "$code" -le 57 ]; } ||
       { [ "$code" -ge 65 ] && [ "$code" -le 90 ]; } ||
       { [ "$code" -ge 97 ] && [ "$code" -le 122 ]; } ||
       [ "$code" -eq 45 ] || [ "$code" -eq 46 ] || [ "$code" -eq 95 ] || [ "$code" -eq 126 ]; then
      out+=$(printf "\\x$byte")
    else
      out+="%$(printf '%s' "$byte" | tr '[:lower:]' '[:upper:]')"
    fi
  done
  printf '%s' "$out"
}

lan_address() {
  local address=""
  if command -v ipconfig >/dev/null 2>&1; then
    for interface in en0 en1 en2 en3; do
      address=$(ipconfig getifaddr "$interface" 2>/dev/null || true)
      [ -n "$address" ] && break
    done
  fi
  if [ -z "$address" ] && command -v hostname >/dev/null 2>&1; then
    address=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  printf '%s' "$address"
}

is_local_ip() {
  local host="$1"
  case "$host" in
    *%*) return 1 ;; # zone-scoped IPv6 (fe80::1%en0) can't be used in a URL on iOS
    \[::1\]|\[[Ff][CcDd]*\]|\[[Ff][Ee][89AaBb]*\]) return 0 ;; # IPv6 loopback, unique-local, link-local
    \[*\]) return 1 ;;
  esac
  [[ "$host" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  local a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
  [ "$a" -eq 10 ] || [ "$a" -eq 127 ] ||
    { [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; } ||
    { [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } ||
    { [ "$a" -eq 169 ] && [ "$b" -eq 254 ]; }
}

server_url=""
lan_port=""
username=${OPENCODE_SERVER_USERNAME:-opencode}
directory=""
name=""
include_password=1
link_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --lan)
      lan_port=4096
      if [ $# -gt 1 ] && [[ "$2" =~ ^[0-9]+$ ]]; then lan_port="$2"; shift; fi ;;
    -u|--username) [ $# -gt 1 ] || die "$1 needs a value"; username="$2"; shift ;;
    -d|--directory) [ $# -gt 1 ] || die "$1 needs a value"; directory="$2"; shift ;;
    -n|--name) [ $# -gt 1 ] || die "$1 needs a value"; name="$2"; shift ;;
    --no-password) include_password=0 ;;
    --link) link_only=1 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) [ -z "$server_url" ] || die "only one server URL is allowed"; server_url="$1" ;;
  esac
  shift
done

if [ -n "$lan_port" ]; then
  [ -z "$server_url" ] || die "use either a server URL or --lan, not both"
  address=$(lan_address)
  [ -n "$address" ] || die "couldn't find this computer's LAN address; pass the URL instead"
  server_url="http://$address:$lan_port"
fi
[ -n "$server_url" ] || { usage >&2; exit 1; }

server_url=${server_url%/}
case "$server_url" in
  https://?*) ;;
  http://?*)
    host=${server_url#http://}
    host=${host%%/*}
    case "$host" in \[*) host=${host%%]*}]; ;; *) host=${host%%:*} ;; esac
    is_local_ip "$host" ||
      die "byot uses plain HTTP only for a local network IP address. Use HTTPS (for example Tailscale Serve) or --lan."
    ;;
  *) die "the server URL must start with https:// (or http:// for a local network IP)" ;;
esac
case "$server_url" in *\?*|*\#*|*@*) die "the server URL can't contain a query, fragment, or credentials" ;; esac

if [ -z "$name" ]; then
  name=$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null || true)
fi

password=""
if [ "$include_password" -eq 1 ]; then
  password=${OPENCODE_SERVER_PASSWORD:-}
  if [ -z "$password" ] && (: </dev/tty) 2>/dev/null; then
    printf 'OpenCode server password (Enter to leave it out): ' >/dev/tty
    IFS= read -rs password </dev/tty || true
    printf '\n' >/dev/tty
  fi
fi

link="byot://pair?v=1&url=$(urlencode "$server_url")"
[ -n "$username" ] && link+="&username=$(urlencode "$username")"
[ -n "$password" ] && link+="&password=$(urlencode "$password")"
[ -n "$directory" ] && link+="&directory=$(urlencode "$directory")"
[ -n "$name" ] && link+="&name=$(urlencode "$name")"

if [ "$link_only" -eq 1 ]; then
  printf '%s\n' "$link"
  exit 0
fi

render_with_swift() {
  command -v swift >/dev/null 2>&1 && [ "$(uname -s)" = Darwin ] || return 1
  local script
  script=$(mktemp "${TMPDIR:-/tmp}/byot-pair-qr.XXXXXX")
  cat >"$script" <<'SWIFT'
import CoreImage
import Foundation
let message = CommandLine.arguments[1]
guard let filter = CIFilter(name: "CIQRCodeGenerator") else { exit(1) }
filter.setValue(Data(message.utf8), forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
guard let image = filter.outputImage else { exit(1) }
let size = Int(image.extent.width)
var pixels = [UInt8](repeating: 255, count: size * size)
let context = CIContext()
context.render(image, toBitmap: &pixels, rowBytes: size, bounds: image.extent,
               format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
let quiet = 2
func dark(_ x: Int, _ y: Int) -> Bool {
    let (mx, my) = (x - quiet, y - quiet)
    guard mx >= 0, my >= 0, mx < size, my < size else { return false }
    return pixels[my * size + mx] < 128
}
let total = size + quiet * 2
var output = ""
for y in stride(from: 0, to: total, by: 2) {
    output += "\u{1B}[30;107m"
    for x in 0..<total {
        switch (dark(x, y), dark(x, y + 1)) {
        case (true, true): output += "\u{2588}"
        case (true, false): output += "\u{2580}"
        case (false, true): output += "\u{2584}"
        case (false, false): output += " "
        }
    }
    output += "\u{1B}[0m\n"
}
print(output, terminator: "")
SWIFT
  swift "$script" "$link" 2>/dev/null
  local status=$?
  rm -f "$script"
  return $status
}

printf '\nScan with byot (Add server > Scan pairing code) or the iPhone Camera:\n\n'
if command -v qrencode >/dev/null 2>&1; then
  qrencode -t ANSIUTF8 -m 2 "$link"
elif ! render_with_swift; then
  printf 'No QR renderer found. Install qrencode (brew install qrencode), or paste this link in byot:\n\n'
  printf '%s\n' "$link"
fi
printf '\n%s\n' "Server: $server_url  User: $username"
if [ -n "$password" ]; then
  printf '%s\n' "This code contains the server password. Don't share it or leave it on screen."
else
  printf '%s\n' "No password included: byot will ask for it after scanning."
fi
