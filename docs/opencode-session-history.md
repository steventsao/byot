# OpenCode session history actions

Issue #4 is implemented against OpenCode commit
[`3a31c4ea`](https://github.com/anomalyco/opencode/commit/3a31c4ea801915c0b050df4b3842997ea62b6e93)
and its generated OpenAPI document.

## Protocol matrix

| Operation | v1 | v2 |
| --- | --- | --- |
| Undo from message | `POST /session/{sessionID}/revert` with `messageID` and optional `partID` | `POST /api/session/{sessionID}/revert/stage` with `messageID` and optional `files` |
| Restore rollback | `POST /session/{sessionID}/unrevert` | `POST /api/session/{sessionID}/revert/clear` |
| Compact history | `POST /session/{sessionID}/summarize` with `providerID`, `modelID`, and optional `auto` | `POST /api/session/{sessionID}/compact` |
| Fork | `POST /session/{sessionID}/fork` with optional `messageID` | Not exposed |

V1 calls include the detected instance's directory and optional workspace query.
V2 history calls are global session-ID routes and send no location query. V1
compaction requires an explicit model; v2 compaction does not accept one. The
v2 fork gap is capability-gated before transport, so BYOT never probes a
guessed route.

## Desktop-parity components

`OpenCodeSessionHistoryPresentation` owns message-boundary projection. A
revert hides its boundary turn and every later turn while preserving those
user prompts as a deterministic restore list. It also derives the latest undo
and fork targets and short prompt previews without importing SwiftUI.
`OpenCodeSessionHistoryProjection` retains the pre-revert message prefix while
OpenCode emits cleanup removals, and fails closed when an uncaptured boundary
is absent, so a deleted boundary cannot briefly reveal reverted turns.

`OpenCodeSessionHistoryPolicy` converts protocol capabilities into UI actions.
`OpenCodeSessionHistoryEventProjection` applies current v2 staged, cleared, and
committed rollback events, including file diffs delivered by a staged event.
Transport adapters only translate typed targets and mutations into their
protocol-specific routes.

## Mobile behavior

- The History menu exposes undo, restore, compact, and capability-gated fork.
- A user prompt's context menu can undo or fork at that exact boundary.
- Undo targets explicitly request file rollback; v1 ignores that adapter-only
  field while v2 sends `files: true` to the staged revert route.
- Active execution is interrupted before undo or restore, and queued follow-ups
  are paused before the interrupt request.
- Reverted prompts appear in a restore card modeled after OpenCode desktop's
  revert dock. The card links directly to the resulting diff review.
- Sending a new prompt through an active revert follows OpenCode's implicit
  commit behavior and reconciles the session plus transcript together. This
  covers v1, which does not emit the v2 committed-revert event.
- Successful v1 fork opens the returned session. V2 never displays a fork
  action because no upstream route exists.

Undo and restore invalidate concurrent transcript and diff snapshots before
mutation. A slower refresh therefore cannot replace the mutation result.
