# Provider authentication on iOS

Connect provider is available from the server's session list and the model picker, including when no models are connected. Authentication methods, labels, prompts, and method IDs come from the selected server. Connecting changes that server's provider access. Provider credentials are sent through its existing authenticated HTTPS transport and are never saved to app preferences or logged.

ChatGPT headless/device sign-in is recommended when advertised. The authorization screen displays the server's instructions/code and an HTTPS link to the provider in the system browser. The OpenAI browser method is disabled with an explanation: its localhost callback targets the server computer and cannot finish on a remote iPhone. No method index is hardcoded. API keys, code callbacks, automatic completion, conditional text/select prompts, search, retry, cancellation, and model reload are supported. Server Basic authentication remains separate.

## Wire contracts

| Operation | v1 (1.18.29) | v2 (beta 19271) |
| --- | --- | --- |
| Discovery | GET /provider + /provider/auth | GET /api/integration |
| API key | PUT /auth/{providerID}, `{type:"api",key}` | POST /api/integration/{integrationID}/connect/key, `{key,answer?}` |
| OAuth start | POST /provider/{providerID}/oauth/authorize, `{method: numericIndex,inputs}` | POST /api/integration/{integrationID}/connect/oauth, `{methodID,answer}` |
| Complete | POST /provider/{providerID}/oauth/callback, `{method,code?}` | POST /api/integration/{integrationID}/connect/oauth/{attemptID}/complete, `{code?}` |
| Automatic | Long-running callback without code | GET provider-scoped attempt |
| Cancel | No server cancellation; stop local waiting | DELETE provider-scoped attempt |

v1 disposes the scoped instance after successful credential changes so the catalog reloads. False callback/key results are rejected. v2 uses location deep-object query parameters and location/data response envelopes. Older v2 attempt routes and `inputs` payloads are used only when explicitly advertised in that server's schema. Missing routes are actionable unsupported states. Unknown method types are not treated as API keys; key fallback is available only for an empty method list. v2 form types beyond string/select are explicitly unavailable.

On backgrounding, iOS cancels local polling; foregrounding reconciles newly connected providers before retrying the status request. This covers v1 completing its callback while the phone is suspended. A transient error preserves the attempt and offers Check again or Start again. Terminal failed/expired attempts return to a restartable state. v2 cancellation is attempted on leave; v1 cancellation is not promised. Attempt details are in memory only; after process termination the user can reopen the picker to see the refreshed catalog or begin a new attempt.

Server error bodies are not echoed into auth UI, and authorization links require HTTPS without URL credentials. Unrecognized forms/routes fail closed. Arbitrary API key validity is determined by the provider when it is used; storing a key on OpenCode does not independently validate it with the provider.

## Verification

- Focused service tests cover v1 numeric method mapping, key/callback bodies, disposal, v2 scoped attempts and form answers, unsafe URLs, missing routes, false success, and error-body redaction.
- State tests cover conditional inputs, duplicate submission, stale results, failed/expired attempts, cancellation, and foreground reconciliation.
- UI fixture tests cover the empty picker, invalid-key retry, device instructions, app background/foreground, and model refresh. Fixtures are DEBUG only and use synthetic credentials.
- Live tests use disposable OpenCode 1.18.29 and beta 19271 servers with isolated data directories. Synthetic keys never contact real provider APIs.

A separate real ChatGPT account acceptance is required on a physical phone: select a remote server, open Connect provider → OpenAI → headless, open the displayed link in Safari, enter the displayed code and authorize, return to byot, and verify OpenAI models and a prompt. Do not publish account codes, tokens, or browser screenshots containing them. This manual account test is not claimed by fixture or synthetic-key tests.

References: [OpenCode server API](https://opencode.ai/docs/server/#provider), [ChatGPT browser/device implementation](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/plugin/openai/codex.ts).

Run the isolated auth acceptance (including the synthetic OAuth plugin) with:

```sh
BYOT_PROVIDER_AUTH_FIXTURE=1 scripts/test-opencode-upstream.sh \
  -only-testing:BYOTTests/OpenCodeProviderAuthLiveTests \
  -only-testing:BYOTTests/OpenCodeProviderAuthServiceTests \
  -only-testing:BYOTTests/OpenCodeProviderConnectionStoreTests \
  -only-testing:BYOTTests/OpenCodeProviderConnectionPolicyTests \
  -only-testing:BYOTUITests/OpenCodeProviderAuthUITests
```
