BYOT 1.0.36 — Session list says "Connecting" while it waits

This build answers the TestFlight question "Why status unavailable?". Everything else is as in 1.0.35.

Please test:

Opening byot while a server is still answering
• Quit byot, then open it on a server whose sessions you have seen before. While byot reaches the server, the saved sessions must say "Connecting", not "Status unavailable". Once the server answers, each row shows its real status (Idle, Working, Needs input).
• Put that computer to sleep, or turn its OpenCode off, and open byot again. After the "Showing sessions saved …" notice appears at the top, the saved rows show no status at all, since none is known.

"Status unavailable" is now kept for a server that answered with an error. That project's error appears in the list with the reason. Also check the list in Simplified Chinese.
