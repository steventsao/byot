# OpenCode provider authentication

This implementation mirrors the provider-connection behavior in OpenCode desktop at pinned revision
`3a31c4ea801915c0b050df4b3842997ea62b6e93` while keeping both wire protocols outside SwiftUI.

## Protocol matrix

| Operation | OpenCode v1 | OpenCode v2 |
| --- | --- | --- |
| Discover connections | `GET /provider` plus `GET /provider/auth` | `GET /api/integration` with a location deep-object query |
| API key | `PUT /auth/{providerID}` with `{type:"api",key}` followed by scoped instance disposal | `POST /api/integration/{integrationID}/connect/key` with `{key}` |
| Begin OAuth | `POST /provider/{providerID}/oauth/authorize` with a numeric method index and prompt inputs | `POST /api/integration/{integrationID}/connect/oauth` with a method ID and inputs |
| Complete code OAuth | `POST /provider/{providerID}/oauth/callback` with the method index and code | `POST /api/integration/attempt/{attemptID}/complete` with an optional code |
| Observe automatic OAuth | Callback without a code through the legacy compatibility behavior | Poll `GET /api/integration/attempt/{attemptID}` |
| Cancel OAuth | Not exposed; leaving the flow is local only | `DELETE /api/integration/attempt/{attemptID}` |

The v1 adapter assigns stable string IDs from auth-method indices and synthesizes an API-key method when a provider reports no plugin-specific methods. The v2 adapter filters environment-only methods from the interactive picker and uses the same API-key fallback as desktop.

## Component boundaries

- `OpenCodeProviderConnectionServicing` is the injectable domain-facing contract.
- `OpenCodeV1Adapter` and `OpenCodeV2Adapter` own request paths, query encoding, request bodies, response envelopes, and normalization.
- `OpenCodeProviderConnectionStore` owns selection, conditional prompt inputs, API-key submission, OAuth phases, polling, cancellation, and redacted presentation errors.
- Provider, method, key, prompt, code, waiting, and completion views are independent SwiftUI components driven only by normalized state.

API keys and OAuth codes stay in transient view/store state. BYOT sends them directly to the configured OpenCode server and does not persist or log them.

## Desktop parity behavior

- providers are searchable and show their current connection state when the protocol reports it;
- one reported method is selected automatically, while multiple methods remain explicit;
- OAuth text/select prompts honor `when` conditions before a request is admitted;
- code and automatic/browser authorization use separate states;
- the local catalog is marked connected after a successful mutation, so the model picker can be refreshed without teaching it either authentication protocol.

Contract tests assert the exact v1 and v2 HTTP methods, paths, location queries, and JSON bodies. Store tests use an injected service and contain no networking or SwiftUI dependency.
