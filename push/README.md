# BYOT push notifications

BYOT 1.0.26 adds opt-in alerts for approvals, questions/forms, finished turns, and terminal errors. Tap an alert to open the saved server and session. Requests still require the user to review and answer them in the app.

## Enable notifications

1. Open a saved server’s menu in BYOT → **Notifications** → **Set up notifications**. Allow iOS notifications.
2. On the OpenCode computer, install Node.js 22+ and run the command shown by BYOT:

   ```sh
   curl -fsS https://byot-push.steventsao.workers.dev/byot-notify.mjs -o /tmp/byot-notify.mjs
   node /tmp/byot-notify.mjs setup
   ```

3. Enter the one-time pairing code and local OpenCode URL, username, and password. HTTPS is required except for localhost HTTP. `OPENCODE_SERVER_PASSWORD` is used if already set; otherwise the password prompt is hidden.
4. On macOS, setup offers a per-user LaunchAgent to keep the companion running after login. Otherwise keep `node ~/.config/byot-notify/byot-notify.mjs run` running through a terminal or your service manager.
5. In BYOT, tap **Check connection**, then **Send test notification**. Start a real OpenCode turn and background BYOT. Verify an alert arrives and tapping it opens that session.

Setup stores credentials in `~/.config/byot-notify/config.json` with mode `0600`, under a `0700` directory. It never sends the OpenCode password or URL to the relay. Each iPhone/server pair has separate credentials. Re-pairing replaces that pair’s old sender key. Running setup again restarts the macOS background service to load the new pair.

Disable categories in Notifications or mute an individual session from its menu. **Disconnect notifications** revokes the sender and deletes the active relay subscription. To remove the macOS service, run `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/app.byot.notify.plist`, then remove that plist and the companion’s local configuration if no longer needed. Disconnect each iPhone subscription first.

## What runs where

- **iPhone:** requests permission, registers an APNs token, keeps owner/encryption keys in Keychain, manages preferences, decrypts notification routes, and opens sessions through the existing authenticated OpenCode client.
- **Companion:** observes OpenCode v1 `/global/event` or v2 `/api/event`; fetches authoritative session context; encrypts session routes with AES-256-GCM; persists a bounded local retry queue. Initial legacy idle snapshots and child-session completions stay quiet.
- **Relay:** Cloudflare Worker + D1; separate hashed owner/sender credentials; 96-bit pairing codes valid for 10 minutes; one-time exchange; preferences and session mutes; delivery deduplication; Apple provider-token authentication. APNs private keys exist only in Worker secrets and the developer’s key store.

