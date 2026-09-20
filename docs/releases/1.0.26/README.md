# BYOT 1.0.26 — background notifications

Tracks [issue #73](https://github.com/steventsao/byot/issues/73).

Adds opt-in APNs registration, per-server notification setup, approval/question/completion/error categories, session mute, test alerts, and trusted tap-to-session routing. A Node.js companion watches OpenCode while iOS is suspended. A Cloudflare Worker and D1 deliver generic alerts without prompts, code, titles, or OpenCode credentials. Encrypted routes use a device-created key exchanged during one-time pairing. This builds on the shipped 1.0.25 rollback; provider onboarding remains removed.

## Validation

- [iOS unit results](unit-tests.json): 236 passed, zero failed; eight existing live-server opt-in tests skipped in this offline run. Six new push tests cover Node-to-CryptoKit encryption, tampering, trusted subscriptions/servers, foreground suppression, test-alert routing, and bounds.
- [UI results](ui-tests.json): all three passed: settings entry, cold notification routing, and switching from an open session to the notification’s saved server. The test harness uses synthetic data. An eager fixture initializer initially caused a render loop; the lazy initializer is corrected in the final source.
- [Relay/companion results](relay-tests.txt): 15 passed, covering SQLite-backed authentication, one-time pairing, revocation, mutes, deduplication, APNs transport responses, SSE parsing, encrypted routes, and retry queue persistence. APNs HTTP is mocked in this suite.
- [Real upstream results](upstream-tests.txt): OpenCode 1.18.29 and 2 beta 19271 passed. Both emitted completion alerts with correct encrypted routes; v2 also emitted a permission and form alert. Servers and model data were isolated; no paid provider was used.
- TypeScript checks and Worker dry builds passed. Four public-site tests passed.
- [Deployed API check](deployed-api-check.json): a synthetic subscription exercised registration, ownership isolation, pairing, sender heartbeat, preferences, and deletion against the production Worker.

## Deployment state

The relay and updated support/privacy pages are deployed. `/health` currently reports `ready: false` because Apple key registration has not been approved yet. The prepared APNs key is restricted to Production and the `com.steventsao.byot` topic; TestFlight uses that environment. Debug/sandbox APNs is not configured.

Signed Release archive built successfully: version **1.0.26**, build **20260919210242**. The first export failed at `codesign` with `errSecInternalComponent` after waiting on Keychain authorization. A follow-up [signing diagnostic](signing-diagnostic.json) verified the distribution certificate trust and expiry, the valid local identity, and a fresh App Store profile with production APNs and the matching certificate. Export has been retried with the same identity. No TestFlight upload or physical APNs delivery is claimed at this stage. Final Apple validation, production entitlements, and distribution receipts will be added after export and upload.

## Acceptance on an iPhone

Use the server menu → Notifications → Set up notifications, allow iOS notifications, and run the displayed command on the OpenCode computer with Node.js 22+. Pair, keep the companion active, send a test alert, then background BYOT during a real turn. Verify approval/question/completion/error alerts and tapping into the correct session. The companion cannot replay events emitted while it was disconnected; captured events retry for one hour. Focus and Apple delivery policies can delay alerts.

See [companion and operator documentation](../../../push/README.md) for setup, revocation, local storage, privacy, and deployment details.
