# Composer shell mode

Shell mode runs one command on the selected OpenCode server, in the session's
directory, without sending anything to the model. It is not a terminal: there
is no PTY, input, or interactive program support (see #17).

## Entering and leaving

- Type `!` into an empty composer, as in OpenCode's TUI and web app, or tap the
  terminal button in the composer's controls. The `!` itself is consumed.
- The header names where the command runs ("Runs in *project* on *server*").
  Model, agent, effort, attachments, server files and slash commands are hidden.
- The field turns off autocapitalization and autocorrection, and typographic
  quotes and dashes from the iOS keyboard are converted back to ASCII on submit.
- Leave with the header's close button, the terminal button, or Escape on a
  hardware keyboard. Sending returns the composer to messages.
- The mode is saved with the draft.

## Protocol contract

| Server | Operation | Body |
| --- | --- | --- |
| v1 (verified on 1.18.21) | `POST /session/{sessionID}/shell` with `directory`/`workspace` query | `{command, agent, model?}`; `agent` is required |
| v2 (beta 19242 schema, upstream `d6c22b3`) | `POST /api/session/{sessionID}/shell`, only when the schema lists it with a `command` property | `{command}` |

v1 answers when the command exits (409 `SessionBusyError` while a turn runs) and
streams output through a `bash` tool part, preceded by a synthetic user text
part. v2 answers 204 and reports `session.shell.started` / `session.shell.ended`
events, recorded as a `shell` message with status, exit code and paged output.
A v2 server without the route hides shell mode entirely; BYOT never tries the
v1 route there.

## Transcript

Both protocols render one terminal card: the command, a status (Running, Done,
Exit *n*, Timed out, Stopped, Didn’t run, Unconfirmed) and the last twelve
lines of output with "Show all". v1's synthetic "The following tool was
executed by the user" text is never shown as a user message. A v1 card keeps
its user message id, so Undo and Fork work from its context menu, and undoing
it restores the command in shell mode.

## Busy, stop, and failures

- Commands run only while the session is idle and no other command is in
  flight, matching OpenCode, which never queues shell input. Otherwise the
  header explains why and the command stays in the composer.
- Messages sent while a command runs are queued and released when it finishes.
- On v1 the session reports busy during the run, so Stop aborts the command.
- A refused command (4xx, including busy) shows a "Didn’t run" card and returns
  to the composer in shell mode, unless a new message was typed meanwhile. A
  dropped connection shows "Unconfirmed" because the command may have run, and
  is never retried automatically.