The relay sees the alert category, timestamp, random identifiers, hashed session identifier, and an encrypted session route. It stores the APNs device token and subscription preferences. Generic alert text excludes prompts, code, titles, and passwords. The route key passes through D1 during pairing and is cleared after exchange or expiry; this is not a claim of cryptographic secrecy from the pairing relay. Delivery records expire after 24 hours. Hourly maintenance cleans expired deliveries and pairing data and unpaired registrations older than 24 hours. Cloudflare operational metadata/backups have platform retention. See [privacy policy](https://byot.app/privacy).

## Live upstream verification

Start `scripts/e2e/fixtures.py` using the pinned CLIs from `scripts/e2e/package-lock.json`, then run `BYOT_PUSH_LIVE_ROOT=/absolute/path/to/fixture npm run test:live` from `push/`. The fixtures must own loopback ports 4195–4199 and use isolated storage. These tests exercise real OpenCode 1.18.29 and 2 beta 19271 SSE, completion alerts, v2 forms/permissions, session lookup, and encrypted routes with a local deterministic model. They do not contact a paid model provider.

## Delivery limits

The computer must remain awake and the companion must stay connected. The upstream SSE stream has no durable replay guarantee, so events emitted while the companion is stopped/disconnected may be missed. Captured alerts persist locally (at most 256) and retry for up to one hour; crash/restart and concurrent writes are covered by tests. APNs acceptance does not guarantee presentation: Focus, system permission, network, and Apple delivery policy apply. Alerts may coalesce within the same session/category. Version 1.0.27 adds the optional durable computer queue described below. No Live Activity or background iOS socket is added.

The installed Apple key is production/topic-specific to `com.steventsao.byot`, covering TestFlight and App Store. Provider authentication and the deployed relay's connection to Apple have been verified using a synthetic invalid device token. Actual iPhone receipt and tap-through still need acceptance testing. Debug builds register sandbox tokens and need a separate sandbox key/deployment for real APNs testing; simulator-injected routing tests do not prove device delivery.

## Relay development and deployment

```sh
cd push
npm ci
npm test
npm run typecheck
npm run build
npx wrangler d1 migrations apply byot-push --remote
# Set APNS_KEY_ID and APNS_PRIVATE_KEY using wrangler secret put through stdin.
# Never commit the key or put it into a command argument.
npm run deploy
```

`GET /health` reports whether provider credentials are configured, never their values; this is not a delivery check. The `Env` type is generated with `npm run types`. Tests use SQLite for real SQL constraints and mock only APNs transport. An additional workerd test exercises real Workers fetch/WebCrypto, verifies the JWT signature, and rejects redirects without forwarding credentials. Workers requires `redirect: 'manual'` with explicit rejection of 3xx responses; `redirect: 'error'` throws before sending the request. Node↔CryptoKit AES-GCM interoperability, tamper rejection, trusted routing, foreground suppression, and cold/warm UI routing are covered in the iOS tests.

Operational checks: verify credential configuration, a current companion heartbeat, device registration, then a real notification on a TestFlight device. A 410 response disables an invalid token. Reopen BYOT and set up/enable notifications to recover after token revocation.

## Durable computer queue (1.0.27)

Update the companion with the setup command and pair it again; its heartbeat advertises queue version 1. In BYOT, session actions → Message queue → Enable computer queue. This opt-in applies to new messages for that saved server. Notifications may be disabled independently; disconnecting the companion revokes and deletes its queue.

The phone atomically saves a protected, backup-excluded outbox before clearing the composer. Encrypted envelopes include the subscription, saved server, session, message ID, revision, attachments, file references, agent/model/variant, and command. Ciphertext uploads in bounded 512 KiB chunks; commit publishes a complete revision. The relay has no upstream password. Its pairing key exchange is described above; encryption is not a claim that the relay can never access content.

Only the authenticated companion can claim jobs. SQLite compare-and-set admits one job per subscription/session, respecting pause and order. The companion checks the authoritative session, pending permissions/forms, and activity before dispatch. A stable message ID reconciles normal prompts across disconnections. A claim is never automatically reissued, even if its response is lost. When a result cannot be proven, the job becomes Needs review and blocks subsequent work until the user reviews and dismisses it. V2 command callbacks have no recoverable message ID; successful acknowledgements finish the callback, while uncertain delivery requires review.

The phone distinguishes Saved on this iPhone from Accepted for computer. Only committed jobs continue with the phone closed. The host must remain awake. Editing/reordering pauses the queue; resume explicitly. Pause prevents new claims, while Stop in the conversation interrupts an already-running turn. Multiple phone subscriptions and other OpenCode clients can submit independently; ordering is per subscription/session.

At most 20 nonterminal jobs per subscription, 20 MiB of attachments per prompt, and 40 MiB of encrypted/base64 envelope per job. Terminal records and abandoned incomplete uploads are deleted after seven days; pending/uncertain jobs remain until resolved. Payloads are excluded from logs. Removing the subscription cascades to all jobs and chunks.

Tests: `npm test`, `npm run typecheck`, and with isolated upstream fixtures running, `BYOT_PUSH_LIVE_ROOT=/absolute/fixture/root node --test tests/queue-upstream-live.mjs`. Live tests restart the runner between checks and verify three ordered prompts and stable admission IDs on both supported protocols.
