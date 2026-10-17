BYOT 1.0.34 — OpenCode 2.0 and its pairing codes

This build connects to OpenCode 2.0 releases and reads OpenCode's own pairing codes. Everything else is as in 1.0.33.

Please test:

OpenCode 2.0 servers
• Update a computer to OpenCode 2.0 (npm i -g @opencode/cli, 2.0.32 or later) and connect to it. Earlier builds stopped with an "unexpected content type" error; this one must connect, list sessions, and run a prompt.
• Answer and cancel a question form the agent asks. Cancel must close the form without an error.

Pairing with opencode pair
• On the computer run: opencode pair --remote. In byot, Settings › Scan pairing code (or Add server › Scan pairing code), scan the QR code. byot shows "Connecting to OpenCode…", then fills the form. Tap Save. Try it on mobile data, away from your Wi-Fi.
• Also try plain opencode pair (no --remote) on the same Wi-Fi or Tailscale, and paste one of the printed links with Paste instead of scanning.
• Scan the same QR code twice. The second time must say the code was already used, and a new code must still work.
• Run opencode pair again later and scan the new code for a saved server. It must update that server, not add a duplicate.

OpenCode 1 servers and byot-pair-qr.sh codes must work as before. Also check the scan page in Simplified Chinese.
