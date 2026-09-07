# OpenCode 2 support

BYOT 1.0.8 automatically selects the OpenCode 1 or OpenCode 2 protocol. Existing saved profiles and passwords continue to work; no protocol selector or migration is required.

## Verified upstream contract

- OpenCode 2 executable: `@opencode-ai/cli@0.0.0-beta-19242`.
- Upstream v2 source: [`e15fb426ec593f02f8c6017d78b1c0ec58c8de8a`](https://github.com/anomalyco/opencode/tree/e15fb426ec593f02f8c6017d78b1c0ec58c8de8a).
- OpenCode 1 live baseline: `1.18.21`. Existing compatibility and recovery fixtures also cover `1.18.10`.
- The beta's live `/openapi.json` is pinned in `Tests/Fixtures/opencode2-beta-19242-openapi.json`.

The initial epic inspected upstream `dev`; the published beta follows `v2` and differs materially. The live beta uses flat prompt bodies, forms, text/reasoning parts without IDs, `session.*` events, and permission source `id`. It does not use the earlier dev snapshot's nested prompt body, question API, or `session.next.*` event vocabulary. The server's own schema determines flat versus nested prompts, forms versus questions, project discovery, and optional session titles. Re-probing discards the previous schema contract.

## Reused client behavior

These native Swift implementations follow the upstream client directly:

- [`packages/client/src/solid/data.ts`](https://github.com/anomalyco/opencode/blob/e15fb426ec593f02f8c6017d78b1c0ec58c8de8a/packages/client/src/solid/data.ts): inbox admission IDs, execution lifecycle, assistant steps, last-of-kind text/reasoning updates, tool updates by ID, and snapshot reconciliation after connection.
- [`packages/app/src/session/requests/session-question-dock.tsx`](https://github.com/anomalyco/opencode/blob/e15fb426ec593f02f8c6017d78b1c0ec58c8de8a/packages/app/src/session/requests/session-question-dock.tsx): option values stay distinct from display labels; answers map field keys to scalar or array values; cancellation uses the form cancel route.
- [`packages/schema/src/session-event.ts`](https://github.com/anomalyco/opencode/blob/e15fb426ec593f02f8c6017d78b1c0ec58c8de8a/packages/schema/src/session-event.ts): event payloads and lifecycle boundaries.

BYOT additionally bounds event buffering and deduplication, retains its generation checks against stale snapshots, and preserves v1's hybrid permission/question lists and stalled-session recovery. A queued prompt retains its UUID through retry; v2 sends it as the same `msg_` admission ID. Text/reasoning block IDs are derived consistently for live events and fetched messages.

MIT attribution and the upstream license are bundled in `Sources/Resources/THIRD-PARTY-NOTICES.txt`.

## Supported behavior and limits

Projects (including those without sessions), session creation/list pagination, enabled model selection, prompt attachments, streamed text/reasoning/tools, transcript reload, permissions, forms, and interruption use the appropriate protocol. Forms preserve typed values, defaults, visibility conditions, and basic constraints; the server remains authoritative for format/pattern validation.

The beta does not expose a per-session diff. Its workspace VCS diff cannot reliably be presented as one session's changes. BYOT explains this on the Changes screen and retains any already received changes. Provider connection status is also unreported and identified as such in model selection. Unknown transcript event types reconcile from the server; unknown message types remain visible as descriptive entries.

## TDD evidence

| Cycle | Failing behavior | Fix |
| --- | --- | --- |
| Detection | Minimal v2 health selected v1 | Accept healthy v2 without requiring version/pid; retain explicit v1 aliases |
| Session/prompt/transcript | v1 URLs, nested prompt, required part IDs | Schema-selected adapter and shared normalization |
| Forms/events/projects | Old question route, required event properties, missing worktree | Upstream form mapping, v2 reducer, canonical project directories |
| Pagination | Server rejects order together with cursor | Order only on first page |
| Permissions | Current tool source lacks callID | Decode current id and legacy callID |

Each failing test was committed before its implementation. Local red/green logs and xcresult bundles are retained under `/tmp/byot-*`; exact runs and final release identifiers are recorded in `docs/opencode2-validation.md`.

## Live acceptance setup

`OpenCodeLiveServerTests` and `OpenCodeV2LiveUITests` opt in with `BYOT_LIVE_ACCEPTANCE=1` in the test-run environment. They target isolated local v1/v2 servers through HTTPS, with a deterministic local OpenAI-compatible model fixture. No paid model service or production session is used. Simulator UI tests must use a signed simulator build so saving passwords can use Keychain.

The fixture certificate is trusted only in the test simulator. Production URL validation, redirect protection, HTTPS, and credential storage are unchanged. Physical-device validation requires an available connected device.

## Server setup and rollback

Install the chosen beta CLI with `npm install -g @opencode-ai/cli@0.0.0-beta-19242`. Configure `OPENCODE_SERVER_PASSWORD` in the server environment, then start `opencode2 serve --hostname 127.0.0.1 --port 4097` in the intended project. The tested beta accepts HTTP Basic authentication with username `opencode` and that server password.

Expose that local listener through the existing authenticated HTTPS/Tailscale deployment. Add its HTTPS address in BYOT, optionally set the working directory, and use Test connection. The app discovers the protocol automatically. Keep the current v1 server/profile available during rollout; select it again to roll back. Provider/model configuration remains on the server.
