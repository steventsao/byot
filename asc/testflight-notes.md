byot 1.0.23 — swipe to archive a session

- Swipe a session left in the session list to reveal a red Archive pill, then tap it to archive the session.
- The archived session leaves the list right away and stays hidden after a refresh. If the server rejects it, the row comes back with an error.
- Only one row stays open at a time, and tapping an open row closes it. VoiceOver offers Archive as a row action.
- Archiving works on OpenCode 1 servers. OpenCode 2 beta servers have no archive API yet, so their sessions don't offer the swipe.

Please swipe a session on an OpenCode 1 server, archive it, pull to refresh, and confirm it stays gone. Also check that scrolling the list and opening a session still feel normal.
