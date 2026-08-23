# OpenCode local discovery

This slice is pinned to OpenCode commit `3a31c4ea801915c0b050df4b3842997ea62b6e93`.

## Advertised contract

`opencode serve --mdns` binds to `0.0.0.0` by default unless a host is configured. The default advertised host is `opencode.local`. OpenCode publishes a Bonjour `_http._tcp` service named `opencode-{port}` with its actual port and TXT `path=/`.

Because `_http._tcp` is generic, BYOT filters the `opencode-` name prefix and validates the resolved TXT record instead of listing every local web service. The advertised hostname is not trusted for transport: BYOT selects a numeric address from the resolved Bonjour socket addresses and rejects the service unless that address is local.

Initial discovery treats both find and remove callbacks as browse-batch
boundaries. A removed pending service therefore cannot leave the search stuck.
Resolved services remain registered when a callback contains only nonlocal
addresses, allowing a later dual-stack callback to publish its local address.

## Transport boundary

- Manually entered profiles remain HTTPS-only.
- A profile created from a validated discovery record stores the resolved numeric address and carries an explicit local-HTTP eligibility flag.
- HTTP eligibility is limited to parsed loopback, link-local, and private/unique-local IP ranges. Hostname suffixes such as `.local` are not sufficient.
- Redirects must preserve the original scheme, host, and effective port before credentials are restored.
- The app declares `_http._tcp`, a local-network usage description, and `NSAllowsLocalNetworking`. It does not enable arbitrary HTTP loads.

Discovery records, endpoint resolution, profile policy, browser lifecycle, and SwiftUI selection are separate components so deterministic tests do not depend on multicast traffic.
