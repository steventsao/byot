# OpenCode project-file browsing

Issue #5 is implemented against OpenCode commit
[`3a31c4ea`](https://github.com/anomalyco/opencode/commit/3a31c4ea801915c0b050df4b3842997ea62b6e93)
and its generated OpenAPI document.

## Protocol matrix

| Operation | v1 | v2 |
| --- | --- | --- |
| List directory | `GET /file?path=` | Not exposed |
| Read file | `GET /file/content?path=` | Not exposed |
| List changed files | `GET /file/status` | Not exposed |
| Search files | `GET /find/file?query=&type=file&limit=200` | `GET /api/fs/find?location[directory]=…&query=…&type=file&limit=200` |

V1 calls carry the detected instance's directory and optional workspace query.
The v2 search call uses the OpenAPI deep-object location query. Missing v2
tree, content, and status surfaces are capability-gated before transport, so
BYOT does not probe guessed routes.

## Desktop-parity components

The pinned desktop client keeps file protocol access, tree state, search, and
file presentation separate. It loads directories on demand, sorts folders
before files, displays ignored nodes with reduced emphasis, replaces the tree
with debounced search results, and opens selected text in a line-oriented
reader.

BYOT follows the same boundaries with mobile-native presentation:

- `OpenCodeFileBrowserServicing` is the injectable protocol seam used by both
  stores and by their isolated tests.
- `OpenCodeFileBrowserPolicy` maps detected capabilities to supported UI.
- `OpenCodeFileBrowserPath` owns separator-agnostic normalization and relative
  navigation without importing SwiftUI.
- `OpenCodeFileBrowserStore` owns tree, change, and search orchestration. It
  rejects stale navigation and search responses independently.
- `OpenCodeFileContentPresentation` converts text, binary content, and missing
  capabilities into deterministic reader states.
- `OpenCodeFileReaderStore` capability-checks before file transport and owns a
  separate stale-response boundary.

## Mobile behavior

- A folder button in the session toolbar presents the project browser.
- V1 users can browse one directory at a time, walk to a parent folder, open
  files, and switch to changed files with addition/deletion totals.
- Search is debounced and available in both protocols. V2 explicitly starts in
  search-only mode because its tree route is absent.
- Ignored files remain visible with reduced emphasis, matching desktop rather
  than silently changing the server's tree.
- Text preserves blank and trailing lines and renders stable line numbers.
  Binary files and unavailable reads use explicit non-content states.
