# Server pairing and nearby discovery

Adding a server no longer requires typing an address and password on the
phone. The server form (and the empty home screen) offers two shortcuts that
fill the form in; nothing is saved until Save, which still tests the server
first (#93, #10).

- **Scan pairing code** reads a QR code from the camera, from a photo, or from a
  pasted link.
- **Find nearby** lists OpenCode servers advertised on the local network by
  `opencode serve --mdns`.

## Pairing code format (v1)

A pairing code is a URL, usually shown as a QR code:

```
byot://pair?v=1&url=<server URL>&username=<name>&password=<password>&directory=<path>&name=<label>
```

| Field | Required | Meaning |
| --- | --- | --- |
| `v` | no | Format version. Only `1` exists; any other value is refused with "needs a newer version of byot". |
| `url` | yes | Server address the phone uses. `https://`, or `http://` only for a numeric local-network IP (see below). No query, fragment, or credentials; a trailing `/` is ignored. |
| `username` | no | Basic-auth user. Defaults to `opencode`, like `OPENCODE_SERVER_USERNAME`. |
| `password` | no | Basic-auth password (`OPENCODE_SERVER_PASSWORD`). When absent, byot asks for it. |
| `directory` | no | Working directory to open. Blank lists the server's known projects. |
| `name` | no | Label for the server in byot. Defaults to the host's first label, or "OpenCode (IP)". |

- Values are percent-encoded UTF-8. Encode everything outside `A-Z a-z 0-9 - . _ ~`;
  `+` is a literal plus, not a space.
- Unknown fields are ignored and the first occurrence of a field wins, so later
  versions can add fields.
- `byot:pair?...` (without `//`) is accepted too.
- A bare `https://host` (optionally `https://user:password@host`) or a local
  `http://` address also works as a code, so any QR generator can be used.

The `byot` URL scheme is registered, so scanning the code with the iPhone
Camera app opens byot with the form filled in. Links are only ever used to
fill the form: they never save, and byot doesn't contact the server until Test
connection or Save, with a note asking to check the address first. A code
scanned inside byot tests the connection right away when it carries a password.

A pairing code with a password is a credential. The helper warns about this,
and the phone keeps the password only in the Keychain after Save.

### Re-pairing

If the code's address (scheme, host, port, path) matches a saved server, the
form edits that server instead of adding a duplicate, so scanning a new code
after changing the password updates it. A saved password or directory is only
reused for the same address, never sent to a different one.

## Helper script

`scripts/byot-pair-qr.sh` prints the code in the terminal of the computer that
runs OpenCode:

```bash
# HTTPS address, e.g. from `tailscale serve`
OPENCODE_SERVER_PASSWORD=… scripts/byot-pair-qr.sh https://mac.tail1234.ts.net

# This computer's LAN address over plain HTTP (OpenCode must listen on the LAN)
OPENCODE_SERVER_PASSWORD=… scripts/byot-pair-qr.sh --lan 4096

# Without the repo
curl -fsSL https://raw.githubusercontent.com/steventsao/byot/main/scripts/byot-pair-qr.sh | bash -s -- https://mac.tail1234.ts.net
```

Options: `-u/--username`, `-d/--directory`, `-n/--name` (defaults to the
computer name), `--no-password`, and `--link` to print only the link. The
password comes from `OPENCODE_SERVER_PASSWORD` or a hidden prompt. The script
renders with `qrencode` when installed, otherwise with Core Image through
`swift` on macOS, otherwise it prints the link to paste.

## Nearby discovery

Pinned to upstream `packages/opencode/src/server/mdns.ts`: with `--mdns`
(or `server.mdns` in config) OpenCode listens on `0.0.0.0` unless a hostname is
set, and publishes a Bonjour `_http._tcp` service named `opencode-{port}` on
host `opencode.local` (`--mdns-domain` changes it), with the real port and TXT
`path=/`. A loopback hostname skips publishing.

- `_http._tcp` is generic, so byot keeps only `opencode-` names with a valid
  TXT `path`.
- The advertised hostname is never used for transport. byot takes a numeric
  local address from the resolved socket addresses, IPv4 first; addresses that
  need an interface scope (`fe80::1%en0`) are skipped.
- A custom `--mdns-domain` such as `studio.local` names the row ("studio");
  the default shows "OpenCode on port 4096".
- The first search settles after the browse batch and each service's
  resolution finish (or after a second with nothing found). Browsing continues
  while the page is open, so servers that appear later are added and removed
  live. Callbacks from a stopped or replaced browse are ignored.
- Choosing a server fills the name and address and moves to the password
  field; OpenCode requires `OPENCODE_SERVER_PASSWORD` for byot.

## Transport policy

- Addresses typed into the form stay HTTPS-only.
- Profiles filled from a nearby server or a local `http://` pairing code carry
  `allowsLocalHTTP`. Only those may use HTTP, and only to a parsed numeric
  loopback, link-local, or private address (10/8, 172.16/12, 192.168/16,
  169.254/16, 127/8, `::1`, `fe80::/10`, `fc00::/7`). Hostnames, including
  `.local`, never qualify. Older saved profiles decode as HTTPS-only.
- The form shows "Local network, not encrypted" for such a profile, because
  Basic-auth credentials and session content cross the network in clear text.
- Redirects keep credentials only for the exact original scheme, host, and
  port, so HTTPS never downgrades and local HTTP never leaves its host.
- Info.plist declares `NSAllowsLocalNetworking` (no arbitrary loads),
  `NSBonjourServices` `_http._tcp`, `NSLocalNetworkUsageDescription`,
  `NSCameraUsageDescription`, and the `byot` URL scheme.

## Permissions and fallbacks

- Camera access is requested when the scan page opens. If it is off, the page
  offers Settings; without a camera (or on the simulator) it explains that,
  and Choose from Photos and Paste still work.
- If browsing fails to start (for example Local Network access is off), Find
  nearby explains it and offers Settings and Try again. The empty state also
  points at the Local Network setting, since iOS can deny it silently.
- An unreadable or foreign code shows one error (announced to VoiceOver) and
  scanning continues; the same code is not reported twice.
