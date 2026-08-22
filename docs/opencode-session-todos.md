# OpenCode session todo contract

Issue #3 is implemented against OpenCode commit
[`3a31c4ea`](https://github.com/anomalyco/opencode/commit/3a31c4ea801915c0b050df4b3842997ea62b6e93).

## Snapshot and event sources

Current v1 exposes
`GET /session/{sessionID}/todo` with directory and optional workspace query
parameters. It returns the ordered array defined by
[`packages/schema/src/session-todo.ts`](https://github.com/anomalyco/opencode/blob/3a31c4ea801915c0b050df4b3842997ea62b6e93/packages/schema/src/session-todo.ts):

```json
{
  "content": "Brief task description",
  "status": "pending | in_progress | completed | cancelled",
  "priority": "high | medium | low"
}
```

Both current OpenCode implementations publish `todo.updated`. Its properties
contain `sessionID` and the complete ordered `todos` snapshot. BYOT projects
that event directly into session state, so progress changes do not wait for a
network round trip.

Current v2 has no session todo REST route. The v2 adapter therefore returns no
fetched snapshot without making a request, the capability records the gap, and
reconciliation is forbidden from replacing an SSE-delivered list. This matches
the live-diff policy: delivered data is useful even when upstream lacks a
snapshot route.

## Mobile presentation

- A visible task list adds a compact progress card to the transcript and an
  accessible Tasks toolbar action.
- The detail sheet preserves server order, displays every status and priority,
  and reports resolved progress. Completed and cancelled tasks count as
  resolved; unknown future statuses remain active and are shown verbatim.
- Empty v1 lists stay out of the way. Empty v2 state remains openable and
  explains the upstream route gap instead of implying that the agent has no
  tasks.

Todo decoding, event projection, progress, and snapshot reconciliation are pure
components with no SwiftUI or transport dependency.
