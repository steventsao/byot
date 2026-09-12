# Session lifecycle, recovery, and tasks

The native session menu opens details, related conversations, task progress,
and history controls. Details supports renaming and a confirmed delete (including
child sessions); active work must be stopped before deletion or history changes.
A child opens using its own server-provided directory and workspace. Its details
can reopen the parent. Forking can copy the current visible history, or start
before a selected user prompt using that prompt's context menu.

## Verified contracts

V1 uses the established `GET/PATCH/DELETE /session/{sessionID}`,
`GET /session/{sessionID}/children`, `GET /session/{sessionID}/todo`,
`POST .../revert` with `messageID`, `POST .../unrevert`, `POST .../summarize`
with `providerID`/`modelID`, and `POST .../fork` with optional `messageID`.
Requests retain the current directory and workspace. Summarize requires an
explicit selected model. V1 cleans a staged revert when the next prompt starts.

V2 is validated against the checked-in beta 19242 OpenAPI contract, the
installed beta 19271 acceptance fixture, and upstream commit
[d6c22b3](https://github.com/anomalyco/opencode/tree/d6c22b3bf531533980dc633a1dac5e38c64fe458).
Operations are disabled when their routes are absent from the negotiated schema.
The service never guesses v1 routes on a v2 server.

| Operation | V2 contract |
| --- | --- |
| Details/delete | `GET/DELETE /api/session/{sessionID}` |
| Rename | `POST .../rename` with `{title}`, then reread details |
| Children | Paginated `/api/session` with advertised `parentID`, otherwise filter project pages locally |
| Undo | `POST .../revert/stage` with `{messageID, files:false}` |
| Redo | Stage the next user boundary, or `POST .../revert/clear` |
| Continue after undo | `POST .../revert/commit`, before dispatching revised prompt |
| Compact | `POST .../compact` with `{}` (admission response, not completion) |
| Fork | `POST .../fork` with `boundary:{type:"before",messageID}` or `{type:"through"}` |
| Tasks | No HTTP snapshot in this beta; no request sent |

V2 undo changes conversation history and explicitly leaves files unchanged.
The staged boundary remains reversible until a revised prompt commits it.
The client retains user boundaries when a staged-history fetch excludes undone
turns; a reopened session without those boundaries can still clear its revert.

Local queued prompts pause before history changes and remain available for
manual review. A revised prompt dispatches ahead of that paused queue and keeps
it paused. V2 undo/redo reads the authoritative inbox and cancels pending user
admissions before staging/clearing; inability to read/cancel fails the action
without moving the boundary. The server still rejects a concurrent running
session. The protocol has no cross-client transaction combining cancellation
and staging, so a prompt admitted simultaneously by another client may race.

## Task reconciliation

V1 fetches an ordered authoritative todo snapshot. `todo.updated` replaces the
whole list only for the current session. Status and priority remain server
values; unknown future status values remain unresolved and are shown verbatim.
An event delivered while a snapshot is loading wins over that stale snapshot.
`server.connected` triggers a fresh snapshot. V2 preserves actual delivered
updates and explains missing snapshots, distinguishing unavailable from empty.
Disconnection marks retained progress stale until fresh data arrives.

## Validation

`OpenCodeSessionFeatureTests` covers exact lifecycle/action requests, scoped
queries, unsupported v2 no-network behavior, authoritative inbox failure,
todo-event ordering and reconnect, multi-step undo/refresh/redo with omitted
reverted snapshots, local queue safeguards, revised-prompt commit ordering,
and rename/fork/delete state.

`OpenCodeLiveSessionFeatureTests` opts into `BYOT_LIVE_ACCEPTANCE=1` through
`scripts/test-opencode-upstream.sh`. It exercises the production negotiated
transport against isolated v1 1.18.29 and v2 beta 19271, including actual
rename/delete/fork/revert/clear/compact responses and v2 commit then revised
prompt. Simulator runtime results belong to the integrated release report;
build-for-testing is not evidence that these live tests ran.
