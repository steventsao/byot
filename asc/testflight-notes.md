byot 1.0.26 — background push notifications

Deployment status: production push delivery is pending APNs provider-key activation. Notification setup and routing can be reviewed now; Send test notification and background delivery require that activation. This note will be updated when delivery is ready to test.

- Get alerts for OpenCode approvals, questions, completed turns, and errors while byot is closed.
- Tap an alert to open its saved server and session.
- Choose alert categories or mute individual sessions. Notifications contain generic text, without your prompts, code, or session titles.

Setup: server menu → Notifications → Set up notifications. Run the copied command on the OpenCode computer (Node.js 22+), enter the pairing code, and keep the companion running. macOS setup can install a background service. Try Send test notification, then complete a real turn with byot in the background.

The companion must stay connected to capture events. Existing model selection and server authentication are unchanged.
