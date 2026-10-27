BYOT 1.0.37 — Reliable refresh when returning to the app

This build follows up on the connection-status feedback. Leaving the session
list or switching apps during a refresh should no longer turn a cancelled
request into a connection error. Optional usage diagnostics also stop counting
cancelled session-list loads as network failures.

Please test:

- Open a saved server, then quickly open a conversation or switch away from
  byot while the list refreshes. Return to byot and confirm the sessions reload
  without a "cancelled" error or a false offline notice.
- Repeat on a slow connection. Existing sessions should remain available while
  the new request finishes, and a newer refresh should win over an older one.
- Put the server to sleep or turn off its network. A real connection failure
  must still show its explanation, and saved sessions should remain readable.
  Wake the server and use Retry to reconnect.
- On a cold launch, saved sessions still say "Connecting" until their status
  arrives; they should not say "Status unavailable" just because it is loading.
- Open a conversation on a slow connection. Check that the loading indicator
  stays centered, the first message starts near the top, and no empty message
  rows appear while the reply streams. Please check these on iOS 27 as well.
