# Mac mini to iPhone OpenCode connection runbook

BYOT supports the server authentication used by both OpenCode v1 and the
current OpenCode v2 beta: HTTP Basic authentication over HTTPS. The protocols
have different routes and response models, but they do not require different
authorization headers.

## Authentication contract

| Server mode | HTTP authorization | Username | Password source |
| --- | --- | --- | --- |
| OpenCode v1 `serve` | Basic | `opencode` by default | `OPENCODE_SERVER_PASSWORD` |
| OpenCode v2 plain `serve` | Basic | `opencode` by default | Explicit server password, or the password printed at startup by beta builds |
| OpenCode v2 managed service | Basic | `opencode` | Persistent private service password shown by `opencode2 pair` |

`OPENCODE_API_KEY` is a model-provider credential. It is consumed by the
OpenCode server when it calls a provider; it is not a BYOT server credential
and must not be entered as a Bearer token.

OpenCode's current v1 documentation defines `OPENCODE_SERVER_USERNAME` and
`OPENCODE_SERVER_PASSWORD` for `serve`. Some v2 beta builds also read the
legacy client variable `OPENCODE_PASSWORD`. Prefer the explicit server variable
for a manually managed server and use the pairing password for service mode.

## Option A: run a dedicated server

Keep the OpenCode listener on loopback and let Tailscale terminate HTTPS. Set a
long random password through a secret manager or launch agent rather than
committing it to a script.

```bash
OPENCODE_SERVER_USERNAME=opencode \
OPENCODE_SERVER_PASSWORD='replace-with-a-long-random-secret' \
opencode serve --hostname 127.0.0.1 --port 4096
```

For the v2 beta binary, use `opencode2 serve` with the same loopback and port
arguments. Capture the startup password if that build generates one instead of
using the explicit password.

## Option B: use the v2 managed service

Run the pairing command in a real terminal:

```bash
opencode2 pair
```

It starts or discovers the service and prints its URL, Basic-auth username, and
persistent pairing password. Store that password in BYOT. Do not substitute an
`OPENCODE_API_KEY`. If provider credentials change, restart the background
service separately; that rotation does not change BYOT's server password.

The service URL or port can change between beta implementations, so use the URL
printed by `pair` rather than assuming port 4096.

## Put HTTPS in front with Tailscale Serve

For a dedicated server on port 4096:

```bash
tailscale serve --bg http://127.0.0.1:4096
tailscale serve status
```

For managed v2 service mode, replace `4096` with the loopback port printed by
`opencode2 pair`. Tailscale Serve publishes an HTTPS `*.ts.net` URL inside the
tailnet and applies tailnet access controls. See the current
[Tailscale Serve command reference](https://tailscale.com/docs/reference/tailscale-cli/serve).

Use Serve, not Funnel: this coding server should not be public. BYOT rejects
plain HTTP and refuses credentials embedded in a URL.

## Configure BYOT

1. Add the HTTPS URL printed by Tailscale Serve, without a username or password
   in the URL.
2. Enter `opencode`, unless the server was started with a custom
   `OPENCODE_SERVER_USERNAME`.
3. Enter the dedicated-server password or the v2 pairing password.
4. Tap **Test connection**, review the detected protocol, then save.

BYOT stores the password in the iOS Keychain and sends the same Basic header on
same-origin redirects and event-stream requests. It never sends credentials to
a different host, port, scheme, or plain-HTTP redirect.

## Verify and troubleshoot

The app's connection test is the preferred verification because it probes both
protocol health routes. Command-line checks are also useful:

```bash
curl --fail --user 'opencode:your-server-password' \
  https://your-mac.your-tailnet.ts.net/global/health

curl --fail --user 'opencode:your-server-password' \
  https://your-mac.your-tailnet.ts.net/api/health
```

The v1 route is `/global/health`; current v2 betas use `/api/health`. A `401`
means the server username or password is wrong. An HTML response usually means
the requested route belongs to the other protocol or a reverse proxy is
serving a web fallback. A network error should be checked with `tailscale serve
status`, the OpenCode process, and the exact loopback target port.
