# OpenCode commands, shell, and agents

Issue #6 is implemented against OpenCode commit
[`3a31c4ea`](https://github.com/anomalyco/opencode/commit/3a31c4ea801915c0b050df4b3842997ea62b6e93)
and its generated OpenAPI document.

## Protocol matrix

| Operation | v1 | v2 |
| --- | --- | --- |
| List commands | `GET /command` | `GET /api/command` with deep-object location |
| Execute command | `POST /session/{sessionID}/command` | Not exposed |
| Run shell command | `POST /session/{sessionID}/shell` | Not exposed |
| List agents | `GET /agent` | `GET /api/agent` with deep-object location |
| Select agent for a prompt | `agent` in `POST /session/{sessionID}/prompt_async` | `POST /api/session/{sessionID}/agent` before prompt admission |

V1 instance calls carry directory and optional workspace query values. V2
catalogs use the generated deep-object location query. Missing v2 command and
shell execution are capability-gated before transport.

## Desktop-parity components

The pinned desktop composer keeps command discovery, input mode, agent choice,
and submission orchestration separate. A leading slash becomes a command only
when its name is registered; otherwise it remains ordinary prompt text. Shell
mode is explicit, and a queued turn captures the agent and model selected when
the user submits it.

BYOT follows those boundaries:

- `OpenCodeSessionInputServicing` isolates catalog loading for deterministic
  store tests.
- `OpenCodeSessionInputPolicy` maps protocol capabilities without exposing
  routes to SwiftUI.
- `OpenCodeSessionInputParser` produces typed prompt, command, or shell intent.
- `OpenCodeSessionInputStore` owns catalogs, picker filtering, selection, and
  capability validation.
- `OpenCodeQueuedPrompt` captures typed intent, agent, and model so follow-ups
  preserve submission-time choices.
- Protocol adapters translate typed input into exact v1 or v2 operations.

## Mobile behavior

- The composer exposes compact model, agent, command, and shell controls.
- Hidden and subagent-only agents do not appear in the primary-agent picker.
- The command sheet shows server descriptions and argument hints. On v2 it
  remains inspectable but explicitly disables execution with the schema gap.
- Shell mode changes the field prompt and returns to normal mode after submit.
- Shell responses are synchronous, so the next queued turn is released without
  waiting for an AI activity event. Prompt and slash-command turns retain the
  existing activity-confirmed FIFO behavior.
