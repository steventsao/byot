# OpenCode server context and settings

This slice is pinned to OpenCode commit `3a31c4ea801915c0b050df4b3842997ea62b6e93` and its generated `packages/sdk/openapi.json`.

## Protocol contract

OpenCode v1 exposes these location-scoped routes. Every request carries the optional `directory` and `workspace` query values:

- `GET /config` and `PATCH /config`
- `GET /vcs`
- `GET /path`
- `GET /mcp`
- `GET /lsp`
- `GET /formatter`

Configuration updates send the complete JSON object. BYOT therefore edits and round-trips `[String: OpenCodeJSONValue]`; it does not project the document into a lossy list of known settings.

The current v2 protocol exposes only `GET /api/location`, scoped with `location[directory]` and `location[workspace]`. Configuration, VCS, MCP, LSP, and formatter sections are declared unavailable locally. The client never probes guessed `/api` routes.

## Components and test seams

- `OpenCodeServerContext` owns normalized, protocol-independent models and the lossless JSON document codec.
- `OpenCodeServerContextServicing` is the injectable transport boundary.
- `OpenCodeServerContextStore` loads each supported section independently and keeps unavailable or failed sections explicit.
- `OpenCodeServerContextView` separates read-only server status from editable settings.
- Contract tests pin exact routes, query scopes, bodies, response shapes, and the v2 no-probe boundary. Store tests cover partial availability and validated saves without SwiftUI or networking.
