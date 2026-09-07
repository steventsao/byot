# OpenCode 2 validation and release

Implementation branch: `feat/opencode2-testflight`, based on origin/main `51c88818dab3f5b5914f68c7713b3eed214345ae` (including #49 session recovery).
Tracking epic: https://github.com/steventsao/byot/issues/52

## TDD runs

| Behavior | Red evidence | Green evidence |
| --- | --- | --- |
| Automatic health detection | `/tmp/byot-health-red.xcresult` | `/tmp/byot-health-green.xcresult` |
| Beta session/prompt/transcript contract | `/tmp/byot-beta-red.xcresult` | `/tmp/byot-beta-green-2.xcresult` |
| Forms, live blocks, projects | `/tmp/byot-stream-forms-red.xcresult` | `/tmp/byot-stream-forms-green-1.xcresult` |
| Session pagination | `/tmp/byot-pagination-red.xcresult` | `/tmp/byot-regression-3.xcresult` |
| Permission source IDs | `/tmp/byot-permission-red.xcresult` | `/tmp/byot-signed-regression.xcresult` |

The baseline on latest main passed before implementation (`/tmp/byot-main-baseline.xcresult`). Regression tests retain hybrid v1/v2 action families, independent partial failures, queued prompts, unanswered prompt recovery, abort(false), reconnect ordering, and bounded SSE parsing.

## Live tests

The production iOS HTTPS client passed the real beta contract in `/tmp/byot-live-acceptance-1.xcresult`: detection, catalog, session creation, prompt admission, streaming, normalized snapshot, idempotent retry, form answer/cancel, and idle interrupt.

Final full signed run: `/tmp/byot-final-suite-1.xcresult` (`/tmp/byot-final-suite-1.log`): **156 tests passed, 0 failures, 0 skips** — 70 XCTest tests, 84 Swift Testing tests, and 2 UI tests. This includes real v1 and v2 server turns, beta permission approval, form reply/cancel, idempotent retry, cursor session browsing, model selection, and the UI path from saving a server through creating/opening a session and receiving a reply.

UI evidence: [live beta transcript](screenshots/08-opencode2-live-transcript.png), [Changes availability](screenshots/09-opencode2-session-changes.png).

 Simulator: iPhone 17 Pro, iOS 26.5. Xcode 26.5 (17F42).

An initial UI attempt used `CODE_SIGNING_ALLOWED=NO`, which prevented Keychain writes (`errSecMissingEntitlement`). UI acceptance uses an ad-hoc signed simulator build with the app's development team; production Keychain behavior was not weakened.

No connected physical device was available during this run. Live model output comes from a deterministic local OpenAI-compatible fixture, not a paid model provider.

## Release

- App Store Connect app: `6782403920` (`com.steventsao.byot`).
- Version/build: **1.0.8 (20260907135630)**.
- Signing team verified from BYOT provisioning profiles: `449BD89VDV`.
- Archive: `/tmp/byot-release-1.0.8/BYOT.xcarchive`.
- IPA: `/tmp/byot-release-1.0.8/BYOT.ipa`.
- Archive and export succeeded; bundle ID, version and build were verified in both archive and IPA.
- Apple IPA validation passed with no errors (`/tmp/byot-release-1.0.8/build-retry.log`).
- Build ID: `cf8a442c-51ea-4c48-9dd2-143030652d5e`.
- Processing: **VALID**. Internal state: **IN_BETA_TESTING**.
- Explicit membership verified in **Internal Testers** (`a2c29c92-ddfd-4c22-9368-8563d9b756ea`).
- English What to Test notes verified after upload. External beta review was not submitted.
- Exported IPA has `449BD89VDV.com.steventsao.byot`, `get-task-allow=false`, and contains no test bundles or beta schema fixture.
- Publish log: `/tmp/byot-release-1.0.8/publish.log`.

Additional live attachment acceptance passed in `/tmp/byot-attachment-live.xcresult`: an attachment-only beta prompt with a text file received an assistant reply, and the fetched user attachment retained its filename, MIME type, and data URI. This adds one test to the full 156-test run (**157 passing tests across the final runs**).
