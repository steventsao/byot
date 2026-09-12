# Server-file context

A file chosen from the session’s server is stored as a remote reference with server ID, project ID, directory, workspace ID, exact path and optional inclusive, one-based line range. Local iPhone attachments continue to use their existing data URLs.

Typing an explicit `@query` offers server-file matches. The Server files picker also supports directory browsing and changed files. A preview allows tapping the start and end lines of a selection. Selected context remains visible and removable in the composer. Earlier transcript file references can reopen the same server file and add it to a new prompt.

| Operation | OpenCode v1 | OpenCode v2 |
| --- | --- | --- |
| Search | `GET /find/file` | `GET /api/fs/find` |
| List | `GET /file` | `GET /api/fs/list` |
| Read | `GET /file/content` (JSON) | `GET /api/fs/read/*` (raw bytes) |
| Changed files | `GET /file/status` | `GET /api/vcs/status` |
| Prompt context | `parts[]` with `type:file`, `mime`, `filename`, `url` | `files[]` with `uri`, `name` |

V2 operations are enabled only when the negotiated OpenAPI schema advertises the exact route and method. The pinned beta-19242 schema contains these four filesystem/VCS routes and the file URI prompt contract. Missing operations display an unavailable explanation and issue no fallback v1 request. V2 query locations use `location[directory]` and `location[workspace]`; returned JSON location envelopes must match the selected session scope. Requests never resolve the path against the phone’s filesystem. Cross-project paths and `..` traversal are rejected.

Both prompt generations use an encoded remote `file://` URI; selected lines append `?start=N&end=M`. The beta prompt DTO does not accept `mime`, so it is not added to a v2 reference. Source URI metadata is retained when normalizing v2 snapshots so reconnect, undo and replay can restore the remote reference. The composer pipeline captures the references in its queued prompt and validates scope at submission/dispatch.

File preview downloads use the shared production transport’s bounded streaming read. An oversized Content-Length stops before reading, and unknown-length streams are cancelled on reaching the byte limit. Raw/decoded preview content is limited to 2 MiB. The v1 JSON envelope allows bounded JSON escaping overhead before enforcing the decoded limit. Binary files display their type and size; oversized files can still be referenced without downloading their entire contents.

Contract reference: [OpenCode composer request at d6c22b3](https://github.com/anomalyco/opencode/blob/d6c22b3bf531533980dc633a1dac5e38c64fe458/packages/app/src/composer/request.ts), and `Tests/Fixtures/opencode2-beta-19242-openapi.json`. Current-source routes are not used as evidence of support on an older server.

Validation is in `OpenCodeRemoteFileTests`, `OpenCodeRemoteFileUITests`, and opt-in `OpenCodeRemoteFileLiveTests`. The live fixture creates a separate Git project containing a modified `src/acceptance #%.txt`, which exercises reserved path characters, reading, fuzzy search, directory listing and changed status without affecting a real checkout. The composer live tests cover sending those references and reloading their server representation.
