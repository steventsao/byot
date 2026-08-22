# OpenCode session sharing parity

This slice is pinned to OpenCode commit
`3a31c4ea801915c0b050df4b3842997ea62b6e93`.

## Protocol contract

- OpenCode v1 publishes with `POST /session/{sessionID}/share` and unpublishes
  with `DELETE /session/{sessionID}/share`.
- Both requests carry the normal `directory` and optional `workspace` location
  query and no request body.
- Both responses are the updated session. A public session includes
  `share: { "url": "..." }`; a private session omits `share`.
- The current OpenCode v2 `/api/session` protocol has no share or unshare
  operation. BYOT reports that capability as unavailable and does not probe a
  speculative route.

## Desktop and mobile state

OpenCode desktop separates publish, copy/view, and unpublish states. BYOT keeps
the same state machine in `OpenCodeSessionSharingStore`, behind an injectable
service, and renders it independently in `OpenCodeSessionSharingView`. The
published state uses SwiftUI `ShareLink` so iOS presents the native share sheet.
