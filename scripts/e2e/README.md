# Upstream OpenCode acceptance tests

Run on a Mac with Xcode, an installed iOS Simulator runtime, XcodeGen, npm, Python 3.9+, and OpenSSL supporting `-addext`:

```sh
scripts/test-opencode-upstream.sh
```

The runner installs the published upstream CLIs pinned in `package-lock.json`: OpenCode 1.18.29 and OpenCode 2 beta 19271. It does not replace the user's global OpenCode installation. Both servers run against fresh project, config, cache, state, and database directories. A local OpenAI-compatible model streams a deterministic response; no paid provider or existing server data is required.

It then creates a dedicated iPhone 17 Pro simulator, trusts a short-lived local certificate in that simulator, builds the normal signed app, and runs all `BYOTTests` plus `OpenCodeUpstreamLiveUITests`. Production HTTPS, authentication, and Keychain code are exercised without a transport mock or app fixture launch argument. The simulator and owned server processes are removed on exit; the `.xcresult`, logs, upstream health/version records, and original screenshot attachments remain in the printed `/tmp/byot-upstream-e2e.*` directory.

The runner needs free loopback ports 4195–4199 and stops if they are occupied. It never terminates an existing listener. `BYOT_E2E_TOOLS` can override the npm cache directory; `BYOT_E2E_DEVICE_TYPE` can select another installed simulator device type. Run one fixture stack at a time. Keep code signing enabled so the server editor can save credentials in Keychain.

## Coverage

- Both protocols: automatic detection, projects and sessions, model discovery, session creation, prompt/response round trip, transcript reload, and HTTPS authentication.
- V2: streamed event reduction, idempotent prompt retry, attachment-only prompts, form answer/cancel, permission approval, and an idle interrupt response.
- UI on both: add/save server, create a chat directly, send/receive, model picker, Changes capability, back to the session list, and reopen the transcript.
- Cross-server UI: horizontal server bar, optional project grouping, selection and password persistence after relaunch, and session isolation when switching v1 ↔ v2.

The live tests are opt-in outside this runner. `BYOT_LIVE_ACCEPTANCE=1`, `BYOT_LIVE_ROOT`, and both version variables are injected into the `.xctestrun` environment. No production build changes are needed for this test setup.

Screenshots are captured by XCTest from the running app and exported after the result bundle is finalized. Release evidence should use these originals, identify the exact upstream versions and app source, and disclose the deterministic model and simulator scope. This run does not establish physical-device, paid-provider, or every future beta's compatibility.
