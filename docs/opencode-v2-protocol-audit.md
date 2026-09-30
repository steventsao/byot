# OpenCode v2 protocol audit

This document maps every HTTP call made by `OpenCodeClient` at BYOT commit
`22f5efe` to OpenCode's current v2 contract. It is the implementation input for
issues #13–#18.

## Audit baseline

- BYOT: [`22f5efe`](https://github.com/steventsao/byot/commit/22f5efe)
- OpenCode: [`3a31c4ea`](https://github.com/anomalyco/opencode/commit/3a31c4ea801915c0b050df4b3842997ea62b6e93), 2026-08-22
- Canonical combined OpenAPI document at that revision:
  [`packages/sdk/openapi.json`](https://github.com/anomalyco/opencode/blob/3a31c4ea801915c0b050df4b3842997ea62b6e93/packages/sdk/openapi.json)
- Protocol source at that revision:
  [`packages/protocol/src/groups`](https://github.com/anomalyco/opencode/tree/3a31c4ea801915c0b050df4b3842997ea62b6e93/packages/protocol/src/groups)

The spec named in issue #11 moved from `packages/protocol/openapi.json` to
`packages/sdk/openapi.json`. The latter currently contains both legacy and v2
routes, so `/api/...` identifies the v2 surface in the table below.

## Result

BYOT does not yet support the v2 session core. Protocol detection and partial
permission/question support exist, but compatibility deliberately rejects v2
before projects or sessions are loaded. The v2 migration is not a path-prefix
swap: request scoping, response envelopes, prompt admission, messages, models,
status, and events all changed shape.

The current upstream contract also invalidates two assumptions from the earlier
v2 spike:

1. `GET /api/health` now documents and returns only `{ "healthy": true }`.
   There is no `pid` or version discriminator in the protocol source. The
   desktop app's current `detectServerProtocol` still checks for `pid`, so BYOT
   must not treat that implementation detail as a durable protocol contract.
2. Current v2 uses `question` routes and `question.v2.*` events. The earlier
   `form` route family is not present in the pinned spec.

## Endpoint map

| BYOT client operation | v1 request | v2 request | Contract changes and implementation status |
| --- | --- | --- | --- |
| Health | `GET /global/health` | `GET /api/health` | v1 includes `healthy` and `version`; pinned v2 exposes only literal `healthy: true`. BYOT already probes both, but its v2 `pid` discriminator is no longer specified. Detection needs a contract-owned strategy (#13), while content-type validation remains required because web fallbacks can return HTML (#19). |
| Experimental capabilities | `GET /experimental/capabilities` | No v2 equivalent | v2 has no capability-negotiation route. Treat the probe as v1-only and derive v2 capabilities from the selected adapter plus successful optional-route probes. |
| Project list | `GET /project?directory=...` | No list equivalent; `GET /api/location?location[directory]=...` resolves one location | The v2 location response is `{directory, workspaceID?, project:{id,directory}}`. It cannot populate BYOT's existing multi-project browser by itself. Preserve the v1 project list and define the v2 onboarding/workspace behavior explicitly in #13. |
| Session list | `GET /session?directory=...&scope=project&roots=true&limit=100` | `GET /api/session?directory=...&limit=100&order=desc` | v2 removes `scope` and `roots`, adds cursor pagination, and returns `{data:[SessionV2Info], cursor:{previous?,next?}}`. Root filtering must be client-side from optional `parentID`. A v2 session carries `location`, `projectID`, token totals, and optional `agent`/`model`; it does not use the v1 directory field directly. |
| Session create | `POST /session?directory=...` with `{title?}` | `POST /api/session` with `{id?, agent?, model?, location?}` | v2 creation has no title input and returns `{data: SessionV2Info}`. Pass `location:{directory,workspaceID?}` and keep title optional only in the normalized domain model. |
| Provider/model catalog | `GET /provider?directory=...` | `GET /api/provider?location[directory]=...` plus `GET /api/model?location[directory]=...` | v1 returns `{all, connected}` and nests models under providers. v2 splits providers and models into location-scoped `{location,data}` envelopes. `ModelV2Info` has `providerID`, `enabled`, status, limits, variants, and capabilities; provider connected-state is absent. Join by `providerID`, filter disabled/disabled-like entries conservatively, and do not claim connection state (#16). |
| Message list | `GET /session/:id/message?...&limit=200` | `GET /api/session/:id/message?limit=200&order=asc` | v1 returns message envelopes containing `info` and `parts`. v2 returns `{data:[SessionMessage], cursor}`; projected user and assistant messages are tagged unions. Assistant `content` embeds text/reasoning/tool items. This requires a v2 decoder and normalization layer before the existing transcript reducer (#13). |
| Prompt send | `POST /session/:id/prompt_async` with `{model?,parts}` | `POST /api/session/:id/prompt` with `{id?,prompt,delivery?,resume?}` | v2 `prompt` is `{text,files?,agents?}`; file inputs use `{uri,name?,description?,source?}` rather than v1 `file` parts. The response is `200 {data: SessionInputAdmitted}`, not an empty success. Model/agent are session state (`POST .../model`, `POST .../agent`) instead of prompt fields. Delivery explicitly supports `steer` or `queue` (#13). |
| Session diff | `GET /session/:id/diff` | No `/api` equivalent in the pinned spec | Neither the earlier workspace-scoped `/api/vcs/diff` nor a session diff route exists in the current pinned v2 surface. Keep the Changes view unavailable for v2 unless a tested fallback is added; track #16. |
| Session status | `GET /session/status` | `GET /api/session/active` | v1 returns all known status values (`idle`, `busy`, `retry`). v2 returns `{data:{sessionID:{type:"running"}}}` for sessions active in this server process; absence means inactive. Normalize present to busy and absent to idle. Retry detail must come from events if exposed (#13). |
| Pending permissions | `GET /permission?directory=...` | `GET /api/permission/request?location[directory]=...` or `GET /api/session/:id/permission` | Location-wide v2 response is `{location,data}`; session-scoped response is `{data}`. `PermissionV2Request` uses `action`, `resources`, optional `save`, metadata, and source instead of the legacy permission shape. BYOT has a partial session-scoped decoder. Consolidate selection in the protocol adapter (#14). |
| Permission reply | `POST /permission/:requestID/reply` | `POST /api/session/:sessionID/permission/:requestID/reply` | v2 body is `{reply,message?}`, where reply is `once`, `always`, or `reject`; success is `204`. BYOT already sends this v2 shape, but selection is attached to decoded requests rather than the detected server protocol. Move routing into the adapter (#14). |
| Pending questions | `GET /question?directory=...` | `GET /api/question/request?location[directory]=...` or `GET /api/session/:id/question` | Current v2 is still `question`, not `form`. Responses are `{location,data}` or `{data}` and `QuestionV2Request` remains a list of questions with optional tool metadata. BYOT has a partial session-scoped decoder (#14). |
| Question reply | `POST /question/:requestID/reply` | `POST /api/session/:sessionID/question/:requestID/reply` | Both use `{answers:[[String]]}` semantically; v2 formalizes `QuestionV2Reply` and returns `204`. Route selection belongs in the adapter (#14). |
| Question reject | `POST /question/:requestID/reject` | `POST /api/session/:sessionID/question/:requestID/reject` | Both have no body; v2 returns `204`. Route selection belongs in the adapter (#14). |
| Event stream | `GET /event?directory=...` | `GET /api/event` | v2 removes instance query scoping and sends `V2Event` over SSE. Current event envelopes retain top-level `id`, `type`, and `properties`, so BYOT's generic envelope can be reused, but the v2 event set adds `permission.v2.*`, `question.v2.*`, and `session.next.*` families and projected message shapes. Heartbeat comment lines are legal SSE and already ignored by the parser. Add event normalization fixtures before enabling v2 (#13, #14). |

`GET /api/session/:sessionID/event` is a second, durable session event stream
with replay (`after`) and a different `SessionDurableEvent` payload. It is not a
drop-in replacement for `/api/event`; evaluate it after core parity because the
global v2 stream is the closest mapping to BYOT's current reconciliation model.

## Cross-cutting model changes

### Location and pagination

Location-scoped v2 routes use the OpenAPI `deepObject` query form, for example
`location[directory]=/repo` and optionally `location[workspace]=...`. Session
listing instead uses top-level `directory`, `workspace`, `project`, and
`subpath` query fields. Session and message list results are paginated and must
not be decoded directly as arrays.

### Responses and errors

Most v2 responses wrap values in `data`; location-scoped responses include both
`location` and `data`. Empty mutation responses use HTTP 204. The v2 spec also
defines structured 400/401/404/409/503 errors, so transport validation must run
before model decoding and preserve the server message when possible.

### Models and providers

The v1 model picker decoder cannot be shared with v2. The v2 catalog is a join
of separate provider and model arrays. Provider connected-state is missing, and
`ModelCapabilities` currently exposes only `tools`, `input`, and `output`; the
v1 `reasoning` and `temperature` flags have no v2 equivalent (#16).

### Messages and prompts

The v2 message projection is a tagged union rather than v1 `{info,parts}`
envelopes. User messages store `text`, `files`, and agents directly. Assistant
messages store text, reasoning, and tool content in a single `content` array.
The v2 prompt input mirrors that projection and returns durable admission
metadata. BYOT should normalize both versions into its existing transcript
domain instead of teaching views about either wire format.

### Events

The pinned global v2 event envelope uses the same generic keys BYOT already
decodes (`id`, `type`, `properties`), but event names and nested models are not
the same contract. In particular, v2 action events use `permission.v2.*` and
`question.v2.*`, and the `session.next.*` family reports durable prompt and
turn progression. Unknown events should remain lossless and harmless while
known events are normalized into transcript/status/action changes.

## TDD-friendly implementation boundary

OpenCode desktop keeps protocol detection and health checks as small functions
with an injected `fetch`, and tests them independently from UI state. BYOT
should adopt the same boundary before adding the v2 core:

1. `OpenCodeTransport` owns URL construction, authentication, MIME/status
   validation, JSON/empty/SSE execution, and can be replaced by a recording
   transport in tests.
2. `OpenCodeProtocolAdapter` owns endpoint paths, query/body encoding, response
   envelopes, and normalization. Implement separate v1 and v2 adapters behind
   the same domain-facing operations.
3. The existing `OpenCodeClient` becomes a small facade selected from the
   detected protocol; stores and SwiftUI views consume only normalized domain
   values.
4. Store one JSON fixture per upstream response/event family and assert both
   decoding and normalization. Route tests assert method, path, query, headers,
   and body without starting a server.
5. Keep transcript reduction and action reconciliation pure. Feed normalized
   events into reducers in unit tests, matching OpenCode desktop's separation of
   reducers/controllers from rendered components.

This makes parity work incremental: each issue can add adapter fixtures and
domain behavior without branching throughout `OpenCodeSessionStore` or SwiftUI.

## Issue sequencing

1. #13: introduce transport/adapter seams; add v2 location, session list/create,
   message list, prompt admission, active status, and event normalization.
2. #14: move permission/question list and reply/reject routing into adapters and
   cover both wire contracts with fixtures.
3. #15: make authentication a transport credential strategy after confirming
   the stable v2 serve contract.
4. #16: gate unavailable diff and provider/model capabilities explicitly; add
   tested fallbacks only where the pinned contract supports them.
5. #17: add selected v2-only surfaces as independent adapter capabilities.
6. #18: validate against a pinned live v2 server and decide the release gate.

Every implementation PR should reference one of these issues, add the failing
contract/domain test first, and keep protocol-specific wire types out of views.
