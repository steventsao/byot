BYOT 1.0.33 — TestFlight feedback fixes

This build fixes the feedback filed against 1.0.30 to 1.0.32. Everything else is as in 1.0.32.

Please test:

Blank space above the first message
• Start a new session, send a one-line prompt, and watch it through at least three tool steps. The first message must stay just under the header the whole time. No empty block may appear above it, and nothing below it should jump. Queue a follow-up while it works and check again.
• This one could not be reproduced on the iOS 26.5 simulator, so your iOS 27 phone is the real check. If the block is still there, a screenshot with the composer in view tells us most.
• Open a long session. It must still open at the latest message, follow new output while you are at the bottom, and stay put while you are scrolled up. Jump to latest must still work.

Slow connections
• Open a session on a slow link. There must be one "Loading transcript" indicator in the middle of the screen, with no task banner above it. Until the session is ready the header says Reconnecting or Connecting, never Idle.

Composer
• The blue spinner beside the send button is gone, in the one-row and the expanded composer. The microphone and send button must not shift when the session connects.
• Tap Stop during a turn. The button stays a dimmed stop square until the server confirms, then becomes send.
• Focus the composer with a long model name, an agent and an effort level available. Every control must be whole and in view in the one row. When names do not fit, agent and effort become icons (hammer for Build, clipboard for Plan), then the model becomes a chip icon too. Touch and hold an icon to confirm it does the same thing as before.

Session list
• The top right has one menu (⋯). It holds grouping and sorting, Terminal and Status, and Settings. Settings holds Notifications, Edit server, Remove server, Add server and Scan pairing code. Check that each still works, including while the server is offline.
• The selected server chip is neutral, with no green. Check that it still reads as selected in Light and Dark Mode.

Also check the session list menu and the composer row in Simplified Chinese and at the largest text size.
