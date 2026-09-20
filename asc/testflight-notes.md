byot 1.0.27 — queue work and close the app

- Enable the computer queue from a session’s actions menu → Message queue.
- Follow-up messages, attachments, file context, agent, model, and reasoning selections are saved before sending.
- “Saved on this iPhone” means upload is pending. “Accepted for computer” means the companion can run it with byot closed.
- Pause, edit, reorder, and cancel pending messages. Edits and reordering pause the queue; resume when ready.
- Interrupted deliveries reconcile against the session. Uncertain work requires review and is never automatically repeated.

Setup: update the companion using the command in server Notifications settings and pair again, then enable Message queue. Keep the computer awake with OpenCode and the companion running. Queued content passes through the BYOT relay in encrypted form; see the updated privacy policy.

Please queue three messages, wait for Accepted, close byot, and reopen after the turns complete. Also test leaving the session, a connection drop, attachment retention, pause/edit/reorder, and stop. Production relay and real OpenCode 1/2 acceptance are recorded with this release; physical-iPhone background delivery still needs device acceptance.
