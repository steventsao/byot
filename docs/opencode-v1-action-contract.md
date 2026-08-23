# Current OpenCode v1 permission and question contract

This audit resolves issue #1 against OpenCode commit
[`3a31c4ea`](https://github.com/anomalyco/opencode/commit/3a31c4ea801915c0b050df4b3842997ea62b6e93).
The current contract differs from the issue's original endpoint assumption.

## Supported HTTP routes

The non-deprecated v1 action routes in the current
[`openapi.json`](https://github.com/anomalyco/opencode/blob/3a31c4ea801915c0b050df4b3842997ea62b6e93/packages/sdk/openapi.json)
are:

| Operation | Method and path | Body |
| --- | --- | --- |
| List pending permissions | `GET /permission` | none |
| Reply to permission | `POST /permission/{requestID}/reply` | `{ "reply": "once" | "always" | "reject" }` |
| List pending questions | `GET /question` | none |
| Answer question | `POST /question/{requestID}/reply` | `{ "answers": [[String]] }` |
| Reject question | `POST /question/{requestID}/reject` | none |

All collection routes return pending requests across sessions. BYOT therefore
filters them by `sessionID` before publishing state. Directory and workspace
remain instance query parameters.

The schema still contains
`POST /session/{sessionID}/permissions/{permissionID}`, but marks it
`deprecated: true`. BYOT must not prefer or probe that route. The `/api/...`
action routes belong to the v2 adapter and must never be selected from payload
fields received through a v1 route.

`OpenCodeV1ActionContract` owns these paths so protocol tests can assert one
route family without constructing a network client. `OpenCodeV1Adapter` is the
only transport consumer.

## SSE events

Current v1 permission code publishes the schemas defined in
[`packages/schema/src/v1/permission.ts`](https://github.com/anomalyco/opencode/blob/3a31c4ea801915c0b050df4b3842997ea62b6e93/packages/schema/src/v1/permission.ts):

- `permission.asked`: the complete request, including `id`, `sessionID`,
  permission, patterns, metadata, always patterns, and optional tool provenance.
- `permission.replied`: `sessionID`, `requestID`, and reply.

Current question code publishes the schemas defined in
[`packages/schema/src/v1/question.ts`](https://github.com/anomalyco/opencode/blob/3a31c4ea801915c0b050df4b3842997ea62b6e93/packages/schema/src/v1/question.ts):

- `question.asked`: the complete request and `sessionID`.
- `question.replied`: `sessionID`, `requestID`, and answers.
- `question.rejected`: `sessionID` and `requestID`.

Every event includes session provenance inside `properties`. BYOT uses that to
ignore another session's action event, then reconciles the active session from
the collection routes. The event is a refresh trigger, not a second source of
pending-action state.
