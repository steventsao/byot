# BYOT 1.0.27 — durable computer queue

Based on 1.0.26 (main `0f7bc3b`). Opt in from session actions → Message queue after updating and pairing the companion. The queue retains prompts, attachments, file references, model, agent, and variant selections; accepted work runs without the iPhone client. The existing direct-phone mode remains available.

The iPhone saves a protected outbox before clearing the composer. An authenticated Cloudflare/D1 mailbox stores encrypted, revisioned chunks. The companion alone claims ordered work and checks current session activity and approvals before sending. Claimed prompts are never automatically reissued. Lost acknowledgements reconcile against stable upstream message IDs; uncertainty blocks the queue for human review. Edit/reorder pauses the queue; Resume is blocked while changes remain unsent. Stop and history changes pause future work. The companion sends an error-category notification for a queue item needing review.

## Validation

- **242 iOS unit tests passed; 8 existing live opt-in tests skipped.** Six new tests cover disk persistence/relaunch, write failure, lost commit acknowledgement, authenticated ciphertext, bounded attachment uploads, and blocking Resume while unsent content exists.
- **2 new iOS UI tests passed.** A real simulator termination/relaunch restored unsent messages and delivery labels. The queue is reachable from session actions. Screenshots were visually reviewed. An initial landscape test failed because the row was outside the visible list; the corrected portrait/scroll test passed. The three existing push UI tests also passed in the preceding run.
- **23 relay/companion tests passed.** Coverage includes owner/sender separation, atomic revision publication, ordering, pause/edit/cancel races, single claim, restarts, lost acknowledgements, approval/failure blocking, encrypted context validation, and attention alert deduplication.
- **Real upstream acceptance passed:** OpenCode 1.18.29 and OpenCode 2 beta 19271, isolated projects/configuration, deterministic local model. Three prompts executed in order after client submission stopped, with the companion runner restarted between checks and each admission ID appearing exactly once. Local relay tests include attachments and model/agent/variant preservation.
- **Production relay acceptance passed on both upstream versions:** three prompts each completed after the client stopped, no duplicate admissions, synthetic subscriptions removed in `finally`. No Apple alerts were sent by this isolated check.
- Worker type checks/dry build and four website tests passed. Support and privacy disclosures describe encrypted queued content, retention, controls, and the existing pairing-key trust boundary.

The simulator and Node-driven production acceptance do not establish physical-iPhone APNs delivery, every network interruption, or compatibility with untested future server versions. The host and companion must remain awake; incomplete phone uploads require the app to reconnect. V2 slash commands lack a recoverable admission identifier, so a lost command acknowledgement requires review. Ordering is per phone subscription/session.

## Distribution

Release signing, Apple validation, and TestFlight receipts are recorded here as distribution completes. The production schema is additive and old notification clients remain supported. See [operator documentation](../../../push/README.md) for limits and setup.
