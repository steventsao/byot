# OpenCode v2 mobile surface decision

This decision closes issue #17 against OpenCode commit
[`3a31c4ea`](https://github.com/anomalyco/opencode/commit/3a31c4ea801915c0b050df4b3842997ea62b6e93).
The source of truth is that commit's
[`packages/sdk/openapi.json`](https://github.com/anomalyco/opencode/blob/3a31c4ea801915c0b050df4b3842997ea62b6e93/packages/sdk/openapi.json).

The product catalog lives in `OpenCodeV2MobileSurfaceCatalog`. Its tests make
route presence and mobile disposition independent from the transport adapter,
so a future endpoint can be evaluated before it reaches production code.

## Current decision

| Surface | Current v2 route | TestFlight decision |
| --- | --- | --- |
| PTY | `/api/pty` plus ID, token, and WebSocket routes | Defer. A complete client needs the short-lived, single-use ticket flow and terminal emulation. A process list or plain text log would be misleading terminal support. |
| Skills | `GET /api/skill` | No separate UI. OpenCode discovers and executes skills on the server; the existing session experience already receives their effects. |
| Integrations | `/api/integration` and connection routes | Adopt through issue #7, alongside provider authentication, rather than create a competing credentials flow. |
| Shell | None | Do not call. It is absent from the pinned schema. |
| Worktree | None | Do not call. It is absent from the pinned schema. |
| Web search | None | Do not call. It is absent from the pinned schema. |
| One-shot generate | None | Do not call. It is absent from the pinned schema. |

PTY is deliberately not described as supported merely because its REST
lifecycle exists. The attach contract first obtains a token from
`POST /api/pty/{ptyID}/connect-token`, then opens
`GET /api/pty/{ptyID}/connect` as a WebSocket with a ticket and optional replay
cursor. Shipping it also requires ANSI/VT-compatible rendering, keyboard and
control input, resize propagation, reconnect/replay behavior, and tests that
prove a ticket is never logged or reused.

## Re-evaluation triggers

Re-open the decision when one of these changes:

1. OpenCode publishes a worktree or other currently absent route in its current
   OpenAPI schema.
2. BYOT adopts a maintained terminal-emulation component and can test the full
   PTY ticket, attach, resize, replay, and teardown lifecycle.
3. Issue #7 defines the integration credential UX and storage boundary.
4. Skills gain a user-controlled operation that cannot be performed through a
   normal session.

Until then, the app must not probe guessed routes. An upstream addition starts
as a catalog and contract-test change, then gains transport and UI in a
separate issue-scoped PR.
