# OpenCode local discovery

This slice is pinned to OpenCode commit `3a31c4ea801915c0b050df4b3842997ea62b6e93`.

## Advertised contract

`opencode serve --mdns` binds to `0.0.0.0` by default unless a host is configured. The default advertised host is `opencode.local`. OpenCode publishes a Bonjour `_http._tcp` service named `opencode-{port}` with its actual port and TXT `path=/`.

Because `_http._tcp` is generic, BYOT filters the `opencode-` name prefix and validates the resolved TXT record instead of listing every local web service.

## Transport boundary

- Manually entered profiles remain HTTPS-only.
- A profile created from a validated discovery record carries an explicit local-HTTP eligibility flag.
- HTTP eligibility is limited to `.local`, localhost, loopback, link-local, and private/unique-local IP ranges.
- Redirects must preserve the original scheme, host, and effective port before credentials are restored.
- The app declares `_http._tcp`, a local-network usage description, and `NSAllowsLocalNetworking`. It does not enable arbitrary HTTP loads.

Discovery records, endpoint resolution, profile policy, browser lifecycle, and SwiftUI selection are separate components so deterministic tests do not depend on multicast traffic.
