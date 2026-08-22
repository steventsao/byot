# OpenCode session lifecycle contract

Issue #2 is implemented against OpenCode commit
[`3a31c4ea`](https://github.com/anomalyco/opencode/commit/3a31c4ea801915c0b050df4b3842997ea62b6e93)
and its
[`packages/sdk/openapi.json`](https://github.com/anomalyco/opencode/blob/3a31c4ea801915c0b050df4b3842997ea62b6e93/packages/sdk/openapi.json).

## Protocol matrix

| Operation | v1 | v2 |
| --- | --- | --- |
| Get one session | `GET /session/{sessionID}` | `GET /api/session/{sessionID}` |
| Rename | `PATCH /session/{sessionID}` with `{ "title": String }` | Not exposed |
| Delete | `DELETE /session/{sessionID}` | Not exposed |
| List child sessions | `GET /session/{sessionID}/children` | Not exposed |
| Stop active execution | `POST /session/{sessionID}/abort` | `POST /api/session/{sessionID}/interrupt` |

V1 lifecycle calls include the detected instance's `directory` and optional
`workspace` query parameters. V2 get and interrupt are global ID routes and do
not send location query parameters. V2 session responses are normalized from
their `data` envelope.

`OpenCodeProtocolCapabilities` is the UI gate. Unsupported v2 mutations throw
`OpenCodeFeatureUnavailableError` before transport, so the client never probes
guessed rename, delete, or children routes.

## Mobile behavior

- Rename and destructive delete actions appear on a session row only for a
  protocol that advertises them. Updated responses replace the local row and
  retain its status; deletion removes both.
- Deletion requires explicit destructive confirmation and explains that the
  server removes messages and history permanently.
- A parent session exposes its v1 child/subagent sessions in a dedicated list;
  each child opens as a normal transcript. Pull-to-refresh reconciles additions.
- Active v1 and v2 sessions show a Stop control. A successful stop moves the
  local status to idle, pauses queued prompts rather than dispatching them
  accidentally, and refreshes the transcript. Failure preserves the active
  state and surfaces the server error.

Transport, capability, lifecycle-state, and stop-policy tests are independent
of SwiftUI. Views consume those components rather than choosing endpoint
families themselves.
