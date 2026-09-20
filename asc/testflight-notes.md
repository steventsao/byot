byot 1.0.26 — background push notifications

- Get alerts for OpenCode approvals, questions, completed turns, and errors while byot is closed.
- Tap an alert to open its saved server and session.
- Choose alert categories or mute individual sessions. Notifications contain generic text, without your prompts, code, or session titles.

Setup: server menu → Notifications → Set up notifications. Run the copied command on the OpenCode computer (Node.js 22+), enter the pairing code, and keep the companion running. macOS setup can install a background service. Try Send test notification, then complete a real turn with byot in the background.

The companion must stay connected to capture events. Existing model selection and server authentication are unchanged.
